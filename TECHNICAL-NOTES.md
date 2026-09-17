# 2026-09-14：AltScreen 模块运行依赖与影响面审计

> 后续 CarPlay 分析基线：发现、认证后的能力协商、`/info`、SETUP、type 111 建链、数据端口和视频接收均先对照固定提交的 LIVI，并留档提交号、源码位置、dio 证据及平台差异，避免重复分析或用猜测替代证据。

## 后续原厂 ABI 全量复核

在实车 `CFLStringGetCStringPtr` 输出指针崩溃修复后，又对当前第二屏调用路径中的 K1004/P1404 原厂接口做了独立机器码复核：64 个双版本符号的地址关系与大小一致，26 组高风险参数、输出指针和 64 位寄存器契约通过。另修正 `CFStringGetCString`、`CFRetain`、`NetSocket_Delete` 三个不会在当前调用点单独致崩的声明偏差。完整证据见 `Research/AltScreen/evidence/20260914-stock-helper-abi-audit/README.md`。

后续实车日志又确认一条 AUG22 调用顺序：手机首次 session SETUP 请求已包含 `altScreen/viewAreas`，代理响应成功接受；随后 `/info` 经 `SessionPlatformCopyProperty(displays)` 发布独立 type 111 display；原厂 `ServerPlatformCopyProperty(features)` 在该流程中返回空对象。旧策略把“features 属性必须产生数值对象”误当成私有 111 的必要条件，因此在手机明确发送 type 111 descriptor 后仍记录 `private_policy=BLOCKED`。LIVI `4bfd62a004de1d114748759943521a7d8917c279` 的实现收到显式 `type=111` 后直接建立独立接收端并返回 `dataPort`，不再检查先前的 display/feature 回调、descriptor UUID 或另一个唯一性证明。当前实现也改为由显式 `type=111` 和后端可用性直接进入私有建链；多个 111 只保留第一个接收端，因为车机只有一个物理 AltScreen，正常 iPhone 请求和实车日志均为一个 descriptor。完整逐项对照见 `Research/AltScreen/evidence/20260914-livi-type111-parity/README.md`。

最新 P1404 日志证明上述门禁修复生效：type 111 descriptor 被接受，私有 ScreenSession 创建、Setup、密钥派生和 `SetSecurityInfo` 均成功，CTR 状态为 ready。旧后端却在打开 listener 前重复 12 次 `prepare_setup_failed`。定位结果是旧代码还要求 `server+0x1d0` 提供 screen stream options；LIVI 的 `_setupScreen` 没有这一步，收到 type 111 后只根据 pair-verify secret 与 `streamConnectionID` 派生密钥并打开独立视频接收端。K1004/P1404 原厂 `ScreenStreamCreate` 入口机器码也证明其第一个参数在读取前即被覆盖，`AirPlayReceiverSessionScreen_StartSession(session, NULL)` 对两版有效。当前后端因此删除 options 的读取、保存和释放，改为安全设置成功后直接建 listener 并返回 `dataPort`，accept 后调用原厂 StartSession 与 ProcessFrames。证据见 `Research/AltScreen/evidence/20260914-livi-direct111-listener/README.md`。

## LIVI type 111 精确对照

当前 AltScreen 增量采用 LIVI 的 Alt UUID `b7e6c5a0-2222-4000-8000-000000000002`、type 111、60 FPS、`features=0x0A`、`primaryInputDevice=3`、200 mm 宽度回退和按像素比例计算的物理高度。session SETUP 只补 `altScreen/viewAreas`；流级 SETUP 只返回 `{type,dataPort}`，不重复修改 `enabledFeatures`，也不回显 `streamConnectionID`。descriptor 按 `type` 单字段选择，密钥设置、listener、响应、accept、StartSession 和 ProcessFrames 的顺序与 LIVI 对应。

没有照搬 LIVI 的主屏、音频、MFi、timing/event 和 iAP tunnel 实现，因为这些能力已经由原厂 dio 提供。请求拆分、响应合并、CF retain/rollback、QNX worker 和 teardown 是把同一 type 111 行为嵌入原厂 dio 所需的平台代码，不增加手机可见字段或协商条件。自动检查 `verify_livi_type111_parity.py` 固定 LIVI 提交并验证 27 项，当前结果为 27/27；完整链路模拟为 138/138。

