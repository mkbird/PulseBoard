# PulseBoard

PulseBoard 是一个原生 SwiftUI macOS 资源监控应用，提供：

- CPU、GPU、内存、Swap 与热状态
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

macOS 没有为普通应用公开 ANE、分项功耗和 DRAM 带宽的完整 API。PulseBoard 使用内置的轻量采样层直接读取 IOReport、SMC 与 IOKit，不依赖 Homebrew、`powermetrics` 或特权辅助进程，也无需管理员授权。

## 分享与公证

对外分发时，App 仍应使用 Developer ID 签名并通过 Apple 公证。先用 `notarytool store-credentials` 在钥匙串中保存公证凭据，然后运行：

```bash
NOTARY_PROFILE=你的凭据名称 ./Scripts/distribute.sh
```

成功后可分享 `dist/PulseBoard.zip`。接收者将 App 拖入 `/Applications` 即可使用，无需额外批准后台项目。

## 数据位置

- 历史数据库：`~/Library/Application Support/PulseBoard/history.sqlite`
默认保留 30 天，可在设置中改为 7 或 90 天。
