# 上车前请先阅读

当前分支：`main`

## 当前定位

`main` 是现在唯一的正式开发主线。

它已经同步到 2026-09-19 实车成功点亮的 V2 路线，并在此基础上继续处理后续优化和生命周期问题。

目前已经实车确认：

- CarPlay private type111 第二屏能够建立；
- 原车 OMX 能够继续作为解码器使用；
- 原车 private renderer 后的画面能够通过 QNX Screen 读取并线性化；
- `/carplay111_decoded` 能够向 sidecar 提供标准 NV12；
- GLES / displayable3 能够完成仪表画面输出；
- Java/HMI Context80 能够接管并显示到 Virtual Cockpit；
- 仪表画面会随手机端 CarPlay 导航内容变化。

## 当前显示路线

```text
private type111
  → 原车 OMX
  → 原车 private renderer
  → QNX Screen 线性化
  → /carplay111_decoded
  → sidecar
  → CPU NV12 → RGBA
  → GLES / displayable3
  → Java Context80
  → Virtual Cockpit
```

Main110 保持原车路径，不经过上述辅助显示链路。

## 上车测试顺序

建议严格按照以下顺序：

```text
iPhone 保持断开
        ↓
INSTALL
        ↓
完整重启车机
        ↓
START
        ↓
再次完整重启车机
        ↓
连接 iPhone / CarPlay
        ↓
启动支持仪表第二屏的导航路线
        ↓
观察 Virtual Cockpit
        ↓
STATUS
        ↓
保存日志
```

不要在一次测试中同时加入新的 decoder、`screen_blit`、新的 Context 或新的显示出口。

## 当前两个主要待办

### 1. 隔一帧读一帧

现阶段优先降低辅助显示链路的 Screen 读取频率。

目标是：

```text
原车每帧照常显示
我们的辅助链路只处理 1、3、5、7... 帧
```

这样可以减少 Screen readback、SHM 发布、CSC 和 GLES 的额外负载。

### 2. CarPlay 断开后原车导航箭头残留

一次测试中出现：

- CarPlay 已断开；
- 仪表已经回到原车地图；
- 原车没有活动导航；
- 但仪表仍出现导航箭头。

后续重点检查 teardown、Context 释放以及原车导航状态恢复过程。

## 成功标记

日志中应尽量看到：

```text
PHASE=FRAME_LINEARIZER_FIRST_FRAME
PHASE=FRAME_LINEARIZER_PROGRESS
PHASE=DECODED_SHM_ATTACHED
PHASE=DECODER_FIRST_FRAME
PHASE=DISPLAYABLE3_FIRST_PRESENT result=OK
CTX80_OBSERVED actual=80
PHASE=DIRECT111_ACTIVE
PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE
```

最终判据仍然是：

> Virtual Cockpit 实际出现正确的 CarPlay 第二屏画面。

## 分支说明

- `main`：当前开发主线；
- `carplay-private111-direct-display-v2`：首次实车成功点亮备份；
- `carplay-private111-direct-display-v1`：历史实验分支。

出现回归时，优先和 V2 备份分支对比。
