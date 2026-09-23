> [!WARNING]
> **⚠️ SD 卡读写权限警告（2026-09-24）**
>
> 本分支为历史/实验/工具分支，**尚未同步当前统一的 SD 可写 preflight**（真实 write probe → 必要时 `mount -uw` → 再次 write probe）。如果 Toolbox/QNX 此时把 `/net/mmx/fs/sda*` 以只读方式挂载，旧版 INSTALL / START / RESTORE / 日志或备份流程可能出现 `sd_write_failed`、`SD_NOT_WRITABLE`，并中止操作。
>
> **不建议直接使用本分支进行新的实车安装、启动、卸载/恢复或写入型维护。** 需要上车请优先使用已完成统一 SD RW 修复并通过 CI 的 `experiment/oem-layout-second-screen_v3.3`；需要公开基础版则使用 `opensource/v1-basic-wheel`。
>
<!-- BRANCH_STATUS_BEGIN -->
> [!IMPORTANT]
> **分支用途：** 维修/恢复工具分支，用来扫描历史 `basevideo3` / mirror / CarPlay AltScreen 安装残留，先只读识别，再对明确命中的遗留项做备份后安全清理；它不是第二屏显示功能分支。
>
> **上车测试结论：** 已在实车上运行过扫描：曾识别出 49 个历史 basevideo3/mirror 遗留项，约 2.89 MB，并发现 `smartphone_integrator.json` 仍有旧引用而对应 `.so` 已不存在。后续针对 QNX `/tmp`/目录兼容问题又修过清理逻辑并通过 CI，但尚未记录一份“最新修复版已完整清理成功”的最终实车验收结果。
>
> **当前定位：** 故障排查/存储恢复工具；扫描能力有实车证据，最新清理流程仍应按 fail-closed 原则看待。
<!-- BRANCH_STATUS_END -->

# MHI2Q AltScreen 存储残留扫描与恢复工具

本分支只用于**扫描、备份和清理历史安装残留**，不负责 CarPlay 第二屏显示，也不应拿它与 V2/V3/V3.1/V3.2 的画面功能做比较。

## 工具目标

重点处理历史测试过程中可能遗留的：

- `startup.sh.basevideo3.*` / `startup.sh.mirror.*` 等旧启动脚本；
- 已失效的 AltScreen/Mirror 运行时文件或引用；
- 历史安装产生但当前版本不再使用的受控残留；
- `smartphone_integrator.json` 与实际 preload/native 文件不一致的情况。

工具遵循“先扫描、先备份、再清理”的原则。无法确认的路径、权限异常、QNX 不支持的临时目录操作或备份失败时，应直接拒绝继续清理，而不是猜测性删除。

## 已有实车结果

已进行过实车扫描，曾发现：

- 49 个历史 basevideo3/mirror 遗留项；
- 总量约 2.89 MB；
- `smartphone_integrator.json` 仍存在旧引用，但对应的 `.so` 已不存在。

后续测试还暴露过 QNX `/tmp` 嵌套目录创建兼容问题；当时工具按 fail-closed 逻辑拒绝继续清理，没有扩大删除范围。之后相应清理流程已经修正并通过 CI/静态校验，但当前没有记录到“最新修复版已在实车完成整套清理并再次验收”的最终结论。

因此本分支应理解为：

`实车扫描已验证 / 最新完整清理流程仍待最终实车验收`
