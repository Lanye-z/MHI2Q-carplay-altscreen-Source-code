# K1004 / P1404 第二屏测试包

供已经安装 Toolbox 的测试车机使用，不是 SWDL 固件刷写包。本包只包含第二屏测试相关内容，独立数据采集包保持分开。

本次包版本：`AUG22_LIVI_TYPE111_DM_MANAGED_WINDOW_20260915`。它包含 CFL ABI 修复、K1004/P1404 原厂调用 ABI 审计、P1404 空流响应修复、实车日志证明的 Type 111 监听生命周期和动态端口 PF 修复，以及对 LIVI 固定提交 `4bfd62a004de1d114748759943521a7d8917c279` 的逐项复核。新增的第二屏协议只按 `type=111` 分派；Alt UUID、60 FPS、显示特征 `0x0A`、物理尺寸默认值、`viewAreas/safeArea`、会话能力、密钥来源、`dataPort` 响应和 `showUI/forceKeyFrame` 与 LIVI 对齐。type111 单独 SETUP 拆分后，P1404 原厂返回空字典 `{}`；当前版本会按 LIVI 形状新建 `streams[]` 并只写入 `{type:111,dataPort}`。监听器在一次 10 秒 `SocketAccept` 返回 `-6722` 时会保留原端口并继续等待，直到手机连入、会话明确停止或出现非超时传输错误。iPhone 发送 `suggestUI` 时，当前版本按 LIVI 的处理方式接受该命令但不显示手机建议的 URL，只对这一个命令的原厂 `kNotHandledErr` 返回成功。每次第二屏会话直接使用同一条 type-111 解码视频；首个真实 CarPlay 帧成功 post 后再进入后续显示链路。包内不再携带 Logo 资源。必须完整覆盖 Toolbox 内的脚本和 profiles，不能只换脚本或 so。如果上次显示 `RESTORE_PENDING_REBOOT`，先完成那次 MMI 重启。

本版本专门修复 Alt-first 时两个原厂 `CScreenRender` 共用固定 window group、在 delayed flush 阶段导致 Main110 `screen_create_window_buffers()` 返回 `EEXIST` 的问题。只有已认领的 type111 renderer 会跳过该固定 group，并在原厂创建 NV12 buffers 前把 displayable 58 window 交给 DisplayManager；Main110 仍使用原厂 group、displayable 59 和原厂 OMX/Screen 生命周期。包内没有 Main110 抓屏、BGRA/EGL 中转、像素搬运或二次缩放组件。

1. 将 ZIP 内容合并到测试 SD 根目录，保证存在 `Toolbox/carplay_alt_screen/profiles/K1004`、`P1404`，不要只复制其中几个 so。保留本车 SD 上原有 Backup、Log。`identities.txt` 只是历史构建记录，安装不再读取或校验它。
2. 断开 iPhone，通过已有 Toolbox 的更新功能更新脚本和菜单，进入 MMI-Cockpit-Carplay。
3. 点 INSTALL。按车机 `Current train` 选择并显示 `FIRMWARE_PROFILE=K1004` 或 `P1404`，不比较原厂文件 CRC/hash，再备份本车原厂文件和 `/mnt/system/etc/pf.conf`，复制对应三库，并确保 `carplay0` 策略允许 type 111 流级 SETUP 返回的动态 TCP `dataPort`。看到 `FIREWALL_PATCH=PASS` 和 `INSTALL=PASS` 才继续。
4. 点 START，完整重启 MMI，保留这张 SD 卡，再连接 iPhone 并开始导航。若刚才已经在 INSTALL 后重启过，START 后仍要重启。本轮必须执行 Alt-first → Main110 顺序：先等待 type111 的 listener、accept、StartSession 和 renderer config 完成，再回到中控 CarPlay 主界面，确认 Main110 随后仍能创建和持续显示。
5. STATUS 可查看选择版本、文件状态和运行标记。连接成功时，仪表应直接进入 CarPlay 第二屏；中控主屏必须同时保持正常。若中控 CarPlay teardown、系统日志再次出现 `setNumOfRenderBuffers ... errno: File exists`，或仪表没有第二屏画面，直接执行 STORE LOGS + RESTORE 并提供日志。
6. 测试结束点 STORE LOGS + RESTORE，然后完整重启。无需收集可点 RESTORE ORIGINAL。备份在 `MMI-Cockpit-Carplay/backup/original`，运行记录在 `MMI-Cockpit-Carplay/logs`。

