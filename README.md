# PulseBoard

[![CI](https://github.com/mkbird/PulseBoard/actions/workflows/ci.yml/badge.svg)](https://github.com/mkbird/PulseBoard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/mkbird/PulseBoard)](https://github.com/mkbird/PulseBoard/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111111?logo=apple)](https://www.apple.com/macos/)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[简体中文](#简体中文) · [English](#english)

| 简体中文 | English |
| --- | --- |
| ![PulseBoard 中文总览](Docs/PulseBoard-overview.png) | ![PulseBoard English overview](Docs/PulseBoard-overview-en.png) |

## 简体中文

PulseBoard 是一个原生 SwiftUI macOS 资源监控应用。它将系统负载、带宽、功耗、历史记录和 Clipto 进程指标集中在一个界面中，并且不依赖 Homebrew、`powermetrics` 或常驻特权辅助进程。应用界面支持简体中文和英文，默认跟随 macOS，也可以在“设置 → 语言”中即时切换。

### 功能

- CPU、GPU、内存、Swap 和热状态
- 系统内存与 Clipto 内存占用对比曲线
- 网络、磁盘与 DRAM 读写带宽曲线
- ANE 活跃度、CPU/GPU/ANE 分项功耗与整机功耗
- 15 分钟至 7 天的实时窗口，以及自定义历史区间
- SQLite 本地历史记录、自动降采样图表和原始 CSV 导出
- Clipto 进程组的 CPU、GPU、内存及磁盘吞吐指标
- 名称包含 `cms` 的逐进程及总计 CPU、内存：当前值、本次启动平均与采样峰值
- CMS 后台采样历史与独立 CSV 导出，关闭窗口后继续记录
- 菜单栏快速状态

### 下载

从 [Releases](https://github.com/mkbird/PulseBoard/releases/latest) 下载 `PulseBoard.zip`，解压后将 `PulseBoard.app` 拖入“应用程序”目录。

发布包使用 Developer ID 签名并通过 Apple 公证。最低系统版本为 macOS 14。

### 本地构建

需要 macOS 14 或更高版本，以及支持 Swift 6 的 Xcode。

```bash
git clone https://github.com/mkbird/PulseBoard.git
cd PulseBoard
swift test
swift run PulseBoard
```

生成可双击运行、使用临时签名的应用包：

```bash
./Scripts/build-app.sh
open dist/PulseBoard.app
```

重新生成图标：

```bash
./Scripts/build-icon.sh
```

图标母版位于 `Resources/AppIcon-master.png`。

### 数据来源与准确性

PulseBoard 使用 Mach、sysctl、getifaddrs、IOKit、IORegistry、IOReport 与 SMC 等本机数据源。CPU、内存、Swap、网络和磁盘指标来自系统累计计数器；速率类指标需要至少两个采样点才能形成有效增量。

ANE 活跃度、功耗、GPU 利用率和 DRAM 带宽依赖不同 Mac 及 macOS 版本上可用的硬件通道。这些指标适合观察趋势，不应用作计费、实验室校准或硬件故障判定依据。通道不可用时，界面会显示缺失值，而不会伪造数据。

macOS 27 在部分 Apple Silicon 机型上会分批刷新组件能量计数器。PulseBoard 会按两次有效刷新之间的完整时间窗口计算平均功耗；第一个完整窗口形成前显示缺失值，而不是错误的 `0 W` 或瞬时尖峰。

Clipto 指标仅在检测到对应进程组时出现。其 CPU 百分比在部分位置会换算为整机占比，以便与系统总 CPU 曲线比较。

CMS 面板通过公开 `libproc` 接口按可执行文件名匹配，不区分大小写。CPU 以一个逻辑核满载为 100%，多核合计可超过 100%；内存为进程物理内存足迹（`phys_footprint`）之和。每个进程实例及总计独立记录本次 PulseBoard 启动以来的时间加权平均和采样峰值，退出实例保留摘要。已确认不存在的时段计为零，休眠、首次 CPU 差分和读取失败的时段不计入对应指标的有效时长；内存平均使用前一采样值近似区间内的占用。总计缺少成员读数时显示缺失值。采样可能遗漏短暂进程或短于采样周期的尖峰。

CMS 面板的当前值、平均值和峰值仍仅针对本次 PulseBoard 会话，切换历史窗口不会改变这些统计，重新启动应用会开始新会话。CMS 原始采样和当次 CPU、内存读数同时写入本地 SQLite 历史数据库；应用保持运行时，关闭窗口后仍继续采样，退出 PulseBoard 则停止采样。重新打开窗口不会创建新会话，也不需要额外常驻服务。

点击 CMS 面板的“导出 CMS 历史”，可导出总览顶部当前选择的时间范围，包括已保存的先前会话。导出在后台分页读取并逐批写入文件，避免一次将整个历史区间加载到内存。CSV 中每个采样帧有一条 `total` 总计行，每个已识别的进程另有一条 `process` 行；空进程组和枚举失败的帧仍保留总计行。缺失读数为空白，合法零值保留为零。记录包含会话 ID、帧序号、连续采样分段、墙上时间和单调时钟、最大有效采样间隔、PID、进程启动时间（微秒）、原始累计 CPU 时间及读取完整性。ISO 8601 时间之外还提供 Unix 秒数，以保留重建所需的时间精度。

CMS 历史采用设置中的同一保留期，过期记录自动删除。完整会话的原始记录可按相同采样口径重建统计；若导出时间范围或保留期只覆盖会话的一部分，重建结果只能代表保留下来的区间，不能声称是完整的“启动至今”统计。历史不会在 CMS 面板中新增曲线，也不提供 HTTP 服务。

### 隐私与数据位置

PulseBoard 不包含遥测、分析 SDK 或云端上传逻辑。监控数据保存在本机：

- 历史数据库：`~/Library/Application Support/PulseBoard/history.sqlite`
- CSV：仅在用户主动导出时写入用户选择的位置

历史数据默认保留 120 天。可以在设置中缩短为 7、30 或 90 天；无论设置如何，超过 120 天的记录都会自动删除。

### 签名与公证

对外分发需要自己的 Developer ID Application 证书，以及保存在钥匙串中的公证凭据：

```bash
NOTARY_PROFILE=你的凭据名称 \
CODESIGN_IDENTITY="Developer ID Application: 你的名称 (TEAMID)" \
./Scripts/distribute.sh
```

成功后可分发 `dist/PulseBoard.zip`。证书私钥和公证密码不会写入仓库。

### 参与贡献

欢迎提交 Issue 和 Pull Request。开始前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)；安全问题请按 [SECURITY.md](SECURITY.md) 私下报告。

### 许可证

PulseBoard 使用 [MIT License](LICENSE)。

---

## English

PulseBoard is a native SwiftUI system monitor for macOS. It brings system load, bandwidth, power, history, and Clipto process metrics into one interface without requiring Homebrew, `powermetrics`, or a persistent privileged helper. The app supports Simplified Chinese and English, follows macOS by default, and can be switched instantly in Settings → Language.

### Features

- CPU, GPU, memory, swap, and thermal state
- System and Clipto memory usage comparison chart
- Network, disk, and DRAM read/write bandwidth charts
- ANE activity, CPU/GPU/ANE component power, and total system power
- Live windows from 15 minutes to 7 days, plus custom history ranges
- Local SQLite history, chart downsampling, and raw CSV export
- CPU, GPU, memory, and disk metrics for the Clipto process group
- Per-process and total CPU/memory for executable names containing `cms`, with current, session-average, and sample-peak readings
- CMS background sampling history and dedicated CSV export, continuing after the window closes
- Quick status in the menu bar

### Download

Download `PulseBoard.zip` from [Releases](https://github.com/mkbird/PulseBoard/releases/latest), extract it, and drag `PulseBoard.app` into Applications.

Release builds are signed with Developer ID and notarized by Apple. PulseBoard requires macOS 14 or later.

### Build from Source

You need macOS 14 or later and an Xcode version that supports Swift 6.

```bash
git clone https://github.com/mkbird/PulseBoard.git
cd PulseBoard
swift test
swift run PulseBoard
```

Create a double-clickable app bundle with an ad-hoc signature:

```bash
./Scripts/build-app.sh
open dist/PulseBoard.app
```

Regenerate the app icon:

```bash
./Scripts/build-icon.sh
```

The source artwork is stored at `Resources/AppIcon-master.png`.

### Data Sources and Accuracy

PulseBoard samples local Mach, sysctl, getifaddrs, IOKit, IORegistry, IOReport, and SMC data sources. CPU, memory, swap, network, and disk metrics are derived from system counters. Rate metrics require at least two samples before a valid delta is available.

ANE activity, power, GPU utilization, and DRAM bandwidth depend on hardware channels that vary across Mac models and macOS releases. These values are intended for trend analysis, not billing, laboratory calibration, or hardware fault diagnosis. When a channel is unavailable, PulseBoard shows a missing value instead of inventing data.

On some Apple Silicon models, macOS 27 refreshes component energy counters in batches. PulseBoard reports power averaged over the complete interval between valid refreshes; it shows a missing value before the first complete window instead of a false `0 W` or an instantaneous spike.

Clipto metrics appear only while a matching process group is detected. In comparison charts, Clipto CPU may be converted to its share of total system CPU capacity.

The CMS panel matches executable names case-insensitively using public `libproc` APIs. CPU uses 100% per logical core and can exceed 100%; memory sums process physical footprints (`phys_footprint`). Each process instance and the group maintain independent time-weighted averages and observed sample peaks for this PulseBoard session. Exited instances retain their summaries. Confirmed absence counts as zero; sleep, initial CPU baselines, and failed readings are excluded from the affected metric's valid duration. Memory averages hold the previous sample over each interval. Incomplete group readings are shown as missing. Polling can miss short-lived processes and peaks shorter than the sampling interval.

The CMS panel's current, average, and peak readings still cover only the current PulseBoard session. Changing the chart range does not change these statistics; restarting the app starts a new session. Raw CMS samples and their CPU/memory readings are also recorded in the local SQLite history database. Sampling continues after the window closes while the app remains running, and stops when PulseBoard quits. Reopening the window keeps the same session and requires no separate background service.

Use **Export CMS history** in the CMS panel to export the time range selected at the top of the dashboard, including earlier saved sessions. Exports read and write pages in the background, avoiding loading the entire history range into memory. Each sample frame has one `total` row and one `process` row per identified process. Empty groups and failed enumerations still produce a total row. Missing readings are blank, and valid zero values remain zero. The CSV includes session IDs, frame sequences, continuous sampling segments, wall-clock and monotonic times, the maximum valid sampling gap, PIDs, process start times in microseconds, cumulative CPU times, and reading completeness. Unix timestamps accompany ISO 8601 timestamps to preserve the precision needed for reconstruction.

CMS history follows the same retention setting; expired records are deleted automatically. A complete session's raw records can reconstruct statistics using the same sampling rules. If the exported range or retained history covers only part of a session, reconstructed results describe that available interval and must not be presented as complete statistics since launch. This feature does not add CMS history charts or an HTTP service.

### Privacy and Data Location

PulseBoard contains no telemetry, analytics SDK, or cloud upload logic. Monitoring data remains local:

- History database: `~/Library/Application Support/PulseBoard/history.sqlite`
- CSV files: written only when the user explicitly exports to a chosen location

History is retained for 120 days by default. You can shorten retention to 7, 30, or 90 days in Settings; records older than 120 days are always deleted automatically.

### Signing and Notarization

Public distribution requires your own Developer ID Application certificate and a notarization profile stored in Keychain:

```bash
NOTARY_PROFILE=YourProfile \
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
./Scripts/distribute.sh
```

The resulting `dist/PulseBoard.zip` can be distributed directly. Certificate private keys and notarization passwords are never stored in the repository.

### Contributing

Issues and pull requests are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before contributing. Report security issues privately as described in [SECURITY.md](SECURITY.md).

### License

PulseBoard is available under the [MIT License](LICENSE).
