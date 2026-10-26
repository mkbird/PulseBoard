# CliptoPulse（PulseBoard + Clipto DAGSC 运行分析 + 开发日报一体机）

**CliptoPulse** 将原有两个独立工具深度整合为一个原生 macOS 菜单栏常驻采集程序 + 统一 Web 控制台：

1. **硬件与进程后台常驻采集（源自 `PulseBoard`）**
   - 原生 C / Mach / IOReport / `libproc` 1Hz 采集整机 CPU、GPU、ANE、内存、Swap、功耗、DRAM 带宽、磁盘/网络吞吐。
   - 实时追踪 **Clipto 进程组**（CPU / GPU / 物理内存 / 磁盘读写）与 **`cms` 算法子进程组**（逐进程与总计 CPU、物理内存 `phys_footprint`）。
   - 100% 兼容并直接复用既有本地历史库：`~/Library/Application Support/PulseBoard/history.sqlite`（无需迁移旧数据）。
2. **DAGSC 调度吞吐与 Nsight 泳道分析（源自 `clipto运行信息分析工具`，已原生 Swift 重写，无需 Python）**
   - 直接读取 `~/Library/Application Support/com.clipto.mac/dagsc_data/data/schedule.db`（安全拷贝临时快照 + WAL/SHM，绝不阻塞正在运行的 Clipto）。
   - **按测试批次统计（晨报模式）**：支持 **测试批次（Batch，默认 15 分钟空闲间隔自动切分，跨午夜的夜跑算作同一批次）**、**自定义时间窗**、**全库** 三种维度；多批次自动按活跃时段合并计算真实耗时，不把中间空闲计入分母。只统计真正执行过任务的素材，未开始排队的素材不计入素材总时长。
   - **泳道 + 硬件同轴联动**：20 泳道 Nsight 风格时间轴下方同步绘制同一毫秒时间窗内的 **CPU 占用曲线、物理内存水位（Clipto / CMS / 整机）、整机与分项功耗曲线**，缩放平移完全联动。
3. **Clipto Markdown 开发日报一键导出**
   - 自动汇总：**测试环境（芯片/内存/系统/Clipto 版本/分析模板版本）**、**素材吞吐与实时处理倍速（Speedup / RTF）**、**运行期对齐的硬件与 Clipto/CMS 资源水位（均值 / P95 / 峰值 / 累计 Wh 耗电）**、**Top 算法服务（`node_type`）耗时瓶颈排行**、**最慢长尾素材明细**、**失败任务异常诊断**。
   - 支持填写测试记录人、版本改动说明与定位备注（浏览器本地自动记忆），一键复制标准 GitHub-Flavored Markdown（无缝粘贴至飞书文档 / `Markdown转飞书文档` / Notion / Git）或下载 `.md` 文件。

---

## 快速启动

### 方式一：直接双击应用或启动脚本（推荐）

- 双击打开 `dist/CliptoPulse.app`，或双击根目录下的 `启动 CliptoPulse.command`。
- 启动后应用常驻在 **macOS 顶部菜单栏**（不占 Dock 图标），持续后台记录硬件与 Clipto/CMS 指标，并自动在浏览器打开统一控制台：
  - 本机访问：`http://127.0.0.1:8766`
  - 团队局域网访问：`http://<本机局域网IP>:8766`（可在菜单栏弹窗一键复制局域网链接发给同事查看）

### 方式二：命令行构建与导出日报

```bash
cd "/Users/yingjia/Desktop/agent的工作间/CliptoPulse"

# 编译并打包 dist/CliptoPulse.app
./Scripts/build-app.sh

# 运行内置自检测试
./dist/CliptoPulse.app/Contents/MacOS/PulseBoard --self-test

# 命令行直接导出最新批次 Markdown 开发日报
./dist/CliptoPulse.app/Contents/MacOS/PulseBoard --export-report --slice=auto --out=./clipto_daily_report.md

# 同时导出 Markdown 与 PNG 晨报图片
./dist/CliptoPulse.app/Contents/MacOS/PulseBoard --export-report --out=./晨报.md --png=./晨报.png
```

---

## 晨报使用流程

1. **晚上走之前**：确认菜单栏 CliptoPulse 在运行，并且「防止 Mac 睡眠与 App Nap」已打开（默认开启，插电即可整夜 1 Hz 采样，显示器照常熄屏）；如需从干净状态开始，可先点「清空全部记录…」，然后在 Clipto 开始跑分析。
2. **早上来**：等 Clipto 全部跑完，点菜单栏「复制晨报图片」直接粘贴到群里；或在网页「Clipto 晨报」页签填写备注后「复制晨报图片 / 下载 PNG / 复制 Markdown」。

### 清空全部记录

菜单栏「清空全部记录…」会删除本机全部硬件 / Clipto / CMS 采样历史（`history.sqlite`）和分析临时快照，并隐藏清空时刻之前的 Clipto 测试批次。
**不会删除**：已导出的晨报（.md / .png / .csv）、软件设置、网页中填写的记录人等表单内容，以及 Clipto 自己的 `schedule.db`（Clipto 不受任何影响；外部备份数据库也不受隐藏影响）。

## 目录与数据说明

- **本地监控历史库**：`~/Library/Application Support/PulseBoard/history.sqlite`（与原 `PulseBoard` 完全共享，默认保留 120 天）
- **默认 Clipto DAGSC 目录**：`~/Library/Application Support/com.clipto.mac/dagsc_data`（亦可在网页顶栏输入任意外部备份 `schedule.db` 路径）
- **内置 HTTP API 端点**：
  - `GET /` — 统一网页控制台（DAGSC 联动分析 / 实时与历史监控 / Clipto 开发日报）
  - `GET /api/bootstrap` — 机器环境、局域网地址、默认路径与实时快照
  - `GET /api/monitor/live` — 实时硬件 + Clipto + CMS 会话指标
  - `GET /api/monitor/history?minutes=60` — 历史监控时间序列
  - `GET /api/dagsc/analyze?slice_mode=auto|batch|custom|all` — DAGSC 切片分析 + 自动对齐的硬件水位报告
  - `POST /api/report/image` — 把晨报 Markdown 渲染为 PNG 图片（body: `{"markdown": "..."}`；`?download=1` 下载）
  - `GET|POST /api/report/markdown` — 生成或下载标准 Markdown 开发日报
  - `GET /api/export/system-csv` & `GET /api/export/cms-csv` — 原始监控 CSV 流式导出
