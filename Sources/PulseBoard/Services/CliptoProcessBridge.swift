import Foundation
import PulseHardware

struct CliptoProcessMetrics {
    let running: Bool
    let cpuPercent: Double?
    let memoryBytes: Double?
    let diskReadBytesPerSecond: Double?
    let diskWriteBytesPerSecond: Double?
    let processCount: Int?
}

final class CliptoProcessBridge {
    func sample() -> CliptoProcessMetrics {
        let value = pb_clipto_sample()
        let running = value.running != 0
        return CliptoProcessMetrics(
            running: running,
            cpuPercent: running && value.rates_valid != 0 ? value.cpu_percent : nil,
            memoryBytes: running ? value.memory_bytes : nil,
            diskReadBytesPerSecond: running && value.rates_valid != 0 ? value.disk_read_bytes_per_second : nil,
            diskWriteBytesPerSecond: running && value.rates_valid != 0 ? value.disk_write_bytes_per_second : nil,
            processCount: running ? Int(value.process_count) : nil
        )
    }
}