最新 P1404 日志还补出一个只在真实返回对象中出现的分支：手机的流级 SETUP 只有 type 111，代理从给原厂的请求中移除 111 后留下 `streams=[]`，原厂返回成功和空字典 `{}`。旧合并器要求原厂响应预先存在 `streams[]`，因此在 ScreenSession、安全设置和 listener 全部成功后仍报 `STREAM_111_RESPONSE_MERGE merge_failed=1` 并撤销 worker。LIVI 对这类流级 SETUP 总是返回 `{streams: respStreams}`；当前合并器在原厂响应没有 `streams` 时先创建空数组，再追加 `{type:111,dataPort}`，已有数组仍按原顺序保留，非数组值继续拒绝。模拟原厂端也已改为对空拆分请求返回 `{}`，避免再次用虚构的 Main110 响应掩盖该分支。证据见 `Research/AltScreen/evidence/20260914-livi-empty-stream-response/README.md`。

## 结论

当前 K1004、P1404 交付物没有新增任何车机系统库依赖。代理新增的唯一 `DT_NEEDED` 边是包内同时交付的 `libairplax.so`。两版重命名原厂 libairplay 的依赖列表与各自原厂文件逐项、顺序完全一致；两版补丁 Nme 的依赖列表也与各自原厂文件完全一致。

当前 START 启用第二屏协商、type 111 建链、视频帧处理和 `NATIVE_DISPLAY_MODE`。仪表路由不会在 START 时立即切换；原生代码仍要求 type 111 流已建立、`showUI` 已接受、动态配置有效且认证 Logo 首帧已经预提交，随后才调用 `dmdt`。Restore/Stop 会清理该标记并执行恢复路由。

可重复检查：

```text
python Toolbox/carplay_alt_screen/tests/audit_module_runtime_contract.py \
  --profiles work/module-runtime-impact-audit-20260914/final-validation/profiles \
  --runtime-libs MMI-Cockpit-Carplay/logs/sessions/19700101_000056_9928842/dio_libraries.txt \
  --output work/module-runtime-impact-audit-20260914/final-validation/module-runtime-contract.json
```

该审计已作为 `module-runtime-contract` 接入双版本完整模拟器。

## dio 装载与模块入口

运行入口为 `dio_manager -> libairplay.so 代理 -> libairplax.so 原厂实现`。dio 同时通过 `libNmeSDK.so -> libNmeBaseClasses.so` 装入对应 profile 的补丁 Nme。P1404 实车运行列表证明三份 overlay 都从 `/mnt/app/root/carplay-altscreen/lib` 装入，顺序为代理在前、重命名原厂库和补丁 Nme 在后。

代理构造函数先绑定原始 libc 转发函数并安装原厂库的精确 GOT 重定向，然后启动后台初始化。后台初始化只有在 state root、14 个重定向、进程身份、原厂私有符号、转发门和 display 1 几何均准备好后才置为 ready；此前所有包装函数保持原厂路径。初始化失败会让本进程中的扩展保持不活动，原厂 CarPlay 路径仍然可调用。

代理实际导出 22 个 AirPlay/Screen/CScreenRender 或私有 Nme 名称，不导出 `open/open64/read/write/send/recv/close/dup`。因此当前交付物不会接管 dio 全进程的通用文件和网络调用。原厂 libairplay 只把 `write/close` 等长改名到代理私有入口；Nme 只把七个指定导入等长改名。特殊处理还受原厂调用者地址、`/dev/otg-cinemo` 路径、iAP2 候选或已管理 FD 限制，其他调用直接转发原函数。

## 依赖差分

| Profile | 原厂 libairplay 依赖 | 原厂 Nme 依赖 | 新增系统依赖 | 新增包内依赖 |
|---|---:|---:|---|---|
| K1004 | 12 | 5 | 无 | `libairplax.so` |
| P1404 | 12 | 7 | 无 | `libairplax.so` |

K1004 尚有 11 个系统 SONAME 没有可读的对应固件字节。这些边全部已经存在于 K1004 原厂 libairplay/Nme，不是模块引入的新需求；固定固件中的 `libc.so.3` 和 `libsocket.so.3` 已按镜像偏移与 SHA256 核对。P1404 的 16 项完整依赖闭包都出现在实车 dio 运行列表；其中 `libOSAbstraction.so`、`libscreen.so.1`、`libssl.so.2`、`libaoi.so.1`、`libcommonUtils.so`、`liblibstd.so` 只有装载路径证据，仓库没有它们的原始字节。

## 第二屏建立所需运行条件

第二屏建立仍有四个只能由实车确认的边界：

