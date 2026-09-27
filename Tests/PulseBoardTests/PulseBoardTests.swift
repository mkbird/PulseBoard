import Foundation
import Testing
@testable import PulseBoard

@Test func powerMetricsParserUnderstandsMilliwatts() {
    let text = """
    CPU Power: 1250 mW
    GPU Power: 0.75 W
    ANE Power: 80 mW
    Combined Power (CPU + GPU + ANE): 2080 mW
    GPU active residency: 44.5%
    DRAM read bandwidth: 12.5 GB/s
    DRAM write bandwidth: 900 MB/s
    """
    let value = PowerMetricsBridge.parse(text: text)
    #expect(value.cpuPowerWatts == 1.25)
    #expect(value.gpuPowerWatts == 0.75)
    #expect(value.anePowerWatts == 0.08)
    #expect(value.systemPowerWatts == 2.08)
    #expect(value.gpuUsage == 44.5)
    #expect(value.aneUsage == 1)
    #expect(value.memoryReadGBps == 12.5)
    #expect(value.memoryWriteGBps == 0.9)
}

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
        cliptoDiskWriteBytesPerSecond: 70, cliptoProcessCount: 8
    )
    try store.append(sample)
    let values = try store.fetchRaw(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
    #expect(values.count == 1)
    #expect(values.first?.cpuUsage == 32)
    #expect(values.first?.aneUsage == 4)
    #expect(values.first?.cliptoCPUPercent == 150)
    #expect(values.first?.cliptoProcessCount == 8)
    #expect(values.first?.thermalState == "正常")
}
