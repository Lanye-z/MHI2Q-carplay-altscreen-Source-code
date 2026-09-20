# MIB2 High Toolbox（CarPlay 仪表第二屏实验主线）

> 当前分支：`main`  
> 当前定位：**正式开发主线 / 已实车点亮基线**

## 当前项目状态

`main` 已于 2026-09-20 从 `carplay-private111-direct-display-v2` 快进同步，
其基线对应已实车验证的 V2 显示链路。

当前已经确认：

- CarPlay Private Stream 111 可以通过现有链路物理点亮 Audi Virtual Cockpit。
- 仪表画面能够跟随手机端导航画面变化。
- 当前成功链路为：

```text
CarPlay Private111
  -> 原车 stock OMX 解码
  -> 原车 private renderer
  -> QNX Screen 线性化读取
  -> /carplay111_decoded
  -> sidecar
  -> CPU NV12 -> RGBA / GLES
  -> displayable3
  -> Java/HMI Context80
  -> Virtual Cockpit
```

Main110 保持原车路径，不进入这条辅助显示链路。

## 当前待办

### 1. 性能优化：主动“隔一帧读一帧”

当前优先优化方向不是更换解码器，也不是立即引入 `screen_blit`，
而是在已经点亮的架构上降低 Screen read / SHM publish 压力：

```text
第 1 帧：读取
第 2 帧：跳过
第 3 帧：读取
第 4 帧：跳过
...
```

目标是在尽量不影响仪表观感的前提下，减少 QNX Screen 读取和像素复制负担。

### 2. CarPlay 断开后的原车导航状态清理

一次实车测试中观察到：

- CarPlay 断开后，仪表回到原车地图；
- 当时并未开启原车导航；
- 但仪表仍异常出现了导航箭头。

目前将其视为 **teardown / 原车导航状态回接清理问题**，
而不是 Private111 显示链路本身失效。

### 3. 当前没有证据要求修改整体架构

成功点亮之后，目前没有发现必须立即引入以下方案的证据：

- 独立 Qualcomm/QNX H.264 解码器；
- `screen_blit` 硬件 CSC；
- 新 displayable；
- 新 Context；
- 替换原车 Private111 协议栈。

后续改动应优先保持小范围、可回退、可通过日志验证。

## 分支说明

- `main`：当前正式开发主线。
- `carplay-private111-direct-display-v2`：已实车点亮的 known-good 备份基线。
- `carplay-private111-direct-display-v1`：历史实验与回归参考。

---

# MIB2 High Toolbox

这是一个面向 MIB2 HIGH / MIB2.5 HIGH 平台的工具箱，可用于研究和定制相关功能。

## 重要提示

本工具箱涉及系统级文件、脚本、显示链路和车辆信息娱乐系统配置。

错误操作可能导致：

- MIB2 HIGH 单元功能异常；
- 软件无法正常启动；
- 部分功能失效；
- 极端情况下需要恢复或重新刷写。

请仅在明确理解当前操作内容、已经做好原车备份，并具备恢复能力的前提下使用。

本项目并不是适用于所有车型、所有固件版本的通用“越狱”方案。

## 基本要求

- 完整阅读本 README。
- 一台 MIB2 HIGH 或 MIB2.5 HIGH 主机。
- **不支持** MIB1 或 MIB2 Standard。
- Discover Media / Composition Media 不属于 MIB2 HIGH。
- 一张 FAT32 格式 SD 卡。
- 建议容量 1 GB 以上。
- 准备独立位置保存原车备份。

## 可选工具

如果需要自行编辑资源文件，还可能需要：

- Python 2.7：用于部分图形容器的提取和压缩；
- 文本编辑器：用于修改 Green Menu 文件或脚本；
- 图片编辑软件：用于修改图形资源。

# 安装方法

1. 如果之前安装过非常老的 Toolbox 版本，建议先清空 SD 卡。
2. 下载仓库全部文件，可以使用 Git clone，也可以使用 GitHub 的 “Download ZIP”。
3. 解压后，将仓库内容放到一张空的 FAT32 SD 卡中。
4. 将 SD 卡插入 MIB2 主机。
5. 建议车辆中只插入这一张 SD 卡，避免脚本识别错误。
6. 长按 MIB2 的 MENU 键进入服务界面。
7. 进入“软件更新/版本”菜单。
8. 点击右上角“Update / 更新”。
9. 选择对应 SD 卡。
10. 选择 MQB Coding MIB2 Toolbox。
11. 等待更新流程完整执行。
12. 更新过程中设备可能会多次重启。
13. 最终如果 Toolbox 项显示为 Y，其余很多模块显示 N/A，通常是正常现象。
14. 返回上一级。
15. 若系统提示连接电脑并清除故障码，可以按实际需要处理；单纯安装 Toolbox 通常可以取消。
16. 系统完成最后一次重启后，安装结束。
17. 长按 MENU 进入 TESTMODE / Developer Menu。
18. 进入 Green Developer Menu。
19. 正常情况下会看到新增的 `mqbcoding` 菜单。

