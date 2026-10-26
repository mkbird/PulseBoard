import Foundation
import SQLite3

enum DAGSCError: LocalizedError {
    case pathNotFound(String)
    case invalidDatabaseFile(String)
    case scheduleDBNotFound(String)
    case sqliteOpenFailed(String)
    case sqliteQueryFailed(String)

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let p): "路径不存在：\(p)"
        case .invalidDatabaseFile(let p): "指定的文件不是数据库文件：\(p)"
        case .scheduleDBNotFound(let p): "在目录 \(p) 下未找到 data/schedule.db 或 schedule.db，请确认路径是否正确。"
        case .sqliteOpenFailed(let msg): "无法打开 DAGSC 数据库：\(msg)"
        case .sqliteQueryFailed(let msg): "读取 DAGSC 数据库失败：\(msg)"
        }
    }
}

struct DAGSCQueryOptions: Sendable {
    var inputPath: String = ""
    /// "auto" | "batch" | "day" | "custom" | "all"
    var sliceMode: String = "auto"
    var batchID: String?
    var day: String?
    var customFromMs: Int64?
    var customToMs: Int64?
    /// Idle gap threshold in milliseconds used to split distinct test batches (default: 15 minutes).
    var batchGapMs: Int64 = 15 * 60 * 1_000
}

enum DAGSCAnalyzer {
    private struct RawWorkflow {
        let workflowID: String
        let templateID: String
        let templateVersion: String
        let assetID: String
        let statusText: String
        let createdAt: Int64
        let startedAt: Int64
        let finishedAt: Int64
        let analysisMode: String
        let filename: String
        let assetType: String
        let mediaDurationMs: Int64
        let fileSizeBytes: Int64
    }

    private struct RawTask {
        let taskID: String
        let workflowID: String
        let nodeID: String
        let nodeType: String
        let statusText: String
        let executorText: String
        let dispatchedAt: Int64
        let startedAt: Int64
        let finishedAt: Int64
        let effStart: Int64
        let effEnd: Int64
        let durationMs: Int64
        let zeroStartFixed: Bool
        let templateID: String
        let assetID: String
        let templateNodeID: String
        let errorJSON: String
    }

