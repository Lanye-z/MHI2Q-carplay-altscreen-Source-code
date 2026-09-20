# OEM 原厂布局观察版 V1

> 分支：`experiment/oem-layout-second-screen`
>
> 目的：在不改变当前 Private111 → OMX → decoded SHM → GLES/displayable3 → Context80 显示链的前提下，
> 一次实车采集 K1004 OEM 布局实际几何，为后续 CarPlay view/safe area 与 renderer geometry 映射提供证据。

## 当前状态

本版本是 **OBSERVE ONLY**。

明确不做：

- 不修改 `p1404_airplay.c` 的 `viewAreas/safeArea`；
- 不修改 Type111 广告/协商尺寸；
- 不修改 sidecar 目前的输出矩形；
- 不调整 displayable3；
- 不切换或移动 OEM displayable33/58；
- 不使用 1440×445、1440×455、1440×542 作为 OEM 硬编码依据。

逆向已经确认：

- OEM 布局模型为 ListModel 176；
- 仪表使用 row 1；
- Full 使用 tube columns 11/12；
- Small 使用 tube columns 13/14；
- map offset 为 columns 24/25；
- `getVisibleArea()` 的公式为：
  - `x = tubeLeft - mapOffsetLeft`
  - `y = reiterlineTop - mapOffsetTop`
  - `w = screenWidth - tubeLeft - tubeRight`
  - `h = screenHeight - reiterlineTop - infolineBottom`

但以下数据仍必须由实车给出：

- ListModel 176 row1 的实际值；
- Classic/Sport 与 Full/Small 的真实差异；
- displayable33/58 的真实 destination/source/buffer W/H；
- 1440×542、455、445 各自属于哪一层。

## 实车新增文件

### 1. 当前完整快照

```
/tmp/carplay-oem-geometry.state
```

关键字段包括：

```
valid=
revision=
timestamp_ms=

nav_view_size_choice=
view=
layout_class=
layout_hint=

row1_column_count=
row1_values=

screen_width=
screen_height=

tube_left_full=
tube_right_full=
tube_left_small=
tube_right_small=

map_offset_left=
map_offset_top=
map_width_raw=
map_height_raw=
map_width_effective=
map_height_effective=

visible_full_x=
visible_full_y=
visible_full_w=
visible_full_h=

visible_small_x=
visible_small_y=
visible_small_w=
visible_small_h=

visible_active_x=
visible_active_y=
visible_active_w=
visible_active_h=

layout_const_80=
layout_const_81=
layout_const_108=
layout_const_109=
layout_const_114=
layout_const_115=

apply_to_carplay=0
apply_to_renderer=0
```

最后两项必须保持为 0；如果不是，说明本观察版契约被破坏。

### 2. 四态变化历史

```
/tmp/carplay-oem-geometry.log
```

每次 ListModel176 / ViewSize / Layout 常量的组合变化时，都会自动写入一份完整快照。

因此一次测试可以依次切换：

```
Classic Full
Classic Small
Sport Full
Sport Small
```

最后只需统一收集日志，不必每切一次就手工复制 state 文件。

### 3. DisplayManager 只读能力元数据

```
/tmp/carplay-oem-displaymanager-read-api.log
```

该文件仅枚举运行时 DisplayManager 中与：

```
displayable
extent
position
size
source
```

相关的方法签名。

本版本 **不会调用这些 getter**，更不会调用任何 setter。目的是确认下一步能否安全读取 displayable33/58 extent，而不是猜 API。

### 4. Controller 日志

```
/tmp/mmi-mirror-controller.log
```

关注：

```
OEM_GEOMETRY_OBSERVER
OEM_DISPLAYMANAGER_API
```

## 建议的一次实车流程

1. 安装该实验分支构建包。
2. 正常连接 CarPlay，确认当前 Type111 第二屏行为与 V2 基线一致。
3. 保持导航运行。
4. 依次进入 Classic Full、Classic Small、Sport Full、Sport Small；每种状态稳定停留数秒。
5. 不需要重连 CarPlay。
6. 测试结束后统一收集：
   - `/tmp/carplay-oem-geometry.state`
   - `/tmp/carplay-oem-geometry.log`
   - `/tmp/carplay-oem-displaymanager-read-api.log`
   - `/tmp/mmi-mirror-controller.log`
   - 当前 AltScreen / Direct111 原有日志
7. 最好同步记录四种状态的仪表照片。

## 关于 updateViewArea 的结论

本轮固件报告在 stock `libairplay.so` 中没有发现：

```
updateViewArea
viewArea
safeArea
initialViewArea
```

等字符串，因此证明 **stock K1004 自身没有使用这套命令的静态证据**。

但这还不足以证明：

> 我们不能通过通用 `AirPlayReceiverSessionSendCommand` 自行构造并发送 `updateViewArea`。

`AirPlayReceiverSessionSendCommand` 本身是通用命令入口时，命令字符串可能完全由调用者构造，不需要预先硬编码在 `libairplay.so` 内。

因此当前工程判定为：

```
STOCK_UPDATE_VIEWAREA_USAGE = NOT_FOUND
CUSTOM_SENDCOMMAND_CAPABILITY = UNRESOLVED
```

在没有进一步 ABI/实车验证之前，不删除动态 view-area 研究路线，也不在本观察版发送任何此类命令。

## 下一阶段 Gate

只有拿到上述实车数据后才进入真正的几何适配：

1. 证明 OEM MapViewer Rect 与实际仪表/plane 坐标的映射；
2. 确定 CarPlay canvas 到 OEM 可视区域的 transform；
3. 再修改 `p1404_airplay.c` 的 view/safe area；
4. 再决定 sidecar 是否需要 source/destination rect；
5. 最后单独验证连接中的动态 ViewArea 切换。

本观察版不能宣称已经解决左上角遮挡。
