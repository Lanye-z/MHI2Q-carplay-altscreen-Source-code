# OEM Layout Second Screen V3.3

> **用途：在 V3.2 已验证的 CarPlay Type111 第二屏基础上，正式接入 Audi VC 原厂灰色导航信息栏。**
>
> **实车状态：待 V3.3 首次实车验证。V3.2 的显示链、布局与滚轮功能保持不变；V3.3 新增部分仅为 CarPlay RGI 元数据到原厂 BAP lower bar 的接管。**

Branch: `experiment/oem-layout-second-screen_v3.3`

Baseline: `experiment/oem-layout-second-screen_v3.2`

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

V3.3 恢复最小 RGI metadata transport，但不恢复旧的自定义 RGI 图形渲染：

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
- V3.2 safeArea：
  - FULL: `370,0,700,455`
  - SMALL: `490,0,460,455`
- Classic / Sport 与 FULL / SMALL 观察及布局逻辑
- 方向盘滚轮 `changeMapZoomLevel`
- stall guard / target-follow pacing
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

缓存重放用于避免“RGI 元数据先到、导航 authority 后到”时首屏缺少路名、距离或 ETA。

## 9. V3.3 首次实车测试目标

第一次上车只验证新增 OEM lower-bar 链，不同时修改 Apple Maps 自己的视频内 ETA：

1. 灰栏到达时间是否与 CarPlay ETA 一致；
2. 当前道路是否跟随 CarPlay；
3. 剩余距离及单位是否正确；
4. 原厂比例尺是否继续正常显示并保持 stock 行为；
5. CarPlay 导航结束/断开后 stock lower bar 是否正常恢复；
6. Type111、V3.2 布局、滚轮和触摸是否无回归。

在以上项目通过前，V3.3 只标记为 **READY_FOR_V3_3_VEHICLE_TEST**，不标记为实车验证完成。
