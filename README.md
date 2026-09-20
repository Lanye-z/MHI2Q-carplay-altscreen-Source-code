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

### 2026-09-20 `experiment/oem-layout-second-screen` 实车结论

本次 `MMI-Cockpit-Carplay.zip` 日志表明，本实验分支在保留 V2 第二屏直显链路的同时，已经完成 **OEM 四态布局参数的一次性实车采集**。本次日志中的车机报告固件为 `MHI2Q_CN_AUG22_P1404`。

核心结论：

- **V2 主显示链没有被 OEM observer 改坏。** Private111 能完成协商、`accept()`、原车 OMX 解码、NV12 linearizer、decoded SHM、displayable3 和 Context80 输出；日志记录到 `CTX80_OBSERVED actual=80`，并持续出现显示帧。
- **Main110 仍保持原车路径。** Native 日志继续记录 `main110_untouched=1`，本轮观察逻辑没有改写主 CarPlay 视频链。
- **四种 OEM 布局均已成功识别。** 同一 CarPlay 会话内捕获到了 Sport Full、Sport Small、Classic Full、Classic Small，无需为同一目的再次上车采集。
- **Observer 契约保持成立。** 所有 geometry snapshot 均为 `apply_to_carplay=0`、`apply_to_renderer=0`；DisplayManager 只完成方法元数据枚举，没有调用 getter/setter 去改变原车显示状态。
- **producer 侧解除限帧已经生效。** Linearizer 连续记录到 3600 次 readback / 3600 次 publish，`publish_drops=0`、`failures=0`、`fallbacks=0`；readback P50 约 3 ms、P95 约 4 ms、最大约 7.05 ms，说明当前 Screen 读取本身可以稳定跟随约 30 fps 的 producer。
- **当前实际显示端仍约 15 fps。** Sidecar 的 `PHASE=RUN` 在稳定阶段约为 14.3–16.8 fps，后段为约 14.97 fps；因此当前主要帧率损失已经不在 producer readback，而更可能位于 `decoded SHM → sidecar 取帧/去重 → RGBA/GLES → present` 这一段。下一步不应再主动把 producer 改成“隔一帧读一帧”。
- 日志中可见少量 `DECODED_SOURCE_STALL` / `RECOVERED` 和 `DECODED_FRAME_RACE retry=1`，但均能自动恢复，没有看到它们导致本次第二屏会话中止。

本次采集得到的 OEM 四态几何如下：

| OEM 状态 | Layout class | 关键布局常量 | Active visible area |
| --- | --- | ---: | --- |
| Sport Full | `LayoutMIB2HighB9Sport` | `layout_const_80=-476` | `x=370, y=49, 700×300` |
| Sport Small | `LayoutMIB2HighB9Sport` | `layout_const_80=-476` | `x=490, y=49, 460×300` |
| Classic Full | `LayoutMIB2HighB9` | `layout_const_80=0` | `x=370, y=49, 700×300` |
| Classic Small | `LayoutMIB2HighB9` | `layout_const_80=0` | `x=490, y=49, 460×300` |

四态共同参数为：

```text
screen = 1440 × 540
map raw/effective = 1440 × 455
map offset = (0, 26)
Full visible = (370, 49, 700, 300)
Small visible = (490, 49, 460, 300)
```

这说明 **Full / Small 的主要差异是左右 tube 留出的可视宽度；Sport / Classic 在本次车上没有改变计算出的地图可视矩形，但可以通过 Layout class 与 `layout_const_80` 明确区分。** 因此，OEM geometry observer 的第一阶段目标已经完成，下一阶段可以基于这些实车参数研究 CarPlay canvas / safe area 与 OEM 可视区域之间的映射，而不再依赖猜测的 1440×445 / 455 / 542 常量。

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
| `experiment/oem-layout-second-screen` | **当前 OEM 布局实验分支。** 已完成四态 geometry 实车采集，并确认未破坏 V2 直显主链。 |
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

### 1. 当前帧率瓶颈在显示消费端，不在 producer Screen 读取端

2026-09-20 的实车日志已经改变了此前“优先隔一帧读一帧”的判断。

当前 producer / linearizer 侧表现为：

```text
rate_policy=uncapped_source_callbacks
sink_target_fps=30
readbacks=3600
published=3600
publish_drops=0
failures=0
fallbacks=0
readback_p50_ms=3
readback_p95_ms=4
readback_max_us≈7050
```

也就是说，**Screen readback 已经能够稳定接近 30 fps 工作**。但 sidecar 的实际 `present_fps` 稳定阶段仍主要落在约 15 fps。

因此下一步应优先检查：

```text
/carplay111_decoded
        ↓
sidecar 新帧检测 / 取帧
        ↓
NV12 → RGBA
        ↓
GLES / displayable3 present
```

重点确认是否存在固定 2:1 取帧、轮询周期与 producer 相位冲突、重复帧过滤或 present 节奏导致的降采样。在这一问题定位前，**不再主动把 producer 改为“隔一帧读一帧”**，否则可能进一步降低实际仪表帧率。

### 2. CarPlay 断开后的原车导航箭头状态

一次首次上车测试中观察到：

- CarPlay 断开后，仪表恢复原车地图；
- 当时原车并没有开启导航路线；
- 但仪表仍异常出现了导航箭头。

这一现象更像是 **CarPlay 第二屏退出后，Context / 导航状态 / 箭头状态的清理或交接不完整**。

目前将其作为独立生命周期问题继续分析，不认为它推翻已经验证成功的 private111 显示路线。

### 3. OEM 四态参数已采集，但尚未应用到 CarPlay / renderer

本轮分支是严格的 **OBSERVE ONLY**。四态参数已经拿到，但当前代码仍没有根据这些参数动态修改 CarPlay `viewArea/safeArea`，也没有改变 sidecar destination/source rect。

因此本次结论是“**采集完成，可以进入映射设计阶段**”，而不是“布局适配已经完成”。下一阶段应先建立 CarPlay 1440×542 canvas 与 OEM Full/Small 可视区域之间的 transform，再单独验证动态切换，避免同时改动协商尺寸、renderer 和 Context80。

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

1. 定位 `decoded SHM → sidecar → GLES/present` 为什么从约 30 fps producer 降到约 15 fps；
2. 基于本次已采集的 Classic/Sport × Full/Small 四态实车几何，建立 CarPlay canvas / safe area 到 OEM 可视区域的映射；
3. CarPlay 断开后的原车导航箭头状态清理，并继续验证多次连接 / 断开的长期稳定性。

在没有新的实车证据前，不主动增加额外显示层和解码层。
