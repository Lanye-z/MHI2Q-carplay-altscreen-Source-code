**实车状态：已上车，链路已打通但画面异常（彩条/花屏），未达到正确显示。** 本分支仅保留历史对照，不再作为新的上车测试基线。

> [!IMPORTANT]
> **历史实验分支**
>
> 本分支是第一次上车的彩条版本；已经被 V2 取代，不建议继续作为新的上车测试版本。当前正式开发请使用 `main`；需要回到首次实车点亮基线时，请使用 `carplay-private111-direct-display-v2`。

# MHI2Q CarPlay 第二屏直显 — V1 历史实验

V1 是 private111 直显路线的早期验证版本，主要用于拆分和确认以下几个边界：

- CarPlay private type111 是否能够稳定建立；
- `ScreenStreamProcessData` 是否能够取得第二屏 H.264 数据；
- 原车 OMX decoded frame 是否能够被旁路读取；
- displayable3 / GLES 是否可以作为仪表视频出口；
- Java/HMI 是否可以稳定持有 Context80。

V1 对后续 V2 的形成非常重要，但它没有形成当前 V2 那样可作为基线使用的实车正确画面，因此现在仅保留用于历史回溯。

## V1 实验路线

```text
iPhone CarPlay
  ↓
private type111
  ↓
ScreenStreamProcessData
  ↓
/carplay111_h264
  ↓
原车 OMX 解码
  ↓
decoded NV12 tap
  ↓
/carplay111_decoded
  ↓
CPU NV12 → RGBA
  ↓
GLES / displayable3
  ↓
Java/HMI Context80
  ↓
Virtual Cockpit
```

V1 的目标不是替换原车 decoder，而是先证明 private111 数据入口和仪表显示出口能够被连接起来。

## V1 的历史价值

V1 已经帮助确认：

- private111 与 Main110 可以区分；
- 不需要额外 `recv()` 消费 private socket；
- H.264 tap 可以放在原车 AirPlay 已处理后的边界；
- sidecar 可以和 `dio_manager` 的 LD_PRELOAD 环境隔离；
- displayable3 / GLES 可以继续作为后续仪表输出路径；
- Java/HMI 适合继续作为 Context80 唯一控制方。

这些结论后来都被 V2 继续沿用。

## 为什么被 V2 取代

V1 对 decoded buffer 的处理仍然依赖早期 tap 方式，无法像后来的 V2 一样稳定解决 MHI2Q 原车 OMX / Screen 内部布局问题。

V2 最终改为：

```text
原车 private renderer
        ↓
对实际 Screen window 做安全读取
        ↓
线性化为标准 NV12
        ↓
decoded SHM
        ↓
现有 displayable3 / Context80
```

修改后的 V2 随后完成了实车物理点亮，因此项目主线已经转移。

## 当前分支关系

| 分支 | 用途 |
| --- | --- |
| `main` | 当前正式开发主线。 |
| `carplay-private111-direct-display-v2` | 首次实车成功点亮的备份基线。 |
| `carplay-private111-direct-display-v1` | 本分支，仅用于历史分析。 |

## 使用建议

除非明确需要复现 V1 行为或比较 V1 / V2 差异，否则不要再从本分支开始新的上车测试，也不要继续在本分支叠加显示架构修改。

需要继续解决的问题，例如：

- 隔一帧读一帧；
- CarPlay 断开后原车导航箭头残留；
- 多次连接 / 断开稳定性；

均应在 `main` 处理。
