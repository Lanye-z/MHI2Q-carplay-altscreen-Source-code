<!-- BRANCH_STATUS_BEGIN -->
> [!CAUTION]
> **V3.3 已冻结（FROZEN）。**
>
> **功能冻结基线：** `4860e36b0f8a1d61b92316ae379f15a3ef9cd2bc`。从 2026-09-24 起，本分支不再继续修改运行逻辑、RGI/BAP、Type111、safeArea、滚轮、安装或恢复链；后续功能开发转移到 `experiment/oem-layout-second-screen_v3.4`。本次冻结后的提交仅允许文档性说明，不代表产生新的 V3.3 runtime。
>
> **已确认能力：** private111 → 原车 OMX → decoded SHM → displayable3 → Context80 第二屏链路可用；safeArea 已收口为 `top=68,bottom=450`；V3.2/V3.3 的布局、滚轮和 lower-bar RGI 数据接收链均已完成静态/CI 验证。
>
> **最终实车结论：** 2026-09-24 的 V3.3 日志确认 CarPlay ETA 已进入 RGI/Java，并且 `Fct22 updateTimeToDestination()` 实际持续写出；但 V3.3 的策略仍是 `BAP_ONLY_DO_NOT_DRIVE_RGI_PRESENTATION_ACTIVE`，没有激活 Audi OEM Route Guidance presentation context，因此 ETA 仍未进入原厂仪表菜单。这个问题**不再在 V3.3 修复**，由 V3.4 继续处理。
>
> **用途：** V3.3 仅作为“68～450 safeArea + V3.3 lower-bar partial takeover + 已验证显示/滚轮基线”的冻结对照版本。若要验证 ETA/道路/剩余距离进入 Audi 原厂导航菜单，请使用 V3.4 后续修正版。
<!-- BRANCH_STATUS_END -->

> [!IMPORTANT]
> **当前状态与安全提示**
>
> 本仓库仍属于实车验证阶段。当前显示链路已经可以正常工作，但布局几何和性能仍有进一步优化空间。请在车辆安全停放后进行安装、启动、日志收集和恢复操作，不要在驾驶过程中操作工程菜单或反复重启车机。

# MHI2Q CarPlay 第二屏直显

本项目用于研究和验证 **Audi MHI2Q 平台上的 CarPlay 第二屏视频流直显到 Virtual Cockpit**。

当前方案不再依赖早期的 Window58 枚举 / Window58 readback 路线，而是直接围绕 CarPlay 的 **private type111** 第二屏链路展开：保留原车 AirPlay / OMX 解码流程，在原车 private renderer 后取得可安全读取的画面，通过 QNX Screen 线性化为标准 NV12，再送入独立 sidecar，最终通过 GLES / displayable3 / Java Context80 输出到仪表。

## 当前进展

### 2026-09-19：首次完成第二屏物理点亮

首次成功路线已经确认：

- **CarPlay 第二屏画面可以物理点亮 Virtual Cockpit。**
- 仪表画面能够跟随手机端 CarPlay 导航画面变化。
- private111、原车 OMX、decoded SHM、displayable3 和 Context80 链路全部打通。
- `carplay-private111-direct-display-v2` 保留为首次成功点亮的备份基线。

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
QNX Screen readback / linearizer
  ↓
标准 NV12 /carplay111_decoded
  ↓
独立 sidecar
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

### 2026-09-20：布局 / source-driven V2 实车验证

当前分支：

```text
experiment/oem-layout-second-screen_v2
```

已完成实车测试，测试结果确认：

- **第二屏可以稳定点亮并持续运行。**
- `source-driven` sidecar pacing 生效，旧版约 16 fps 的明显限速已经解除。
- FULL / SMALL 可在同一 CarPlay session 中动态切换，不需要断开重连。
- 本次日志中共观察到 **38 次 `updateViewArea` result，38/38 accepted，未出现 retry 失败。**
- Classic / Sport 布局识别正常。
- Sport Small 的 `renderer_offset=-476,0` 已实车生效。
- 未观察到持续黑屏、花屏、EGL swap failure 或 Context80 丢失。
- HMI state 原子替换期间的 transient gap 会保留上一帧有效 placement，不再瞬间回退 fullscreen。

## 本次性能结果

