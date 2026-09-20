# CarPlay 第二屏日志设计规范

## 范围与目标

本文约束本项目新增的 hook、HMI Java 控制器、mirror sidecar、启动脚本、操作日志和诊断采集。OEM 自己的 `CinemoDioManager.log` 仍由 OEM 写在 `/tmp`；本项目只在启用诊断时复制它的增量。

日志是证据，不是协议状态。任何日志路径不可写、队列满、SD 卡拔出或空间耗尽，都不得改变原有 iAP2 协商、type 111 转发、解码、显示、Context 80 或启动/停止命令的返回值。持久日志的写入顺序为：已选中且可写的测试 SD 卡 → 车机 `/tmp` → 丢弃。启动诊断在挂载发现前仍需要 `/tmp` 暂存探针、游标和快照，发现 SD 后持续复制或直接写入；这些临时工作文件不保证只在 SD 上出现。生产线程只做有界内存操作；文件系统操作放在异步日志线程或独立脚本中。

## 路径和归属

SD 卡必须同时有 `Toolbox/` 和 `MMI-Cockpit-Carplay/state/`，日志目录为该卡的 `MMI-Cockpit-Carplay/logs/`。候选挂载点按 `/net/mmx/fs/sd{a,b}{0,1}`、`/fs/sd{a,b}{0,1}` 的既定顺序查找。hook 一旦选中权威卡，本进程不切到另一张卡；卡不可写时降级到 `/tmp`。`state/` 下的 `direct111_tap_stop.state` 是控制状态，**不是日志**，不参与轮转，也不计入日志预算。PID、FIFO、ready、gate 等运行状态也保留在 `/tmp`。

| 生产者 | SD 主文件 | SD 轮转上限 | `/tmp` 回退 | 写入方式 |
| --- | --- | ---: | --- | --- |
| 原生 hook | `altscreen_hook.log` | 20 MiB × (当前 1 + 历史 15) = 320 MiB | `MMI-Cockpit-Carplay/altscreen_hook.log`，16 MiB 后停止 | 256 槽、每行 768 字节的内存队列；单个后台线程写盘 |
| mirror sidecar、启动器、生命周期监视器 | `mirror.log` | 20 MiB × (1 + 15) = 320 MiB | `MMI-Cockpit-Carplay/mirror/mirror.log` 等原有路径，单文件 16 MiB 后重置 | stdout/stderr 非阻塞；FIFO 后面的 `altscreen_log_ring.sh` 写盘 |
| Java Context 80 控制器 | `mmi-mirror-controller.log` | 8 MiB × (1 + 3) = 32 MiB | 原有 `DIAG_FILE`，128 KiB 后重置 | 128 槽内存队列；daemon 线程写盘 |
| 启动入口 | `boot-entry.log` | 1 MiB × (1 + 2) = 3 MiB | 既有 boot entry 临时文件 | `altscreen_log_ring.sh pipe boot-entry` |
| 启动、实时、自适应、操作诊断 | `boots/`、`adaptive/`、`operations/` 等 | 纳入全局清理；单次采集块/探针输出另有限制 | 原有 `/tmp` spool；采集失败可丢弃 | 独立观察脚本，不在 CarPlay 回调运行 |

前四项固定槽合计最多约 675 MiB。`altscreen_log_ring.sh prune` 在诊断及操作周期扫描日志树，超过 896 MiB 时按修改时间删除最旧的诊断/历史文件，保留前四项的当前文件、轮转文件及游标；余下 128 MiB 留给并发写入。此机制是**运行时清理目标**，不是文件系统级硬配额：检查之间的大批量并发诊断写入可能短时超过 1 GiB。需要物理上绝对不能越过 1 GiB 时，须在 SD 分区层另设配额或让所有生产者共用一个带预留计数的写入服务，不能仅凭当前 `prune` 声称硬上限。

