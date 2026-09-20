# 上车前请先阅读

当前分支：`carplay-private111-direct-display-v2`

## 当前定位

这是 **2026-09-19 首次实车成功点亮 Virtual Cockpit 的 V2 备份分支**。

本分支建议保持功能代码冻结，只用于：

- 回归对比；
- 故障恢复；
- 判断 `main` 后续修改是否引入退化；
- 保留首次成功点亮时的完整实现。

日常开发请使用 `main`。

## 已经确认的结果

实车测试已经证明：

```text
private type111
  → 原车 OMX
  → 原车 private renderer
  → QNX Screen 线性化
  → /carplay111_decoded
  → sidecar
  → GLES / displayable3
  → Java Context80
  → Virtual Cockpit
```

这条链路可以物理点亮仪表，并且画面会跟随手机端 CarPlay 导航更新。

## 推荐测试顺序

```text
iPhone 保持断开
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
观察仪表
        ↓
STATUS / 保存日志
```

## 当前已知问题

### 隔一帧读一帧尚未加入

当前备份版本保留首次点亮时的实现。

性能优化将在 `main` 进行，优先改为主动“隔一帧读一帧”，而不是在本分支继续修改。

### CarPlay 断开后箭头状态异常

一次测试中，在 CarPlay 断开、原车地图恢复且没有活动导航的情况下，仪表仍出现导航箭头。

该问题后续在 `main` 处理。

## 使用原则

如果后续 `main` 出现：

- 仪表不再点亮；
- 画面异常；
- CarPlay 主画面受影响；
- 多次连接后链路退化；

优先切回本 V2 分支进行对照。

本分支的主要价值就是保持一个已经实车验证成功的参考点。
