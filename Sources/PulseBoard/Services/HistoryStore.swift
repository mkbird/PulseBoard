import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class HistoryStore {
    var database: OpaquePointer?
    let databaseURL: URL

    init(databaseURL: URL? = nil) throws {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PulseBoard", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.databaseURL = directory.appendingPathComponent("history.sqlite")
        }
        guard sqlite3_open(self.databaseURL.path, &database) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw StoreError.openFailed
        }
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA busy_timeout=2000;")
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute(Self.schema)
        let migrations = [
            ("ane_usage", "REAL"),
            ("clipto_cpu", "REAL"),
            ("clipto_memory", "REAL"),
            ("clipto_disk_read", "REAL"),
            ("clipto_disk_write", "REAL"),
            ("clipto_process_count", "INTEGER"),
            ("clipto_gpu", "REAL"),
            ("swap_used", "REAL"),
            ("swap_total", "REAL"),
            ("cms_gpu", "REAL")
        ]
        for (column, type) in migrations {
            if try !hasColumn(column, in: "samples") {
                try execute("ALTER TABLE samples ADD COLUMN \(column) \(type);")
            }
        }
        try execute("CREATE INDEX IF NOT EXISTS samples_timestamp ON samples(timestamp);")
        try execute(Self.cmsSchema)
    }

    deinit { sqlite3_close(database) }

    func append(_ sample: MetricSample) throws {
        try append(system: sample, cms: nil)
    }

    /// A capture either persists both system and CMS data, or persists neither.
    func append(system: MetricSample?, cms: CMSHistoryFrame?) throws {
        guard system != nil || cms != nil else { return }
        try transaction {
            if let system { try appendSystem(system) }
            if let cms { try appendCMS(cms) }
        }
    }

    private func appendSystem(_ sample: MetricSample) throws {
        let sql = """
        INSERT INTO samples (
          timestamp,cpu,gpu,memory,memory_used,memory_total,memory_pressure,
          ane_power,cpu_power,gpu_power,system_power,memory_read,memory_write,
          disk_read,disk_write,disk_free,disk_total,net_down,net_up,thermal,ane_usage,
          clipto_cpu,clipto_memory,clipto_disk_read,clipto_disk_write,clipto_process_count,clipto_gpu,
          swap_used,swap_total,cms_gpu
        ) VALUES (
          ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
        );
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.queryFailed(message)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_double(statement, 1, sample.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, sample.cpuUsage)
        bind(sample.gpuUsage, to: statement, at: 3)
        sqlite3_bind_double(statement, 4, sample.memoryUsage)
        sqlite3_bind_double(statement, 5, sample.memoryUsedBytes)
        sqlite3_bind_double(statement, 6, sample.memoryTotalBytes)
        sqlite3_bind_double(statement, 7, sample.memoryPressure)
        bind(sample.anePowerWatts, to: statement, at: 8)
        bind(sample.cpuPowerWatts, to: statement, at: 9)
        bind(sample.gpuPowerWatts, to: statement, at: 10)
        bind(sample.systemPowerWatts, to: statement, at: 11)
        bind(sample.memoryReadGBps, to: statement, at: 12)
        bind(sample.memoryWriteGBps, to: statement, at: 13)
        sqlite3_bind_double(statement, 14, sample.diskReadBytesPerSecond)
        sqlite3_bind_double(statement, 15, sample.diskWriteBytesPerSecond)
        sqlite3_bind_double(statement, 16, sample.diskFreeBytes)
        sqlite3_bind_double(statement, 17, sample.diskTotalBytes)
        sqlite3_bind_double(statement, 18, sample.networkDownBytesPerSecond)
        sqlite3_bind_double(statement, 19, sample.networkUpBytesPerSecond)
        _ = sample.thermalState.withCString { sqlite3_bind_text(statement, 20, $0, -1, sqliteTransient) }
        bind(sample.aneUsage, to: statement, at: 21)
        bind(sample.cliptoCPUPercent, to: statement, at: 22)
        bind(sample.cliptoMemoryBytes, to: statement, at: 23)
        bind(sample.cliptoDiskReadBytesPerSecond, to: statement, at: 24)
        bind(sample.cliptoDiskWriteBytesPerSecond, to: statement, at: 25)
        if let processCount = sample.cliptoProcessCount {
            sqlite3_bind_int(statement, 26, Int32(processCount))
        } else {
            sqlite3_bind_null(statement, 26)
        }
        bind(sample.cliptoGPUPercent, to: statement, at: 27)
        sqlite3_bind_double(statement, 28, sample.swapUsedBytes)
        sqlite3_bind_double(statement, 29, sample.swapTotalBytes)
        bind(sample.cmsGPUPercent, to: statement, at: 30)

        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.queryFailed(message) }
    }

    func fetch(from: Date, to: Date, maxPoints: Int = 1_200) throws -> [MetricSample] {
        let span = max(1, to.timeIntervalSince(from))
        let bucket = max(1, Int(ceil(span / Double(maxPoints))))
        let columns = Self.columns
        let sql: String
        if bucket == 1 {
            sql = "SELECT \(columns) FROM samples WHERE timestamp BETWEEN ? AND ? ORDER BY timestamp;"
        } else {
            let anePower = Self.sanitizedPowerSQL("ane_power", absoluteMaximum: 150)
            let cpuPower = Self.sanitizedPowerSQL("cpu_power", absoluteMaximum: 500, minimum: 0.001)
            let gpuPower = Self.sanitizedPowerSQL("gpu_power", absoluteMaximum: 500)
            sql = """
            SELECT AVG(timestamp),AVG(cpu),AVG(gpu),AVG(ane_usage),AVG(memory),AVG(memory_used),AVG(memory_total),
                   AVG(memory_pressure),AVG(\(anePower)),AVG(\(cpuPower)),AVG(\(gpuPower)),
                   AVG(CASE WHEN system_power >= 0 AND system_power <= 1000 THEN system_power END),
                   AVG(memory_read),AVG(memory_write),AVG(disk_read),AVG(disk_write),AVG(disk_free),
                   AVG(disk_total),AVG(net_down),AVG(net_up),MAX(thermal),AVG(clipto_cpu),
                   AVG(clipto_memory),AVG(clipto_disk_read),AVG(clipto_disk_write),MAX(clipto_process_count),
                   AVG(clipto_gpu),AVG(swap_used),AVG(swap_total),AVG(cms_gpu)
            FROM samples WHERE timestamp BETWEEN ? AND ?
            GROUP BY CAST(timestamp / \(bucket) AS INTEGER)
            ORDER BY timestamp;
            """
        }
        return try query(sql: sql, from: from, to: to)
    }

    func fetchRaw(from: Date, to: Date) throws -> [MetricSample] {
        try query(
            sql: "SELECT \(Self.columns) FROM samples WHERE timestamp BETWEEN ? AND ? ORDER BY timestamp;",
            from: from,
            to: to
        )
    }

    func prune(olderThan date: Date) throws {
        try transaction {
            for table in ["samples", "cms_frames"] {
                try withStatement("DELETE FROM \(table) WHERE timestamp < ?;") { statement in
                    try check(sqlite3_bind_double(statement, 1, date.timeIntervalSince1970))
                    try finish(statement)
                }
            }
            // Frame deletion cascades into samples; only unreferenced identities
            // and sessions are removed. Retained frames keep their original starts.
            try execute("""
            DELETE FROM cms_processes WHERE NOT EXISTS (
              SELECT 1 FROM cms_process_samples AS p
              WHERE p.session_id=cms_processes.session_id
                AND p.pid=cms_processes.pid AND p.start_time=cms_processes.start_time
            );
            DELETE FROM cms_sessions WHERE NOT EXISTS (
              SELECT 1 FROM cms_frames AS f WHERE f.session_id=cms_sessions.session_id
            );
            """)
        }
    }

    private func query(sql: String, from: Date, to: Date) throws -> [MetricSample] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.queryFailed(message)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, from.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, to.timeIntervalSince1970)

        var samples: [MetricSample] = []
        while try nextRow(statement) {
            let systemPower = PowerReadingSanitizer.systemPower(optionalDouble(statement, 11))
            samples.append(MetricSample(
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                cpuUsage: sqlite3_column_double(statement, 1),
                gpuUsage: optionalDouble(statement, 2),
                aneUsage: optionalDouble(statement, 3),
                memoryUsage: sqlite3_column_double(statement, 4),
                memoryUsedBytes: sqlite3_column_double(statement, 5),
                memoryTotalBytes: sqlite3_column_double(statement, 6),
                memoryPressure: sqlite3_column_double(statement, 7),
                anePowerWatts: PowerReadingSanitizer.componentPower(optionalDouble(statement, 8), systemPower: systemPower, absoluteMaximum: 150),
                cpuPowerWatts: PowerReadingSanitizer.componentPower(optionalDouble(statement, 9), systemPower: systemPower, absoluteMaximum: 500, minimum: 0.001),
                gpuPowerWatts: PowerReadingSanitizer.componentPower(optionalDouble(statement, 10), systemPower: systemPower, absoluteMaximum: 500),
                systemPowerWatts: systemPower,
                memoryReadGBps: optionalDouble(statement, 12),
                memoryWriteGBps: optionalDouble(statement, 13),
                diskReadBytesPerSecond: sqlite3_column_double(statement, 14),
                diskWriteBytesPerSecond: sqlite3_column_double(statement, 15),
                diskFreeBytes: sqlite3_column_double(statement, 16),
                diskTotalBytes: sqlite3_column_double(statement, 17),
                networkDownBytesPerSecond: sqlite3_column_double(statement, 18),
                networkUpBytesPerSecond: sqlite3_column_double(statement, 19),
                thermalState: sqlite3_column_text(statement, 20).map { String(cString: $0) } ?? "unknown",
                cliptoCPUPercent: optionalDouble(statement, 21),
                cliptoMemoryBytes: optionalDouble(statement, 22),
                cliptoDiskReadBytesPerSecond: optionalDouble(statement, 23),
                cliptoDiskWriteBytesPerSecond: optionalDouble(statement, 24),
                cliptoProcessCount: optionalInt(statement, 25),
                cliptoGPUPercent: optionalDouble(statement, 26),
                swapUsedBytes: optionalDouble(statement, 27) ?? 0,
                swapTotalBytes: optionalDouble(statement, 28) ?? 0,
                cmsGPUPercent: optionalDouble(statement, 29)
            ))
        }
        return samples
    }

    private func bind(_ value: Double?, to statement: OpaquePointer, at index: Int32) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, index))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.queryFailed(message) }
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.queryFailed(message) }
        defer { sqlite3_finalize(statement) }
        while try nextRow(statement) {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.queryFailed(message)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw StoreError.queryFailed(message) }
    }

    private func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.queryFailed(message) }
    }

    func nextRow(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StoreError.queryFailed(message)
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        try check(value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) })
    }

    private func bindCMS(_ value: Double?, to statement: OpaquePointer, at index: Int32) throws {
        if let value { try check(sqlite3_bind_double(statement, index, value)) }
        else { try check(sqlite3_bind_null(statement, index)) }
    }

    private var message: String { database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error" }

    private static func sanitizedPowerSQL(_ column: String, absoluteMaximum: Double, minimum: Double = 0) -> String {
        "CASE WHEN \(column) >= \(minimum) AND \(column) <= \(absoluteMaximum) " +
        "AND (system_power IS NULL OR system_power < 0 OR system_power > 1000 " +
        "OR \(column) <= MAX(50, system_power * 3 + 20)) THEN \(column) END"
    }

    private static let columns = "timestamp,cpu,gpu,ane_usage,memory,memory_used,memory_total,memory_pressure,ane_power,cpu_power,gpu_power,system_power,memory_read,memory_write,disk_read,disk_write,disk_free,disk_total,net_down,net_up,thermal,clipto_cpu,clipto_memory,clipto_disk_read,clipto_disk_write,clipto_process_count,clipto_gpu,swap_used,swap_total,cms_gpu"
    private static let schema = """
    CREATE TABLE IF NOT EXISTS samples (
      timestamp REAL PRIMARY KEY,
      cpu REAL NOT NULL,
      gpu REAL,
      memory REAL NOT NULL,
      memory_used REAL NOT NULL,
      memory_total REAL NOT NULL,
      memory_pressure REAL NOT NULL,
      ane_power REAL,
      cpu_power REAL,
      gpu_power REAL,
      system_power REAL,
      memory_read REAL,
      memory_write REAL,
      disk_read REAL NOT NULL,
      disk_write REAL NOT NULL,
      disk_free REAL NOT NULL,
      disk_total REAL NOT NULL,
      net_down REAL NOT NULL,
      net_up REAL NOT NULL,
      thermal TEXT NOT NULL,
      ane_usage REAL,
      clipto_cpu REAL,
      clipto_memory REAL,
      clipto_disk_read REAL,
      clipto_disk_write REAL,
      clipto_process_count INTEGER,
      clipto_gpu REAL,
      swap_used REAL,
      swap_total REAL
    );
    """
}

extension HistoryStore {
    private func appendCMS(_ frame: CMSHistoryFrame) throws {
        guard (1...2).contains(frame.statisticsVersion) else {
            throw StoreError.queryFailed("Unsupported CMS statistics version.")
        }
        try withStatement("""
        INSERT INTO cms_sessions(session_id, started_at, schema_version) VALUES (?, ?, ?)
        ON CONFLICT(session_id) DO NOTHING;
        """) { statement in
            try bindText(frame.sessionID, to: statement, at: 1)
            try check(sqlite3_bind_double(statement, 2, frame.sessionStartedAt.timeIntervalSince1970))
            try check(sqlite3_bind_int(statement, 3, Int32(frame.statisticsVersion)))
            try finish(statement)
        }
        try withStatement("SELECT started_at,schema_version FROM cms_sessions WHERE session_id=?;") { statement in
            try bindText(frame.sessionID, to: statement, at: 1)
            guard try nextRow(statement), sqlite3_column_int(statement, 1) == Int32(frame.statisticsVersion),
                  sqlite3_column_double(statement, 0) == frame.sessionStartedAt.timeIntervalSince1970 else {
                throw StoreError.queryFailed("CMS session metadata does not match the stored session.")
            }
        }
        try withStatement("""
        INSERT INTO cms_frames (
          session_id,sequence,segment,maximum_gap,timestamp,monotonic_seconds,
          enumeration_valid,unreadable_count,total_cpu_percent,total_memory_bytes
        ) VALUES (?,?,?,?,?,?,?,?,?,?);
        """) { statement in
            try bindText(frame.sessionID, to: statement, at: 1)
            try check(sqlite3_bind_int64(statement, 2, frame.sequence))
            try check(sqlite3_bind_int64(statement, 3, frame.segment))
            try check(sqlite3_bind_double(statement, 4, frame.maximumGap))
            try check(sqlite3_bind_double(statement, 5, frame.raw.timestamp.timeIntervalSince1970))
            try check(sqlite3_bind_double(statement, 6, frame.raw.monotonicSeconds))
            try check(sqlite3_bind_int(statement, 7, frame.raw.enumerationValid ? 1 : 0))
            try check(sqlite3_bind_int64(statement, 8, Int64(frame.raw.unreadableCount)))
            try bindCMS(frame.totalCPUPercent, to: statement, at: 9)
            try bindCMS(frame.totalMemoryBytes, to: statement, at: 10)
            try finish(statement)
        }

        try withStatement("""
        INSERT INTO cms_processes(session_id,pid,start_time,first_name) VALUES (?,?,?,?)
        ON CONFLICT(session_id,pid,start_time) DO NOTHING;
        """) { identity in
            try withStatement("""
            INSERT INTO cms_process_samples (
              session_id,sequence,pid,start_time,ordinal,name,cpu_seconds,memory_bytes,cpu_percent
            ) VALUES (?,?,?,?,?,?,?,?,?);
            """) { sample in
                for (ordinal, reading) in frame.raw.processes.enumerated() {
                    try check(sqlite3_reset(identity))
                    try check(sqlite3_clear_bindings(identity))
                    try bindText(frame.sessionID, to: identity, at: 1)
                    try check(sqlite3_bind_int(identity, 2, reading.id.pid))
                    // Bit-pattern conversion preserves every UInt64 identity exactly.
                    try check(sqlite3_bind_int64(identity, 3, Int64(bitPattern: reading.id.startTime)))
                    try bindText(reading.name, to: identity, at: 4)
                    try finish(identity)

                    try check(sqlite3_reset(sample))
                    try check(sqlite3_clear_bindings(sample))
                    try bindText(frame.sessionID, to: sample, at: 1)
                    try check(sqlite3_bind_int64(sample, 2, frame.sequence))
                    try check(sqlite3_bind_int(sample, 3, reading.id.pid))
                    try check(sqlite3_bind_int64(sample, 4, Int64(bitPattern: reading.id.startTime)))
                    try check(sqlite3_bind_int64(sample, 5, Int64(ordinal)))
                    try bindText(reading.name, to: sample, at: 6)
                    try bindCMS(reading.cpuSeconds, to: sample, at: 7)
                    try bindCMS(reading.memoryBytes, to: sample, at: 8)
                    try bindCMS(frame.processCPUPercent[reading.id], to: sample, at: 9)
                    try finish(sample)
                }
            }
        }
    }

    /// Convenience for bounded history reads; long exports should consume pages.
    func fetchCMS(from: Date, to: Date) throws -> [CMSHistoryFrame] {
        var frames: [CMSHistoryFrame] = []
        var cursor: CMSHistoryCursor?
        while true {
            let page = try fetchCMSPage(from: from, to: to, after: cursor)
            frames.append(contentsOf: page)
            guard page.count == 500, let last = page.last else { return frames }
            cursor = CMSHistoryCursor(sessionID: last.sessionID, sequence: last.sequence)
        }
    }

    /// Limit whole frames before joining their process rows. A frame with many
    /// processes is never split between pages; empty frames also consume a slot.
    func fetchCMSPage(from: Date, to: Date, after: CMSHistoryCursor? = nil,
                      limit: Int = 500) throws -> [CMSHistoryFrame] {
        guard limit > 0 else { return [] }
        // The composite PRIMARY KEY in cmsSchema creates this index. Subsequent
        // pages must seek from the cursor instead of sorting the entire date
        // range again; the first page can still use the timestamp index.
        let frameSource = after == nil ? "cms_frames" : "cms_frames INDEXED BY sqlite_autoindex_cms_frames_1"
        let cursorClause = after == nil ? "" : "AND (session_id,sequence) > (?,?)"
        return try withStatement("""
        WITH selected_frames AS (
          SELECT * FROM \(frameSource) WHERE timestamp BETWEEN ? AND ? \(cursorClause)
          ORDER BY session_id,sequence LIMIT ?
        )
        SELECT f.session_id,s.started_at,f.sequence,f.segment,f.maximum_gap,
               f.timestamp,f.monotonic_seconds,f.enumeration_valid,f.unreadable_count,
               f.total_cpu_percent,f.total_memory_bytes,p.pid,p.start_time,p.name,
               p.cpu_seconds,p.memory_bytes,p.cpu_percent,s.schema_version
        FROM selected_frames AS f
        JOIN cms_sessions AS s ON s.session_id=f.session_id
        LEFT JOIN cms_process_samples AS p ON p.session_id=f.session_id AND p.sequence=f.sequence
        ORDER BY f.session_id,f.sequence,p.ordinal;
        """) { statement in
            try check(sqlite3_bind_double(statement, 1, from.timeIntervalSince1970))
            try check(sqlite3_bind_double(statement, 2, to.timeIntervalSince1970))
            var limitIndex: Int32 = 3
            if let after {
                try bindText(after.sessionID, to: statement, at: 3)
                try check(sqlite3_bind_int64(statement, 4, after.sequence))
                limitIndex = 5
            }
            try check(sqlite3_bind_int64(statement, limitIndex, Int64(limit)))
            var result: [CMSHistoryFrame] = []
            var pending: CMSHistoryFrame?
            var readings: [CMSProcessReading] = []
            var cpuPercent: [CMSProcessID: Double] = [:]

            func completed(_ frame: CMSHistoryFrame) -> CMSHistoryFrame {
                CMSHistoryFrame(
                    sessionID: frame.sessionID, sessionStartedAt: frame.sessionStartedAt,
                    sequence: frame.sequence, segment: frame.segment, maximumGap: frame.maximumGap,
                    raw: CMSRawSnapshot(
                        timestamp: frame.raw.timestamp, monotonicSeconds: frame.raw.monotonicSeconds,
                        processes: readings, enumerationValid: frame.raw.enumerationValid,
                        unreadableCount: frame.raw.unreadableCount
                    ),
                    totalCPUPercent: frame.totalCPUPercent, totalMemoryBytes: frame.totalMemoryBytes,
                    processCPUPercent: cpuPercent, statisticsVersion: frame.statisticsVersion
                )
            }

            while try nextRow(statement) {
                let statisticsVersion = Int(sqlite3_column_int(statement, 17))
                guard (1...2).contains(statisticsVersion),
                      let sessionText = sqlite3_column_text(statement, 0) else {
                    throw StoreError.queryFailed("Unsupported or invalid CMS history version.")
                }
                let sessionID = String(cString: sessionText)
                let sequence = sqlite3_column_int64(statement, 2)
                if pending?.sessionID != sessionID || pending?.sequence != sequence {
                    if let pending { result.append(completed(pending)) }
                    readings = []
                    cpuPercent = [:]
                    pending = CMSHistoryFrame(
                        sessionID: sessionID,
                        sessionStartedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                        sequence: sequence, segment: sqlite3_column_int64(statement, 3),
                        maximumGap: sqlite3_column_double(statement, 4),
                        raw: CMSRawSnapshot(
                            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                            monotonicSeconds: sqlite3_column_double(statement, 6), processes: [],
                            enumerationValid: sqlite3_column_int(statement, 7) != 0,
                            unreadableCount: Int(sqlite3_column_int64(statement, 8))
                        ),
                        totalCPUPercent: optionalDouble(statement, 9),
                        totalMemoryBytes: optionalDouble(statement, 10), processCPUPercent: [:],
                        statisticsVersion: statisticsVersion
                    )
                }
                // LEFT JOIN emits one row even for an empty process frame.
                if sqlite3_column_type(statement, 11) != SQLITE_NULL {
                    guard let name = sqlite3_column_text(statement, 13) else {
                        throw StoreError.queryFailed("A CMS process sample is missing its name.")
                    }
                    let id = CMSProcessID(pid: sqlite3_column_int(statement, 11),
                                          startTime: UInt64(bitPattern: sqlite3_column_int64(statement, 12)))
                    readings.append(CMSProcessReading(id: id, name: String(cString: name),
                                                      cpuSeconds: optionalDouble(statement, 14),
                                                      memoryBytes: optionalDouble(statement, 15)))
                    if let cpu = optionalDouble(statement, 16) { cpuPercent[id] = cpu }
                }
            }
            if let pending { result.append(completed(pending)) }
            return result
        }
    }

    private static let cmsSchema = """
    CREATE TABLE IF NOT EXISTS cms_sessions (
      session_id TEXT PRIMARY KEY NOT NULL,
      started_at REAL NOT NULL,
      schema_version INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS cms_processes (
      session_id TEXT NOT NULL,
      pid INTEGER NOT NULL,
      start_time INTEGER NOT NULL,
      first_name TEXT NOT NULL,
      PRIMARY KEY(session_id,pid,start_time),
      FOREIGN KEY(session_id) REFERENCES cms_sessions(session_id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS cms_frames (
      session_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      segment INTEGER NOT NULL,
      maximum_gap REAL NOT NULL,
      timestamp REAL NOT NULL,
      monotonic_seconds REAL NOT NULL,
      enumeration_valid INTEGER NOT NULL,
      unreadable_count INTEGER NOT NULL CHECK(unreadable_count >= 0),
      total_cpu_percent REAL,
      total_memory_bytes REAL,
      PRIMARY KEY(session_id,sequence),
      FOREIGN KEY(session_id) REFERENCES cms_sessions(session_id) ON DELETE CASCADE
    );
    CREATE TABLE IF NOT EXISTS cms_process_samples (
      session_id TEXT NOT NULL,
      sequence INTEGER NOT NULL,
      pid INTEGER NOT NULL,
      start_time INTEGER NOT NULL,
      ordinal INTEGER NOT NULL,
      name TEXT NOT NULL,
      cpu_seconds REAL,
      memory_bytes REAL,
      cpu_percent REAL,
      PRIMARY KEY(session_id,sequence,pid,start_time),
      UNIQUE(session_id,sequence,ordinal),
      FOREIGN KEY(session_id,sequence) REFERENCES cms_frames(session_id,sequence) ON DELETE CASCADE,
      FOREIGN KEY(session_id,pid,start_time) REFERENCES cms_processes(session_id,pid,start_time) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS cms_frames_timestamp ON cms_frames(timestamp);
    CREATE INDEX IF NOT EXISTS cms_process_samples_identity ON cms_process_samples(session_id,pid,start_time);
    """
}

enum StoreError: LocalizedError {
    case openFailed
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: L10n.text("error.history_open")
        case .queryFailed(let message): L10n.format("error.history_query", message)
        }
    }
}