1 GiB 按连续 1 小时计算约为 291 KiB/s 的**总平均**写入预算。单个流会更早覆盖自己的历史段；高于这个速率、队列溢出、卡断开或诊断清理都会缩短可回溯时间。因此“约 1 小时”是容量估算，不是保留承诺。逐帧视频探针按 30 fps、两端各约 250 字节估算约 15 KiB/s；再加原有日志仍须以实车写入量核对留存时长。

## 显示链路延迟与稳定性探针

decoded SHM 使用 **v2**；hook 与 sidecar 必须配套安装。版本不匹配时 sidecar 拒绝附着，不会把旧布局当新帧读取。每个三槽帧都有独立时间元数据，生产者先写数据及元数据，再发布 `sequence`；消费者在拷贝后复查 writer、generation、cookie、sequence 和 slot。所有跨进程时间是同一车机 `gettimeofday` 的微秒值取低 32 位，模 2^32 相减；0 或差值超过 5 秒视为无效并记 0。车机系统时间跳变可能使单帧样本失效，不影响图像。

| 事件 | 频率 | 产生位置 | 关键字段与含义 |
| --- | --- | --- | --- |
| `FRAME_DECODE_TIMING` | 每个**成功发布**的解码帧一次 | hook 的 `p111_frame_tap_write` | `gen/seq` 关联键；`h264_seq` 最近压缩包；`decode_proxy_us` 最近 H264 包进入至解码回调开始；`readback_us` Screen 同步读回；`render_to_publish_us` 回调开始到 SHM 发布；`frame_interval_us` 相邻发布间隔 |
| `FRAME_PRESENT_TIMING` | 每个**成功 EGL 呈现**的帧一次，含首帧 | sidecar `display.present_frame` 返回后 | 同一 `gen/seq`；`publish_to_copy_end_us`、`copy_us`、`copy_to_present_us`、`present_call_us`、`publish_to_present_us`、`input_to_present_proxy_us`、`present_interval_us`、`instant_fps100`。`fps100=3000` 表示 30.00 fps |
| `FRAME_CHAIN_HEALTH` | 主循环每 60 秒一次，**停帧期间也运行** | sidecar | 区间 H264 包、解码、拷贝、呈现数及真实时间窗 `decoded_fps/present_fps`；序号跳过、H264/decoded 丢弃、读竞争、停顿次数、四项最大延迟 |
| H264、线性化、解码、消费进度 | 有持续活动时约每 60 秒一次 | hook / sidecar | 累计计数、读回 p50/p95、fallback 和失败数；首次成功、错误和恢复继续单独报告 |

`decode_proxy_us` 和 `input_to_present_proxy_us` **不是精确解码耗时**：当前 stock OMX 回调没有暴露与输入 NAL 一一对应的 PTS，压缩包可能合帧、重排或已经属于下一帧。它们只能作为链路等待时间的趋势指标。`readback_us`、`copy_us`、`present_call_us`、`publish_to_present_us` 是各边界实测值；`present_call_us` 到 `eglSwapBuffers` 返回为止，不等于屏幕实际发光时刻。需要精确 H264 包到画面耗时，须在 decoder 输入和输出取得同一帧标识后扩展协议，不能从当前日志反推。

逐帧日志在 hook 只进入有界异步队列，在 sidecar 只写非阻塞 FIFO。队列或 FIFO 满时可缺行，因此评估丢帧要同时看 `seq` 差、`FRAME_CHAIN_HEALTH` 计数与 `LOG_QUEUE_DROPPED`，不能把缺失日志行直接判为视频丢帧。主链路不能等待这些日志落盘。`FRAME_LINEARIZER_SLOW` 与 NV12→RGBA fallback 重复警告按一分钟节流；连续停顿超过 250 ms 才发停顿事件，恢复时发一次恢复事件。

## 写入和轮转流程