1. `libscreen.so.1` 必须能提供 context/display 查询函数，并且 screen 服务必须返回有效的 display id 1 几何。这个条件发生在第二屏信息发布前，属于协商和取流的实际前提，不只是仪表显示条件。
2. iPhone、USB 和 MFi 认证必须先让原厂主 CarPlay 会话成功建立。本模块沿用原厂认证，不替代它。
3. 原厂 `ServerSocketOpen` 必须成功建立动态端口，启动时必须确保 `carplay0` 策略允许流级 SETUP 返回的实际动态 `dataPort`，手机必须连接该端口，`SocketAccept`、`NetSocket_CreateWithNative` 和 `AirPlayReceiverSessionScreen_ProcessFrames` 必须按已逆向 ABI 工作。P1404 日志已证明前一版本的 `65504`/`65499` 被原厂 PF 最终 block 阻断；配置与恢复逻辑现已修复，活动规则加载和成功 accept 留待实车确认。根因证据见 `docs/altscreen/29-type111-pf-firewall-fix-20260915.md`。
4. K1004 尚无实车 dio 库装载顺序日志；K1004 的 ELF、原厂依赖差分、调用者窗口和模拟链路已验证，最终装载和调度仍需该车型日志确认。

`/eso/bin/apps/dmdt` 不参与手机发现、认证、SETUP、type 111 TCP 建链或视频获取；它只在上述原生门禁全部满足后负责仪表显示路由。`/dev/otg-cinemo` 是 Nme 原厂承载路径的作用域条件，模块不会自行打开或读写该设备。

## 线程、Socket 与清理

运行期会创建一次初始化线程和一个进程生命周期日志线程。日志队列固定为 256 项、单行 768 字节，日志上限 16 MiB；队列满时丢弃日志，不阻塞 CarPlay。private 111 worker 由会话拥有，teardown 通过本机连接唤醒 accept，发送原厂 loopback stop，并在删除 ScreenSession 前 join worker。native monitor/route worker 使用 generation 防止旧任务接管新会话；当前测试会创建 `NATIVE_DISPLAY_MODE`，但路由 worker 仍受 type 111、`showUI`、动态配置和认证 Logo 首帧门禁约束。

静态检查能证明这些创建、限制、回退和清理代码存在，也能在主机协议模拟中覆盖成功、失败、重复连接和 teardown。它不能执行 QNX 的真实线程调度；若原厂 `ProcessFrames` 在 stop 后不退出，teardown 仍可能等待，这是实车需要观察的剩余风险。

## 安装和恢复影响

INSTALL 会备份 dio、原厂 libairplay、原厂 Nme、overlay 目录原状态、CarPlay 配置、启动脚本和 `/mnt/system/etc/pf.conf`，然后向 `/mnt/app/root/carplay-altscreen/lib` 发布三个 profile 文件，并确保原厂最终 `carplay0` block 前的入站策略允许 type111 listener 在流级 SETUP 返回的动态 `dataPort`。dio 二进制和 `/eso/lib` 原厂库不被覆盖。CarPlay 配置只移除已知冲突 preload；开机诊断块负责实时写 SD 日志并周期采集 `netstat -an` 和活动 `pfctl -sr`。任一步发布失败会执行事务回滚。Restore 会按备份清单逐文件恢复或删除本次新增文件，并把原始 `pf.conf` 字节写回，随后要求重启让原厂进程和 PF 策略重新加载。

审计器还包含负例：删除原函数回退、删除 FD guard、删除 worker 停止路径、删除运行库记录、重新在 START 中启用仪表路由，五种修改都必须被拒绝。

本地结果可以确认模块的新增依赖、装载入口、符号影响面、脚本文件调用、状态标记和已知回退没有再发现阻断项。它不能替代真实 iPhone/MFi、QNX loader/调度和 display 1 几何的实车验证，因此上车仍应依据实时日志判断第一处未通过的 phase。
# 2026-09-15 persistent log protection

The vehicle-test build now keeps the native hook plaintext log only in volatile
`/tmp` and encrypts every persistent diagnostic artifact before writing it to
SD. Boot/live streams, operation journals, and collection reports use
authenticated `ASLG/v1` files. Runtime markers under `current/` remain readable
because the hook and controller parse them. The local decryption key and tool
are excluded from the vehicle ZIP. The complete format and recovery boundary
are recorded in `docs/altscreen/28-encrypted-runtime-logs-20260915.md`.
