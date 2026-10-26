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

enum PowerReadingSanitizer {
    static func systemPower(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= 1_000 else { return nil }
        return value
    }

    static func componentPower(
        _ value: Double?,
        systemPower: Double?,
        absoluteMaximum: Double,
        minimum: Double = 0
    ) -> Double? {
        guard let value, value.isFinite, value >= minimum, value <= absoluteMaximum else { return nil }
        if let systemPower {
            // Allow source timing skew and component-model overhead, while
            // rejecting impossible counter-wrap spikes far above whole-system power.
            let relativeMaximum = max(50, systemPower * 3 + 20)
            guard value <= relativeMaximum else { return nil }
        }
        return value
    }
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
