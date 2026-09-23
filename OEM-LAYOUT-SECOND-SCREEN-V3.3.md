# OEM Layout Second Screen V3.3

> **用途：在 V3.2 已验证的 CarPlay Type111 第二屏基础上，正式接入 Audi VC 原厂灰色导航信息栏。**
>
> **实车状态：V3.3 已完成首轮实车观察，当前进入 safeArea 微调复测。Type111 显示链、1:1 renderer、横向 safeArea、RGI lower bar 与滚轮架构保持不变；纵向 safeArea 从 V3.2 的 `0..455` 收敛为 `60..450`，目标是让顶部指南针/控制项比 V3.1 略下移，同时让 ETA 保持低位但不完全贴底。**

Branch: `experiment/oem-layout-second-screen_v3.3`

Baseline: `experiment/oem-layout-second-screen_v3.2`


## 上车前收口（2026-09-23）

本轮收口保持 V3.2 已验证的 Type111 显示链、滚轮 target-follow 架构和触摸主链。首轮实车显示表明 `y=0,h=455` 的纵向 safeArea 过度放开：顶部指南针/控制项过高甚至消失，ETA 又过度贴底。因此 V3.3 仅收敛纵向边界为 **top=60、bottom=450（h=390）**；横向 X/W、viewArea、renderer、Sport 偏移、RGI/BAP 与滚轮协议均不改变。

- `visible_in_app=0` 只表示 CarPlay 导航界面未处于前台；只要 `route_state` 或已缓存的有效路线数据仍表明路线活跃，就继续保持 Fct19/21/22 ownership。显式、已由 native debounce 的 `route_state=NO_ROUTE_SET` 仍然结束接管。
- `CarplayBus` 在 Java 侧缓存 native sticky frame；RouteGuidance listener 晚注册时由 `on()` 在同一 bus lock 下本地重放最新 `EVT_RGD_UPDATE`。bus 保持 native→Java 单向，不再发送无效 `CMD_SYNC_REQ`。
- `start()/stop()/onFrame()` 使用同一对象 monitor 串行化，并在 `bap.onStart()` 前再次检查 `running`，防止断开 teardown 后旧 frame 重新锁住 lower bar。
- 导航结束或断开时，先清 `Fct19=""`、`Fct21=0`、`Fct22=invalid`，再解除 gate；CarPlay 明确发送空路名或 0 距离时也会立即清旧值。每次 owned update 与 teardown 前都会重新核对 `ClusterService` 当前 listener；若 HMI 生命周期中替换了 listener，会重新包一层 `GatedCombiService`，避免 detached gate 让 stock 与 CarPlay 同时写 Fct19/21/22。
- Fct45 仍为 **Audi stock passthrough**，不是 CarPlay 地图实际比例尺同步；这一点属于 V3.3 的明确功能边界，而不是已实现能力。
- V3.3 已继承 V3.2 后续的 wheel observability / SD diagnostics 增强；这些诊断改动只增加可观测性，不改变 wheel target-follow 行为。
- V3.3 后续实车表明固定 200 ms 会在快速滚轮时积累 5–7 档 backlog，并产生约 1.1–1.5 s 的停手后追赶尾巴；Apple Maps 还观察到新尺度外围延迟补绘。现改为 `BURST_ADAPTIVE_100_150_200_V2`：首格立即；输入活跃时第 1–2 档 100 ms、第 3–6 档 150 ms、第 7 档起 200 ms；300 ms 无新物理输入后，剩余 backlog ≤2 档用 100 ms 收尾，≥3 档用 150 ms 收尾；真实反向在目标跨入新方向后优先 100 ms 响应。telemetry 不可用仍走 250 ms fallback，send retry 仍为 150 ms。decoded frame 只作为 liveness，不解释为 camera animation 已完成。
- 两个 preload 保持 `AltScreen → RGI → libc`。父 CarPlay 进程完成装载后，供 `/bin/sh`、`pfctl` 等 helper `exec()` 继承的 `LD_PRELOAD` 会同时剔除 AltScreen 与 RGI 两个项目 hook；CI 同时审计共享 interposer 与 RGI 的额外 `read/open/writev/MsgSend/MsgSendv` 表面。
- `V3.3 HMI/RGI audit` 已改为检查当前包名和真实 bytecode/source invariants；缺类或关键生命周期约束丢失会直接失败，不再以 `|| true` 掩盖。


## 1. V3.3 目标

V3.3 不再尝试隐藏 Audi VC 原厂灰色导航栏，也不在 Type111 视频上自行绘制 ETA/文字。

目标是保留 Audi 原生 HMI，并把 CarPlay 导航元数据送入原厂已有槽位：

