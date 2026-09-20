# 上车前请先阅读

当前分支：`carplay-private111-direct-display-v1`

## 当前定位

这是历史实验分支，已经被 V2 取代。

不建议再从本分支开始新的上车测试。

当前项目应使用：

- `main`：正式开发；
- `carplay-private111-direct-display-v2`：首次实车成功点亮备份；
- 本 V1：仅用于历史回溯和代码比较。

## V1 当时验证的内容

V1 主要用于确认：

- private type111 能否建立；
- `ScreenStreamProcessData` 是否可以取得第二屏 H.264；
- 原车 OMX decoded frame 是否能够旁路获取；
- displayable3 / GLES 是否能够作为仪表出口；
- Java/HMI Context80 是否适合作为唯一 Context 控制方。

V1 的历史路线为：

```text
private type111
  → ScreenStreamProcessData
  → /carplay111_h264
  → 原车 OMX
  → decoded NV12 tap
  → /carplay111_decoded
  → CPU NV12 → RGBA
  → GLES / displayable3
  → Java Context80
  → Virtual Cockpit
```

## 为什么停止继续开发 V1

后续实车分析表明，真正需要解决的是 MHI2Q 原车 OMX / Screen decoded buffer 的内部布局问题。

V2 改为从实际 private renderer 的 Screen window 做安全读取并线性化为标准 NV12，最终实现了可用的仪表物理点亮。

因此 V1 不再承担新的功能开发任务。

## 不要在本分支继续处理

以下工作全部转到 `main`：

- 隔一帧读一帧；
- CarPlay 断开后的原车导航箭头状态恢复；
- 多次连接 / 断开稳定性；
- 后续性能优化。

需要比较 V1 与 V2 差异时再使用本分支。
