# 开源来源与技术依据

## 实际复用：Stats（MIT）

项目：https://github.com/exelban/stats
固定参考版本：v3.0.17。原始文件及其 SHA-256 存于 Vendor/Stats/manifest.json。

保留的上游文件为 LICENSE、SMC/smc.swift、Modules/Sensors/values.swift；原始完整 MIT 许可证存于 Vendor/Stats/LICENSE，并随构建产物复制到 Contents/Resources/Stats-MIT-LICENSE.txt。

Sources/Bridge.c 的 AppleSMC 请求结构、只读命令方式、浮点/定点温度解码和 M4 CPU 热区键映射参考/改写自上述 Stats 文件。上游版权归其作者 Serhiy Mytrovtsiy 等原权利人所有；许可声明予以保留。没有编译完整 Stats 程序，也没有带入上游写风扇、管理员帮助程序或网络模块。

## 仅研究比较，未复制实现

- OpenTamer：https://github.com/Digital-Shane/OpenTamer 。仓库标示 GPL-3.0；提供监测、降低优先级、CPU 限制及后台暂停等路线。其 Go/C 实现没有纳入本项目。
- AppPolice：https://github.com/AppPolice/AppPolice 。仓库标示 GPL-2.0；可参考 CPU 限制产品形态。其实现没有纳入本项目。
- psutil：https://github.com/giampaolo/psutil 。跨平台 Python 进程/系统信息库，可用于跨平台研究，但本应用运行时未使用它；不把它视为 macOS CPU 温度来源。

本文件记录技术选择与上游标注，不替代面向外部分发前的完整许可审查。不存在“仅因源码可见就能忽略其许可”的假设。

## 系统行为的权威参考

Apple 对 kernel_task 与温度管理的解释：
https://support.apple.com/en-us/102172

Apple ProcessInfo.thermalState：
https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property

Apple 对 Mac 笔记本运行温度的说明：
https://support.apple.com/en-us/102336

Stats 的说明指出传感器是芯片热区，并不逐个对应物理 CPU 核心，且不同 SoC 的键映射可能改变。QuietGuard 因此分别显示有效热区数量与逻辑 CPU 数量，不将 12 个传感器误称为 12 个核心。
