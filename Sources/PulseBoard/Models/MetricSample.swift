import Foundation

struct MetricSample: Codable, Identifiable, Hashable, Sendable {
    var id: TimeInterval { timestamp.timeIntervalSince1970 }

    let timestamp: Date
    let cpuUsage: Double
    let gpuUsage: Double?
    let aneUsage: Double?
    let memoryUsage: Double
    let memoryUsedBytes: Double
    let memoryTotalBytes: Double
    let memoryPressure: Double
    let anePowerWatts: Double?
    let cpuPowerWatts: Double?
    let gpuPowerWatts: Double?
    let systemPowerWatts: Double?
    let memoryReadGBps: Double?
    let memoryWriteGBps: Double?
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let diskFreeBytes: Double
    let diskTotalBytes: Double
    let networkDownBytesPerSecond: Double
    let networkUpBytesPerSecond: Double
    let thermalState: String
    let cliptoCPUPercent: Double?
    let cliptoMemoryBytes: Double?
    let cliptoDiskReadBytesPerSecond: Double?
    let cliptoDiskWriteBytesPerSecond: Double?
    let cliptoProcessCount: Int?
    let cliptoGPUPercent: Double?
    let cliptoNetworkDownBytesPerSecond: Double?
    let cliptoNetworkUpBytesPerSecond: Double?
    let cliptoEnergyImpact: Double?

    var cliptoRunning: Bool { (cliptoProcessCount ?? 0) > 0 }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case fifteenMinutes
    case oneHour
    case sixHours
    case oneDay
    case sevenDays
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: "15 分钟"
        case .oneHour: "1 小时"
        case .sixHours: "6 小时"
        case .oneDay: "24 小时"
        case .sevenDays: "7 天"
        case .custom: "自定义"
        }
    }

    var duration: TimeInterval? {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .sixHours: 6 * 60 * 60
        case .oneDay: 24 * 60 * 60
        case .sevenDays: 7 * 24 * 60 * 60
        case .custom: nil
        }
    }
}

enum MetricFormat {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value < 1 { return String(format: "%.0f mW", value * 1_000) }
        return String(format: "%.2f W", value)
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, value)), countStyle: .memory)
    }

    static func rate(_ value: Double) -> String {
        "\(bytes(value))/s"
    }

    static func bandwidth(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f GB/s", value)
    }
}
