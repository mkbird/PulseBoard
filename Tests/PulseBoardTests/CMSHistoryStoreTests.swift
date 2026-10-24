import Foundation
import SQLite3
import Testing
@testable import PulseBoard

@Test func cmsHistoryRoundTripsAfterReopenWithInstancesNullsAndRenames() throws {
    try withCMSHistoryDatabase { url in
        var store: HistoryStore? = try HistoryStore(databaseURL: url)
        let first = CMSProcessID(pid: 42, startTime: 10)
        let reused = CMSProcessID(pid: 42, startTime: UInt64.max)
        let original = historyFrame(sequence: 1, timestamp: 105, readings: [
            historyReading(reused, name: "cms_新实例", cpu: nil, memory: nil),
            historyReading(first, name: "cms_original", cpu: 2, memory: 100)
        ], unreadable: 3, totalCPU: nil, totalMemory: nil, processCPU: [first: 25])
        let renamed = historyFrame(sequence: 2, timestamp: 104, segment: 1, readings: [
            historyReading(first, name: "CMS_renamed", cpu: 3, memory: 200)
        ], totalCPU: 80, totalMemory: 200, processCPU: [first: 80])
        let empty = historyFrame(sequence: 3, timestamp: 105, readings: [], totalCPU: 0, totalMemory: 0)
        let unavailable = historyFrame(sequence: 4, timestamp: 106, readings: [], enumerationValid: false,
                                       unreadable: 2, totalCPU: nil, totalMemory: nil)
        let otherSession = historyFrame(session: "session-b", sequence: 1, timestamp: 105,
                                        readings: [historyReading(first, name: "cms_other_session", cpu: 10, memory: 300)])
        // Insert out of sequence and reuse wall timestamps across frames/sessions.
        for frame in [renamed, otherSession, original, empty, unavailable] {
            try store?.append(system: nil, cms: frame)
        }
        store = nil
        let reopened = try HistoryStore(databaseURL: url)
        let frames = try reopened.fetchCMS(from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 110))
        #expect(frames.map(\.sessionID) == ["session-a", "session-a", "session-a", "session-a", "session-b"])
        #expect(frames.map(\.sequence) == [1, 2, 3, 4, 1])
        #expect(frames[0].raw.processes.map(\.id) == [reused, first])
        #expect(frames[0].raw.processes[0].name == "cms_新实例")
        #expect(frames[0].raw.processes[0].cpuSeconds == nil)
        #expect(frames[0].raw.processes[0].memoryBytes == nil)
        #expect(frames[0].totalCPUPercent == nil)
        #expect(frames[0].totalMemoryBytes == nil)
        #expect(frames[0].processCPUPercent == [first: 25])
        #expect(frames[0].raw.unreadableCount == 3)
        #expect(frames[0].raw.enumerationValid)
        #expect(frames[1].raw.processes[0].name == "CMS_renamed")
        #expect(frames[1].segment == 1)
        #expect(frames[1].maximumGap == 17)
        #expect(frames[1].raw.monotonicSeconds == 12)
        #expect(frames[1].raw.timestamp == renamed.raw.timestamp)
        #expect(frames[1].sessionStartedAt == renamed.sessionStartedAt)
        #expect(frames[1].processCPUPercent[first] == 80)
        #expect(frames[2].raw.processes.isEmpty)
        #expect(frames[2].totalCPUPercent == 0)
        #expect(frames[2].totalMemoryBytes == 0)
        #expect(frames[3].raw.processes.isEmpty)
        #expect(!frames[3].raw.enumerationValid)
        #expect(frames[3].raw.unreadableCount == 2)
        #expect(frames[4].raw.processes[0].cpuSeconds == 10)
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM cms_sessions WHERE schema_version=1;") == 2)
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM cms_processes;") == 3)
    }
}

@Test func cmsHistoryPaginationLimitsFramesAndKeepsAllChildren() throws {
    try withCMSHistoryDatabase { url in
        let store = try HistoryStore(databaseURL: url)
        let readings = (1...20).map { historyReading(CMSProcessID(pid: Int32($0), startTime: 1),
                                                    name: "cms_\($0)", cpu: Double($0), memory: 100) }
        try store.append(system: nil, cms: historyFrame(session: "b", sequence: 1, timestamp: 105, readings: []))
        try store.append(system: nil, cms: historyFrame(session: "a", sequence: 2, timestamp: 104, readings: []))
        try store.append(system: nil, cms: historyFrame(session: "a", sequence: 1, timestamp: 105, readings: readings))
        let from = Date(timeIntervalSince1970: 100), to = Date(timeIntervalSince1970: 110)
        let first = try store.fetchCMSPage(from: from, to: to, limit: 1)
        #expect(first.count == 1)
        #expect(first[0].sessionID == "a")
        #expect(first[0].sequence == 1)
        #expect(first[0].raw.processes.map(\.id) == readings.map(\.id))
        let second = try store.fetchCMSPage(from: from, to: to,
                                           after: CMSHistoryCursor(sessionID: "a", sequence: 1), limit: 1)
        #expect(second.count == 1)
        #expect(second[0].sequence == 2)
        #expect(second[0].raw.processes.isEmpty)
        let third = try store.fetchCMSPage(from: from, to: to,
                                          after: CMSHistoryCursor(sessionID: "a", sequence: 2), limit: 1)
        #expect(third.count == 1)
        #expect(third[0].sessionID == "b")
        #expect(try store.fetchCMSPage(from: from, to: to,
                                     after: CMSHistoryCursor(sessionID: "b", sequence: 1), limit: 1).isEmpty)
        // The timestamp predicate stays active on subsequent cursor pages.
        let sameTime = try store.fetchCMSPage(from: Date(timeIntervalSince1970: 105), to: to,
                                             after: CMSHistoryCursor(sessionID: "a", sequence: 1), limit: 5)
        #expect(sameTime.map(\.sessionID) == ["b"])
    }
}

