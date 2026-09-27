import Foundation
import Testing
@testable import PulseBoard

@Test func historyRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try HistoryStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
    let now = Date()
    let sample = MetricSample(
        timestamp: now, cpuUsage: 32, gpuUsage: 12, aneUsage: 4, memoryUsage: 55,
        memoryUsedBytes: 8, memoryTotalBytes: 16, memoryPressure: 55,
        anePowerWatts: 0.2, cpuPowerWatts: 2, gpuPowerWatts: 1, systemPowerWatts: 3.2,
        memoryReadGBps: 4, memoryWriteGBps: 2, diskReadBytesPerSecond: 10,
        diskWriteBytesPerSecond: 20, diskFreeBytes: 100, diskTotalBytes: 200,
        networkDownBytesPerSecond: 30, networkUpBytesPerSecond: 40, thermalState: "正常",
        cliptoCPUPercent: 150, cliptoMemoryBytes: 500, cliptoDiskReadBytesPerSecond: 60,
        cliptoDiskWriteBytesPerSecond: 70, cliptoProcessCount: 8, cliptoGPUPercent: 24
    )
    try store.append(sample)
    let values = try store.fetchRaw(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
    #expect(values.count == 1)
    #expect(values.first?.cpuUsage == 32)
    #expect(values.first?.aneUsage == 4)
    #expect(values.first?.cliptoCPUPercent == 150)
    #expect(values.first?.cliptoProcessCount == 8)
    #expect(values.first?.cliptoGPUPercent == 24)
    #expect(values.first?.thermalState == "正常")
}
