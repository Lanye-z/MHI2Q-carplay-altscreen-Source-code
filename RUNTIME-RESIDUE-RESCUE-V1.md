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

## 不安装 V3.4、先恢复原厂的推荐流程

对于已经存在历史 unowned runtime、但目标只是先确认原车状态的车辆，可以不执行 V3.4 INSTALL：

```text
CHECK
  ↓
QUARANTINE OLD RUNTIME
  ↓
V3.4 RESTORE ORIGINAL
  ↓
完整重启 MMI
  ↓
验证原车 CarPlay / 原车功能
  ↓
再次 CHECK
  ↓
DELETE QUARANTINE (FINAL)
```

恢复成功后，CHECK 会重新核对 OEM 原始文件、preload、pf.conf、HMI JAR、startup 和 runtime 状态。
如果全部与可信 backup 一致，应显示：

```text
OEM_VERIFY=PASS ...
RESCUE_STATE=OEM_RESTORED_WITH_QUARANTINE current_runtime=ABSENT safe_to_delete=YES
```

此时最终删除只删除旧隔离目录，不要求安装 V3.4。

注意：V3.4 RESTORE 的 recovery route 使用当前标准路径
`MMI-Cockpit-Carplay/backup/original/`。旧卡如果是 `backup/ORIGINAL/`，建议在电脑上改成小写 `original` 后再上车。

## 日志与最终删除前备份

救援工具不再使用一个会被后续动作覆盖的公共日志。每种动作使用独立固定日志：

```text
MMI-Cockpit-Carplay/logs/rescue/
  runtime-residue-rescue-check.log
  runtime-residue-rescue-check.previous.log
  runtime-residue-rescue-quarantine.log
  runtime-residue-rescue-quarantine.previous.log
  runtime-residue-rescue-restore.log
  runtime-residue-rescue-restore.previous.log
  runtime-residue-rescue-delete.log
  runtime-residue-rescue-delete.previous.log
  runtime-residue-rescue-restore-backup.log
  runtime-residue-rescue-restore-backup.previous.log
```

因此典型的 `CHECK → QUARANTINE → OEM RESTORE → CHECK → DELETE` 流程中，第一次 CHECK 会在第二次 CHECK 时转成
`runtime-residue-rescue-check.previous.log`，其余动作各自保留，不会互相覆盖，也不会按点击次数无限创建新文件。

V3.4 自己的 **RESTORE ORIGINAL** 仍保留完整 operation journal，位置为：

```text
MMI-Cockpit-Carplay/logs/operations/restore_YYYYMMDD_HHMMSS.log
```

该日志捕获 RESTORE ORIGINAL 的 stdout/stderr、preflight、事务快照、APPLY、逐文件恢复校验、COMMIT 或 rollback 结果。

### DELETE QUARANTINE 的额外保险

执行 **4) DELETE QUARANTINE (FINAL)** 时，不再直接删除车机里的旧 runtime。删除前必须先创建：

```text
MMI-Cockpit-Carplay/rescue-backup/runtime-residue-v1/
  COMPLETE
  payload/
  meta/
    files.manifest
    dirs.manifest
    source_path
    target_state
    purpose
```

其中 `payload/` 是整个：

```text
/mnt/app/root/.carplay-altscreen.rescue-v1
```

的完整文件内容副本。

创建过程为：

```text
quarantine
  ↓
复制到 SD 临时 staging
  ↓
为源目录生成文件 cksum/size manifest
  ↓
为 SD 副本重新生成 manifest
  ↓
逐项 cmp
  ↓
写 COMPLETE
  ↓
发布为固定 rescue-backup
  ↓
再次与车机 quarantine 对比
  ↓
全部 PASS
  ↓
才允许 rm -rf 车机 quarantine
```

因此如果 SD 备份创建、校验、同步或发布任一步失败：

```text
DELETE_QUARANTINE=REFUSED
reason=FINAL_SD_BACKUP_FAILED
production_changed=NO
```

车机里的 quarantine 不会被删除。

已有 `runtime-residue-v1` 备份不会被静默覆盖：
- 如果与当前 quarantine 完全一致，直接复用；
- 如果内容不同，DELETE 会拒绝，保留旧备份和车机 quarantine。

最终删除后还会再次验证 SD backup 完整性。

如以后确实需要重新取回被删掉的旧 runtime，可执行：

```text
5) RESTORE SD BACKUP TO QUARANTINE
```

它只会把已校验的 SD `payload/` 重建到：

```text
/mnt/app/root/.carplay-altscreen.rescue-v1
```

不会覆盖当前 `/mnt/app/root/carplay-altscreen`。之后是否使用 **3) RESTORE QUARANTINE** 恢复为活动 runtime，由人工决定。

OEM 原厂备份目录：

```text
MMI-Cockpit-Carplay/backup/
```

与这个 rescue backup 完全分开，最终删除不会修改 OEM backup。

## 2026-09-24 上车前收口：V3.4 RESTORE readiness gate

当前版本不再把旧的 `backup/ORIGINAL/` 视为可直接进入急救流程的正式恢复介质。
最新 V3.4 的 recovery route 使用：

```text
MMI-Cockpit-Carplay/backup/original/
```

所以如果 CHECK 只发现旧的大写目录，会明确拒绝并记录：

```text
BACKUP_TRUST=FAIL
reason=CANONICAL_ORIGINAL_MISSING
found_legacy_uppercase=YES
action=RENAME_ORIGINAL_TO_original_ON_PC
```

在执行 **2) QUARANTINE OLD RUNTIME** 前/期间，救援脚本会校验：

- canonical `backup/original` 的 5 个 native 成员、manifest、每个 cksum；
- overlay_dir / overlay_present；
- firewall original + cksum；
- universal-hook original 的 present/path/cksum 状态；
- HMI backup 的 target、present/absent 唯一性和 cksum；
- boot-diagnostics COMPLETE；
- 当前 live HMI 是否与可信 backup 冲突；
- startup.sh 去掉项目自启动块后的 shell 语法。

旧 runtime 移入 quarantine 后，还会直接调用**当前 SD 卡上的 V3.4 `altscreen_chain_test.sh restore-precheck`**。
这个 precheck 是非破坏性的，会再检查 V3.4 universal recovery set、runtime cleanup 和 persistent diagnostics cleanup。

只有看到：

```text
RESTORE_READINESS=PASS ...
QUARANTINE=PASS ... restore_preflight=PASS
```

隔离才正式成功。

如果移动后的 V3.4 preflight 失败，脚本会自动把：

```text
/mnt/app/root/.carplay-altscreen.rescue-v1
```

移回：

```text
/mnt/app/root/carplay-altscreen
```

并记录：

```text
QUARANTINE_POSTCHECK=FAIL action=ROLLBACK_TO_ORIGINAL_PATH
QUARANTINE_ROLLBACK=PASS ... production_state=PRE_QUARANTINE
```

因此，不应在只看到目录被移动后就继续 RESTORE；以最终的 `QUARANTINE=PASS ... restore_preflight=PASS` 为准。
