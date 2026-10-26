import Foundation
import Testing
@testable import PulseBoard

@Test func cmsPersistedFramesReproduceSessionStatistics() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("replay.sqlite")
    let repository = HistoryRepository(databaseURL: url)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let id = CMSProcessID(pid: 42, startTime: 10)
    let replacement = CMSProcessID(pid: 42, startTime: 20)
    func reading(_ cpu: Double?, _ memory: Double?, id: CMSProcessID? = nil) -> CMSProcessReading {
        CMSProcessReading(id: id ?? CMSProcessID(pid: 42, startTime: 10), name: "cms_worker", cpuSeconds: cpu, memoryBytes: memory)
    }
    let observations: [(Double, Double, Int64, Bool, [CMSProcessReading])] = [
        (0, 0, 0, true, []), (1, 1, 0, true, []),
        (2, 2, 0, true, [reading(100, 10)]),
        (3, 3, 0, true, [reading(101, 20)]),
        (4, 4, 0, false, []),
        (5, 5, 0, true, [reading(103, nil)]),
        (6, 6, 0, true, [reading(104, 40)]),
        // A short monotonic step after a long sleep still needs a new baseline.
        (3_606, 6.2, 1, true, [reading(500, 50)]),
        (3_607, 7.2, 1, true, [reading(500.5, 60)]),
        (3_660, 60, 1, true, [reading(510, 70)]),
        (3_661, 61, 1, true, [reading(1, 80, id: replacement)]),
        // A wall-clock correction must not change replay order.
        (-1, 62, 1, true, [reading(2, 90, id: replacement)]),
        (0, 63, 1, true, []), (1, 64, 1, true, [])
    ]
    var live = CMSProcessSession(startedAt: start)
    var previousSegment: Int64 = 0
    for (index, observation) in observations.enumerated() {
        let (wall, monotonic, segment, complete, processes) = observation
        if segment != previousSegment { live.suspend() }
        previousSegment = segment
        let raw = CMSRawSnapshot(timestamp: start.addingTimeInterval(wall), monotonicSeconds: monotonic,
                                 processes: processes, enumerationValid: complete, unreadableCount: complete ? 0 : 1)
        live.consume(raw, maximumGap: 30)
        let frame = CMSHistoryFrame.capture(sessionID: "session", sequence: Int64(index + 1), segment: segment,
                                            maximumGap: 30, raw: raw, statistics: live.snapshot)
        // Exited summaries stay in the UI, but must never become stored readings.
        #expect(frame.processCPUPercent.keys.allSatisfy { key in raw.processes.contains { $0.id == key } })
        try await repository.append(system: nil, cms: frame)
    }
    await repository.flush()
    let reopened = HistoryRepository(databaseURL: url)
    let frames = try await reopened.fetchCMS(from: start.addingTimeInterval(-10), to: start.addingTimeInterval(4_000))
    #expect(frames.count == observations.count)
    var replayed = CMSProcessSession(startedAt: try #require(frames.first?.sessionStartedAt),
                                    statisticsVersion: try #require(frames.first?.statisticsVersion))
    previousSegment = 0
    for frame in frames {
        if frame.segment != previousSegment { replayed.suspend() }
        previousSegment = frame.segment
        replayed.consume(frame.raw, maximumGap: frame.maximumGap)
        #expect(replayed.snapshot.cpu.current == frame.totalCPUPercent)
        #expect(replayed.snapshot.memory.current == frame.totalMemoryBytes)
    }
    let expected = live.snapshot
    let actual = replayed.snapshot
    #expect(actual.cpu.average == expected.cpu.average)
    #expect(actual.cpu.peak == expected.cpu.peak)
    #expect(actual.cpu.validDuration == expected.cpu.validDuration)
    #expect(actual.memory.average == expected.memory.average)
    #expect(actual.memory.peak == expected.memory.peak)
    #expect(actual.memory.validDuration == expected.memory.validDuration)
    #expect(Set(actual.processes.map(\.id)) == Set([id, replacement]))
    for row in actual.processes {
        let original = try #require(expected.processes.first { $0.id == row.id })
        #expect(row.state == original.state)
        #expect(row.cpu.average == original.cpu.average)
        #expect(row.cpu.peak == original.cpu.peak)
        #expect(row.memory.average == original.memory.average)
        #expect(row.memory.peak == original.memory.peak)
    }
}

@Test func cmsRepositoryExportsMultiplePagesAndReplacesDestination() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = HistoryRepository(databaseURL: directory.appendingPathComponent("export.sqlite"))
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var session = CMSProcessSession(startedAt: start)
    var expected: [CMSHistoryFrame] = []
    for index in 0..<503 {
        let raw = CMSRawSnapshot(timestamp: start.addingTimeInterval(Double(index)), monotonicSeconds: Double(index),
                                 processes: [], enumerationValid: true, unreadableCount: 0)
        session.consume(raw)
        let frame = CMSHistoryFrame.capture(sessionID: "pages", sequence: Int64(index + 1), segment: 0,
                                            maximumGap: 30, raw: raw, statistics: session.snapshot)
        expected.append(frame)
        try await repository.append(system: nil, cms: frame)
    }
    let destination = directory.appendingPathComponent("CMS.csv")
    try "old export".write(to: destination, atomically: true, encoding: .utf8)
    try await repository.exportCMS(from: start, to: start.addingTimeInterval(600), destination: destination)
    #expect(try String(contentsOf: destination, encoding: .utf8) == CMSCSVExporter.csv(frames: expected))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasSuffix(".tmp") })

    let empty = directory.appendingPathComponent("empty.csv")
    try await repository.exportCMS(from: start.addingTimeInterval(-10), to: start.addingTimeInterval(-1), destination: empty)
    #expect(try String(contentsOf: empty, encoding: .utf8) == CMSCSVExporter.csv(frames: []))
}