| VC 原生项目 | BAP | V3.3 数据源 / 所有权 |
| --- | --- | --- |
| 到达时间 | FctID 22 TimeToDestination | CarPlay RGI，发送绝对 ETA |
| 当前道路 | FctID 19 CurrentPositionInfo | CarPlay RGI |
| 剩余距离 | FctID 21 DistanceToDestination | CarPlay RGI |
| 比例尺 | FctID 45 MapScale | **原厂 stock passthrough** |

目标视觉效果保持 Audi OEM 结构，例如：

```text
13:34 到达     江海南路     4.4 km     20m
```

V3.3 **不发布剩余时间文本**，不把 `12 min` 拼入 FctID 19，也不修改 VC gtf2 布局。

## 2. 所有权边界

新增 `GatedCombiService` 只在 CarPlay Route Guidance 活跃期间阻止 stock navigator 写入：

- FctID 19
- FctID 21
- FctID 22

CarPlay 停止导航或断开时立即释放这三个字段，恢复 stock navigator。

下列功能始终保持原厂所有权：

- FctID 16 CompassInfo
- FctID 20 TurnToInfo
- FctID 45 MapScale
- FctID 47 Altitude
- 其它 maneuver / lane / map lifecycle BAP

特别地，V3.3 的 `BAPBridge` **没有 `updateMapScale()` 写入路径**。比例尺继续由 Audi 原生导航栈绘制和更新。

## 3. 元数据路径

V3.3 **只消费 RGI metadata 子集**，不恢复旧的自定义 RGI 图形渲染。当前固定 SHA 的 `libcarplay_rgi_meta.so` 实际来自完整 RGI hook，仍包含 CoverArt 等历史模块；V3.3 lower-bar 不消费这些额外模块，因此明确标记为 `PINNED_FULL_RGI_HOOK_METADATA_CONSUMER_ONLY`，不再把二进制描述成真正裁剪后的 metadata-only build：

```text
iPhone / CarPlay
     │
     │ iAP2 RGI 0x5200..0x5204
     ▼
libcarplay_rgi_meta.so
     │
     ▼
CarplayBus / EVT_RGD_UPDATE
     │
     ▼
RouteGuidance
     │
     ▼
BAPBridge
     ├── Fct19 current road
     ├── Fct21 distance to destination
     └── Fct22 absolute ETA
     │
     ▼
Audi VC OEM lower bar
```

`dio_manager.json` 只注册标准 RGI 消息集合：

- accessory -> phone: `0x5200`, `0x5203`
- phone -> accessory: `0x5201`, `0x5202`, `0x5204`

安装脚本使用 fail-closed 的 `altscreen_v33_rgi_config.sh`：仅接受“全部不存在”或“全部已正确存在”，拒绝 MIXED/重复/不完整状态。

## 4. RGI metadata binary

V3.3 使用独立项目路径：

```text
/mnt/app/root/carplay-altscreen/lib/libcarplay_rgi_meta.so
```

其发布身份固定为：

```text
SHA-256:
87d10f67fbb3dc142642d899977bab0a6eb4009f61d3bcd873d0cce9e01511f7
```

安装后 LD_PRELOAD 的项目内顺序为：

```text
libcarplay_altscreen.so : libcarplay_rgi_meta.so : other stock/third-party entries
```

旧路径 `/mnt/app/root/hooks/libcarplay_hook.so` 不并存，避免重复 RGI hook。

## 5. V3.2 保持不变的部分

以下内容不因 V3.3 lower-bar 功能而改变：

- private Stream111 协商与 Type111 视频源
- stock OMX 解码
- `/carplay111_decoded` decoded SHM
- displayable3
- Java 独占 Context80，`ctx80={98,101,102,3}`
- V3.1 1:1 renderer + 1440x455 可见区
- V3.3 tuned safeArea：
  - FULL: `370,60,700,390`
  - SMALL: `490,60,460,390`
  - top = `60`
  - bottom = `450`
  - 横向仍完全继承 V3.1/V3.2：FULL `370/700`、SMALL `490/460`
- Classic / Sport 与 FULL / SMALL 观察及布局逻辑
- 方向盘滚轮 `changeMapZoomLevel` 协议、target-follow / retarget / stall / rebase 架构
- V3.3 滚轮 pacing 更新为 burst-aware adaptive：首格立即；active 100/150/200 ms；停手后小 backlog 100 ms、大 backlog 150 ms；telemetry fallback 250 ms
- 安装、卸载事务与 SD 日志框架

## 6. 触摸功能

触摸不作为“残留”删除。

V3.3 明确保留现有：

```text
com/luka/carplay/cursor/CursorController
```

因此 MMI 触摸板相关能力继续作为正式输入模块存在，与 lower-bar BAP 模块分离。

