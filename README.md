> [!WARNING]
> **⚠️ SD 卡读写权限警告（2026-09-24）**
>
> 本分支为历史/实验/工具分支，**尚未同步当前统一的 SD 可写 preflight**（真实 write probe → 必要时 `mount -uw` → 再次 write probe）。如果 Toolbox/QNX 此时把 `/net/mmx/fs/sda*` 以只读方式挂载，旧版 INSTALL / START / RESTORE / 日志或备份流程可能出现 `sd_write_failed`、`SD_NOT_WRITABLE`，并中止操作。
>
> **不建议直接使用本分支进行新的实车安装、启动、卸载/恢复或写入型维护。** 需要上车请优先使用已完成统一 SD RW 修复并通过 CI 的 `experiment/oem-layout-second-screen_v3.3`；需要公开基础版则使用 `opensource/v1-basic-wheel`。
>
<!-- BRANCH_STATUS_BEGIN -->
> [!IMPORTANT]
> **分支用途：** 默认开发基线。以 2026-09-19 已正确点亮的 V2 private111 → 原车 OMX → Screen linearizer → displayable3 → Context80 路线为基础，承接通用显示链、诊断和生命周期维护；它不是当前 V3.x 滚轮/布局实验分支。
>
> **上车测试结论：** V2 基础路线已经实车确认可正确点亮 Virtual Cockpit 并随 CarPlay 导航更新。当前 `main` 在同步 V2 后仍有维护性改动，因此若要做“最后一个严格已知可点亮版本”的回归，请以 `carplay-private111-direct-display-v2` 为黄金基线。
>
> **当前定位：** 正式开发基础分支；用于通用回归，不代表 V3.x 最新功能状态。
<!-- BRANCH_STATUS_END -->

> [!IMPORTANT]
> **当前状态与安全提示**
>
> 本仓库仍属于实车验证阶段。当前 `main` 已基于实车点亮的 V2 版本收口，但仍存在少量待完善问题。请在车辆安全停放后进行安装、启动、日志收集和恢复操作，不要在驾驶过程中操作工程菜单或反复重启车机。

# MHI2Q CarPlay 第二屏直显

本项目用于研究和验证 **Audi MHI2Q 平台上的 CarPlay 第二屏视频流直显到 Virtual Cockpit**。

当前方案不再依赖早期的 Window58 枚举 / Window58 readback 路线，而是直接围绕 CarPlay 的 **private type111** 第二屏链路展开：保留原车 AirPlay / OMX 解码流程，在原车 private renderer 后取得可安全读取的画面，通过 QNX Screen 线性化为标准 NV12，再送入独立 sidecar，最终复用现有的 GLES / displayable3 / Java Context80 链路输出到仪表。

## 当前进展

2026-09-19 的实车测试已经确认：

- **CarPlay 第二屏画面已经可以物理点亮 Virtual Cockpit。**
- 仪表画面能够跟随手机端 CarPlay 导航画面变化。
- 当前成功路线为修改后的 **V2**，并已同步到 `main` 作为后续开发基线。
- `carplay-private111-direct-display-v2` 保留为首次成功点亮的备份分支。
- `carplay-private111-direct-display-v1` 仅保留用于历史对照，不再作为新的测试起点。

当前已证明的显示链路为：

```text
iPhone CarPlay
  ↓
private type111
  ↓
原车 AirPlay / ScreenStreamProcessData
  ↓
原车 OMX 解码
  ↓
原车 private renderer
  ↓
QNX Screen 读取并线性化为标准 NV12
  ↓
/carplay111_decoded
  ↓
独立显示 sidecar
  ↓
CPU NV12 → RGBA
  ↓
GLES / displayable3
  ↓
Java/HMI Context80
  ↓
Virtual Cockpit
```

其中主 CarPlay 画面 Main110 保持原车链路，不参与这条辅助显示路径。

## 主要功能

- **private111 第二屏链路接入**
  - 监听并确认 CarPlay 第二屏请求、建连和视频数据。
  - 不额外消费 socket 数据，不破坏原车 CarPlay 主链路。

- **复用原车 OMX 解码**
  - 当前不引入独立 FFmpeg / NvMedia / Qualcomm 解码器。
  - 继续利用已经在 MHI2Q 上工作的原车解码路径，降低新变量。

- **Screen 线性化**
  - 对原车 private renderer 的实际 Screen window 进行安全读取。
  - 将厂商内部布局转换为 sidecar 可稳定消费的标准 NV12。

- **独立 SHM 数据通道**
  - H.264 证据：`/carplay111_h264`
  - 解码后画面：`/carplay111_decoded`
  - 通过 writer PID、generation、stream cookie 等信息区分不同连接会话。

- **Virtual Cockpit 输出**
  - 使用现有 GLES / displayable3 路径。
  - Java/HMI 继续作为 Context80 的唯一控制方。
  - sidecar 不直接修改终端 Context。

- **诊断与恢复**
  - 提供 INSTALL / START / STATUS / 日志保存 / 原车恢复流程。
  - 日志可区分 private111、H.264、解码帧、Screen 读取、SHM、displayable3 和 Context80 各阶段。