以下数据来自本次约二十余分钟的实车日志，属于当前 K1004 / 当前测试条件下的观测值，不应直接视为所有车型和固件的固定性能指标。

### 显示帧率

sidecar `present_fps` 统计：

```text
平均       ≈ 25.8 fps
中位数     ≈ 25.4 fps
常见区间   ≈ 21–31 fps
最高       ≈ 34 fps
```

相比旧版约 16 fps 的显示节奏，当前 source-driven 版本流畅度有明显提升。

producer / Screen linearizer 本身状态良好：

```text
readback p50 ≈ 3 ms
readback p95 ≈ 4 ms
readback max ≈ 17 ms

readback failures = 0
fallbacks         = 0
publish drops     = 0
slow readbacks    = 0
```

因此当前性能瓶颈已经不主要位于 Screen readback，而更接近：

```text
decoded NV12
  ↓
sidecar consumer
  ↓
CPU NV12 → RGBA CSC
  ↓
GLES present
```

### CPU 负荷

本次日志中：

```text
sidecar 进程：
平均约 16% CPU

dio_manager：
约 5–7% CPU
```

`dio_manager` 本身包含原车工作负载，因此不能把其全部 CPU 占用都视为第二屏新增开销。

整机在启动初期可能出现较高 CPU 占用；稳定运行后大多处于约 50–60% 区间。

### 温度

本次连续运行期间观测：

```text
启动初期约 47–49 °C
稳定运行约 56–58 °C
最高约 58 °C
```

未观察到明显 thermal throttling / overheat / thermal mitigation 迹象。

### 内存

稳定运行阶段 free memory 大致维持在：

```text
约 670–690 MB
```

本次测试未观察到明显持续单向下降的内存泄漏趋势。

## 当前布局机制

当前分支同时处理两个不同层面的布局问题。

### 1. CarPlay viewArea / safeArea

当前 private111 runtime canvas 实测为：

```text
1440×542
```

CarPlay 侧预声明：

```text
FULL
SMALL
```

两个 viewArea，并通过标准 `updateViewArea` 在同一 session 中切换。

当前 HMI / ListModel176 实车观测值包括：

```text
screen_width      = 1440
screen_height     = 540

map_height_raw    = 455
map_width_raw     = 1440

FULL visible      = 370,49,700×300
SMALL visible     = 490,49,460×300
```

### 2. 当前 displayable3 输出

当前 sidecar 仍采用：

```text
decoded source = 1440×542
       ↓
GLES
       ↓
displayable3   = 1440×455
```

因此当前版本存在一次纵向缩放。

为了使最终物理 safeArea 尺寸与 HMI 测得的 455-plane 结果对应，当前 hook 使用：

```text
455-reference Y/H
       ↓
映射到 542 source canvas
       ↓
542 → 455 GLES 缩放
       ↓
回到目标物理 Y/H
```

例如：

```text
49  → 约58 → 缩放后约49
300 → 约357 → 缩放后约300
```

这套机制在**当前 542→455 renderer 架构下是数学自洽的**，并且本次实车 UI 已达到可用状态。

因此不要只删除 455→542 的 safeArea 换算而保留现有 542→455 GLES 缩放；那样反而可能使最终物理 safeArea 变小。

## 当前几何问题

当前版本已经能正常使用，但它并不等价于 OEM 原生 geometry pipeline。

固件逆向已经确认 OEM 显示管理链存在：

```text
Layout / ListModel geometry
        ↓
DisplayManager
        ↓
setPosition + setCropping
        ↓
DSI
        ↓
CDisplayable
        ↓
CGLRenderer / viewport
        ↓
Cluster
```

因此后续如果要进一步提高几何正确性，更合理的实验方向不是继续调 455→542 的补偿比例，而是研究：

```text
decoded 1440×542
        ↓
1:1 renderer
        ↓
displayable3 1440×542
        ↓
OEM-style position / cropping
        ↓
Cluster visible area
```

这条路线的潜在好处：

- 不再对整张地图做约 `455/542` 的纵向缩放；
- 地图、圆形、道路、图标等保持原始纵横比；
- FULL / SMALL / Sport / Classic 的最终物理布局可以更接近 OEM compositor 语义；
- CarPlay source-space geometry 与车机物理 geometry 的职责更清晰。

