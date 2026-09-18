# CarPlay Second Screen / BaseVideo3 Standalone V1

这是一个**独立第二屏实验包**。目标是在没有安装 MMI Mirror 的车辆上，仅通过本 ZIP 完成：

```text
iPhone type111
  -> private ScreenSession / ScreenStream
  -> stock H.264
  -> stock Qualcomm OMX
  -> stock CScreenRender
  -> managed displayable3
  -> Java/HMI ctx80={98,101,102,3}
  -> Virtual Cockpit
```

## 与 MMI Mirror 的关系

本包**不依赖、也不启动** MMI Mirror：

- 不安装 `mmi-mirror-display`
- 不启动 Mirror sidecar
- 不读取 Window58
- 不使用 `screen_read_window`
- 不经过 BGRA/CPU copy/GLES 二次渲染
- 不安装 `maneuver_render-rgi98`

本包只复用已经在同一台车验证过的 **Java/HMI context80 控制逻辑**。为了保持已验证二进制兼容性，其中仍使用以下历史 marker 名称：

```text
/tmp/mmi-mirror-active
/tmp/mmi-mirror-basevideo.ready
/tmp/mmi-mirror-controller.started
/tmp/mmi-mirror-controller.log
```

这些名字现在只是 Java80 ABI/状态桥接名称，不表示 MMI Mirror runtime 正在运行。

## 包内完整依赖

Standalone ZIP 自带：

```text
Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so
Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar
Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh
Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh
Toolbox/scripts/status_mmi_cockpit_carplay_test.sh
Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh
Toolbox/GEM/mqb-carplayAltScreen.esd
```

Java80 JAR 固定身份：

```text
size    = 141858
SHA256  = eafebf9fd1a7f4d3962fa5330b6908f45570756ade24676baf1f2bf66edc2c8a
cksum   = 2378993239
target  = /mnt/app/eso/hmi/lsd/jars/carplay_hook.jar
ctx80   = {98,101,102,3}
```

INSTALL 会先备份车辆当前的 `carplay_hook.jar`（包括“原本不存在”的状态），然后再事务式替换。RESTORE ORIGINAL 会恢复安装前的精确状态。

## 推荐实车流程

1. 若车辆还残留旧 AltScreen/MMI Mirror 测试状态，先执行旧包的 **RESTORE ORIGINAL** 并完整重启一次。
2. 下载本分支 ZIP，解压后把其中内容完整覆盖到测试 SD 根目录。保留本车自己的 `MMI-Cockpit-Carplay/backup` 与 `logs`，不要带入其他车辆备份。
3. 断开 iPhone，进入 Toolbox 的 **MMI-Cockpit-Carplay**。
4. 执行 **INSTALL**。
5. 完整重启 MMI。
6. 执行 **START**。
7. 再完整重启 MMI。
8. 连接 iPhone，启动支持仪表第二屏的导航。
9. 执行 **STATUS** 或 **STORE LOGS + RESTORE** 采集结果。

## INSTALL 成功应看到

```text
PACKAGE_MODE=CARPLAY_SECOND_SCREEN_STANDALONE
MMI_MIRROR_RUNTIME=NOT_INCLUDED
RGI98_NATIVE_RENDERER=NOT_INCLUDED
HMI_CONTROL_PLANE=INSTALLED ...
HMI_CONTRACT=JAVA80 ctx80=98,101,102,3 basevideo=3
INSTALL=PASS integrated=AltScreen+BaseVideo3+Java80 reboot_required=YES
```

## START 成功应看到

```text
DISPLAY_PATH=BASEVIDEO3_NATIVE ... displayable=3
HMI_CONTROL_PLANE=JAVA80 context=80 composite=98,101,102,3
CONTEXT_POLICY=JAVA_ONLY native_dmdt=0
BASEVIDEO3_BOOT_DEMAND=ENABLED
MMI_MIRROR_SIDECAR=DISABLED
START=PASS ... reboot_required=YES
```

## 关键运行证据

Native：

```text
[MAIN110] ... window_id=59 rewrite=0 ownership=stock
[ALT111] ... displayable=3
PHASE=BASEVIDEO3_WINDOW_PROBE stage=pre_manage
PHASE=BASEVIDEO3_WINDOW_PROBE stage=post_manage
PHASE=BASEVIDEO3_FORCE_VISIBLE ... rc=0
PHASE=BASEVIDEO3_WINDOW_PROBE stage=post_buffers
PHASE=NATIVE_111_FIRST_REAL_FRAME ... result=POSTED
[BASEVIDEO3] PHASE=BASEVIDEO3_READY ... ready=1
```

Java：

```text
JAVA_CONTROLLER=STARTED
ownership acquire requested; base=1/1 ...
enter-bounce -> ctx72
enter-composite -> ctx80
ownership acquired -> ctx80
```

只有仪表实际出现 CarPlay second-screen 视频，才算：

```text
PHYSICAL_VISIBILITY=PASS
```

`manage_rc=0`、`screen_post_window` 成功或 `ctx80` 写入成功都不能单独等价于物理点亮。

## 恢复

执行 **RESTORE ORIGINAL**：

- 清除 BaseVideo3 persistent enable
- 删除 BaseVideo3 startup block
- 撤销 active/ready marker，让当前 Java controller 先释放到 ctx74
- 恢复安装前的原始 `carplay_hook.jar`（或恢复“原本不存在”状态）
- 恢复 AltScreen/LD_PRELOAD/CarPlay 配置
- 提示完整重启

这是测试分支，不修改 `main`。
