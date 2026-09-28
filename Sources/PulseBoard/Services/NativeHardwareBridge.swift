import Foundation
import PulseHardware

final class NativeHardwareBridge {
    private let initialized: Bool
    private var cached: EnhancedMetrics?
    private var cacheDate = Date.distantPast

    init() {
        let status = pb_hardware_init()
        initialized = status == 0
        if status != 0 {
            FileHandle.standardError.write(Data(L10n.format("hardware.init_failed", status).utf8))
        }
    }

    deinit {
        if initialized { pb_hardware_shutdown() }
    }

    var isAvailable: Bool { initialized }

    func latest() -> EnhancedMetrics? {
        guard initialized else { return nil }
        if let cached, Date().timeIntervalSince(cacheDate) < 0.5 { return cached }
        let sample = pb_hardware_sample()
        guard sample.valid != 0 else { return cached }
        let systemPower = PowerReadingSanitizer.systemPower(sample.system_power_watts)
        let result = EnhancedMetrics(
            cpuPowerWatts: sample.cpu_power_valid != 0
                ? PowerReadingSanitizer.componentPower(sample.cpu_power_watts, systemPower: systemPower, absoluteMaximum: 500, minimum: 0.001)
                : nil,
            gpuPowerWatts: sample.gpu_power_valid != 0
                ? PowerReadingSanitizer.componentPower(sample.gpu_power_watts, systemPower: systemPower, absoluteMaximum: 500)
                : nil,
            anePowerWatts: sample.ane_power_valid != 0
                ? PowerReadingSanitizer.componentPower(sample.ane_power_watts, systemPower: systemPower, absoluteMaximum: 150)
                : nil,
            systemPowerWatts: systemPower,
            gpuUsage: sample.gpu_usage_valid != 0 ? min(100, max(0, sample.gpu_usage_percent)) : nil,
            aneUsage: sample.ane_usage_percent,
            memoryReadGBps: sample.memory_read_gbps,
            memoryWriteGBps: sample.memory_write_gbps
        )
        cached = result
        cacheDate = Date()
        return result
    }
}
