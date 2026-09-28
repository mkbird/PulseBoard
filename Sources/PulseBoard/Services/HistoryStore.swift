import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class HistoryStore {
    private var database: OpaquePointer?
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
            throw StoreError.openFailed
        }
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
            ("swap_total", "REAL")
        ]
        for (column, type) in migrations where !hasColumn(column, in: "samples") {
            try execute("ALTER TABLE samples ADD COLUMN \(column) \(type);")
        }
        try execute("CREATE INDEX IF NOT EXISTS samples_timestamp ON samples(timestamp);")
    }

    deinit { sqlite3_close(database) }

    func append(_ sample: MetricSample) throws {
        let sql = """
        INSERT INTO samples (
          timestamp,cpu,gpu,memory,memory_used,memory_total,memory_pressure,
          ane_power,cpu_power,gpu_power,system_power,memory_read,memory_write,
          disk_read,disk_write,disk_free,disk_total,net_down,net_up,thermal,ane_usage,
          clipto_cpu,clipto_memory,clipto_disk_read,clipto_disk_write,clipto_process_count,clipto_gpu,
          swap_used,swap_total
        ) VALUES (
          ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?
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
                   AVG(clipto_gpu),AVG(swap_used),AVG(swap_total)
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
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM samples WHERE timestamp < ?;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw StoreError.queryFailed(message) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.queryFailed(message) }
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
        while sqlite3_step(statement) == SQLITE_ROW {
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
                swapTotalBytes: optionalDouble(statement, 28) ?? 0
            ))
        }
        return samples
    }

    private func bind(_ value: Double?, to statement: OpaquePointer, at index: Int32) {
        if let value { sqlite3_bind_double(statement, index, value) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, index))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.queryFailed(message) }
    }

    private func hasColumn(_ column: String, in table: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == column { return true }
        }
        return false
    }

    private var message: String { database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error" }

    private static func sanitizedPowerSQL(_ column: String, absoluteMaximum: Double, minimum: Double = 0) -> String {
        "CASE WHEN \(column) >= \(minimum) AND \(column) <= \(absoluteMaximum) " +
        "AND (system_power IS NULL OR system_power < 0 OR system_power > 1000 " +
        "OR \(column) <= MAX(50, system_power * 3 + 20)) THEN \(column) END"
    }

    private static let columns = "timestamp,cpu,gpu,ane_usage,memory,memory_used,memory_total,memory_pressure,ane_power,cpu_power,gpu_power,system_power,memory_read,memory_write,disk_read,disk_write,disk_free,disk_total,net_down,net_up,thermal,clipto_cpu,clipto_memory,clipto_disk_read,clipto_disk_write,clipto_process_count,clipto_gpu,swap_used,swap_total"
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
