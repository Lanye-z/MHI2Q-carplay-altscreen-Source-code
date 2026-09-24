# Runtime Residue Quarantine V1

这个分支基于 `experiment/oem-layout-second-screen_v3.4`，只增加一个针对历史残留
`/mnt/app/root/carplay-altscreen` 的安全救援工具。

## 为什么不是直接 rm -rf

V3.4 会拒绝接管“非空且没有合法 owner 标记”的 runtime。这个保护是正确的，因为程序不能仅凭路径就假定目录一定属于本项目。

本工具采用固定隔离槽位：

```text
/mnt/app/root/carplay-altscreen
        ↓ atomic mv
/mnt/app/root/.carplay-altscreen.rescue-v1
```

不递归删除任何文件，因此如果识别结果不对或需要回退，可以恢复原目录。

## 安全条件

只有同时满足以下条件才允许 QUARANTINE：

1. runtime 是普通目录，不是 symlink；
2. 没有合法的当前 V3.4 owner；
3. 顶层只允许 `bin/`、`lib/`、`state/`；
4. 至少命中 2 个本项目 runtime 指纹文件；
5. SD 卡存在可信恢复集：
   - `MMI-Cockpit-Carplay/backup/original/COMPLETE`（兼容旧的 `ORIGINAL`）
   - `MMI-Cockpit-Carplay/backup/universal-hook-original/COMPLETE`
6. 固定 quarantine 槽位尚不存在。

任一条件不满足都只报错，不修改 `/mnt/app`。

## 上车顺序

1. 将该分支内容放到 SD 根目录并执行 **Update Toolbox**。
2. 进入 **Runtime-Residue-Rescue**。
3. 先执行 **1) CHECK RUNTIME RESIDUE**。
4. 只有看到：
   `RESCUE_STATE=LEGACY_UNOWNED_RECOGNIZED safe_to_quarantine=YES`
   时，才执行 **2) QUARANTINE OLD RUNTIME**。
5. 成功后应看到：
   `QUARANTINE=PASS ... deletion=NONE reversible=YES`
6. 此时原路径已空，可以进入 **MMI-Cockpit-Carplay** 执行 V3.4 **INSTALL**。
7. V3.4 INSTALL 完成后完整重启车机，确认 CarPlay、第二屏、原车功能和再次启动均正常。
8. 可以再执行一次 **1) CHECK RUNTIME RESIDUE**；此时正常应看到：
   `RESCUE_STATE=V3_4_WITH_QUARANTINE current_runtime=VERIFIED safe_to_delete=YES`。
9. 确认无误后，才执行 **4) DELETE QUARANTINE (FINAL)** 永久删除旧隔离 runtime。

**3) RESTORE QUARANTINE** 只用于还没有安装新 V3.4 runtime 时回退。
如果 `/mnt/app/root/carplay-altscreen` 已经存在，新 runtime 不会被覆盖，恢复操作会拒绝执行。

## 最终删除保护

**4) DELETE QUARANTINE (FINAL)** 是不可逆操作，因此脚本不会只因为 quarantine 存在就删除。
它会再次要求：

- 当前 `/mnt/app/root/carplay-altscreen` 有合法项目 owner；
- owner 明确包含 `runtime=carplay-altscreen`；
- 当前 runtime 的 `bin/mirror/BUILD_INFO.txt` 明确标记 `PRIVATE111_DIRECT_DISPLAY_V3_4`；
- 当前 runtime 已有 `state/diagnostics.enabled`，即 V3.4 INSTALL 已完整提交；
- quarantine 仍通过旧项目 runtime 指纹、目录结构、无 symlink 和可信 OEM backup 校验。

全部通过后，只删除：

```text
/mnt/app/root/.carplay-altscreen.rescue-v1
```

不会删除当前 V3.4 runtime，也不会删除 SD 卡中的 OEM backup。

日志固定写到：

```text
MMI-Cockpit-Carplay/logs/runtime-residue-rescue.log
MMI-Cockpit-Carplay/logs/runtime-residue-rescue.previous.log
```

只保留当前和上一份，不会按次数无限堆积。