但目前仍需实车确认：

1. displayable3 是否能稳定创建为 `1440×542`；
2. Context80 是否能正常组合 542 高的 displayable3；
3. displayable3 是否能接受与 OEM 33 / 58 类似的 position / cropping 语义；
4. 四种布局最终是否需要额外的 DSI geometry 处理。

因此当前 V2 仍作为**已验证、可回退的稳定 baseline** 保留，不应在没有对照实验的情况下直接替换。

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
  - 本次测试表明该阶段不是当前主要性能瓶颈。

- **独立 SHM 数据通道**
  - H.264 证据：`/carplay111_h264`
  - 解码后画面：`/carplay111_decoded`
  - 通过 writer PID、generation、stream cookie 等信息区分不同连接会话。

- **source-driven 显示**
  - sidecar 不再使用旧版固定成功帧 sleep。
  - 无新帧时采用 5 ms polling。
  - decoded stall 120 ms 后记录诊断，但默认 freeze last good frame，不主动退出。

- **动态布局**
  - FULL / SMALL 双 viewArea。
  - `updateViewArea` 同 session 动态切换。
  - Classic / Sport 状态跟随 HMI。
  - Sport Small 使用当前实车测得的 `-476,0` map translation。
  - HMI state 短暂缺失时 retain previous placement。

- **Virtual Cockpit 输出**
  - 使用现有 GLES / displayable3 路径。
  - Java/HMI 继续作为 Context80 的唯一控制方。
  - sidecar 不直接修改终端 Context。

- **CarPlay 仪表导航外观增强**
  - `showUI` 的 Cluster Map URL 按 CarPlay Simulator 已观测格式启用 `showSpeedLimit=user`、`showCompass=user`、`showETA=yes`。
  - `maneuverLayout` 保持已观测到的空值形式。
  - 这三个开关只请求 iPhone / 导航 App 将限速牌、指南针和 ETA 直接绘制进 type111 导航视频，不改变 Private111、OMX、SHM、542→455、displayable3、Context80 或滚轮控制链。
  - 是否实际显示由当前导航 App 的 CarPlay Instrument Cluster 实现决定。

- **诊断与恢复**
  - 提供 INSTALL / START / STATUS / 日志保存 / 原车恢复流程。
  - 日志可区分 private111、H.264、解码帧、Screen 读取、SHM、displayable3、Context80、viewArea 和布局状态。

## 分支说明

| 分支 | 当前用途 |
| --- | --- |
| `main` | **正式开发主线。** 基于首次实车成功的 V2 路线。 |
| `experiment/oem-layout-second-screen_v2` | **当前布局 / source-driven 实车验证分支。** 已完成四布局、同 session viewArea、source-driven pacing 实车验证。 |
| `carplay-private111-direct-display-v2` | **首次实车点亮备份。** 用于回归对比和恢复。 |
| `carplay-private111-direct-display-v1` | **历史实验分支。** 用于回看早期 private111 / OMX / Context80 验证过程。 |

## 安装与测试

建议每次上车都从干净状态开始，不要同时混用不同实验分支的安装文件。

### 1. 准备测试 SD 卡

V3 分支已经按“**分支 ZIP 可直接安装**”方式发布。下载本分支的 GitHub `Download ZIP` 后解压，确认根目录存在：

```text
BRANCH-ZIP-READY.txt
VERIFY-BRANCH-ZIP-READY.sh
Toolbox/
```

其中 `BRANCH-ZIP-READY.txt` 必须包含 `BRANCH_ZIP_READY=YES`。如在电脑上具备 `sha256sum`，还可以在仓库根目录执行：

```bash
sh VERIFY-BRANCH-ZIP-READY.sh
```

看到 `BRANCH_ZIP_VERIFY=PASS` 后即可将**解压后的仓库根目录内容**复制到 SD 卡根目录。不要把 GitHub 自动生成的最外层 `altscreen-test-...` 文件夹本身再套一层复制到 SD 卡，否则车机会找不到根目录下的 `Toolbox/`。

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
启动支持仪表第二屏的导航路线
        ↓
依次测试 FULL / SMALL / Classic / Sport
        ↓