## 分支说明

| 分支 | 当前用途 |
| --- | --- |
| `main` | **正式开发主线。** 当前基于实车已点亮的 V2，后续修复和优化在这里进行。 |
| `carplay-private111-direct-display-v2` | **实车点亮备份。** 保留首次成功路线，主要用于回归对比和恢复。 |
| `carplay-private111-direct-display-v1` | **历史实验分支。** 用于回看早期 private111 / OMX / Context80 验证过程。 |

## 安装与测试

建议每次上车都从干净状态开始，不要同时混用不同实验分支的安装文件。

### 1. 准备测试 SD 卡

下载当前分支 ZIP 并解压，保持仓库目录结构完整，将测试文件放入 SD 卡。

进入工程菜单中的：

```text
MMI-Cockpit-Carplay
```

当前页面主要操作为：

| 菜单项 | 作用 |
| --- | --- |
| `INSTALL` | 安装 private111、SHM、显示 sidecar 和 Java Context80 相关运行文件。 |
| `START` | 启用并启动当前第二屏显示链路。 |
| `STATUS` | 查看当前链路各阶段状态和关键日志。 |
| `STORE LOGS + RESTORE` | 保存测试日志并执行恢复。 |
| `RESTORE ORIGINAL` | 停止实验链路并恢复安装前的原车状态。 |

### 2. 推荐上车顺序

```text
保持 iPhone 未连接
        ↓
执行 INSTALL
        ↓
完整重启车机
        ↓
执行 START
        ↓
再次完整重启车机
        ↓
连接 iPhone / CarPlay
        ↓
启动一条支持仪表第二屏的导航路线
        ↓
观察 Virtual Cockpit
        ↓
执行 STATUS / 保存日志
```

不要在一次测试中同时加入新的 decoder、`screen_blit`、新的 Context 或其他大范围显示结构修改，否则出现异常后很难判断是哪一层造成的。

## 成功判据

软件链路完整时，STATUS 应能够观察到类似以下关键阶段：

```text
PHASE=STREAM_111_ACCEPT_RETURN
PHASE=VIDEO_111_FIRST_PAYLOAD

PHASE=FRAME_LINEARIZER_FIRST_FRAME
PHASE=FRAME_LINEARIZER_PROGRESS

PHASE=DECODED_SHM_ATTACHED
PHASE=DECODER_FIRST_FRAME

PHASE=DISPLAYABLE3_FIRST_PRESENT result=OK
CTX80_OBSERVED actual=80
PHASE=DIRECT111_ACTIVE
```

以及：

```text
PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE
```

但软件日志只能证明链路已经走通，最终仍以 **Virtual Cockpit 是否实际出现正确 CarPlay 第二屏画面** 为准。

## 当前已知问题

### 1. Screen 读取负载仍可继续优化

当前已确认显示路线本身能够工作。下一步优先优化的是读取节奏，而不是更换架构。

计划方向为：

```text
原车每帧继续正常渲染
        ↓
我们的辅助链路主动隔一帧处理一帧
        ↓
只对选中的帧执行 Screen 读取 / SHM 发布
```

也就是“**隔一帧读一帧**”，目标是在保持仪表导航流畅度的同时减少 QNX Screen 读取和后续 CSC / GLES 的负载。

目前没有证据表明必须立刻加入独立解码器或 `screen_blit`。

### 2. CarPlay 断开后的原车导航箭头状态

一次首次上车测试中观察到：

- CarPlay 断开后，仪表恢复原车地图；
- 当时原车并没有开启导航路线；
- 但仪表仍异常出现了导航箭头。

这一现象更像是 **CarPlay 第二屏退出后，Context / 导航状态 / 箭头状态的清理或交接不完整**。

目前将其作为独立生命周期问题继续分析，不认为它推翻已经验证成功的 private111 显示路线。

## 日志

主要运行日志位于：

```text
/tmp/MMI-Cockpit-Carplay/
```

其中会包含：

- private111 建连与 teardown 信息；
- H.264 tap 证据；
- Screen linearizer 进度与耗时；
- decoded SHM 状态；
- sidecar 显示日志；
- Java Context80 状态。

建议出现问题后先保存完整日志，再修改代码。

## 恢复原车

测试结束或需要切换到其他分支前，建议先执行：

```text
RESTORE ORIGINAL
```

恢复流程会：

- 停止当前 sidecar；
- 释放当前 Context80 显示需求；
- 移除实验启动项；
- 恢复安装前保存的 HMI 文件；
- 恢复 native AltScreen / preload 相关状态。

恢复完成后建议执行一次完整车机重启。

## 当前开发原则

现阶段已经不需要继续同时维护多套平行显示方案。后续工作围绕当前实车成功路线继续收口：

```text
private111
  → 原车 OMX
  → Screen 线性化
  → decoded SHM
  → GLES / displayable3
  → Java Context80
  → Virtual Cockpit
```

优先处理：

1. 隔一帧读一帧的性能优化；
2. CarPlay 断开后的原车导航箭头状态清理；
3. 多次连接 / 断开后的长期稳定性验证。

在没有新的实车证据前，不主动增加额外显示层和解码层。