## 7. Java 代码整理

V3.3 将历史 Route Guidance 代码收口为 lower-bar metadata controller：

```text
CarPlay HMI
├── ClusterStateController     Context80 / layout
├── WheelZoomBridge            steering wheel zoom
├── CursorController           MMI touch input
└── routeguidance/
    ├── RouteGuidance          RGI metadata state
    ├── AmapRouteGuidance      existing app seam
    ├── BAPBridge              Fct19 / 21 / 22 only
    └── GatedCombiService      lower-bar ownership gate
```

旧 routeguidance 包中的自定义 Renderer / ManeuverMapper / SideStreets class 在 V3.3 JAR 构建时删除，不再让历史自定义 RGI 图形链与 Type111 第二屏混在一起。

## 8. 启动/恢复原则

CarPlay RGI 激活：

```text
metadata authority active
        ↓
acquire Fct19/21/22
        ↓
replay cached current road / distance / ETA
        ↓
continue delta updates
```

CarPlay 导航停止或断开：

```text
release Fct19/21/22 gate
        ↓
stock navigator regains ownership
```

缓存重放用于避免“RGI 元数据先到、导航 authority 后到”时首屏缺少路名、距离或 ETA。`source_supports_rg=0` 与经过 native debounce 后真正送到 Java 的 `route_state=0` 都会同时失效 Java 内的道路/距离/ETA/剩余时间缓存，防止下一次 re-enable 重新发布上一条路线。

当 `source_name` 明确识别为高德/Amap/Gaode，**或 source_name 缺失但已先观察到真实活跃路线**，随后出现 `route_state=1 + maneuver_count=0 + visible_in_app=0` 时，V3.3 启用 5 秒行为探测 grace；真实变化的道路/距离/ETA/剩余时间会续期，持续无变化超时后释放 lower bar。已明确识别为非高德的 source 不进入该探测。这个边界与成熟 RGI 兼容逻辑一致，解决部分 snapshot 不提供 `source_name` 时的无限 ownership 风险。

## 9. V3.3 滚轮 pacing 修正

V3.2/V3.3 实车已经给出两类相反约束：固定 100 ms 的连续缩放主观最顺，但 Apple Maps 曾出现比例尺继续变化而底图 camera 冻结；固定 200 ms 虽降低瞬时命令密度，却在快速滚轮时形成明显 target backlog，用户停手后仍可能继续追档约 1.1–1.5 秒，并观察到 Apple Maps 新尺度外围延迟补绘。

因此 V3.3 保留 `OEM_TARGET_FOLLOW_V1`，只把 pacing 改成 `BURST_ADAPTIVE_100_150_200_V2`：

- 第一格：立即发送；
- 输入仍活跃（距最近物理滚轮事件 <300 ms）时：第 1–2 档 100 ms，第 3–6 档 150 ms，第 7 档起 200 ms；
- 输入停止 ≥300 ms 后：剩余 backlog ≤2 档用 100 ms 收尾，backlog ≥3 档用 150 ms 收尾；
- 物理方向反转后保留 reverse-response pending；当 desired target 真正跨入新物理方向时，下一条命令优先使用 100 ms；
- decoded progress 只作为 liveness evidence；不把任意新 frame 或 `status=0` 当作 camera animation completion；
- telemetry 不可用时仍使用 250 ms fallback；
- send failure retry 仍为 150 ms；
- `target limit ±12`、stall/recovery、settled rebase、50 ms scheduler tick 均不变；
- 不做 Apple Maps/高德应用特判，也不做地图像素识别。

## 10. V3.3 首次实车测试目标

第一次上车只验证新增 OEM lower-bar 链，不同时修改 Apple Maps 自己的视频内 ETA：

1. 灰栏到达时间是否与 CarPlay ETA 一致；
2. 当前道路是否跟随 CarPlay；
3. 剩余距离及单位是否正确；
4. 原厂比例尺是否继续正常显示并保持 stock 行为；
5. CarPlay 导航结束/断开后 stock lower bar 是否正常恢复；
6. Apple Maps 连续同方向滚动 6–10 格时，比例尺与底图 camera 是否始终同步变化；
7. Apple Maps 到缩放边界后立即反向滚动 4–6 格，底图是否能正常反向恢复；
8. 高德重复相同测试，确认短 burst 100 ms 恢复接近原 100 ms 版本的连续感，同时长 burst 能平滑过渡到 150/200 ms；
9. Type111、V3.2 布局、target-follow 方向反转、触摸是否无回归。

在以上项目通过前，V3.3 只标记为 **READY_FOR_V3_3_VEHICLE_TEST**，不标记为实车验证完成。
