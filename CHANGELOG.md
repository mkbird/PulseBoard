# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/)。

## [2.1.0] - 2026-10-26

### Added

- 晨报导出为 PNG 图片：菜单栏「复制晨报图片」、网页「复制晨报图片 / 下载 PNG」、命令行 `--png`
- 菜单栏「清空全部记录…」：删除本机采样历史与临时快照，并隐藏清空前的 Clipto 批次（不修改 Clipto 自身数据库、不删除已导出晨报）
- 「防止 Mac 睡眠与 App Nap」开关（默认开启），保证整夜 1 Hz 采样
- 硬件采样覆盖率低于 90% 时在晨报中显式警告
- 晨报头条指标：端到端分析速度、全 CMS 内存峰值、全 CMS CPU P95、全 CMS GPU P95
- 新增全 CMS 进程 GPU 占用采集（按进程 IOAccelerator GPU 时间，历史库新增 `cms_gpu` 列）
- 晨报图片改为深色渐变页眉 + 卡片式版面
- 单列 CSV 导出（第 1 行版本号，之后每行一个指标，纯数字）：网页「导出 CSV / 复制 CSV 列 / 复制行名」、菜单栏「复制 CSV 列」、命令行 `--csv`、接口 `/api/report/csv`
- 评测人手动填写；局域网 IP 默认自动取本机第一个 192.168.* 地址（可手动覆盖），菜单栏与网页同步保存（接口 `/api/report/profile`，命令行 `--lan-ip`）；晨报附「查看详情：http://IP:8766」

### Changed

- 移除「自然日」统计维度，统一按测试批次 / 自定义时间窗 / 全库统计；日报更名为晨报，标题显示起止时间
- 跨午夜批次标签显示结束日期
- 晨报标题包含 Clipto Mac 版本号并标注 macOS 版；移除「算法服务耗时排行」「长尾慢素材」两节

### Fixed

- 尚未开始执行的排队素材不再计入素材总时长（避免未跑完时倍速虚高）

## [1.1.3] - 2026-09-28

### Fixed

- 修复 macOS 27 IOReport Energy Model 批量刷新造成的 CPU/ANE 功耗尖峰
- 批量能量按两次有效更新之间的完整时间窗口计算平均功耗
- Energy Model 与 Energy Counters 保持主备关系，不再重复累加
- 使用 SMC 整机功耗交叉校验组件功耗，并过滤已有历史数据中的不可能值

## [1.1.2] - 2026-09-28

### Fixed

- 修复在未安装开发构建目录的新 Mac 上因 SwiftPM 本地化资源包路径错误导致的启动崩溃
- 本地化资源加载增加旧版安装包兼容与缺失资源安全降级
- 构建脚本现在会校验资源包，并保持可通过 macOS 签名验证的标准资源布局

## [1.1.1] - 2026-09-27

### Added

- 总览“处理器负载”下方新增系统内存与 Clipto 内存占用对比曲线
- 内存占用组件支持实时窗口、自定义历史区间和中英文界面

## [1.1.0] - 2026-09-27

### Added

- 简体中文与英文界面本地化，跟随 macOS 应用语言设置
- 设置中新增“跟随系统 / 简体中文 / English”即时语言切换
- 历史数据默认保留 120 天，并强制删除超过 120 天的记录
- 完整的中英文双语 README 与英文界面截图

### Changed

- 将 Swift Package 本地化资源打入签名和公证的应用包
- 热状态改用稳定内部值存储，同时兼容旧版中文历史记录
- 清理已移除历史标签页遗留的不可达界面代码
- 总览指标卡固定为 3 列 × 2 行，侧边栏收起时不改变排列

## [1.0.0] - 2026-09-27

### Added

- 原生 SwiftUI macOS 性能总览与菜单栏状态
- CPU、GPU、内存、Swap、网络、磁盘和热状态采样
- ANE、系统与芯片分项功耗、DRAM 带宽增强指标
- Clipto 进程组 CPU、GPU、内存和磁盘指标
- SQLite 历史记录、自定义时间范围和 CSV 导出
- Developer ID 签名、公证和可分发应用包脚本

[1.1.3]: https://github.com/mkbird/PulseBoard/releases/tag/v1.1.3
[1.1.2]: https://github.com/mkbird/PulseBoard/releases/tag/v1.1.2
[1.1.1]: https://github.com/mkbird/PulseBoard/releases/tag/v1.1.1
[1.1.0]: https://github.com/mkbird/PulseBoard/releases/tag/v1.1.0
[1.0.0]: https://github.com/mkbird/PulseBoard/releases/tag/v1.0.0
