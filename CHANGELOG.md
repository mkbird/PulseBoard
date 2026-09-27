# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)。

## [1.1.0] - 2026-09-27

### Added

- 简体中文与英文界面本地化，跟随 macOS 应用语言设置
- 完整的中英文双语 README 与英文界面截图

### Changed

- 将 Swift Package 本地化资源打入签名和公证的应用包
- 热状态改用稳定内部值存储，同时兼容旧版中文历史记录
- 清理已移除历史标签页遗留的不可达界面代码

## [1.0.0] - 2026-09-27

### Added

- 原生 SwiftUI macOS 性能总览与菜单栏状态
- CPU、GPU、内存、Swap、网络、磁盘和热状态采样
- ANE、系统与芯片分项功耗、DRAM 带宽增强指标
- Clipto 进程组 CPU、GPU、内存和磁盘指标
- SQLite 历史记录、自定义时间范围和 CSV 导出
- Developer ID 签名、公证和可分发应用包脚本

[1.1.0]: https://github.com/mkbird/PulseBoard/releases/tag/v1.1.0
[1.0.0]: https://github.com/mkbird/PulseBoard/releases/tag/v1.0.0
