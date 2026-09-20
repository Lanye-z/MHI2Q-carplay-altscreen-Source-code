> **移植说明（experiment/oem-layout-second-screen）**  
> 下文主体来自 yuedizhibo 日志增强版 2026-09-20 的静态审查记录，用于说明设计来源。当前分支已经把对应源码/脚本与 OEM_LAYOUT_OBSERVER_V1 融合，但**尚未进行本次合并后的统一编译**；因此凡下文写“已重建/READY”的结论均只属于上游原始版本，不能作为当前分支发布结论。当前分支以 BUILD_INFO 中的 `*_REBUILD_REQUIRED` 为准。

# 日志改造静态审查与主机验证

审查日期：2026-09-20。范围：第二屏 hook、mirror sidecar、Java Context 80 控制器、启动/恢复/停止脚本及诊断采集。本次变更重建 hook 与 sidecar；HMI JAR 源码和产物沿用 2026-09-19 已验证版本。主机验证结论不代替实车运行结果。

## 链路不变量检查

| 链路阶段 | 日志故障隔离检查 | 结果 |
| --- | --- | --- |
| hook 初始化与 iAP2/type 111 生产回调 | `altscreen_log()` 仅写有界内存队列，锁冲突/满队列立即返回；SD 打开、写入、轮转在独立线程，失败转 `/tmp` 后可丢弃。真实 TAP_STOP 的原子事件号先于队列判断递增。 | 源码通过 |
| 手机请求门控 | sidecar 同时读取 SD、命名空间 `/tmp`、平面 `/tmp`；inode 改变或文件缩短时重开。`HOOK_LOG_SEGMENT` 不清空待消费请求，真正 `HOOK_INIT` 才重置会话候选。 | 源码通过 |
| 视频解码与显示 | sidecar stdout/stderr 设非阻塞；FIFO/SD 日志阻塞或满时允许丢文本，主帧路径不等待日志读者。 | 源码通过；目标 QNX 行为待验证 |
| 逐帧遥测 | hook 每个发布帧入队一个短事件；sidecar 每个成功呈现帧用单次非阻塞 `write` 发一个短事件。失败不会改帧返回值。 | 源码及 ARMv7 构建通过；车机吞吐待量测 |
| SHM v2 帧时间 | 三个槽各有独立时间元数据，随 NV12 和图像元数据一起在 `sequence` 发布前写入；读端拷贝后再次校验完整会话身份和序号。旧版本因版本检查拒绝附着。 | 布局夹具、源码和目标编译通过 |
| Java Context 80 | `diag()` 只构造短行并写入 128 槽队列；后台 daemon 写 SD 或 `/tmp`，异常被诊断层捕获。 | 源码及 Java 1.2 major 46 重建通过 |
| 生命周期停止与重启 | hook 的 TAP_STOP 状态标记在异步线程原子替换，日志队列满仍保留事件号；监视器比较启动前基线与新标记，不扫描环形日志。旧标记不会触发停止。 | 源码与主机夹具通过 |
| SD 无法写入、锁忙、卡消失 | shell sink 转 `/tmp`；日志子进程失败不会使启动脚本或 sidecar 因 SIGPIPE 退出；双路径失效后丢诊断。 | 源码与主机夹具通过 |
| 容量 | 四个直接轮转流合计约 675 MiB，诊断清理阈值 896 MiB，留 128 MiB 缓冲。 | 运行时目标通过；**严格瞬时 1 GiB 硬上限未证明** |

控制标记仍依赖文件系统：SD 与 `/tmp` 同时不可写、后台写入线程无法创建，或者底层文件系统调用永久卡住时，跨进程停止通知可能延迟或丢失。该情况不能用静态分析排除。其余协议和图像回调的返回值没有绑定到日志写入成功与否。

## 已执行的检查

