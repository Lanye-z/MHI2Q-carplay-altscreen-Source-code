# 上车前请先阅读

当前分支：`experiment/oem-layout-second-screen`

## 当前用途

本分支基于已经实车点亮的 V2 显示链，同时叠加两组**尚待统一编译和实车验证**的增强：

1. `OEM_LAYOUT_OBSERVER_V1`：只读采集原厂 ListModel176 / Layout / DisplayManager 几何证据，不应用到 CarPlay 或 renderer。
2. yuedizhibo 日志与遥测增强：SD 优先的有界日志、逐帧 decode/present 时间、60 秒链路健康统计、独立 TAP_STOP 状态标记和日志轮转。

## 显示链保持不变

```text
private type111
→ stock OMX
→ stock private renderer
→ QNX Screen linearizer
→ /carplay111_decoded (SHM v2)
→ sidecar
→ CPU NV12→RGBA
→ GLES / displayable3
→ Java Context80
→ Virtual Cockpit
```

Main110 仍保持原车路径。

## 帧率策略

当前必须保持：

```text
producer / Screen readback: uncapped source callbacks
sidecar presentation:       30 fps
```

禁止重新引入 `P111_LINEARIZER_TARGET_INTERVAL_US`、`next_readback_due_us` 或 `rate_limit_skips` 一类 producer 限速器。

## 新增日志

SD 优先写入：

```text
MMI-Cockpit-Carplay/logs/altscreen_hook.log*
MMI-Cockpit-Carplay/logs/mirror.log*
MMI-Cockpit-Carplay/logs/mmi-mirror-controller.log*
MMI-Cockpit-Carplay/logs/boots/
```

关键遥测：

```text
FRAME_DECODE_TIMING
FRAME_PRESENT_TIMING
FRAME_CHAIN_HEALTH
LOG_QUEUE_DROPPED
DIAG_QUEUE_DROPPED
PHASE=HOOK_LOG_SEGMENT
```

生命周期停止不再依赖扫描大日志，而使用 `direct111_tap_stop.state` 的原子状态变化。

详细设计见：

- `Toolbox/carplay_alt_screen/LOGGING_DESIGN.md`
- `Toolbox/carplay_alt_screen/LOGGING_STATIC_ANALYSIS.md`
- `OEM-LAYOUT-OBSERVER-V1.md`

## OEM observer

本分支仍保持：

```text
apply_to_carplay=0
apply_to_renderer=0
```

因此当前版本**不会**根据原厂 geometry 改变 CarPlay safeArea、viewArea、displayable3 位置或视频尺寸。

## 当前发布状态

源码已经完成日志增强与 OEM observer 的融合，但二进制尚未统一重建。

预期当前状态为：

```text
HMI:
oem_geometry_build_status=SOURCE_CHANGED_REBUILD_REQUIRED
logging_build_status=SOURCE_CHANGED_REBUILD_REQUIRED

QNX:
release_binary_status=V2_BINARY_STALE_LOGGING_REBUILD_REQUIRED
vehicle_zip_status=NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED
```

**此状态下不要下载 ZIP 上车。**

下一步应先重建 Java 1.2 HMI JAR，再重建 QNX hook/sidecar，刷新全部 size/cksum/SHA256 和 manifest，最后运行 `VERIFY-NATIVE-DIRECT-RELEASE.sh`。