执行 STATUS / 保存完整日志
```

不要在一次测试中同时加入新的 decoder、`screen_blit`、新的 Context 或多项大范围显示结构修改，否则出现异常后很难判断是哪一层造成的。

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

布局动态切换还应观察：

```text
PHASE=ALT111_VIEWAREA_TARGET
PHASE=ALT111_VIEWAREA_SUBMIT
PHASE=ALT111_VIEWAREA_RESULT ... accepted=1

PHASE=OEM_MAP_PLACEMENT
PHASE=OEM_MAP_RERENDER
```

最终仍以 **Virtual Cockpit 是否实际出现正确且稳定的 CarPlay 第二屏画面** 为准。

## 当前已知问题

### 1. 当前 542→455 输出不是 OEM 原生几何实现

当前版本为了复用已经验证成功的 displayable3 路线，仍把 1440×542 decoded frame 通过 GLES 输出到 1440×455 surface。

它目前工作正常，但会引入纵向缩放。

后续是否值得改成：

```text
1440×542
→ 1:1 displayable3
→ position / cropping
```

应通过单独实验判断，而不是在当前稳定 V2 上直接大改。

### 2. sidecar CPU CSC 是下一步主要性能优化方向

Screen linearizer 当前 readback 延迟已经较低，且无明显 failure/drop。

如果后续需要进一步接近稳定 30 fps 或降低 CPU，占优先级更高的方向是：

```text
CPU NV12 → RGBA
```

的替代路径，例如评估 QNX `screen_blit` 或其它硬件辅助 CSC。

在 geometry 尚未收口前，不建议同时引入新的 decoder 或大范围性能架构变化。

### 3. decoded stall 日志较敏感

当前 120 ms 无新 decoded frame 即记录 stall，并 freeze last good frame。

导航画面本身可能存在静态帧 / burst 输出，因此部分 stall 日志并不代表显示链异常。

判断故障应同时结合：

- 是否出现持续黑屏；
- 是否出现 `EGL_SWAP_FAILED`；
- decoded / H264 是否持续前进；
- VC 实际画面是否停止更新。

### 4. CarPlay 断开后的原车导航箭头状态

早期测试中曾观察到：

- CarPlay 断开后，仪表恢复原车地图；
- 当时原车并没有开启导航路线；
- 仪表仍异常出现导航箭头。

这一现象更像是 CarPlay 第二屏退出后的 Context / 导航状态交接问题。

当前将其作为独立生命周期问题继续分析，不认为它推翻 private111 显示路线。

### 5. OEM 同 Context 覆盖 / 接管

此前移动测试中还观察到过 OEM HMI 在同一个 Context80 下重新生成布局后，原厂地图层重新盖到当前 displayable3 上方。

当时：

```text
Context = 80
displayable3 present 仍在继续
private111 / OMX / decoded frames 正常
```

因此该问题更像是同 Context 下的 compositor/layer ownership 重建，而不是第二屏流断开。

当前分支并未专门解决这一问题，后续如再次稳定复现，需要单独处理 HMI layout regeneration / layer reapply。

## 日志

主要运行日志位于：

```text
/tmp/MMI-Cockpit-Carplay/
```

其中会包含：

- private111 建连与 teardown；
- H.264 tap；
- Screen linearizer 延迟和进度；
- decoded SHM；
- sidecar present fps；
- displayable3；
- Java Context80；
- FULL / SMALL viewArea；
- Classic / Sport placement；
- CPU / 温度 / 内存等系统诊断。

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

当前阶段已经从“第二屏能否点亮”进入“显示质量与工程化收口”阶段。

稳定基线继续保持：

```text
private111
  → 原车 OMX
  → Screen linearizer
  → decoded SHM
  → source-driven sidecar
  → GLES / displayable3
  → Java Context80
  → Virtual Cockpit
```

后续优先级建议：

1. **保留当前 V2 作为实车已验证 baseline。**
2. 单独评估 `displayable3=1440×542 + 1:1 renderer` 的可行性。
3. 若 542 sink 可行，再研究 OEM-style position / cropping，而不是继续叠加 455↔542 补偿。
4. geometry 收口后，再考虑 CPU CSC / `screen_blit` 等性能优化。
5. 独立处理 OEM 同 Context 覆盖和 CarPlay teardown 后导航状态交接问题。

在没有新的实车证据前，不同时引入多项架构变化。