    static func resolveScheduleDB(inputPath: String) throws -> (dagscRoot: URL, dbURL: URL) {
        let (_, defaultDir) = SystemEnvironmentService.detectUserAndDefaultDagscDir()
        var raw = inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        while (raw.hasPrefix("\"") && raw.hasSuffix("\"")) || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            raw = String(raw.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if raw.hasPrefix("file://"), let fileURL = URL(string: raw), fileURL.isFileURL {
            raw = fileURL.path
        } else if raw.hasPrefix("Users/"), FileManager.default.fileExists(atPath: "/" + raw) {
            raw = "/" + raw
        }
        let target = raw.isEmpty ? defaultDir : (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: target).standardizedFileURL

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw DAGSCError.pathNotFound(url.path)
        }

        if !isDir.boolValue {
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".db") || name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite3") else {
                throw DAGSCError.invalidDatabaseFile(url.path)
            }
            let parent = url.deletingLastPathComponent()
            let root = parent.lastPathComponent == "data" ? parent.deletingLastPathComponent() : parent
            return (root, url)
        }

        let candidates = [
            url.appendingPathComponent("data/schedule.db"),
            url.appendingPathComponent("schedule.db"),
            url.appendingPathComponent("dagsc_data/data/schedule.db")
        ]
        for candidate in candidates {
            var candDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &candDir), !candDir.boolValue {
                let parent = candidate.deletingLastPathComponent()
                let root = parent.lastPathComponent == "data" ? parent.deletingLastPathComponent() : parent
                return (root, candidate)
            }
        }
        throw DAGSCError.scheduleDBNotFound(url.path)
    }

    static func detectCliptoVersion(dagscRoot: URL) -> String {
        var logVer = ""
        let candidateLogs = [
            dagscRoot.deletingLastPathComponent().appendingPathComponent("logs/main.log"),
            dagscRoot.appendingPathComponent("logs/main.log")
        ]
        let versionPattern = try? NSRegularExpression(pattern: #"version:\s*'(\d+\.\d+\.\d+[^']*)'"#)
        for logURL in candidateLogs where FileManager.default.fileExists(atPath: logURL.path) {
            if let text = readTailUTF8(url: logURL, maxBytes: 1_024 * 1_024),
               let regex = versionPattern {
                let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
                let matches = regex.matches(in: text, range: nsRange)
                if let last = matches.last,
                   let range = Range(last.range(at: 1), in: text) {
                    logVer = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !logVer.isEmpty { break }
                }
            }
        }

        var plistVer = ""
        var plistShort = ""
        let homeApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Clipto.app/Contents/Info.plist")
        let candidatePlists = [
            URL(fileURLWithPath: "/Applications/Clipto.app/Contents/Info.plist"),
            homeApps
        ]
        for plistURL in candidatePlists where FileManager.default.fileExists(atPath: plistURL.path) {
            if let data = try? Data(contentsOf: plistURL),
               let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
                plistVer = (plist["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                plistShort = (plist["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                break
            }
        }

        let primary = !logVer.isEmpty ? logVer : plistVer
        if !primary.isEmpty, !plistShort.isEmpty, plistShort != primary {
            return "v\(primary) (\(plistShort))"
        }
        if !primary.isEmpty {
            return "v\(primary)"
        }
        if !plistShort.isEmpty {
            return "v\(plistShort)"
        }
        return "未知版本"
    }

    static func analyze(options: DAGSCQueryOptions, environment: SystemEnvironmentInfo) throws -> DAGSCAnalysisResponse {
        let (username, defaultDir) = SystemEnvironmentService.detectUserAndDefaultDagscDir()
        let (dagscRoot, dbURL) = try resolveScheduleDB(inputPath: options.inputPath)
        let batchGapMs = max(60_000, options.batchGapMs)

        let attrs = try FileManager.default.attributesOfItem(atPath: dbURL.path)
        let dbSizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let dbMtime = (attrs[.modificationDate] as? Date) ?? Date()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliptopulse_dagsc_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tempDB = tempDir.appendingPathComponent("schedule.db")
        try FileManager.default.copyItem(at: dbURL, to: tempDB)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: dbURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.copyItem(at: sidecar, to: URL(fileURLWithPath: tempDB.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempDB.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close(db) }
            throw DAGSCError.sqliteOpenFailed(msg)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)

        let rawWorkflows = try loadWorkflows(db: db)
        let workflowsByID = Dictionary(rawWorkflows.map { ($0.workflowID, $0) }, uniquingKeysWith: { _, last in last })
        let rawTasks = try loadTasks(db: db, workflowsByID: workflowsByID)
        // Only analyze media asset analysis (`clipto_asset_analysis`), excluding startup/lightweight non-asset flows
        let workflows = rawWorkflows.filter { $0.templateID == "clipto_asset_analysis" }
        let allLoadedTasks = rawTasks.filter { $0.templateID == "clipto_asset_analysis" }
        let templateVersion = loadTemplateVersion(db: db)

        // 1. Discover Batches & Days across the whole schedule.db
        let (batchesChrono, daysDesc) = discoverBatchesAndDays(
            workflows: workflows,
            tasks: allLoadedTasks,
            batchGapMs: batchGapMs
        )
        let batchesDesc = Array(batchesChrono.reversed())

        // 2. Resolve effective slice
        let resolved = resolveEffectiveSlice(
            options: options,
            batchesDesc: batchesDesc,
            daysDesc: daysDesc,
            allTasks: allLoadedTasks,
            allWorkflows: workflows
        )

        // 3. Filter tasks & workflows to the resolved slice
        let filteredTasks: [RawTask]
        let filteredWorkflows: [RawWorkflow]

        if resolved.mode == "all" {
            filteredTasks = allLoadedTasks
            filteredWorkflows = workflows
        } else {
            let wStart = resolved.startMs
            let wEnd = resolved.endMs
            filteredTasks = allLoadedTasks.filter { t in
                guard t.effStart > 0 else { return false }
                if resolved.mode == "day" {
                    return t.effStart >= wStart && t.effStart <= wEnd
                }
                return t.effStart <= wEnd && t.effEnd >= wStart
            }
            let activeWorkflowIDs = Set(filteredTasks.map(\.workflowID))
            filteredWorkflows = workflows.filter { wf in
                if activeWorkflowIDs.contains(wf.workflowID) { return true }
                let anchor = wf.startedAt > 0 ? wf.startedAt : wf.createdAt
                return anchor > 0 && anchor >= wStart && anchor <= wEnd
            }
        }

        // 4. Workflow summary by template
        var wfSummaryMap: [String: (
            total: Int, succeeded: Int, failed: Int, canceled: Int, running: Int,
            minStart: Int64?, maxFinish: Int64?
        )] = [:]
        var wfOrder: [String] = []
        for wf in filteredWorkflows {
            if wfSummaryMap[wf.templateID] == nil {
                wfOrder.append(wf.templateID)
                wfSummaryMap[wf.templateID] = (0, 0, 0, 0, 0, nil, nil)
            }
            guard var entry = wfSummaryMap[wf.templateID] else { continue }
            entry.total += 1
            switch wf.statusText {
            case "succeeded": entry.succeeded += 1
            case "failed": entry.failed += 1
            case "canceled": entry.canceled += 1
            case "running": entry.running += 1
            default: break
            }
            if wf.startedAt > 0 {
                entry.minStart = entry.minStart.map { min($0, wf.startedAt) } ?? wf.startedAt
            }
            if wf.finishedAt > 0 {
                entry.maxFinish = entry.maxFinish.map { max($0, wf.finishedAt) } ?? wf.finishedAt
            }
            wfSummaryMap[wf.templateID] = entry
        }
        let workflowsByTemplate = wfOrder.compactMap { tid -> DAGSCWorkflowSummary? in
            guard let e = wfSummaryMap[tid] else { return nil }
            return DAGSCWorkflowSummary(
                templateID: tid, total: e.total, succeeded: e.succeeded,
                failed: e.failed, canceled: e.canceled, running: e.running,
                minStartedAt: e.minStart, maxFinishedAt: e.maxFinish
            )
        }

        // 5. Media assets breakdown (keyed by workflowID so repeated asset_ids on different runs stay distinct)
        struct AssetAccumulator {
            let wf: RawWorkflow
            var taskCount: Int = 0
            var firstTaskStart: Int64?
            var lastTaskFinish: Int64?
            var cumulativeTaskMs: Int64 = 0
            var typeMs: [String: Int64] = [:]
        }
        var assetAccByWF: [String: AssetAccumulator] = [:]
        var totalMediaDurationMs: Int64 = 0
        var totalMediaSizeBytes: Int64 = 0
        var videoAssetsCount = 0
        var imageAssetsCount = 0

        for wf in filteredWorkflows where wf.templateID == "clipto_asset_analysis" && !wf.assetID.isEmpty {
            totalMediaDurationMs += wf.mediaDurationMs
            totalMediaSizeBytes += wf.fileSizeBytes
            if wf.assetType == "image" || wf.mediaDurationMs == 0 {
                imageAssetsCount += 1
            } else {
                videoAssetsCount += 1
            }
            assetAccByWF[wf.workflowID] = AssetAccumulator(wf: wf)
        }

        let assetTasks = filteredTasks.filter { $0.templateID == "clipto_asset_analysis" }
        for t in assetTasks {
            guard var acc = assetAccByWF[t.workflowID] else { continue }
            acc.taskCount += 1
            acc.cumulativeTaskMs += t.durationMs
            if t.effStart > 0 {
                acc.firstTaskStart = acc.firstTaskStart.map { min($0, t.effStart) } ?? t.effStart
            }
            if t.finishedAt > 0 {
                acc.lastTaskFinish = acc.lastTaskFinish.map { max($0, t.finishedAt) } ?? t.finishedAt
            }
            let nt = t.nodeType.isEmpty ? "unknown" : t.nodeType
            acc.typeMs[nt, default: 0] += t.durationMs
            assetAccByWF[t.workflowID] = acc
        }

        var byAsset: [DAGSCAssetRow] = assetAccByWF.values.map { acc in
            let wf = acc.wf
            let fS = acc.firstTaskStart ?? wf.startedAt
            let lF = acc.lastTaskFinish ?? wf.finishedAt
            let spanMs: Int64 = (lF > fS && fS > 0) ? (lF - fS) : 0
            let topPair = acc.typeMs.max { $0.value < $1.value }
            let (wallRtf, wallSpeedup) = calcSpeedRatios(procMs: spanMs, mediaMs: wf.mediaDurationMs)
            let (cumRtf, cumSpeedup) = calcSpeedRatios(procMs: acc.cumulativeTaskMs, mediaMs: wf.mediaDurationMs)
            return DAGSCAssetRow(
                assetID: wf.assetID,
                workflowID: wf.workflowID,
                filename: wf.filename,
                assetType: wf.assetType,
                mediaDurationMs: wf.mediaDurationMs,
                fileSizeBytes: wf.fileSizeBytes,
                status: wf.statusText,
                taskCount: acc.taskCount,
                firstStartMs: fS,
                firstStartText: formatTimestampMs(fS),
                lastFinishMs: lF,
                lastFinishText: formatTimestampMs(lF),
                wallSpanMs: spanMs,
                wallRtf: wallRtf,
                wallSpeedup: wallSpeedup,
                cumulativeTaskMs: acc.cumulativeTaskMs,
                cumRtf: cumRtf,
                cumSpeedup: cumSpeedup,
                topNodeType: topPair?.key ?? "",
                topNodeMs: topPair?.value ?? 0
            )
        }
        byAsset.sort { a, b in
            switch (Int64(a.assetID), Int64(b.assetID)) {
            case let (ia?, ib?):
                return ia == ib ? a.firstStartMs < b.firstStartMs : ia < ib
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return a.assetID < b.assetID
            }
        }

        // 6. Compute media asset analysis metrics (Scope 1)
        let scopeA = computeScopeMetrics(
            tasks: assetTasks,
            totalMediaDurationMs: totalMediaDurationMs,
            batchGapMs: batchGapMs
        )

        // 7. Active intervals for hardware alignment (exact match with scopeA.activeSegments)
        let activeIntervalsForJSON: [[Int64]]
        if !scopeA.activeSegments.isEmpty {
            activeIntervalsForJSON = scopeA.activeSegments.map { [$0.wallStartMs, $0.wallEndMs] }
        } else if resolved.startMs > 0, resolved.endMs >= resolved.startMs {
            activeIntervalsForJSON = [[resolved.startMs, resolved.endMs]]
        } else {
            activeIntervalsForJSON = []
        }

        // 8. Failed task samples (up to 20)
        let failedSamples = assetTasks
            .filter { $0.statusText == "failed" || !$0.errorJSON.isEmpty }
            .prefix(20)
            .map { t in
                DAGSCFailedTaskSample(
                    taskID: t.taskID,
                    workflowID: t.workflowID,
                    assetID: t.assetID,
                    nodeType: t.nodeType,
                    templateNodeID: t.templateNodeID,
                    statusText: t.statusText,
                    timestampText: formatTimestampMs(t.finishedAt > 0 ? t.finishedAt : t.effStart),
                    errorSummary: summarizeErrorJSON(t.errorJSON)
                )
            }

        let effectiveStart = scopeA.activeSegments.first?.wallStartMs ?? resolved.startMs
        let effectiveEnd = scopeA.activeSegments.last?.wallEndMs ?? resolved.endMs
        let appVersion = detectCliptoVersion(dagscRoot: dagscRoot)

        return DAGSCAnalysisResponse(
            ok: true,
            appVersion: appVersion,
            templateVersion: templateVersion,
            detectedUsername: username,
            defaultDagscDir: defaultDir,
            dagscDir: dagscRoot.path,
            dbPath: dbURL.path,
            dbSizeBytes: dbSizeBytes,
            dbMtimeText: formatTimestampMs(Int64(dbMtime.timeIntervalSince1970 * 1_000)),
            analyzedAtText: formatNowSecond(),
            sliceMode: resolved.mode,
            selectedBatchID: resolved.batchID,
            selectedDay: resolved.day,
            sliceLabel: resolved.label,
            sliceStartMs: effectiveStart,
            sliceEndMs: effectiveEnd,
            sliceStartText: formatTimestampMs(effectiveStart),
            sliceEndText: formatTimestampMs(effectiveEnd),
            activeIntervalsMs: activeIntervalsForJSON,
            availableBatches: batchesDesc,
            availableDays: daysDesc,
            workflowsTotal: filteredWorkflows.count,
            assetsTotal: byAsset.count,
            videoAssetsCount: videoAssetsCount,
            imageAssetsCount: imageAssetsCount,
            totalMediaDurationMs: totalMediaDurationMs,
            totalMediaSizeBytes: totalMediaSizeBytes,
            workflowsByTemplate: workflowsByTemplate,
            scopes: DAGSCScopesContainer(assetAnalysis: scopeA),
            byAsset: byAsset,
            failedTaskSamples: Array(failedSamples),
            environment: environment,
            alignedHardware: nil
        )
    }

    // MARK: - Internal SQLite Loaders

    private static func loadWorkflows(db: OpaquePointer) throws -> [RawWorkflow] {
        let sql = """
        SELECT workflow_id, template_id, template_version, asset_id, status_text,
               created_at, started_at, finished_at, analysis_mode,
               asset_metadata, context_json
        FROM v_workflows
        ORDER BY created_at ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DAGSCError.sqliteQueryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [RawWorkflow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let wfID = colString(stmt, 0)
            let tplID = colString(stmt, 1)
            let tplVer = colString(stmt, 2)
            let assetID = colString(stmt, 3)
            let statusText = colString(stmt, 4)
            let createdAt = sqlite3_column_int64(stmt, 5)
            let startedAt = sqlite3_column_int64(stmt, 6)
            let finishedAt = sqlite3_column_int64(stmt, 7)
            let analysisMode = colString(stmt, 8)
            let assetMetaRaw = colString(stmt, 9)
            let contextRaw = colString(stmt, 10)

            var filename = assetID.isEmpty ? "" : "Asset #\(assetID)"
            var mediaDurMs: Int64 = 0
            var fileSize: Int64 = 0
            var assetType = "unknown"

            if tplID == "clipto_asset_analysis", !assetID.isEmpty {
                if !assetMetaRaw.isEmpty,
                   let data = assetMetaRaw.data(using: .utf8),
                   let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let fn = meta["filename"] as? String, !fn.isEmpty {
                    filename = fn
                }
                if !contextRaw.isEmpty,
                   let data = contextRaw.data(using: .utf8),
                   let ctx = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    mediaDurMs = jsonInt64(ctx["duration"])
                    fileSize = jsonInt64(ctx["file_size_bytes"])
                    if let at = ctx["asset_type"] as? String, !at.isEmpty {
                        assetType = at
                    } else {
                        assetType = mediaDurMs > 0 ? "video" : "unknown"
                    }
                } else {
                    assetType = "unknown"
                }
            }

            rows.append(RawWorkflow(
                workflowID: wfID,
                templateID: tplID,
                templateVersion: tplVer,
                assetID: assetID,
                statusText: statusText,
                createdAt: createdAt,
                startedAt: startedAt,
                finishedAt: finishedAt,
                analysisMode: analysisMode,
                filename: filename,
                assetType: assetType,
                mediaDurationMs: mediaDurMs,
                fileSizeBytes: fileSize
            ))
        }
        return rows
    }

    private static func loadTasks(db: OpaquePointer, workflowsByID: [String: RawWorkflow]) throws -> [RawTask] {
        let sql = """
        SELECT
            t.task_id,
            t.workflow_id,
            t.node_id,
            t.node_type,
            t.status_text,
            t.executor_text,
            t.dispatched_at,
            t.started_at,
            t.finished_at,
            w.template_id,
            w.asset_id,
            n.template_node_id,
            t.error_json
        FROM v_tasks t
        LEFT JOIN workflows w ON t.workflow_id = w.workflow_id
        LEFT JOIN nodes n ON t.workflow_id = n.workflow_id AND t.node_id = n.node_id;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DAGSCError.sqliteQueryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var tasks: [RawTask] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let taskID = colString(stmt, 0)
            let wfID = colString(stmt, 1)
            let nodeID = colString(stmt, 2)
            let nodeType = colString(stmt, 3)
            let statusText = colString(stmt, 4)
            let executorText = colString(stmt, 5)
            let dAt = sqlite3_column_int64(stmt, 6)
            let sAt = sqlite3_column_int64(stmt, 7)
            let fAt = sqlite3_column_int64(stmt, 8)
            let tplID = colString(stmt, 9)
            let assetID = colString(stmt, 10)
            let tplNodeRaw = colString(stmt, 11)
            let errorJSON = colString(stmt, 12)

            let effStart: Int64
            let zeroStartFixed: Bool
            if sAt > 0 {
                effStart = sAt
                zeroStartFixed = false
            } else if dAt > 0 {
                effStart = dAt
                zeroStartFixed = true
            } else {
                effStart = 0
                zeroStartFixed = false
            }

            let dur: Int64 = (fAt > 0 && effStart > 0 && fAt >= effStart) ? (fAt - effStart) : 0
            let effEnd: Int64 = max(effStart, fAt)
            let resolvedTplID = !tplID.isEmpty ? tplID : (workflowsByID[wfID]?.templateID ?? "")
            let resolvedAssetID = !assetID.isEmpty ? assetID : (workflowsByID[wfID]?.assetID ?? "")
            let tplNodeID = !tplNodeRaw.isEmpty ? tplNodeRaw : nodeType

            tasks.append(RawTask(
                taskID: taskID,
                workflowID: wfID,
                nodeID: nodeID,
                nodeType: nodeType,
                statusText: statusText,
                executorText: executorText,
                dispatchedAt: dAt,
                startedAt: sAt,
                finishedAt: fAt,
                effStart: effStart,
                effEnd: effEnd,
                durationMs: dur,
                zeroStartFixed: zeroStartFixed,
                templateID: resolvedTplID,
                assetID: resolvedAssetID,
                templateNodeID: tplNodeID,
                errorJSON: errorJSON
            ))
        }
        return tasks
    }

    private static func loadTemplateVersion(db: OpaquePointer) -> String {
        let sql = "SELECT template_version FROM workflow_templates WHERE template_id='clipto_asset_analysis' ORDER BY loaded_at DESC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return "" }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            let v = colString(stmt, 0)
            if !v.isEmpty { return "v\(v)" }
        }
        return ""
    }

    // MARK: - Batch & Day Discovery

    private static func discoverBatchesAndDays(
        workflows: [RawWorkflow],
        tasks: [RawTask],
        batchGapMs: Int64
    ) -> (batchesChrono: [DAGSCBatchSummary], daysDesc: [DAGSCDaySummary]) {
        let wfByID = Dictionary(workflows.map { ($0.workflowID, $0) }, uniquingKeysWith: { _, last in last })
        let validTasks = tasks.filter { $0.effStart > 0 }.sorted { $0.effStart < $1.effStart }

        struct Cluster {
            var startMs: Int64
            var endMs: Int64
            var taskCount: Int
            var workflowIDs: Set<String>
        }

        var clusters: [Cluster] = []
        for t in validTasks {
            let s = t.effStart
            let e = max(s, t.effEnd)
            if var last = clusters.last, s - last.endMs <= batchGapMs {
                last.endMs = max(last.endMs, e)
                last.taskCount += 1
                if !t.workflowID.isEmpty { last.workflowIDs.insert(t.workflowID) }
                clusters[clusters.count - 1] = last
            } else {
                var wfs = Set<String>()
                if !t.workflowID.isEmpty { wfs.insert(t.workflowID) }
                clusters.append(Cluster(startMs: s, endMs: e, taskCount: 1, workflowIDs: wfs))
            }
        }

        let batchesChrono: [DAGSCBatchSummary] = clusters.enumerated().map { idx, c in
            var assetCount = 0
            var videoCount = 0
            var imageCount = 0
            var mediaDur: Int64 = 0
            for wfID in c.workflowIDs {
                if let wf = wfByID[wfID], wf.templateID == "clipto_asset_analysis", !wf.assetID.isEmpty {
                    assetCount += 1
                    mediaDur += wf.mediaDurationMs
                    if wf.assetType == "image" || wf.mediaDurationMs == 0 {
                        imageCount += 1
                    } else {
                        videoCount += 1
                    }
                }
            }
            let day = formatDayLocal(c.startMs)
            let startShort = formatTimeOnlyLocal(c.startMs)
            let endShort = formatTimeOnlyLocal(c.endMs)
            let durMs = max(0, c.endMs - c.startMs)
            let batchNum = idx + 1
            let assetDesc = assetCount > 0 ? "\(assetCount) 素材" : "系统流"
            let label = "批次 #\(batchNum) · \(day) \(startShort)~\(endShort) (\(assetDesc) · \(c.taskCount) 任务)"
            return DAGSCBatchSummary(
                batchID: "batch-\(batchNum)",
                index: batchNum,
                day: day,
                label: label,
                startMs: c.startMs,
                endMs: c.endMs,
                startText: formatTimestampMs(c.startMs),
                endText: formatTimestampMs(c.endMs),
                durationMs: durMs,
                taskCount: c.taskCount,
                assetCount: assetCount,
                videoCount: videoCount,
                imageCount: imageCount,
                totalMediaDurationMs: mediaDur
            )
        }

        // Group by local day
        struct DayAcc {
            var taskCount: Int = 0
            var firstStart: Int64 = .max
            var lastFinish: Int64 = 0
            var workflowIDs: Set<String> = []
            var intervals: [(Int64, Int64)] = []
        }
        var dayMap: [String: DayAcc] = [:]
        for t in validTasks {
            let d = formatDayLocal(t.effStart)
            var acc = dayMap[d] ?? DayAcc()
            acc.taskCount += 1
            acc.firstStart = min(acc.firstStart, t.effStart)
            acc.lastFinish = max(acc.lastFinish, t.effEnd)
            if !t.workflowID.isEmpty { acc.workflowIDs.insert(t.workflowID) }
            acc.intervals.append((t.effStart, t.effEnd))
            dayMap[d] = acc
        }

        let daysDesc: [DAGSCDaySummary] = dayMap.keys.sorted(by: >).compactMap { d in
            guard let acc = dayMap[d] else { return nil }
            var assetCount = 0
            var videoCount = 0
            var imageCount = 0
            var mediaDur: Int64 = 0
            for wfID in acc.workflowIDs {
                if let wf = wfByID[wfID], wf.templateID == "clipto_asset_analysis", !wf.assetID.isEmpty {
                    assetCount += 1
                    mediaDur += wf.mediaDurationMs
                    if wf.assetType == "image" || wf.mediaDurationMs == 0 {
                        imageCount += 1
                    } else {
                        videoCount += 1
                    }
                }
            }
            let merged = mergeIntervalsWithGap(acc.intervals, maxGapMs: batchGapMs)
            let activeWall = merged.reduce(Int64(0)) { $0 + max(0, $1.1 - $1.0) }
            let fS = acc.firstStart == .max ? 0 : acc.firstStart
            return DAGSCDaySummary(
                day: d,
                batchCount: merged.count,
                taskCount: acc.taskCount,
                assetCount: assetCount,
                videoCount: videoCount,
                imageCount: imageCount,
                totalMediaDurationMs: mediaDur,
                firstStartMs: fS,
                lastFinishMs: acc.lastFinish,
                firstStartText: formatTimestampMs(fS),
                lastFinishText: formatTimestampMs(acc.lastFinish),
                activeBatchWallMs: activeWall
            )
        }

        return (batchesChrono, daysDesc)
    }

    private struct ResolvedSlice {
        let mode: String
        let batchID: String?
        let day: String?
        let label: String
        let startMs: Int64
        let endMs: Int64
    }

    private static func resolveEffectiveSlice(
        options: DAGSCQueryOptions,
        batchesDesc: [DAGSCBatchSummary],
        daysDesc: [DAGSCDaySummary],
        allTasks: [RawTask],
        allWorkflows: [RawWorkflow]
    ) -> ResolvedSlice {
        let reqMode = options.sliceMode.lowercased()

        if reqMode == "all" {
            let starts = allTasks.filter { $0.effStart > 0 }.map(\.effStart)
            let ends = allTasks.filter { $0.effEnd > 0 }.map(\.effEnd)
            return ResolvedSlice(
                mode: "all", batchID: nil, day: nil,
                label: "全库汇总（包含所有历史批次）",
                startMs: starts.min() ?? 0,
                endMs: ends.max() ?? 0
            )
        }

        if reqMode == "custom",
           let cFrom = options.customFromMs,
           let cTo = options.customToMs,
           cTo >= cFrom, cFrom > 0 {
            return ResolvedSlice(
                mode: "custom", batchID: nil, day: nil,
                label: "自定义时间窗 (\(formatTimestampMs(cFrom)) ~ \(formatTimestampMs(cTo)))",
                startMs: cFrom, endMs: cTo
            )
        }

        if reqMode == "day" {
            let targetDay = options.day ?? daysDesc.first?.day
            if let targetDay, let bounds = dayBoundsMs(dayString: targetDay) {
                return ResolvedSlice(
                    mode: "day", batchID: nil, day: targetDay,
                    label: "自然日汇总 · \(targetDay)",
                    startMs: bounds.startMs, endMs: bounds.endMs
                )
            }
        }

        if reqMode == "batch", let bid = options.batchID,
           let found = batchesDesc.first(where: { $0.batchID == bid }) {
            return ResolvedSlice(
                mode: "batch", batchID: found.batchID, day: found.day,
                label: found.label,
                startMs: found.startMs, endMs: found.endMs
            )
        }

        // Default ("auto" or fallback): pick latest batch with media assets, or latest batch overall, or "all"
        if let bestBatch = batchesDesc.first(where: { $0.assetCount > 0 }) ?? batchesDesc.first {
            return ResolvedSlice(
                mode: "batch", batchID: bestBatch.batchID, day: bestBatch.day,
                label: bestBatch.label,
                startMs: bestBatch.startMs, endMs: bestBatch.endMs
            )
        }

        return ResolvedSlice(
            mode: "all", batchID: nil, day: nil,
            label: "全库汇总",
            startMs: 0, endMs: 0
        )
    }

    // MARK: - Scope Metrics Computation

    private static func computeScopeMetrics(
        tasks: [RawTask],
        totalMediaDurationMs: Int64,
        batchGapMs: Int64
    ) -> DAGSCScopeMetrics {
        guard !tasks.isEmpty else {
            return DAGSCScopeMetrics(
                totalTasks: 0, succeededTasks: 0, failedTasks: 0, zeroStartFixedCount: 0,
                wallClockMs: 0, spanWallClockMs: 0, activeBatchWallMs: 0, batchCountInScope: 0,
                originStartMs: 0, originEndMs: 0,
                wallRtf: 0, wallSpeedup: 0, spanSpeedup: 0,
                cumulativeMs: 0, cumulativeRtf: 0, cumulativeSpeedup: 0, concurrency: 0,
                firstTask: nil, lastTask: nil, activeSegments: [],
                byNodeType: [], byTemplateNode: [], timelineSpans: [:]
            )
        }

        let validStartTasks = tasks.filter { $0.effStart > 0 }
        let validEndTasks = validStartTasks.filter { $0.effEnd > 0 }
        let firstTask = validStartTasks.min { $0.effStart < $1.effStart }
        let lastTask = validEndTasks.max { $0.effEnd < $1.effEnd }

        let minStartMs = firstTask?.effStart ?? 0
        let maxFinMs = lastTask?.effEnd ?? minStartMs
        let spanWallMs: Int64 = (firstTask != nil && lastTask != nil && maxFinMs >= minStartMs)
            ? (maxFinMs - minStartMs)
            : 0

        let taskIntervals: [(Int64, Int64)] = validStartTasks.map { ($0.effStart, max($0.effStart, $0.effEnd)) }
        let mergedBatches = mergeIntervalsWithGap(taskIntervals, maxGapMs: batchGapMs)

        var activeSegments: [DAGSCActiveSegment] = []
        var virtualCursor: Int64 = 0
        for (idx, seg) in mergedBatches.enumerated() {
            let dur = max(0, seg.1 - seg.0)
            let gapBefore: Int64 = idx > 0 ? max(0, seg.0 - mergedBatches[idx - 1].1) : 0
            activeSegments.append(DAGSCActiveSegment(
                index: idx,
                wallStartMs: seg.0,
                wallEndMs: seg.1,
                wallStartText: formatTimestampMs(seg.0),
                wallEndText: formatTimestampMs(seg.1),
                virtualStartMs: virtualCursor,
                virtualEndMs: virtualCursor + dur,
                durationMs: dur,
                gapBeforeMs: gapBefore
            ))
            virtualCursor += dur
        }

        let activeBatchWallMs = virtualCursor > 0 ? virtualCursor : spanWallMs
        let wallClockMs = activeBatchWallMs

        let cumulativeMs = tasks.reduce(Int64(0)) { $0 + $1.durationMs }
        let concurrency = wallClockMs > 0 ? round2(Double(cumulativeMs) / Double(wallClockMs)) : 0.0

        let (wallRtf, wallSpeedup) = calcSpeedRatios(procMs: wallClockMs, mediaMs: totalMediaDurationMs)
        let (_, spanSpeedup) = calcSpeedRatios(procMs: spanWallMs, mediaMs: totalMediaDurationMs)
        let (cumRtf, cumSpeedup) = calcSpeedRatios(procMs: cumulativeMs, mediaMs: totalMediaDurationMs)

        func mapToVirtualTimeline(_ wallMs: Int64) -> (vStart: Int64, segIdx: Int) {
            for seg in activeSegments {
                if wallMs >= seg.wallStartMs && wallMs <= seg.wallEndMs {
                    return (seg.virtualStartMs + (wallMs - seg.wallStartMs), seg.index)
                }
            }
            if let last = activeSegments.last, wallMs > last.wallEndMs {
                return (last.virtualEndMs, last.index)
            }
            return (max(0, wallMs - minStartMs), 0)
        }

        // Aggregate by node_type + stitched timeline_spans
        struct TypeGroup {
            let nodeType: String
            var executors: Set<String> = []
            var count = 0
            var succeeded = 0
            var failed = 0
            var sumMs: Int64 = 0
            var intervals: [(Int64, Int64)] = []
            var minMs: Int64?
            var maxMs: Int64?
            var zeroStartFixed = 0
        }

        var typeGroups: [String: TypeGroup] = [:]
        var timelineSpans: [String: [DAGSCTimelineSpan]] = [:]
        let sortedTasks = tasks.sorted { $0.effStart < $1.effStart }

        for t in sortedTasks {
            let nt = t.nodeType.isEmpty ? "unknown" : t.nodeType
            var g = typeGroups[nt] ?? TypeGroup(nodeType: nt)
            g.executors.insert(t.executorText.isEmpty ? "unspecified" : t.executorText)
            g.count += 1
            if t.statusText == "succeeded" { g.succeeded += 1 }
            else if t.statusText == "failed" { g.failed += 1 }
            g.sumMs += t.durationMs
            if t.effStart > 0 && t.effEnd >= t.effStart {
                g.intervals.append((t.effStart, t.effEnd))
                let (vStart, segIdx) = mapToVirtualTimeline(t.effStart)
                timelineSpans[nt, default: []].append(DAGSCTimelineSpan(
                    relStartMs: vStart,
                    durationMs: t.durationMs,
                    assetID: t.assetID,
                    templateNodeID: t.templateNodeID.isEmpty ? nt : t.templateNodeID,
                    segmentIndex: segIdx
                ))
            }
            g.minMs = g.minMs.map { min($0, t.durationMs) } ?? t.durationMs
            g.maxMs = g.maxMs.map { max($0, t.durationMs) } ?? t.durationMs
            if t.zeroStartFixed { g.zeroStartFixed += 1 }
            typeGroups[nt] = g
        }

        let byNodeType: [DAGSCNodeTypeRow] = typeGroups.values
            .sorted { $0.sumMs == $1.sumMs ? $0.nodeType < $1.nodeType : $0.sumMs > $1.sumMs }
            .map { g in
                let activeMs = mergeIntervalsExactMs(g.intervals)
                let (rtf, speedup) = calcSpeedRatios(procMs: g.sumMs, mediaMs: totalMediaDurationMs)
                return DAGSCNodeTypeRow(
                    nodeType: g.nodeType,
                    executor: g.executors.sorted().joined(separator: "/"),
                    count: g.count,
                    succeeded: g.succeeded,
                    failed: g.failed,
                    sumMs: g.sumMs,
                    activeUnionMs: activeMs,
                    avgMs: g.count > 0 ? round2(Double(g.sumMs) / Double(g.count)) : 0,
                    minMs: g.minMs ?? 0,
                    maxMs: g.maxMs ?? 0,
                    pctCumulative: cumulativeMs > 0 ? round4(Double(g.sumMs) * 100.0 / Double(cumulativeMs)) : 0,
                    pctWall: wallClockMs > 0 ? round4(Double(g.sumMs) * 100.0 / Double(wallClockMs)) : 0,
                    busyPct: wallClockMs > 0 ? round2(Double(activeMs) * 100.0 / Double(wallClockMs)) : 0,
                    rtf: rtf,
                    speedup: speedup,
                    zeroStartFixed: g.zeroStartFixed
                )
            }

        // Aggregate by (template_node_id, node_type)
        struct TNKey: Hashable {
            let tn: String
            let nt: String
        }
        struct TNGroup {
            let tn: String
            let nt: String
            var executors: Set<String> = []
            var templates: Set<String> = []
            var count = 0
            var sumMs: Int64 = 0
            var minMs: Int64?
            var maxMs: Int64?
        }

        var tnGroups: [TNKey: TNGroup] = [:]
        for t in tasks {
            let nt = t.nodeType.isEmpty ? "unknown" : t.nodeType
            let tn = t.templateNodeID.isEmpty ? nt : t.templateNodeID
            let key = TNKey(tn: tn, nt: nt)
            var g = tnGroups[key] ?? TNGroup(tn: tn, nt: nt)
            g.executors.insert(t.executorText.isEmpty ? "unspecified" : t.executorText)
            if !t.templateID.isEmpty { g.templates.insert(t.templateID) }
            g.count += 1
            g.sumMs += t.durationMs
            g.minMs = g.minMs.map { min($0, t.durationMs) } ?? t.durationMs
            g.maxMs = g.maxMs.map { max($0, t.durationMs) } ?? t.durationMs
            tnGroups[key] = g
        }

        let byTemplateNode: [DAGSCTemplateNodeRow] = tnGroups.values
            .sorted { $0.sumMs == $1.sumMs ? $0.tn < $1.tn : $0.sumMs > $1.sumMs }
            .map { g in
                let (rtf, speedup) = calcSpeedRatios(procMs: g.sumMs, mediaMs: totalMediaDurationMs)
                return DAGSCTemplateNodeRow(
                    templateNodeID: g.tn,
                    nodeType: g.nt,
                    executor: g.executors.sorted().joined(separator: "/"),
                    templateID: g.templates.sorted().joined(separator: "/"),
                    count: g.count,
                    sumMs: g.sumMs,
                    avgMs: g.count > 0 ? round2(Double(g.sumMs) / Double(g.count)) : 0,
                    minMs: g.minMs ?? 0,
                    maxMs: g.maxMs ?? 0,
                    pctCumulative: cumulativeMs > 0 ? round4(Double(g.sumMs) * 100.0 / Double(cumulativeMs)) : 0,
                    rtf: rtf,
                    speedup: speedup
                )
            }

        func makeEndpoint(_ t: RawTask?, useFinish: Bool) -> DAGSCTaskEndpoint? {
            guard let t else { return nil }
            let ts = useFinish ? t.effEnd : t.effStart
            return DAGSCTaskEndpoint(
                taskID: t.taskID,
                workflowID: t.workflowID,
                templateID: t.templateID,
                assetID: t.assetID,
                nodeType: t.nodeType,
                templateNodeID: t.templateNodeID,
                timestampMs: ts,
                timestampText: formatTimestampMs(ts),
                dispatchedAt: t.dispatchedAt,
                startedAt: t.startedAt,
                finishedAt: t.finishedAt,
                durationMs: t.durationMs
            )
        }

        return DAGSCScopeMetrics(
            totalTasks: tasks.count,
            succeededTasks: tasks.filter { $0.statusText == "succeeded" }.count,
            failedTasks: tasks.filter { $0.statusText == "failed" }.count,
            zeroStartFixedCount: tasks.filter(\.zeroStartFixed).count,
            wallClockMs: wallClockMs,
            spanWallClockMs: spanWallMs,
            activeBatchWallMs: activeBatchWallMs,
            batchCountInScope: mergedBatches.count,
            originStartMs: minStartMs,
            originEndMs: maxFinMs,
            wallRtf: wallRtf,
            wallSpeedup: wallSpeedup,
            spanSpeedup: spanSpeedup,
            cumulativeMs: cumulativeMs,
            cumulativeRtf: cumRtf,
            cumulativeSpeedup: cumSpeedup,
            concurrency: concurrency,
            firstTask: makeEndpoint(firstTask, useFinish: false),
            lastTask: makeEndpoint(lastTask, useFinish: true),
            activeSegments: activeSegments,
            byNodeType: byNodeType,
            byTemplateNode: byTemplateNode,
            timelineSpans: timelineSpans
        )
    }

    // MARK: - Helpers

    static func calcSpeedRatios(procMs: Int64, mediaMs: Int64) -> (rtf: Double, speedup: Double) {
        let rtf = mediaMs > 0 ? round6(Double(procMs) / Double(mediaMs)) : 0.0
        let speedup = (procMs > 0 && mediaMs > 0) ? round4(Double(mediaMs) / Double(procMs)) : 0.0
        return (rtf, speedup)
    }

    static func mergeIntervalsExactMs(_ intervals: [(Int64, Int64)]) -> Int64 {
        let merged = mergeIntervalsWithGap(intervals, maxGapMs: 0)
        return merged.reduce(Int64(0)) { $0 + max(0, $1.1 - $1.0) }
    }

    static func mergeIntervalsWithGap(_ intervals: [(Int64, Int64)], maxGapMs: Int64) -> [(Int64, Int64)] {
        let valid = intervals.filter { $0.0 > 0 && $0.1 >= $0.0 }.sorted { $0.0 < $1.0 }
        guard let first = valid.first else { return [] }
        var merged: [(Int64, Int64)] = [first]
        for (s, e) in valid.dropFirst() {
            let lastIdx = merged.count - 1
            if s - merged[lastIdx].1 <= maxGapMs {
                if e > merged[lastIdx].1 {
                    merged[lastIdx].1 = e
                }
            } else {
                merged.append((s, e))
            }
        }
        return merged
    }

    static func formatTimestampMs(_ ms: Int64) -> String {
        guard ms > 0 else { return "—" }
        let sec = TimeInterval(ms) / 1_000.0
        let date = Date(timeIntervalSince1970: sec)
        let remMs = Int(ms % 1_000)
        return "\(dateTimeFormatter.string(from: date)).\(String(format: "%03d", remMs))"
    }

    static func formatDayLocal(_ ms: Int64) -> String {
        guard ms > 0 else { return "未知日期" }
        return dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1_000.0))
    }

    static func formatTimeOnlyLocal(_ ms: Int64) -> String {
        guard ms > 0 else { return "—" }
        return timeOnlyFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1_000.0))
    }

    static func formatNowSecond() -> String {
        dateTimeFormatter.string(from: Date())
    }

    static func dayBoundsMs(dayString: String) -> (startMs: Int64, endMs: Int64)? {
        guard let start = dayFormatter.date(from: dayString) else { return nil }
        let cal = Calendar.current
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: start) else { return nil }
        let startMs = Int64(start.timeIntervalSince1970 * 1_000)
        let endMs = Int64(nextDay.timeIntervalSince1970 * 1_000) - 1
        return (startMs, endMs)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func colString(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cStr)
    }

    private static func jsonInt64(_ val: Any?) -> Int64 {
        if let n = val as? NSNumber { return n.int64Value }
        if let s = val as? String, let d = Double(s) { return Int64(d) }
        return 0
    }

    private static func summarizeErrorJSON(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let data = trimmed.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["message", "error", "detail", "reason", "code"] {
                if let s = obj[key] as? String, !s.isEmpty {
                    return String(s.prefix(180))
                }
            }
        }
        return String(trimmed.prefix(180))
    }

    private static func readTailUTF8(url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        if end > UInt64(maxBytes) {
            try? handle.seek(toOffset: end - UInt64(maxBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private static func round4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
    private static func round6(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }
}
