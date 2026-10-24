import Foundation
import PulseHardware

/// All libproc enumeration happens on this actor, away from the UI executor.
actor CMSProcessSampler {
    func sample() -> CMSRawSnapshot {
        var raw = pb_cms_snapshot()
        defer { pb_cms_snapshot_free(&raw) }
        var processes: [CMSProcessReading] = []
        if let pointer = raw.processes {
            for item in UnsafeBufferPointer(start: pointer, count: Int(raw.count)) {
                var name = item.name
                let decoded = withUnsafeBytes(of: &name) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                processes.append(CMSProcessReading(
                    id: CMSProcessID(pid: item.pid, startTime: item.start_time), name: decoded,
                    cpuSeconds: item.usage_valid != 0 ? item.cpu_seconds : nil,
                    memoryBytes: item.usage_valid != 0 ? Double(item.memory_bytes) : nil
                ))
            }
        }
        return CMSRawSnapshot(timestamp: Date(), monotonicSeconds: raw.monotonic_seconds,
                              processes: processes, enumerationValid: raw.enumeration_valid != 0,
                              unreadableCount: Int(raw.unreadable_count))
    }
}
