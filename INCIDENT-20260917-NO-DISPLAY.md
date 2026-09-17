# 2026-09-17 仪表未点亮专项分析

## 结论

本次采集不支持“iPhone 第二屏视频流没有接入车机”的判断。相反，type 111 从协商到真实帧提交均已成功。未点亮发生在最后一跳：正式架构要求 Mirror sidecar 把 private111 Window58 接入仪表 displayable 3 并切换 context 76，但采集期间没有该进程或其日志。

## 已确认的链路

- 手机 SETUP 包含 `altScreen/viewAreas`，车机发布 type 111 display。
- type 111 listener 在动态端口 `65494` 打开，精确 PF 规则先于响应生效。
- `STREAM_111_ACCEPT_RETURN rc=0 native_fd=36`，随后 NetSocket、StartSession 和 ProcessFrames 均成功。
- renderer 配置为 `1440x542`、`displayable=58`，DisplayManager 报告 `new window available 58`。
- `NATIVE_111_FIRST_REAL_FRAME ... result=POSTED`，随后累计接收约 4.5 MB，证明不是只有空连接。
- `showUI` 和 `forceKeyFrame` 均收到 status 0。

## 缺失的最后一跳

- 三次 `pidin arguments` 快照都没有 `carplay-alt111-mirror-display`。
- 采集包没有 `mirror.log` 或 `mirror_autostart.log`。
- 没有 sidecar 读取 Window58、创建 displayable 3 输出或切换 context 76 的证据。
- SD 状态同时存在 ACTIVE、FULL_CHAIN_MODE、NATIVE_DISPLAY_MODE 等标记，说明此前仅凭这些标记会产生“已启动”的假阳性。

正式 sidecar 的 `BUILD_INFO.txt` 明确声明：

```text
source=private111_stock_omx_window58
direct_context_route=disabled
capture=screen_read_window
mirror_sink=displayable3_gles
context=76_transition72_restore74
```

因此 Window58 收到真实帧只是上游成功，并不等于仪表已经接入。

## 根因边界

采集包没有保存对应 START operation journal，也没有导出当时的 `/mnt/app/root/carplay-altscreen/state` 和 Mirror runtime 目录，无法从现有证据唯一确定是旧脚本、直接调用底层 controller，还是不完整安装造成 sidecar 未启动。但代码审计确认底层 controller 的 `start` 以前可以绕过集成 launcher，独立创建 ACTIVE 标记；这与本次“hook 活动、sidecar 缺失”的状态完全一致，是必须封闭的确定性缺口。

## 修复

1. known/universal controller 的生产 START 只接受集成 launcher 的事务标记。
2. controller 在创建 ACTIVE 前验证 sidecar 二进制、启动脚本和 ownership marker。
3. 集成 launcher 显式传递事务标记；现有失败路径继续执行 restore，避免半启动。
4. STATUS 在 fullchain probe 存在时要求 autostart marker 和活的 sidecar PID，否则返回失败。
5. boot diagnostics 新增 Mirror runtime/state、`mirror.log` 和 `mirror_autostart.log` 采集。
6. 用户文档改为区分“Window58 已有帧”和“仪表最后一跳已成功”。

## 复测判据

重新覆盖 Toolbox 后必须重新执行 INSTALL、START 和完整 MMI 重启。连接 iPhone 前运行 STATUS，应看到：

```text
MIRROR_INSTALLED=YES
MIRROR_AUTOSTART=ENABLED
MIRROR_PROCESS=RUNNING
MIRROR_HEALTH=PASS
```

开始导航后，还应看到 `MIRROR_FIRST_FRAME=READY`，并在新采集包中保留 Mirror/autostart 日志。若 type111 仍有 `FIRST_REAL_FRAME ... POSTED`，但 STATUS 报 Mirror 健康失败，则故障已被准确限定在仪表接入层，不应继续修改手机协商或动态端口代码。