| 检查 | 结果 | 覆盖/限制 |
| --- | --- | --- |
| 13 个相关 shell 文件 `sh -n` | PASS | 语法，不代替 QNX `/bin/sh` 实机执行 |
| hook `altscreen_core.c`：Clang ARMv7 freestanding、`-Wall -Wextra -Werror -fsyntax-only` | PASS | 使用仓库 QNX shim；不链接目标 libc/pthread |
| mirror `main.cpp`：GNU C++98、`-Wall -Wextra -Werror -fsyntax-only` | PASS | 主机 EGL/GLES/fcntl 临时头；不验证 QNX SDK ABI |
| Java 控制器：`javac -source 7 -target 7` | PASS | 只检查可用主机编译器的语法；**不是** Java 1.2 class 46 构建或旧运行库验收 |
| `tests/test_log_ring.sh` | PASS | SD 优先、并发写者、换段容量、锁忙/卡缺失/双路径失效、档案清理 |
| `tests/test_stop_marker_watch.sh` | PASS | 老标记不误触发，新标记使 mock sidecar 结束并清理 PID |
| `tests/test_frame_telemetry.sh` | PASS | v2 帧头偏移、三槽隔离、32 位微秒回绕、零时间戳、时钟倒退与 5 秒无效上限 |
| QNX 6.5 ARMv7 sidecar 完整编译、ELF/依赖检查 | PASS | 与旧 sidecar 的四项动态库依赖一致；仍须实车验证 |
| ARMv7 freestanding hook 完整编译、ELF 布局检查 | PASS | `libc.so.3`、`libm.so.2`，目标符号与加载布局通过 |
| Java 8 `-source 1.3 -target 1.2` 重建 JAR | PASS | 新控制器及两个内部类为 major 46；15 项公开 API 未减少，其他 JAR 条目内容未变 |
| `VERIFY-NATIVE-DIRECT-RELEASE.sh` | PASS，报告 `READY_FOR_VEHICLE_TEST` | 源码合同、发布文件哈希和 V2 二进制标记 |

主机测试不能证明真实 SD 写入延迟、拔卡时 QNX `rename` 行为、车机 libc 实际装载、Java 1.2 车机运行库或 1 小时保留量。hook 和 sidecar 已按本次源码重建，HMI JAR 沿用上次版本；仍须在车上进行启动、协议协商、type 111 视频、Context 80、拔卡/满卡及停止重连验收。

## 逐帧探针静态判定

`FRAME_DECODE_TIMING` 和 `FRAME_PRESENT_TIMING` 以同一 `generation/sequence` 对齐，序号跨会话不比较。所有样本以微秒记录；32 位时间每约 71.6 分钟回绕，模减在有效的 5 秒区间内可正常工作。零或超过 5 秒的差值记 0，不能当作真实零延迟。`decode_proxy_us` 只来自最近一次 type 111 H264 包和解码回调时间；stock OMX 没有逐帧输入 PTS 对照，故这不是精确解码耗时。`publish_to_present_us` 是 SHM 发布时间到 EGL swap 返回的实测耗时，也不是面板亮起时间。

生产端日志不直接触盘；消费端逐帧日志为单次非阻塞管道写。按 30 fps、两端每帧合计约 500 字节估算约 15 KiB/s，低于 1 GiB/小时对应的约 291 KiB/s 总平均预算，但车机 `/bin/sh` 日志汇聚进程的 CPU 用量、SD 写入速度、队列溢出及实际留存分钟数只能实车测得。若 `LOG_QUEUE_DROPPED` 或镜像 FIFO 丢行，诊断证据可能不连续，不能把缺行等同解码丢帧。每分钟 `FRAME_CHAIN_HEALTH` 持续给出计数和帧率，包括停帧期间；连续无新帧超过 250 ms 才进入停顿状态。

## 审查中修正的问题

1. 换段标记原先会清空待消费的手机请求；已与真正 `HOOK_INIT` 分开。
2. 监视器原先每秒扫描完整循环日志且旧段覆盖时可能漏判；改读异步状态标记。
3. 停止事件原先可能随日志队列满而丢；改为队列外的原子事件号。
4. 多个 shell 生产者原先可同时更新 `mirror.log` 和轮转游标；改用原子目录锁，锁忙走 `/tmp`。
5. sidecar 输出原先可能被阻塞的日志管道拖住帧线程；改为非阻塞描述符，允许丢诊断文本。

## 发布判定

静态审查未发现日志失败会直接改变现有 iAP2、type 111、解码或显示函数的控制返回值。**已重建、可进行上车测试，不代表实车兼容已确认**。当前全局 1 GiB 机制是周期清理而非强制硬配额；若验收条件要求“任何瞬间绝不超过 1 GiB”，还需补文件系统配额或跨所有生产者的统一预留写入服务。
