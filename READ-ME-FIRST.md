# AUG22 第二屏统一 UNIVERSAL 测试包

供已经安装 Toolbox 的测试车机使用，不是 SWDL 固件刷写包。

## 2026-09-17 路由策略变更

从本版本开始，**K1004 / P1404 profile 不再参与正常安装和运行**。所有通过 AUG22 支持门禁的车机统一走：

`dio_manager + stock libairplay/Nme + LD_PRELOAD libcarplay_altscreen.so`

正常 INSTALL 不再根据 K1004/P1404 指纹选择三库 overlay，也不再部署 `profiles/K1004` 或 `profiles/P1404` 中的 `libairplay.so / libairplax.so / libNmeBaseClasses.so`。

`Toolbox/carplay_alt_screen/profiles/K1004`、`P1404` 和 `altscreen_chain_test_known.sh` **暂时保留在仓库中，仅用于历史分析、回归比对和旧安装恢复**。不要继续为新固件增加同类 profile；后续兼容性应优先在 universal resolver 中解决。

> 兼容迁移：如果 SD 状态中仍记录 `firmware_profile.txt=K1004` 或 `P1404`，说明车辆上仍可能存在旧 profile 安装。此时 START/STATUS/COLLECT 不再调用旧运行分支；请先执行 **RESTORE ORIGINAL**，完整重启 MMI，再使用本版本重新 INSTALL。旧 known controller 仅为完成这一步 RESTORE 而保留。

## 当前安装流程

1. 将 ZIP 内容完整覆盖到测试 SD，保留本车已有 `MMI-Cockpit-Carplay/backup` 和 `logs`；不要把另一台车的备份带过来。
2. 断开 iPhone，通过 Toolbox 更新脚本和菜单，进入 MMI-Cockpit-Carplay。
3. 点 INSTALL。支持的 AUG22 车机应显示：
   - `ROUTER_PROFILE=UNIVERSAL policy=AUG22_UNIVERSAL_ONLY`
   - `FIRMWARE_PROFILE=UNIVERSAL source=aug22_unified_policy stock_reuse=YES`
   - `UNIVERSAL_PRELOAD=INSTALLED ... resolver=ELF_DYNAMIC_RELOCATION`
4. INSTALL 完成后完整重启 MMI。
5. 点 START，再完整重启 MMI，然后连接 iPhone 并开始导航。
6. STATUS / STORE LOGS 用于确认 universal preload、type 111 建链和仪表显示状态。
7. 测试结束后执行 RESTORE ORIGINAL，并按提示完整重启。

## 安装影响面

UNIVERSAL 路径不会替换原车 `dio_manager`、`/eso/lib/libairplay.so` 或原厂 Nme。安装器会备份这些文件和 CarPlay 配置用于完整恢复，但正常运行直接复用原厂实现。新增的运行库为：

`/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so`

并通过 `smartphone_integrator.json` 的 `LD_PRELOAD` 装入。安装器仍会维护 type 111 动态 TCP dataPort 所需的 PF 规则，并保留事务回滚与原始配置恢复。

`SELECT_PROFILE` 不再用于正常安装。即使旧脚本显式请求 `K1004` 或 `P1404`，新路由也只把它当作已废弃的别名并转到 UNIVERSAL，不会部署对应 profile overlay。

## 重要验证边界

这次修改首先完成的是**路由和安装行为统一**。现有 `universal/libcarplay_altscreen.so` 虽然采用动态符号/ELF relocation 解析并直接复用 stock 库，但其二进制内部仍可看到历史 `p1404_*` 命名和部分 P1404 ABI 防护逻辑。因此，“所有车统一走 UNIVERSAL”不等于“universal hook 内部已经完全去固件化”。

K1004/P1404 改走 universal 后需要重新进行实车回归，至少确认：认证、type 111 descriptor、listener/dataPort、accept、StartSession、ProcessFrames、Main110 共存、断连/重连和原车导航恢复。若 universal resolver 在某个固件上无法安全解析必要 ABI，应优先修复动态解析/签名验证，而不是恢复 profile overlay 作为正常安装路径。

历史 K1004/P1404 profile 的 ABI、LIVI 对照和旧 overlay 设计记录仍保留在 `TECHNICAL-NOTES.md` 与 `profiles/` 中，仅供参考。

## 2026-09-17 仪表未点亮修复

本次黑屏采集证明 type 111 已完成 listener、accept、StartSession、持续收帧和首帧 POST，DisplayManager 也创建了 Window58；但三次进程快照均没有 `carplay-alt111-mirror-display`，采集包中也没有 Mirror/autostart 日志。因此这次不是“手机第二屏流没有进入车机”，而是最后的 Window58 → 仪表显示链没有运行。完整证据和边界见 `INCIDENT-20260917-NO-DISPLAY.md`。

正式架构由 universal hook 把真实帧提交到 private111 Window58，再由集成 Mirror sidecar 读取 Window58、输出 displayable 3 并负责 context 76/74；当前交付物的 hook 内 direct context route 为 disabled。只有 Window58 首帧 POST 不能证明仪表已经点亮。

修复后，底层 controller 不再允许绕过集成 START 单独激活 type111，并会在激活前校验 Mirror 二进制、启动脚本和 ownership marker。STATUS 在活动状态下必须同时显示：

```text
MIRROR_INSTALLED=YES
MIRROR_AUTOSTART=ENABLED
MIRROR_PROCESS=RUNNING
MIRROR_HEALTH=PASS
```

尚未开始导航时 `MIRROR_FIRST_FRAME=WAITING` 是正常的；开始导航并点亮后应变为 `READY`。若出现 `chain_active_but_autostart_disabled` 或 `chain_active_but_sidecar_not_running`，STATUS 会返回失败，不能继续把 ACTIVE 标记当作点亮成功。boot diagnostics 现在还会采集 Mirror runtime/state、`mirror.log` 和 `mirror_autostart.log`。

包内 `HOST_VALIDATION.json` 是二进制构建时的原始记录；本次启动链热修复的主机验证见 `HOTFIX_VALIDATION.json`。实体仪表回归仍需重新 INSTALL、集成 START、完整重启后执行。
