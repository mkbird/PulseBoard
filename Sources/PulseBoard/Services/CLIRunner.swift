import Foundation
import SQLite3

enum SelfTestError: LocalizedError {
    case assertionFailed(String)

    var errorDescription: String? {
        switch self {
        case .assertionFailed(let msg): "Self-test assertion failed: \(msg)"
        }
    }
}

enum SelfTestSuite {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw SelfTestError.assertionFailed(message)
        }
    }

    static func runAll() throws {
        try verifyURLFormQueryDecoding()
        try verifyDAGSCBatchAndDaySlicing()
        try verifyAlignedHardwareAndMarkdownReport()
    }

    static func verifyURLFormQueryDecoding() throws {
        let raw = "/api/dagsc/analyze?path=%2FUsers%2Fyingjia%2FLibrary%2FApplication+Support%2Fcom.clipto.mac%2Fdagsc_data&tag=C%2B%2B+%E6%97%A5%E6%8A%A5&slice_mode=batch"
        let (path, q) = LocalWebServer.parseTarget(raw)
        try check(path == "/api/dagsc/analyze", "Expected decoded path /api/dagsc/analyze, got \(path)")
        try check(
            q["path"] == "/Users/yingjia/Library/Application Support/com.clipto.mac/dagsc_data",
            "Expected '+' in query value to decode as space, got \(String(describing: q["path"]))"
        )
        try check(
            q["tag"] == "C++ 日报",
            "Expected '%2B' to remain '+' while '+' becomes space, got \(String(describing: q["tag"]))"
        )
    }

    static func verifyDAGSCBatchAndDaySlicing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliptopulse_test_dagsc_\(UUID().uuidString)", isDirectory: true)
        let dataDir = tempDir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = dataDir.appendingPathComponent("schedule.db")
        try createSyntheticScheduleDB(at: dbURL)

        let env = SystemEnvironmentService.current(webPort: 8766, historyDBURL: tempDir.appendingPathComponent("history.sqlite"))

        // 1. Auto mode picks the latest media asset batch (batch-3 on 2026-10-24), ignoring non-asset startup workflows
        let autoRes = try DAGSCAnalyzer.analyze(
            options: DAGSCQueryOptions(inputPath: tempDir.path, sliceMode: "auto"),
            environment: env
        )
        try check(autoRes.availableBatches.count == 3, "Expected 3 asset batches (startup check excluded), got \(autoRes.availableBatches.count)")
        try check(autoRes.availableDays.count == 2, "Expected 2 natural days, got \(autoRes.availableDays.count)")
        try check(autoRes.selectedBatchID == "batch-3", "Expected selectedBatchID == batch-3, got \(String(describing: autoRes.selectedBatchID))")
        try check(autoRes.assetsTotal == 1, "Expected 1 media asset in batch-3")
        try check(autoRes.videoAssetsCount == 1, "Expected 1 video asset in batch-3")
        try check(autoRes.totalMediaDurationMs == 60_000, "Expected 60_000ms media duration")
        try check(autoRes.scopes.assetAnalysis.wallClockMs == 10_000, "Expected 10_000ms wallClockMs")
        try check(autoRes.scopes.assetAnalysis.activeSegments.last?.virtualEndMs == 10_000, "Expected swimlane virtualEndMs == 10_000ms")
        try check(autoRes.scopes.assetAnalysis.wallSpeedup == 6.0, "Expected 6.0x wallSpeedup")
        try check(autoRes.failedTaskSamples.count == 1, "Expected 1 failed task sample")

        // 2. Day mode on 2026-10-24 has two asset batches (10:00 for 5s + 11:00 for 10s = 15_000ms active),
        //    and stitched swimlane virtualEndMs must equal wallClockMs (15_000ms), NOT 3_610_000ms!
        let dayRes = try DAGSCAnalyzer.analyze(
            options: DAGSCQueryOptions(inputPath: tempDir.path, sliceMode: "day", day: "2026-10-24"),
            environment: env
        )
        try check(dayRes.sliceMode == "day", "Expected day sliceMode")
        try check(dayRes.scopes.assetAnalysis.wallClockMs == 15_000, "Expected active wallClockMs == 15_000ms, got \(dayRes.scopes.assetAnalysis.wallClockMs)")
        try check(dayRes.scopes.assetAnalysis.activeSegments.count == 2, "Expected 2 stitched active segments")
        try check(dayRes.scopes.assetAnalysis.activeSegments.last?.virtualEndMs == 15_000, "Expected stitched swimlane length == 15_000ms")
        try check(dayRes.scopes.assetAnalysis.zeroStartFixedCount == 1, "Expected 1 zeroStartFixedCount task")

        // 3. All-DB mode across multiple days must also stitch active segments so swimlane length == wallClockMs (35_000ms)
        let allRes = try DAGSCAnalyzer.analyze(
            options: DAGSCQueryOptions(inputPath: tempDir.path, sliceMode: "all"),
            environment: env
        )
        try check(allRes.scopes.assetAnalysis.wallClockMs == 35_000, "Expected all-DB active wallClockMs == 35_000ms")
        try check(allRes.scopes.assetAnalysis.activeSegments.last?.virtualEndMs == 35_000, "Expected all-DB swimlane virtualEndMs == 35_000ms")
    }

    static func verifyAlignedHardwareAndMarkdownReport() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliptopulse_test_full_\(UUID().uuidString)", isDirectory: true)
        let dataDir = tempDir.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scheduleURL = dataDir.appendingPathComponent("schedule.db")
        try createSyntheticScheduleDB(at: scheduleURL)

        let historyURL = tempDir.appendingPathComponent("history.sqlite")
        let store = try HistoryStore(databaseURL: historyURL)

        let batch3StartMs = localTimestampMs(year: 2026, month: 10, day: 24, hour: 11, minute: 0, second: 0)
        let sessionStart = Date(timeIntervalSince1970: Double(batch3StartMs) / 1_000.0)
        let pid1 = CMSProcessID(pid: 1001, startTime: 1_000_001)
        let pid2 = CMSProcessID(pid: 1002, startTime: 1_000_002)

        for sec in 0...10 {
            let ts = Date(timeIntervalSince1970: Double(batch3StartMs) / 1_000.0 + Double(sec))
            let sample = MetricSample(
                timestamp: ts,
                cpuUsage: 45,
                gpuUsage: 30,
                aneUsage: 12,
                memoryUsage: 60,
                memoryUsedBytes: 18_000_000_000,
                memoryTotalBytes: 32_000_000_000,
                memoryPressure: 40,
                anePowerWatts: 2.0,
                cpuPowerWatts: 18.0,
                gpuPowerWatts: 10.0,
                systemPowerWatts: 36.0,
                memoryReadGBps: 24.0,
                memoryWriteGBps: 12.0,
                diskReadBytesPerSecond: 100_000_000,
                diskWriteBytesPerSecond: 20_000_000,
                diskFreeBytes: 200_000_000_000,
                diskTotalBytes: 500_000_000_000,
                networkDownBytesPerSecond: 1_000,
                networkUpBytesPerSecond: 500,
                thermalState: "正常",
                cliptoCPUPercent: 38.0,
                cliptoMemoryBytes: 4_294_967_296,
                cliptoDiskReadBytesPerSecond: 80_000_000,
                cliptoDiskWriteBytesPerSecond: 10_000_000,
                cliptoProcessCount: 6,
                cliptoGPUPercent: 28.0,
                swapUsedBytes: 0,
                swapTotalBytes: 2_147_483_648
            )

            let raw = CMSRawSnapshot(
                timestamp: ts,
                monotonicSeconds: Double(100 + sec),
                processes: [
                    CMSProcessReading(id: pid1, name: "cms_vlm_worker", cpuSeconds: Double(sec) * 1.85, memoryBytes: 2_147_483_648),
                    CMSProcessReading(id: pid2, name: "cms_asr_worker", cpuSeconds: Double(sec) * 0.65, memoryBytes: 536_870_912)
                ],
                enumerationValid: true,
                unreadableCount: 0
            )
            let cmsFrame = CMSHistoryFrame(
                sessionID: "test-session",
                sessionStartedAt: sessionStart,
                sequence: Int64(sec + 1),
                segment: 0,
                maximumGap: 3.0,
                raw: raw,
                totalCPUPercent: 250.0,
                totalMemoryBytes: 2_684_354_560,
                processCPUPercent: [pid1: 185.0, pid2: 65.0],
                statisticsVersion: 2
            )
            try store.append(system: sample, cms: cmsFrame)
        }

        let env = SystemEnvironmentService.current(webPort: 8766, historyDBURL: historyURL)
        var analysis = try DAGSCAnalyzer.analyze(
            options: DAGSCQueryOptions(inputPath: tempDir.path, sliceMode: "batch", batchID: "batch-3"),
            environment: env
        )

        let aligned = try store.fetchAlignedReport(
            activeIntervalsMs: analysis.activeIntervalsMs,
            fallbackStartMs: analysis.sliceStartMs,
            fallbackEndMs: analysis.sliceEndMs
        )
        try check(aligned.hasData, "Expected aligned.hasData == true")
        try check(aligned.sampleCount == 11, "Expected 11 aligned samples, got \(aligned.sampleCount)")
        try check(aligned.cmsFrameCount == 11, "Expected 11 aligned CMS frames, got \(aligned.cmsFrameCount)")
        try check(aligned.cliptoMemoryBytes.max == 4_294_967_296, "Expected Clipto max memory 4 GiB")
        try check(aligned.cmsProcesses.count == 2, "Expected 2 CMS process summaries")
        try check((aligned.estimatedEnergyWh ?? 0) > 0.05, "Expected positive estimatedEnergyWh")

        analysis.alignedHardware = aligned

        let md = MarkdownReportGenerator.generate(
            analysis: analysis,
            options: MarkdownReportOptions(
                reporter: "测试工程师 A",
                changeSummary: "优化 VLM 并发与解码管线 | 降低峰值内存",
                notes: "观察到长视频切片耗时稳定 | 无 OOM"
            )
        )

        try check(md.contains("# Clipto 运行与性能开发日报（2026-10-24）"), "Missing Markdown report H1 header")
        try check(md.contains("测试工程师 A"), "Missing reporter field in Markdown")
        try check(md.contains("优化 VLM 并发与解码管线 \\| 降低峰值内存"), "Unescaped pipe in changeSummary")
        try check(md.contains("## 二、运行期硬件与进程资源水位（PulseBoard 自动对齐）"), "Missing aligned hardware section")
        try check(md.contains("`cms_vlm_worker`"), "Missing CMS worker row in Markdown")
        try check(md.contains("clip_pipe\\|test.mp4"), "Unescaped pipe in asset filename")
    }

    private static func localTimestampMs(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int64 {
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.timeZone = TimeZone.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        let date = comps.date ?? Date()
        return Int64((date.timeIntervalSince1970 * 1_000.0).rounded())
    }

    private static func createSyntheticScheduleDB(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw DAGSCError.sqliteOpenFailed("Failed to create synthetic schedule.db")
        }
        defer { sqlite3_close(db) }

        let schema = """
        CREATE TABLE workflow_templates (
            template_id TEXT,
            template_version TEXT,
            loaded_at INTEGER
        );
        CREATE TABLE workflows (
            workflow_id TEXT PRIMARY KEY,
            template_id TEXT,
            template_version TEXT,
            asset_id TEXT,
            status_text TEXT,
            created_at INTEGER,
            started_at INTEGER,
            finished_at INTEGER,
            analysis_mode TEXT,
            asset_metadata TEXT,
            context_json TEXT
        );
        CREATE VIEW v_workflows AS SELECT * FROM workflows;
        CREATE TABLE nodes (
            workflow_id TEXT,
            node_id TEXT,
            template_node_id TEXT
        );
        CREATE TABLE v_tasks (
            task_id TEXT PRIMARY KEY,
            workflow_id TEXT,
            node_id TEXT,
            node_type TEXT,
            status_text TEXT,
            executor_text TEXT,
            dispatched_at INTEGER,
            started_at INTEGER,
            finished_at INTEGER,
            error_json TEXT
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw DAGSCError.sqliteQueryFailed(String(cString: sqlite3_errmsg(db)))
        }

        let d1Start = localTimestampMs(year: 2026, month: 10, day: 20, hour: 15, minute: 0, second: 0)
        let d2StartupNoise = localTimestampMs(year: 2026, month: 10, day: 24, hour: 9, minute: 0, second: 0)
        let d2Batch2Start = localTimestampMs(year: 2026, month: 10, day: 24, hour: 10, minute: 0, second: 0)
        let d2Batch3Start = localTimestampMs(year: 2026, month: 10, day: 24, hour: 11, minute: 0, second: 0)

        let statements = [
            "INSERT INTO workflow_templates VALUES ('clipto_asset_analysis', '1.4.0', \(d2Batch3Start));",
            """
            INSERT INTO workflows VALUES (
                'wf-day1', 'clipto_asset_analysis', '1.4.0', 'asset-1', 'succeeded',
                \(d1Start), \(d1Start), \(d1Start + 20_000), 'full',
                '{"filename":"intro.mp4"}',
                '{"duration":120000,"file_size_bytes":52428800,"asset_type":"video"}'
            );
            """,
            "INSERT INTO nodes VALUES ('wf-day1', 'n1', 'video_decode');",
            """
            INSERT INTO v_tasks VALUES (
                't-day1-1', 'wf-day1', 'n1', 'media.decode', 'succeeded', 'native',
                \(d1Start), \(d1Start), \(d1Start + 20_000), ''
            );
            """,
            // Non-asset startup workflow at 09:00 -> must be completely ignored
            """
            INSERT INTO workflows VALUES (
                'wf-startup', 'clipto_startup_check', '1.0.0', '', 'succeeded',
                \(d2StartupNoise), \(d2StartupNoise), \(d2StartupNoise + 5_000), '', '', ''
            );
            """,
            "INSERT INTO nodes VALUES ('wf-startup', 'n-boot', 'env_probe');",
            """
            INSERT INTO v_tasks VALUES (
                't-boot-1', 'wf-startup', 'n-boot', 'system.probe', 'succeeded', 'local',
                \(d2StartupNoise), \(d2StartupNoise), \(d2StartupNoise + 5_000), ''
            );
            """,
            // Asset batch #2 at 10:00 (5s, started_at=0 -> zeroStartFixed)
            """
            INSERT INTO workflows VALUES (
                'wf-day2-early', 'clipto_asset_analysis', '1.4.0', 'asset-early', 'succeeded',
                \(d2Batch2Start), \(d2Batch2Start), \(d2Batch2Start + 5_000), 'full',
                '{"filename":"early.jpg"}',
                '{"duration":0,"file_size_bytes":1048576,"asset_type":"image"}'
            );
            """,
            "INSERT INTO nodes VALUES ('wf-day2-early', 'n-img', 'img_tag');",
            """
            INSERT INTO v_tasks VALUES (
                't-d2-img', 'wf-day2-early', 'n-img', 'ai.vision', 'succeeded', 'cms',
                \(d2Batch2Start), 0, \(d2Batch2Start + 5_000), ''
            );
            """,
            """
            INSERT INTO workflows VALUES (
                'wf-day2-asset', 'clipto_asset_analysis', '1.4.0', 'asset-2', 'succeeded',
                \(d2Batch3Start), \(d2Batch3Start), \(d2Batch3Start + 10_000), 'full',
                '{"filename":"clip_pipe|test.mp4"}',
                '{"duration":60000,"file_size_bytes":104857600,"asset_type":"video"}'
            );
            """,
            "INSERT INTO nodes VALUES ('wf-day2-asset', 'n-vlm', 'vlm_caption');",
            "INSERT INTO nodes VALUES ('wf-day2-asset', 'n-asr', 'asr_transcribe');",
            """
            INSERT INTO v_tasks VALUES (
                't-d2-vlm', 'wf-day2-asset', 'n-vlm', 'ai.vlm', 'succeeded', 'cms',
                \(d2Batch3Start), \(d2Batch3Start), \(d2Batch3Start + 10_000), ''
            );
            """,
            """
            INSERT INTO v_tasks VALUES (
                't-d2-asr', 'wf-day2-asset', 'n-asr', 'ai.asr', 'failed', 'cms',
                \(d2Batch3Start + 1_000), \(d2Batch3Start + 1_000), \(d2Batch3Start + 4_000), '{"message":"mock timeout"}'
            );
            """
        ]

        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw DAGSCError.sqliteQueryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}

enum CLIRunner {
    /// Returns true if a CLI-only flag (`--self-test`, `--export-report`, `--help`) was handled and the process should exit.
    static func handleIfNeeded(arguments: [String] = CommandLine.arguments) -> Bool {
        if arguments.contains("--help") || arguments.contains("-h") {
            printUsage()
            return true
        }

        if arguments.contains("--self-test") {
            do {
                try SelfTestSuite.runAll()
                print("CliptoPulse self-test passed (DAGSC batch/day slicing + aligned hardware + GFM Markdown report).")
                return true
            } catch {
                fputs("CliptoPulse self-test FAILED: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        if arguments.contains("--export-report") {
            do {
                try exportReportCLI(arguments: arguments)
                return true
            } catch {
                fputs("CliptoPulse --export-report failed: \(error.localizedDescription)\n", stderr)
                Foundation.exit(1)
            }
        }

        return false
    }

    private static func exportReportCLI(arguments: [String]) throws {
        var dagscPath = ""
        var sliceMode = "auto"
        var batchID: String?
        var day: String?
        var reporter = ""
        var changeSummary = ""
        var notes = ""
        var outPath: String?

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            func nextVal() -> String? {
                guard i + 1 < arguments.count else { return nil }
                i += 1
                return arguments[i]
            }
            if arg == "--dagsc", let v = nextVal() { dagscPath = v }
            else if arg.hasPrefix("--dagsc=") { dagscPath = String(arg.dropFirst("--dagsc=".count)) }
            else if arg == "--slice", let v = nextVal() { sliceMode = v }
            else if arg.hasPrefix("--slice=") { sliceMode = String(arg.dropFirst("--slice=".count)) }
            else if arg == "--batch", let v = nextVal() { batchID = v }
            else if arg.hasPrefix("--batch=") { batchID = String(arg.dropFirst("--batch=".count)) }
            else if arg == "--day", let v = nextVal() { day = v }
            else if arg.hasPrefix("--day=") { day = String(arg.dropFirst("--day=".count)) }
            else if arg == "--reporter", let v = nextVal() { reporter = v }
            else if arg.hasPrefix("--reporter=") { reporter = String(arg.dropFirst("--reporter=".count)) }
            else if arg == "--change", let v = nextVal() { changeSummary = v }
            else if arg.hasPrefix("--change=") { changeSummary = String(arg.dropFirst("--change=".count)) }
            else if arg == "--notes", let v = nextVal() { notes = v }
            else if arg.hasPrefix("--notes=") { notes = String(arg.dropFirst("--notes=".count)) }
            else if arg == "--out", let v = nextVal() { outPath = v }
            else if arg.hasPrefix("--out=") { outPath = String(arg.dropFirst("--out=".count)) }
            i += 1
        }

        let fallbackHistURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PulseBoard/history.sqlite")
        let store = try? HistoryStore()
        let env = SystemEnvironmentService.current(webPort: 8766, historyDBURL: store?.databaseURL ?? fallbackHistURL)

        var analysis = try DAGSCAnalyzer.analyze(
            options: DAGSCQueryOptions(
                inputPath: dagscPath,
                sliceMode: sliceMode,
                batchID: batchID,
                day: day
            ),
            environment: env
        )
        if let store {
            analysis.alignedHardware = try? store.fetchAlignedReport(
                activeIntervalsMs: analysis.activeIntervalsMs,
                fallbackStartMs: analysis.sliceStartMs,
                fallbackEndMs: analysis.sliceEndMs
            )
        }

        let md = MarkdownReportGenerator.generate(
            analysis: analysis,
            options: MarkdownReportOptions(
                reporter: reporter,
                changeSummary: changeSummary,
                notes: notes
            )
        )

        if let outPath, !outPath.isEmpty {
            let expanded = (outPath as NSString).expandingTildeInPath
            let outURL = URL(fileURLWithPath: expanded)
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try md.write(to: outURL, atomically: true, encoding: String.Encoding.utf8)
            print("Saved Markdown report to \(outURL.path)")
        } else {
            print(md)
        }
    }

    private static func printUsage() {
        let usage = """
        CliptoPulse v2.0 — 菜单栏常驻采集 + 统一网页控制台 + Clipto 开发日报工具

        用法:
          PulseBoard [选项]

        常规运行选项:
          (无参数)              启动菜单栏常驻采集与统一 Web 控制台 (http://127.0.0.1:8766)
          --no-browser          启动常驻采集与 Web 服务，但不自动打开浏览器标签页
          --port <端口号>       指定首选 Web 控制台端口（默认 8766）

        命令行工具选项:
          --export-report       直接生成并输出 Clipto Markdown 开发日报后退出
            --dagsc <路径>      指定 dagsc_data 目录或 schedule.db 路径（默认自动探测本机 Clipto）
            --slice <模式>      auto | batch | day | all（默认 auto）
            --batch <batch-id>  当 --slice=batch 时指定批次 ID（如 batch-3）
            --day <YYYY-MM-DD>  当 --slice=day 时指定自然日（如 2026-10-24）
            --reporter <姓名>   日报记录人
            --change <说明>     本轮版本/改动说明
            --notes <备注>      问题定位与后续计划备注
            --out <文件路径>    保存 Markdown 到文件（省略则输出到标准输出）
          --self-test           运行内置自检测试套件（验证分批/自然日切分、硬件对齐与日报生成）
          --help, -h            显示本帮助信息
        """
        print(usage)
    }
}
