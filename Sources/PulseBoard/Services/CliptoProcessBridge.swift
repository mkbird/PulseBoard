import Foundation
import PulseHardware

struct CliptoProcessMetrics {
    let running: Bool
    let cpuPercent: Double?
    let memoryBytes: Double?
    let diskReadBytesPerSecond: Double?
    let diskWriteBytesPerSecond: Double?
    let gpuPercent: Double?
    let processCount: Int?
    /// Summed GPU busy % of all CMS-named processes (nil when no CMS process is running).
    let cmsGPUPercent: Double?
    /// Per-process-name breakdown of the Clipto group (cms + Electron helpers + workers …).
    let members: [CliptoMemberSample]
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
            gpuPercent: running && value.rates_valid != 0 ? value.gpu_percent : nil,
            processCount: running ? Int(value.process_count) : nil,
            cmsGPUPercent: value.rates_valid != 0 && value.cms_gpu_valid != 0 ? value.cms_gpu_percent : nil,
            members: running ? Self.groupedMembers() : []
        )
    }

    /// Groups the last sampled Clipto processes by executable name (e.g. 22 × `cms_r5` → one row).
    private static func groupedMembers() -> [CliptoMemberSample] {
        var pointer: UnsafePointer<PBAppProcess>?
        let count = pb_clipto_last_processes(&pointer)
        guard let pointer, count > 0 else { return [] }
        var byName: [String: CliptoMemberSample] = [:]
        for item in UnsafeBufferPointer(start: pointer, count: count) {
            var raw = item.name
            let name = withUnsafeBytes(of: &raw) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let key = name.isEmpty ? "pid-\(item.pid)" : name
            var entry = byName[key] ?? CliptoMemberSample(name: key, isCMS: item.is_cms != 0, count: 0, memoryBytes: 0, cpuPercent: nil)
            entry.count += 1
            entry.memoryBytes += item.memory_bytes
            if item.cpu_valid != 0 { entry.cpuPercent = (entry.cpuPercent ?? 0) + item.cpu_percent }
            byName[key] = entry
        }
        return byName.values.sorted { $0.memoryBytes > $1.memoryBytes }
    }
}