1. 启动时按上面的权威卡规则探测 SD；目录和写入都成功才使用 SD。
2. hook/Java 将格式化后的短行入队；满队列直接丢证据并累计 `LOG_QUEUE_DROPPED` 或 `DIAG_QUEUE_DROPPED`，不等待磁盘。mirror 的 stdout/stderr 设为非阻塞，FIFO 满时允许丢诊断文本。
3. 后台写入者在当前文件写满前换段。hook 使用 `altscreen_hook.log.00` 到 `.14`；Java 使用 `.0` 到 `.2`；shell sink 使用 `mirror.log.0` 到 `.14` 并用 `.mirror.cursor` 选择下一槽。shell 对同一流用原子 `mkdir .mirror.lock` 序列化检查、换段和追加；锁忙或残留时本行退到 `/tmp`。
4. 卡打开、换段或追加失败时尝试 `/tmp`；`/tmp` 也失败就丢弃，不向协议层返回错误。hook 每处理 64 行重试 SD，Java 每行重试，shell 每行重新探测。
5. `prune` 只删除本卡 `logs/` 下的可清理文件；原生 hook、mirror、Java、boot-entry 四个固定环由各自写入者限长。诊断快照不复制已直接写在 SD 的 hook/mirror 当前文件，避免重复占空间。

`PHASE=HOOK_LOG_SEGMENT` 只是新段标记。读取端可据此知道文件已换段，但**不得**把它当作新的 CarPlay 会话或清空已接收的手机 type 111 请求。读取端还必须在 inode 变化或文件变短时重开文件，并同时考虑 SD 和 `/tmp` 的回退日志。

## 生命周期信号与协议隔离

真实的 `PHASE=DIRECT111_TAP_STOP stream=...` 在 hook 生产线程只递增原子事件序号。即使普通日志队列已满，后台线程仍会把新的事件号、进程号、`run_id` 和时间写到 `direct111_tap_stop.state`；使用同目录临时文件加 `rename` 原子发布，先试 SD `state/`，再试命名空间 `/tmp`，最后试平面 `/tmp`。写失败继续异步重试。`_STALE` 事件不更新标记。

启动器在启动 sidecar **之前**读取三个候选标记作为基线。生命周期监视器只比较标记内容是否变化；变化时才终止本次 sidecar，并按现有 demand/stop guard 规则决定是否重启。它不再每秒扫描高达 320 MiB 的循环日志，也不把日志行数当作停止事件。日志可缺失，但状态标记可写时停机语义仍可工作；SD 与 `/tmp` 同时不可写时，任何文件式跨进程通知都无法保证送达，这属于设备存储故障边界。

## 后续新增日志的要求

1. 明确生产者、最大行长、最大速率、SD 槽数与总预算；不要直接无限追加到 `logs/`。增加固定环容量时重新核算 675 MiB 基线和 1 GiB 目标。
2. C/Java 实时或回调线程只入有界队列；禁止 `fopen`、`FileOutputStream`、`fsync`、`du`、`find`、轮转和 SD 探测。shell 非实时脚本优先复用 `altscreen_log_ring.sh`，同一流的并发生产者必须经同一锁。
3. 日志失败必须吞掉在诊断层，不能改变 stock forward、协议门控、帧消费、Context 80、启动/恢复/停止的控制返回值。不要依赖日志文本、换段次数或日志是否可写来控制生命周期；必要事件应另设小型状态标记。
4. 行中保留会话标识或 `run_id`、阶段名和可读时间；不得默认记录完整视频帧、iAP2 私有 payload 或其他大块敏感数据。单行要限长；新增逐帧探针须说明必要性、每帧最多几行与带宽预算，其他进度用一分钟计数或抽样。
5. 提交前运行 shell 语法检查、C/C++/Java 源码语法检查、`tests/test_log_ring.sh`、`VERIFY-NATIVE-DIRECT-RELEASE.sh`，覆盖 SD 正常、锁忙、卡消失、`/tmp` 不可写、换段、队列满、旧停止标记及新停止标记。修改发布文件后更新 `SHA256SUMS`、根 `SHA256SUMS.txt` 和 `PACKAGE_SOURCE_MAP.json`。
6. 车机发布必须用目标 QNX 工具链重建 hook 与 sidecar、用 Java 1.2 兼容工具链重建 HMI JAR，然后做真机启动、协议、显示及拔卡验证。源码静态检查不能代替该门槛。
