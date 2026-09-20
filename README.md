**实车状态：已成功点亮。** 2026-09-19 实车已确认 CarPlay private type111 第二屏可正确显示到 Virtual Cockpit，并随导航实时更新；这是当前首次成功基线。

> [!IMPORTANT]
> **实车点亮备份分支**
>
> 本分支保存 2026-09-19 实车首次成功点亮 Virtual Cockpit 的 V2 路线。后续功能修改请优先在 `main` 进行，本分支主要用于回归对比、故障恢复和确认“最后一个已知可点亮版本”。

# MHI2Q CarPlay 第二屏直显 — V2 实车备份

本项目用于验证 **Audi MHI2Q 平台上的 CarPlay private type111 第二屏视频流直接输出到 Virtual Cockpit**。

V2 已经通过实车测试证明：CarPlay 第二屏画面可以经过原车 OMX、QNX Screen 线性化、decoded SHM、GLES / displayable3 和 Java Context80，最终在仪表上正确显示并随手机导航变化。

## 当前状态

本分支定位为：

```text
实车已点亮
        ↓
保留为稳定备份
        ↓
不再作为日常开发主线
```

当前正式开发分支为：

```text
main
```

如果 `main` 后续优化引入显示回归，可以直接与本分支进行代码、二进制和上车现象对比。

## 已验证显示链路

```text
iPhone CarPlay
  ↓
private type111
  ↓
原车 AirPlay / ScreenStreamProcessData
  ↓
原车 OMX 解码
  ↓
原车 private renderer
  ↓
QNX Screen 线性化为标准 NV12
  ↓
/carplay111_decoded
  ↓
独立 sidecar
  ↓
CPU NV12 → RGBA
  ↓
GLES / displayable3
  ↓
Java/HMI Context80
  ↓
Virtual Cockpit
```

主 CarPlay 画面 Main110 不经过这条辅助路径。

## V2 解决的关键问题

- 不再依赖 Window58 枚举作为最终显示来源；
- 对原车 private renderer 的实际 Screen window 进行读取；
- 将厂商内部 decoded buffer 安全转换为标准线性 NV12；
- 去除不安全的原始 vendor pointer fallback；
- 加强 decoded SHM 的大小、magic、version、writer PID 校验；
- 使用 writer PID + generation + stream cookie 区分不同 CarPlay 会话；
- 加入同一 private111 会话内 sidecar 异常退出后的恢复逻辑；
- 防止旧连接的迟到 callback 抢回当前 stream 所有权；
- Java/HMI 保持 Context80 唯一控制权。

## 实车结果

2026-09-19 的测试确认：

- Virtual Cockpit 已出现 CarPlay 第二屏画面；
- 画面会跟随手机端导航内容更新；
- private111 → stock OMX → Screen → SHM → GLES → Context80 的完整物理链路成立。

因此本分支已经不再是“等待点亮”的实验版本，而是当前项目的 **首次实车成功基线**。

## 当前已知问题

### 1. 后续应优化为隔一帧读一帧

当前方案能够点亮，但辅助链路没有必要对原车 renderer 的每一帧都执行完整读取和发布。

后续 `main` 计划改为：

```text
第 1 帧：读取 / 发布
第 2 帧：跳过
第 3 帧：读取 / 发布
第 4 帧：跳过
...
```

原车仍然每帧正常渲染，我们只是主动降低辅助链路采样频率。

### 2. CarPlay 断开后出现原车导航箭头

一次测试中，CarPlay 断开后仪表已经回到原车地图，并且原车没有活动导航，但仍出现了导航箭头。

该问题暂时归类为 teardown / 导航状态交接问题，后续在 `main` 中继续处理。

## 安装与测试

进入工程菜单：

```text
MMI-Cockpit-Carplay
```

主要操作：

| 菜单项 | 作用 |
| --- | --- |
| `INSTALL` | 安装 V2 private111 直显运行环境。 |
| `START` | 启用第二屏显示链路。 |
| `STATUS` | 查看 private111、Screen、SHM、displayable3、Context80 状态。 |
| `STORE LOGS + RESTORE` | 保存日志并恢复。 |
| `RESTORE ORIGINAL` | 恢复原车状态。 |

推荐顺序：

```text
iPhone 保持未连接
        ↓
INSTALL
        ↓
完整重启
        ↓
START
        ↓
再次完整重启
        ↓
连接 CarPlay
        ↓
启动导航
        ↓
观察仪表并保存 STATUS / 日志
```

## 关键成功标记

```text
PHASE=FRAME_LINEARIZER_FIRST_FRAME
PHASE=DECODED_SHM_ATTACHED
PHASE=DECODER_FIRST_FRAME
PHASE=DISPLAYABLE3_FIRST_PRESENT result=OK
CTX80_OBSERVED actual=80
PHASE=DIRECT111_ACTIVE
PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE
```

最终仍以仪表实际画面为准。

## 分支使用建议

| 分支 | 用途 |
| --- | --- |
| `main` | 后续开发、性能优化、生命周期修复。 |
| `carplay-private111-direct-display-v2` | 当前首次实车点亮备份，不建议继续改功能。 |
| `carplay-private111-direct-display-v1` | 历史实验与回归分析。 |

如果需要判断后续修改是否引入退化，优先和本 V2 分支进行对照。
