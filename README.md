# PulseBoard

PulseBoard 是一个原生 SwiftUI macOS 资源监控应用，提供：

- CPU、GPU、内存、磁盘容量与热状态
- 网络和磁盘实时吞吐曲线
- ANE、CPU/GPU/ANE 功耗与内存带宽增强采样
- SQLite 历史记录、15 分钟至 7 天时间选择、自定义时间范围
- 自动降采样图表与原始 CSV 导出
- 菜单栏快速状态

## 运行

使用 Xcode 打开 `Package.swift`，选择 `PulseBoard` scheme 后运行；也可以：

```bash
swift run PulseBoard
```

生成可双击运行、经过本机临时签名的应用包：

```bash
./Scripts/build-app.sh
open dist/PulseBoard.app
```

最低系统版本为 macOS 14。

重新生成 macOS 图标资源：

```bash
./Scripts/build-icon.sh
```

母版位于 `Resources/AppIcon-master.png`，脚本会生成构建应用所需的 `Resources/PulseBoard.icns`。

## 增强指标

macOS 没有为普通应用公开 ANE、分项功耗和 DRAM 带宽的完整 API。PulseBoard 使用内置的轻量采样层直接读取 IOReport/SMC，不依赖 Homebrew 或外部监控程序；`powermetrics` 特权辅助进程作为降级路径保留。

在“设置 → 增强指标”中点击“启用高级监控”，然后由管理员在系统设置中批准一次。内置 LaunchDaemon 会以特权辅助进程运行 `powermetrics`，后续无需保持终端窗口。终端命令仍作为开发和故障排除的兼容方案保留。

## 分享与公证

特权辅助进程要求 App 使用 Developer ID 签名并通过 Apple 公证。先用 `notarytool store-credentials` 在钥匙串中保存公证凭据，然后运行：

```bash
NOTARY_PROFILE=你的凭据名称 ./Scripts/distribute.sh
```

成功后可分享 `dist/PulseBoard.zip`。接收者将 App 拖入 `/Applications`，首次启用高级监控时批准后台项目即可。

## 数据位置

- 历史数据库：`~/Library/Application Support/PulseBoard/history.sqlite`
- 增强指标桥接文件：`/Library/Application Support/PulseBoard/powermetrics.txt`

默认保留 30 天，可在设置中改为 7 或 90 天。
