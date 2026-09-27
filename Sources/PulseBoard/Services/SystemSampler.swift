import Darwin
import Foundation
import IOKit

final class SystemSampler {
    private var previousCPUTicks: [UInt32]?
    private var previousDisk: (read: UInt64, write: UInt64)?
    private var previousNetwork: (read: UInt64, write: UInt64)?
    private var previousDate = Date()
    private let enhanced = PowerMetricsBridge()
    private let clipto = CliptoProcessBridge()

    var enhancedMetricsAvailable: Bool { enhanced.isFresh }

    func sample() -> MetricSample {
        let now = Date()
        let elapsed = max(0.05, now.timeIntervalSince(previousDate))
        previousDate = now

        let cpu = cpuUsage()
        let memory = memoryUsage()
        let diskTotals = diskByteTotals()
        let networkTotals = networkByteTotals()
        let diskRate = rate(current: diskTotals, previous: &previousDisk, elapsed: elapsed)
        let networkRate = rate(current: networkTotals, previous: &previousNetwork, elapsed: elapsed)
        let capacity = diskCapacity()
        let extra = enhanced.latest()
        let gpu = extra.gpuUsage ?? gpuUsage()
        let cliptoMetrics = clipto.sample()

        return MetricSample(
            timestamp: now,
            cpuUsage: cpu,
            gpuUsage: gpu,
            aneUsage: extra.aneUsage,
            memoryUsage: memory.percent,
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            memoryPressure: memory.pressure,
            anePowerWatts: extra.anePowerWatts,
            cpuPowerWatts: extra.cpuPowerWatts,
            gpuPowerWatts: extra.gpuPowerWatts,
            systemPowerWatts: extra.systemPowerWatts,
            memoryReadGBps: extra.memoryReadGBps,
            memoryWriteGBps: extra.memoryWriteGBps,
            diskReadBytesPerSecond: diskRate.read,
            diskWriteBytesPerSecond: diskRate.write,
            diskFreeBytes: capacity.free,
            diskTotalBytes: capacity.total,
            networkDownBytesPerSecond: networkRate.read,
            networkUpBytesPerSecond: networkRate.write,
            thermalState: thermalState(),
            cliptoCPUPercent: cliptoMetrics.cpuPercent,
            cliptoMemoryBytes: cliptoMetrics.memoryBytes,
            cliptoDiskReadBytesPerSecond: cliptoMetrics.diskReadBytesPerSecond,
            cliptoDiskWriteBytesPerSecond: cliptoMetrics.diskWriteBytesPerSecond,
            cliptoProcessCount: cliptoMetrics.processCount,
            cliptoGPUPercent: cliptoMetrics.gpuPercent,
            swapUsedBytes: memory.swapUsed,
            swapTotalBytes: memory.swapTotal
        )
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let ticks = withUnsafeBytes(of: &info.cpu_ticks) { raw in
            Array(raw.bindMemory(to: UInt32.self))
        }
        defer { previousCPUTicks = ticks }
        guard let previous = previousCPUTicks, previous.count == ticks.count else { return 0 }

        let deltas = zip(ticks, previous).map { UInt64($0) &- UInt64($1) }
        let total = deltas.reduce(0, +)
        guard total > 0, deltas.count > Int(CPU_STATE_IDLE) else { return 0 }
        return min(100, max(0, Double(total - deltas[Int(CPU_STATE_IDLE)]) / Double(total) * 100))
    }

    private func memoryUsage() -> (percent: Double, used: Double, total: Double, pressure: Double, swapUsed: Double, swapTotal: Double) {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return (0, 0, total, 0, 0, 0) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        // Match macOS monitoring tools: inactive pages are immediately reclaimable,
        // so count them as available instead of used. Compressor pages must not be
        // added independently because their physical storage is already represented.
        let availablePages = UInt64(info.free_count) + UInt64(info.inactive_count)
        let available = min(total, Double(availablePages) * Double(pageSize))
        let used = max(0, total - available)
        let percent = total > 0 ? used / total * 100 : 0
        let pressure = min(100, max(0, percent + (info.pageouts > 0 ? 5 : 0)))
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapResult = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        let swapUsed = swapResult == 0 ? Double(swap.xsu_used) : 0
        let swapTotal = swapResult == 0 ? Double(swap.xsu_total) : 0
        return (percent, used, total, pressure, swapUsed, swapTotal)
    }

    private func gpuUsage() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var values: [Double] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let property = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let statistics = property as? [String: Any],
               let value = statistics["Device Utilization %"] as? NSNumber {
                values.append(value.doubleValue)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return values.max().map { min(100, max(0, $0)) }
    }

    private func diskByteTotals() -> (read: UInt64, write: UInt64) {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return (0, 0) }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var largest = (read: UInt64(0), write: UInt64(0))
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let property = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let statistics = property as? [String: Any] {
                let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                let write = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                if read + write > largest.read + largest.write { largest = (read, write) }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return largest
    }

    private func networkByteTotals() -> (read: UInt64, write: UInt64) {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return (0, 0) }
        defer { freeifaddrs(pointer) }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            let item = interface.pointee
            if let address = item.ifa_addr,
               address.pointee.sa_family == UInt8(AF_LINK),
               item.ifa_flags & UInt32(IFF_UP) != 0,
               item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
               let dataPointer = item.ifa_data {
                let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                received &+= UInt64(data.ifi_ibytes)
                sent &+= UInt64(data.ifi_obytes)
            }
            current = item.ifa_next
        }
        return (read: received, write: sent)
    }

    private func diskCapacity() -> (free: Double, total: Double) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Double(values?.volumeAvailableCapacityForImportantUsage ?? 0), Double(values?.volumeTotalCapacity ?? 0))
    }

    private func rate(
        current: (read: UInt64, write: UInt64),
        previous: inout (read: UInt64, write: UInt64)?,
        elapsed: TimeInterval
    ) -> (read: Double, write: Double) {
        defer { previous = current }
        guard let previous else { return (0, 0) }
        let read = current.read >= previous.read ? current.read - previous.read : 0
        let write = current.write >= previous.write ? current.write - previous.write : 0
        return (Double(read) / elapsed, Double(write) / elapsed)
    }

    private func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "正常"
        case .fair: "温热"
        case .serious: "较高"
        case .critical: "严重"
        @unknown default: "未知"
        }
    }
}
