import Foundation

struct EnhancedMetrics: Sendable {
    var cpuPowerWatts: Double?
    var gpuPowerWatts: Double?
    var anePowerWatts: Double?
    var systemPowerWatts: Double?
    var gpuUsage: Double?
    var aneUsage: Double?
    var memoryReadGBps: Double?
    var memoryWriteGBps: Double?
}

struct PowerMetricsBridge {
    private let native = NativeHardwareBridge()

    var isFresh: Bool { native.isAvailable }

    func latest() -> EnhancedMetrics {
        native.latest() ?? EnhancedMetrics(
            cpuPowerWatts: nil,
            gpuPowerWatts: nil,
            anePowerWatts: nil,
            systemPowerWatts: nil,
            gpuUsage: nil,
            aneUsage: nil,
            memoryReadGBps: nil,
            memoryWriteGBps: nil
        )
    }
}