@Test func cmsHistoryPruneCascadesAndKeepsBoundaryEmptyFrames() throws {
    try withCMSHistoryDatabase { url in
        let store = try HistoryStore(databaseURL: url)
        let old = historyReading(CMSProcessID(pid: 1, startTime: 1), name: "cms_old", cpu: 1, memory: 100)
        let retained = historyReading(CMSProcessID(pid: 1, startTime: 2), name: "cms_new", cpu: 2, memory: 200)
        try store.append(system: historySystemSample(104), cms: historyFrame(sequence: 1, timestamp: 104, readings: [old]))
        try store.append(system: historySystemSample(105), cms: historyFrame(sequence: 2, timestamp: 105, readings: [retained]))
        try store.append(system: nil, cms: historyFrame(session: "expired", sequence: 1, timestamp: 104, readings: [old]))
        try store.append(system: nil, cms: historyFrame(session: "empty", sequence: 1, timestamp: 105, readings: []))
        try store.prune(olderThan: Date(timeIntervalSince1970: 105))
        let frames = try store.fetchCMS(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 200))
        #expect(frames.count == 2)
        #expect(frames.map(\.sessionID) == ["empty", "session-a"])
        #expect(frames[1].raw.processes.map(\.id) == [retained.id])
        #expect(frames[1].sessionStartedAt == Date(timeIntervalSince1970: 90))
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM cms_process_samples;") == 1)
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM cms_processes;") == 1)
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM cms_sessions;") == 2)
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM samples;") == 1)
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM pragma_foreign_key_check;") == 0)
    }
}

@Test func cmsAndSystemAppendRollBackTogetherOnChildWriteFailure() throws {
    try withCMSHistoryDatabase { url in
        let store = try HistoryStore(databaseURL: url)
        let reading = historyReading(CMSProcessID(pid: 1, startTime: 2), name: "cms_one", cpu: 1, memory: 100)
        let frame = historyFrame(sequence: 1, timestamp: 105, readings: [reading])
        try cmsExecute(url, """
        CREATE TRIGGER reject_cms_sample BEFORE INSERT ON cms_process_samples
        BEGIN SELECT RAISE(ABORT,'test child write failure'); END;
        """)
        #expect(throws: (any Error).self) { try store.append(system: historySystemSample(105), cms: frame) }
        for table in ["samples", "cms_sessions", "cms_frames", "cms_processes", "cms_process_samples"] {
            #expect(try cmsScalar(url, "SELECT COUNT(*) FROM \(table);") == 0)
        }
        try cmsExecute(url, "DROP TRIGGER reject_cms_sample;")
        try store.append(system: historySystemSample(105), cms: frame)
        // A duplicate frame must also roll back the newly inserted system sample.
        #expect(throws: (any Error).self) { try store.append(system: historySystemSample(106), cms: frame) }
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM samples;") == 1)
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM cms_frames;") == 1)
        // A failed system insert must not leave any CMS metadata behind either.
        let other = historyFrame(session: "not_written", sequence: 1, timestamp: 105, readings: [])
        #expect(throws: (any Error).self) { try store.append(system: historySystemSample(105), cms: other) }
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM cms_sessions;") == 1)
    }
}

