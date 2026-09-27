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

@Test func processMetricsParserAggregatesCliptoTree() throws {
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>tasks</key><array>
      <dict><key>pid</key><integer>10</integer><key>parent_pid</key><integer>1</integer><key>name</key><string>Clipto</string><key>gputime_ms_per_s</key><real>120</real><key>bytes_received_per_s</key><real>1000</real><key>bytes_sent_per_s</key><real>200</real><key>energy_impact_per_s</key><real>3.5</real></dict>
      <dict><key>pid</key><integer>11</integer><key>parent_pid</key><integer>10</integer><key>name</key><string>Clipto Helper (GPU)</string><key>gputime_ms_per_s</key><real>80</real><key>bytes_received_per_s</key><real>500</real><key>bytes_sent_per_s</key><real>100</real><key>energy_impact_per_s</key><real>1.5</real></dict>
      <dict><key>pid</key><integer>99</integer><key>parent_pid</key><integer>1</integer><key>name</key><string>Other</string><key>gputime_ms_per_s</key><real>500</real></dict>
    </array></dict></plist>
    """
    let value = try #require(PowerMetricsBridge.parseCliptoProcessMetrics(data: Data(plist.utf8)))
    #expect(value.gpuPercent == 20)
    #expect(value.networkDownBytesPerSecond == 1_500)
    #expect(value.networkUpBytesPerSecond == 300)
    #expect(value.energyImpact == 5)
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
        cliptoDiskWriteBytesPerSecond: 70, cliptoProcessCount: 8, cliptoGPUPercent: 24,
        cliptoNetworkDownBytesPerSecond: 80, cliptoNetworkUpBytesPerSecond: 90,
        cliptoEnergyImpact: 12
    )
    try store.append(sample)
    let values = try store.fetchRaw(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
    #expect(values.count == 1)
    #expect(values.first?.cpuUsage == 32)
    #expect(values.first?.aneUsage == 4)
    #expect(values.first?.cliptoCPUPercent == 150)
    #expect(values.first?.cliptoProcessCount == 8)
    #expect(values.first?.cliptoGPUPercent == 24)
    #expect(values.first?.cliptoNetworkDownBytesPerSecond == 80)
    #expect(values.first?.thermalState == "正常")
}