# 手动安装

如果需要通过调试终端手动安装：

1. 将 mib2-toolbox 放入 SD 卡并插入 SD1。
2. 通过 D-Link DUB-E100、ASIX AX88179 或主机背部串口连接调试控制台。
3. 登录系统。
4. 挂载 SD 卡：

```sh
mount -uw /net/mmx/fs/sda0
```

5. 执行：

```sh
sh /net/mmx/fs/sda0/Toolbox/final/finalScripts.sh
```

6. 安装完成后进入 Green Developer Menu，确认存在 `mqbcoding` 菜单。

# Green Menu 菜单结构

```text
MQBCoding Main
|
+---Customization                       # 定制功能
|   +---Adaptations                     # Adaptation 参数
|       +---CarDeviceBUSAssignment
|       +---CarFunctionsList_BAP
|       +---CarFunctionsList_CAN
|       +---CarMenuOperation
|       +---HMI_FunctionBlockingTable
|       +---RCCAdaptions
|       +---VariantInfo
|       +---VehicleConfiguration
|       +---WLAN
|   +---Advanced                        # 高级操作
|   +---AndroidAuto                     # Android Auto 相关
|   +---Coding                          # Long Coding 编辑
|   +---Display                         # DisplayManager 与显示相关
|   +---GreenMenu                       # Green Menu 文件导入
|   +---Language                        # 语言资源
|   +---Navigation                      # 导航相关
|   +---Privacy                         # 隐私相关
|   +---Skin                            # 皮肤资源
|   +---Sounds                          # 声音相关（实验）
|   +---Startup                         # 启动画面
|   +---Updates                         # 更新与 SWDL
|   +---Various                         # 其他功能
|
+---Disclaimer                          # 免责声明
|
+---Dump                                # 导出数据
|
+---History                             # 版本历史
|
+---MIB_Information                     # MIB 信息
|   +---Password                        # 密码相关
|
+---Uninstall                           # 卸载 / 清理 Toolbox
```

# 新增界面的使用

大部分界面内部都有说明。执行涉及导入、导出、恢复等操作时，
建议在 SD1 中插入 SD 卡。

## Dump

用于导出需要进一步研究或修改的数据。

## Customization

### Android Auto

通常包含：

- 对 Android Auto 配置进行修改；
- 恢复原始 `gal.json`。

### Skin

用于导入各皮肤目录中的 `images.mcf`。

请只使用与当前固件匹配的资源文件。
导入其他固件的图形资源可能导致界面异常或功能损坏。

### Green Menu

用于导入 GreenMenu 目录中的 `.esd` 文件。

# Tools 目录中的工具

Tools 目录包含若干资源提取与压缩脚本，例如：

- `extract-canim_seat.py`
- `extract-canim_vw.py`
- `extract-mcf.py`
- `compress-canim_seat.py`
- `compress-canim_vw.py`
- `compress-mcf.py`
- `extract-cff.py`

## CANIM 提取示例

```text
extract_canim.py <filename> <outdir>
```

例如：

```text
extract_canim.py test.canim .\testfiles\
```

如果一个脚本不能正确提取，可尝试另一个车型版本。

## MCF 提取示例

```text
extract_mcf.py images.mcf c:\extracted\
```

## CANIM 压缩示例

```text
compress-canim.py <original-file> <new-file> <imagesdir>
```

例如：

```text
compress-canim.py test.canim modified.canim .\testfiles\
```

## MCF 压缩示例

```text
compress-mcf.py images.mcf images2.mcf .\extracted\
```

## CFF 提取示例

```text
extract-cff.py images.cff c:\extracted\
```

# 固件兼容性

Toolbox 并不能保证兼容所有 MIB2 HIGH 固件。

不同市场、不同硬件版本、不同软件版本之间可能存在：

- 文件路径差异；
- 二进制版本差异；
- HMI 结构差异；
- DisplayManager / QNX Screen 行为差异；
- AirPlay / CarPlay 实现差异。

在执行车辆测试前，应确认对应版本已有备份和恢复方案。

# 免责声明

这些功能可能导致主机异常、失去部分功能或需要恢复。

使用前请确保：

- 已备份原车文件；
- 知道当前固件版本；
- 知道如何恢复；
- 不将未经测试的包直接用于其他车辆。

项目用途以研究、验证、学习和社区交流为主。