INSTALL 保留各版本原厂 dio，在原车库搜索目录部署对应的代理及库补丁。第一次完整备份不会被重复安装覆盖；原始 PF 配置单独保存在 `MMI-Cockpit-Carplay/backup/firewall-original`。RESTORE 会恢复原始 `pf.conf` 字节。换另一台车须使用那台车自己的备份，不能携带前一台车的 `original` 或 `firewall-original` 目录。

如果车机没有可读的 `Current train`，在 SD 的 `Toolbox/carplay_alt_screen/profiles/SELECT_PROFILE` 文件中只写一行 `K1004` 或 `P1404`，再点 INSTALL。这是手动选择要复制哪组库，不校验原厂字节；手动选择优先于自动识别。备份/复制遇到实际读写错误仍会报告。

包内 HOST_VALIDATION.json 是本地验证记录。当前适配覆盖已采集的 K1004/P1404 组合；本地已经覆盖明文 profile/package 契约、NV12 type-111 实帧路径、安装/重复安装/启动/采集/恢复。实体仪表是否按预期亮屏、真实 iPhone 的持续解码时序和车辆 QNX Screen 运行时仍需本次实车确认。

本次先在 STATUS 和明文采集日志中确认 `FIREWALL_TYPE111=ALLOWED`，并确认 `pf_rules.txt` 没有阻断流级 SETUP 返回的实际 `dataPort`；`network.txt` 应显示该动态端口处于 LISTEN。实时 `altscreen_hook.log` 中，`CF_EXPORT_BIND` 应出现 `cfl_cstr3=1`；第二屏 descriptor 到达时应显示 `advertised=1 display_published=1 feature_negotiated=1`。随后应依次出现 `STREAM_111_LISTENER_OPEN_RETURN rc=0`、`STREAM_111_PREPARED`、`STREAM_111_RESPONSE_NORMALIZE empty_stock_response=1`、带非零 `dataPort` 的 `SETUP_111_FINAL_READY`、`STREAM_111_ACCEPT_WAIT`。如果手机发送 `suggestUI`，应出现 `PHASE=SUGGEST_UI_ACCEPTED ... policy=LIVI_NOOP`，系统日志不应再出现该命令的 HTTP 422。手机连入后必须继续出现 `STREAM_111_ACCEPT_RETURN rc=0 native_fd>=0`、`NETSOCKET_CREATE_RETURN rc=0`、`START_RETURN rc=0` 和 `PROCESSFRAMES_BEGIN`。

renderer 阶段必须出现 `PHASE=NATIVE_111_MANAGED_WINDOW ... group_skipped=1 manage_rc=0 buffers_rc=0 managed=1 manager=displaymanager stock_buffer_owner=1`，其后的 `PHASE=NATIVE_111_CONFIG_RETURN` 必须包含 `displayable=58 scaling=0 dm_managed=1`。Main110 随后启动时不得再出现 `setNumOfRenderBuffers ... errno: File exists`，也不得复用 displayable 58；它应保持原厂 displayable 59。仪表源阶段应确认 type111 renderer 持续提交真实 CarPlay 帧，不再等待 Logo/splash 门禁。停止导航、断开或 RESTORE 时必须出现 `PHASE=NATIVE_111_ROUTE_RESTORE_RESULT ... sc1_74=0`，表示已恢复 context 74。持续只有 `STREAM_111_ACCEPT_RETURN rc=-6722` 说明流量仍未到达 listener。只有 INSTALL/START=PASS 不能说明这些运行阶段成功。

### Unified project storage layout

Persistent project-owned SD data is rooted at `MMI-Cockpit-Carplay/` with `state/`, `logs/`, `backup/`, and `staging/`. Vehicle-owned project files are rooted at `/mnt/app/root/carplay-altscreen/` with `bin/`, `lib/`, `state/`, and `tmp/`. First-run migration copies valid legacy `Log/MMI-Cockpit-Carplay` / `Backup/AltScreenChain` state into the new layout and deliberately leaves the legacy first backup untouched until an explicit cleanup. OEM/native volatile logs such as `/tmp/altscreen_hook.log` remain on volatile storage because `/mnt/app` is normally read-only while CarPlay is running.