@Test func cmsHistoryCoexistsWithAnOriginalSystemOnlySchema() throws {
    try withCMSHistoryDatabase { url in
        try cmsExecute(url, """
        CREATE TABLE samples (
          timestamp REAL PRIMARY KEY,cpu REAL NOT NULL,gpu REAL,memory REAL NOT NULL,
          memory_used REAL NOT NULL,memory_total REAL NOT NULL,memory_pressure REAL NOT NULL,
          ane_power REAL,cpu_power REAL,gpu_power REAL,system_power REAL,memory_read REAL,memory_write REAL,
          disk_read REAL NOT NULL,disk_write REAL NOT NULL,disk_free REAL NOT NULL,disk_total REAL NOT NULL,
          net_down REAL NOT NULL,net_up REAL NOT NULL,thermal TEXT NOT NULL
        );
        INSERT INTO samples VALUES(100,12,NULL,30,100,200,30,NULL,NULL,NULL,NULL,NULL,NULL,0,0,100,200,0,0,'nominal');
        """)
        let store = try HistoryStore(databaseURL: url)
        let old = try store.fetchRaw(from: Date(timeIntervalSince1970: 99), to: Date(timeIntervalSince1970: 101))
        #expect(old.count == 1)
        #expect(old[0].cpuUsage == 12)
        #expect(old[0].cliptoCPUPercent == nil)
        #expect(old[0].swapUsedBytes == 0)
        try store.append(system: historySystemSample(105), cms: historyFrame(sequence: 1, timestamp: 105, readings: []))
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM samples;") == 2)
        #expect(try cmsScalar(url, "SELECT COUNT(*) FROM cms_frames;") == 1)
    }
}

@Test func historyReadStepErrorsAreNotReturnedAsAnEmptyOrPartialSuccess() throws {
    try withCMSHistoryDatabase { url in
        let store = try HistoryStore(databaseURL: url)
        try store.append(system: historySystemSample(105), cms: historyFrame(sequence: 1, timestamp: 105, readings: []))
        // SQLite prepares these views successfully; evaluating abs(Int64.min)
        // raises an integer overflow during sqlite3_step, not during prepare.
        try cmsExecute(url, """
        ALTER TABLE samples RENAME TO saved_samples;
        CREATE VIEW samples AS SELECT abs(-9223372036854775808) AS timestamp,saved_samples.* FROM saved_samples;
        ALTER TABLE cms_frames RENAME TO saved_cms_frames;
        CREATE VIEW cms_frames AS SELECT abs(-9223372036854775808) AS timestamp,saved_cms_frames.* FROM saved_cms_frames;
        """)
        #expect(throws: (any Error).self) {
            try store.fetchRaw(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 200))
        }
        #expect(throws: (any Error).self) {
            try store.fetchCMS(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 200))
        }
    }
}

private func withCMSHistoryDatabase(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pulseboard-cms-history-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory.appendingPathComponent("history.sqlite"))
}

private func historyReading(_ id: CMSProcessID, name: String, cpu: Double?, memory: Double?) -> CMSProcessReading {
    CMSProcessReading(id: id, name: name, cpuSeconds: cpu, memoryBytes: memory)
}

private func historyFrame(session: String = "session-a", sequence: Int64, timestamp: Double,
                          segment: Int64 = 0, readings: [CMSProcessReading], enumerationValid: Bool = true,
                          unreadable: Int = 0, totalCPU: Double? = nil, totalMemory: Double? = nil,
                          processCPU: [CMSProcessID: Double] = [:]) -> CMSHistoryFrame {
    CMSHistoryFrame(sessionID: session, sessionStartedAt: Date(timeIntervalSince1970: 90),
                    sequence: sequence, segment: segment, maximumGap: 17,
                    raw: CMSRawSnapshot(timestamp: Date(timeIntervalSince1970: timestamp),
                                        monotonicSeconds: Double(sequence) + 10, processes: readings,
                                        enumerationValid: enumerationValid, unreadableCount: unreadable),
                    totalCPUPercent: totalCPU, totalMemoryBytes: totalMemory, processCPUPercent: processCPU)
}

private func historySystemSample(_ timestamp: Double) -> MetricSample {
    MetricSample(timestamp: Date(timeIntervalSince1970: timestamp), cpuUsage: 10, gpuUsage: nil, aneUsage: nil,
                 memoryUsage: 30, memoryUsedBytes: 100, memoryTotalBytes: 200, memoryPressure: 30,
                 anePowerWatts: nil, cpuPowerWatts: nil, gpuPowerWatts: nil, systemPowerWatts: nil,
                 memoryReadGBps: nil, memoryWriteGBps: nil, diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0,
                 diskFreeBytes: 100, diskTotalBytes: 200, networkDownBytesPerSecond: 0, networkUpBytesPerSecond: 0,
                 thermalState: "nominal", cliptoCPUPercent: nil, cliptoMemoryBytes: nil,
                 cliptoDiskReadBytesPerSecond: nil, cliptoDiskWriteBytesPerSecond: nil,
                 cliptoProcessCount: nil, cliptoGPUPercent: nil, swapUsedBytes: 0, swapTotalBytes: 0)
}

private func withCMSRawDatabase<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw StoreError.openFailed }
    defer { sqlite3_close(database) }
    return try body(database)
}

private func cmsExecute(_ url: URL, _ sql: String) throws {
    try withCMSRawDatabase(url) { database in
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
    }
}

private func cmsScalar(_ url: URL, _ sql: String) throws -> Int64 {
    try withCMSRawDatabase(url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw StoreError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}
