import Foundation
import Testing
@testable import PulseBoard

@Test func localizedResourcesAreAvailable() {
    #expect(L10n.text("dashboard.title", language: "en") == "Resource Overview")
    #expect(L10n.text("dashboard.title", language: "zh-Hans") == "资源总览")
    #expect(L10n.text("settings.title", language: "en") == "Settings")
    #expect(L10n.text("settings.title", language: "zh-Hans") == "设置")
}

@Test func impossiblePowerReadingsAreRejected() {
    let systemPower = PowerReadingSanitizer.systemPower(36.96)
    #expect(systemPower == 36.96)
    #expect(PowerReadingSanitizer.componentPower(42, systemPower: systemPower, absoluteMaximum: 500) == 42)
    #expect(PowerReadingSanitizer.componentPower(3_709.14, systemPower: systemPower, absoluteMaximum: 500) == nil)
    #expect(PowerReadingSanitizer.componentPower(0, systemPower: systemPower, absoluteMaximum: 500, minimum: 0.001) == nil)
    #expect(PowerReadingSanitizer.componentPower(251.5, systemPower: 33.18, absoluteMaximum: 150) == nil)
    #expect(PowerReadingSanitizer.systemPower(.infinity) == nil)
}

@Test func historyRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try HistoryStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
    let now = Date()
    let sample = testSample(timestamp: now)
    try store.append(sample)
    let values = try store.fetchRaw(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
    #expect(values.count == 1)
    #expect(values.first?.cpuUsage == 32)
    #expect(values.first?.aneUsage == 4)
    #expect(values.first?.cliptoCPUPercent == 150)
    #expect(values.first?.cliptoProcessCount == 8)
    #expect(values.first?.cliptoGPUPercent == 24)
    #expect(values.first?.swapUsedBytes == 300)
    #expect(values.first?.swapTotalBytes == 400)
    #expect(values.first?.thermalState == "正常")
}

@Test func historyAggregationDropsImpossiblePowerSpikes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = try HistoryStore(databaseURL: directory.appendingPathComponent("test.sqlite"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try store.append(testSample(timestamp: now, cpuPowerWatts: 10, systemPowerWatts: 20))
    try store.append(testSample(timestamp: now.addingTimeInterval(1), cpuPowerWatts: 3_709.14, systemPowerWatts: 36.96))

    let values = try store.fetch(from: now, to: now.addingTimeInterval(2), maxPoints: 1)
    #expect(values.count == 1)
    #expect(values.first?.cpuPowerWatts == 10)
}

private func testSample(
    timestamp: Date,
    cpuPowerWatts: Double = 2,
    systemPowerWatts: Double = 3.2
) -> MetricSample {
    MetricSample(
        timestamp: timestamp, cpuUsage: 32, gpuUsage: 12, aneUsage: 4, memoryUsage: 55,
        memoryUsedBytes: 8, memoryTotalBytes: 16, memoryPressure: 55,
        anePowerWatts: 0.2, cpuPowerWatts: cpuPowerWatts, gpuPowerWatts: 1, systemPowerWatts: systemPowerWatts,
        memoryReadGBps: 4, memoryWriteGBps: 2, diskReadBytesPerSecond: 10,
        diskWriteBytesPerSecond: 20, diskFreeBytes: 100, diskTotalBytes: 200,
        networkDownBytesPerSecond: 30, networkUpBytesPerSecond: 40, thermalState: "正常",
        cliptoCPUPercent: 150, cliptoMemoryBytes: 500, cliptoDiskReadBytesPerSecond: 60,
        cliptoDiskWriteBytesPerSecond: 70, cliptoProcessCount: 8, cliptoGPUPercent: 24,
        swapUsedBytes: 300, swapTotalBytes: 400
    )
}
