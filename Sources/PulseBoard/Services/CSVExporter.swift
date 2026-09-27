import AppKit
import Foundation

enum CSVExporter {
    @MainActor
    static func export(samples: [MetricSample]) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "PulseBoard-\(fileDate.string(from: Date())).csv"
        panel.title = "导出监控数据"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try csv(samples: samples).write(to: url, atomically: true, encoding: .utf8)
    }

    static func csv(samples: [MetricSample]) -> String {
        var rows = ["timestamp,cpu_percent,gpu_percent,ane_percent,memory_percent,memory_used_bytes,memory_total_bytes,memory_pressure_percent,ane_watts,cpu_watts,gpu_watts,system_watts,memory_read_gbps,memory_write_gbps,disk_read_bps,disk_write_bps,disk_free_bytes,disk_total_bytes,network_down_bps,network_up_bps,thermal_state,clipto_cpu_percent,clipto_memory_bytes,clipto_disk_read_bps,clipto_disk_write_bps,clipto_process_count,clipto_gpu_percent,clipto_network_down_bps,clipto_network_up_bps,clipto_energy_impact"]
        let formatter = ISO8601DateFormatter()
        rows += samples.map { sample in
            [
                formatter.string(from: sample.timestamp),
                number(sample.cpuUsage), number(sample.gpuUsage), number(sample.aneUsage), number(sample.memoryUsage),
                number(sample.memoryUsedBytes), number(sample.memoryTotalBytes), number(sample.memoryPressure),
                number(sample.anePowerWatts), number(sample.cpuPowerWatts), number(sample.gpuPowerWatts),
                number(sample.systemPowerWatts), number(sample.memoryReadGBps), number(sample.memoryWriteGBps),
                number(sample.diskReadBytesPerSecond), number(sample.diskWriteBytesPerSecond),
                number(sample.diskFreeBytes), number(sample.diskTotalBytes),
                number(sample.networkDownBytesPerSecond), number(sample.networkUpBytesPerSecond),
                "\"\(sample.thermalState.replacingOccurrences(of: "\"", with: "\"\""))\"",
                number(sample.cliptoCPUPercent), number(sample.cliptoMemoryBytes),
                number(sample.cliptoDiskReadBytesPerSecond), number(sample.cliptoDiskWriteBytesPerSecond),
                sample.cliptoProcessCount.map(String.init) ?? "", number(sample.cliptoGPUPercent),
                number(sample.cliptoNetworkDownBytesPerSecond), number(sample.cliptoNetworkUpBytesPerSecond),
                number(sample.cliptoEnergyImpact)
            ].joined(separator: ",")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func number(_ value: Double?) -> String {
        value.map { String(format: "%.6f", $0) } ?? ""
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
