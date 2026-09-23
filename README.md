> [!WARNING]
> **⚠️ SD 卡读写权限警告（2026-09-24）**
>
> 本分支为历史/实验/工具分支，**尚未同步当前统一的 SD 可写 preflight**（真实 write probe → 必要时 `mount -uw` → 再次 write probe）。如果 Toolbox/QNX 此时把 `/net/mmx/fs/sda*` 以只读方式挂载，旧版 INSTALL / START / RESTORE / 日志或备份流程可能出现 `sd_write_failed`、`SD_NOT_WRITABLE`，并中止操作。
>
> **不建议直接使用本分支进行新的实车安装、启动、卸载/恢复或写入型维护。** 需要上车请优先使用已完成统一 SD RW 修复并通过 CI 的 `experiment/oem-layout-second-screen_v3.3`；需要公开基础版则使用 `opensource/v1-basic-wheel`。
>
<!-- BRANCH_STATUS_BEGIN -->
> [!IMPORTANT]
> **分支用途：** 计划用于“原厂地图专用”的只读 plane census：在不启动 CarPlay 实验链的情况下，单独观察原厂地图 plane 33/58，并按 Classic Full / Classic Small / Sport Full / Sport Small 采样 QNX Screen 属性。
>
> **上车测试结论：** 未上车测试，也没有形成任何 V1.1 实车采样数据。该 observer 只完成了 QNX ARMv7 编译、release promotion、静态/CI 校验并达到 `READY_FOR_STOCK_MAP_CENSUS`。由于 `experiment/oem-layout-second-screen` 已经实车拿到了可用的四态 OEM 布局数据，V1.1 后续并没有实际用上。
>
> **当前定位：** 未使用的备用采样工具/历史分支；不要把其中的 READY 状态写成“已实车验证”。
<!-- BRANCH_STATUS_END -->

# OEM Plane Census V1.1

本分支是一个**只读原厂地图几何采样工具**，不是 CarPlay 第二屏功能版本。

## 原计划

V1.1 的目标是在原厂地图工作时，独立观察 QNX Screen 中与仪表地图相关的 plane/window，重点记录 displayable/plane 33、58 在以下四种状态下的属性：

- Classic Full
- Classic Small
- Sport Full
- Sport Small

采样程序使用 `SCREEN_WINDOW_MANAGER_CONTEXT` 监听 CREATE / PROPERTY / POST / CLOSE 事件，只读窗口属性，不修改 CarPlay `viewArea/safeArea`，不启动 private111，不切换 Context80，也不写 Screen property。

## 实际执行情况

本分支已经完成：

- QNX 6.5 ARMv7 observer 编译；
- release binary promotion；
- 安装、启动、状态、四态 CAPTURE、停止与卸载脚本；
- 静态 verifier / CI 校验；
- 状态达到 `READY_FOR_STOCK_MAP_CENSUS`。

但**没有实际安装到车上执行 V1.1 census**，因此没有 V1.1 的实车日志，也没有由本分支产生的四态原厂地图数据。

项目真正使用的第一批 Classic/Sport × Full/Small 实车布局数据，来自已经上车完成采集的：

`experiment/oem-layout-second-screen`

因此 V1.1 目前只保留为备用的 stock-map-only 采样工具和历史方案，不应把 `READY_FOR_STOCK_MAP_CENSUS` 理解为“已实车验证”。

详细设计见 [OEM-PLANE-CENSUS-V1.1.md](OEM-PLANE-CENSUS-V1.1.md)。
