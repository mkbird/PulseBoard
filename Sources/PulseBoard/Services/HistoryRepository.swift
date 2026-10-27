import Foundation

/// A single owner for the SQLite connection. Opening, migration, reads, writes,
/// and retention all run on this actor, never on the UI's main actor.
actor HistoryRepository {
    private let databaseURL: URL?
    private var store: HistoryStore?
    private var activeCMSExports = 0

    init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    func append(system: MetricSample?, cms: CMSHistoryFrame?) throws {
        try connection().append(system: system, cms: cms)
    }

    func fetch(from: Date, to: Date, maxPoints: Int = 1_200) throws -> [MetricSample] {
        try Task.checkCancellation()
        return try connection().fetch(from: from, to: to, maxPoints: maxPoints)
    }

    func fetchRaw(from: Date, to: Date) throws -> [MetricSample] {
        try Task.checkCancellation()
        return try connection().fetchRaw(from: from, to: to)
    }

    func fetchCMS(from: Date, to: Date) throws -> [CMSHistoryFrame] {
        try Task.checkCancellation()
        return try connection().fetchCMS(from: from, to: to)
    }

    func appendStorage(_ snapshot: StorageSnapshot) throws {
        try connection().appendStorage(snapshot)
    }

    func resolvedDatabaseURL() throws -> URL {
        try connection().databaseURL
    }

    func fetchWebHistory(from: Date, to: Date, maxPoints: Int = 600) throws -> [AlignedTimeSeriesPoint] {
        try Task.checkCancellation()
        return try connection().fetchWebHistory(from: from, to: to, maxPoints: maxPoints)
    }

    func fetchAlignedReport(
        activeIntervalsMs: [[Int64]],
        fallbackStartMs: Int64,
        fallbackEndMs: Int64,
        maxSeriesPoints: Int = 480
    ) throws -> AlignedHardwareReport {
        try Task.checkCancellation()
        return try connection().fetchAlignedReport(
            activeIntervalsMs: activeIntervalsMs,
            fallbackStartMs: fallbackStartMs,
            fallbackEndMs: fallbackEndMs,
            maxSeriesPoints: maxSeriesPoints
        )
    }

    func buildCMSCSVString(from: Date, to: Date) async throws -> String {
        try Task.checkCancellation()
        activeCMSExports += 1
        defer { activeCMSExports -= 1 }
        var output = ""
        var cursor: CMSHistoryCursor?
        var includeHeader = true
        while true {
            try Task.checkCancellation()
            let frames = try connection().fetchCMSPage(from: from, to: to, after: cursor, limit: 500)
            output += CMSCSVExporter.csv(frames: frames, includeHeader: includeHeader)
            includeHeader = false
            guard let last = frames.last else { break }
            cursor = CMSHistoryCursor(sessionID: last.sessionID, sequence: last.sequence)
            await Task.yield()
        }
        return output
    }

    /// Export bounded pages off the main actor. Releasing the actor between
    /// pages lets sampling transactions continue during a long export.
    func exportCMS(from: Date, to: Date, destination: URL) async throws {
        try Task.checkCancellation()
        activeCMSExports += 1
        defer { activeCMSExports -= 1 }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".PulseBoard-CMS-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var cursor: CMSHistoryCursor?
        var includeHeader = true
        while true {
            try Task.checkCancellation()
            let frames = try connection().fetchCMSPage(from: from, to: to, after: cursor, limit: 500)
            let contents = CMSCSVExporter.csv(frames: frames, includeHeader: includeHeader)
            try handle.write(contentsOf: Data(contents.utf8))
            includeHeader = false
            guard let last = frames.last else { break }
            cursor = CMSHistoryCursor(sessionID: last.sessionID, sequence: last.sequence)
            await Task.yield()
        }
        try Task.checkCancellation()
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// A paged export releases its read transaction between pages. Delay
    /// retention until the next sample so those pages cannot disappear midway.
    @discardableResult
    func prune(olderThan date: Date) throws -> Bool {
        guard activeCMSExports == 0 else { return false }
        try connection().prune(olderThan: date)
        return true
    }

    /// Sampling awaits every append; a termination barrier lets already
    /// submitted transactions finish before the process exits.
    func flush() {}

    /// Deletes the whole local history database (system samples + CMS frames) and starts a fresh,
    /// empty one. Closing the connection first lets SQLite release the WAL/SHM files.
    func wipeAll() throws {
        guard activeCMSExports == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "正在导出 CMS CSV，请导出完成后再清空。"])
        }
        let url = try store?.databaseURL ?? databaseURL ?? connection().databaseURL
        store = nil // deinit -> sqlite3_close
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
        _ = try connection()
    }

    private func connection() throws -> HistoryStore {
        if let store { return store }
        let opened = try HistoryStore(databaseURL: databaseURL)
        store = opened
        return opened
    }
}
