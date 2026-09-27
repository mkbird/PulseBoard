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
    private let fileURLs: [URL]
    private let native: NativeHardwareBridge?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURLs = [fileURL]
            self.native = nil
            return
        }
        let system = URL(fileURLWithPath: "/Library/Application Support/PulseBoard", isDirectory: true)
            .appendingPathComponent("powermetrics.txt")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PulseBoard", isDirectory: true)
        self.fileURLs = [system, support.appendingPathComponent("powermetrics.txt")]
        self.native = NativeHardwareBridge()
    }

    var fileURL: URL { freshFileURL ?? fileURLs[0] }

    var isFresh: Bool {
        native?.isAvailable == true || freshFileURL != nil
    }

    func latest() -> EnhancedMetrics {
        let systemMetrics = native?.latest()
        let powerMetrics: EnhancedMetrics? = {
            guard let source = freshFileURL,
                  let data = try? Data(contentsOf: source),
                  let text = String(data: data.suffix(256_000), encoding: .utf8) else { return nil }
            return Self.parse(text: text)
        }()
        return EnhancedMetrics(
            cpuPowerWatts: systemMetrics?.cpuPowerWatts ?? powerMetrics?.cpuPowerWatts,
            gpuPowerWatts: systemMetrics?.gpuPowerWatts ?? powerMetrics?.gpuPowerWatts,
            anePowerWatts: systemMetrics?.anePowerWatts ?? powerMetrics?.anePowerWatts,
            systemPowerWatts: systemMetrics?.systemPowerWatts ?? powerMetrics?.systemPowerWatts,
            gpuUsage: systemMetrics?.gpuUsage ?? powerMetrics?.gpuUsage,
            aneUsage: systemMetrics?.aneUsage ?? powerMetrics?.aneUsage,
            memoryReadGBps: systemMetrics?.memoryReadGBps ?? powerMetrics?.memoryReadGBps,
            memoryWriteGBps: systemMetrics?.memoryWriteGBps ?? powerMetrics?.memoryWriteGBps
        )
    }

    private var freshFileURL: URL? {
        fileURLs.first { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { return false }
            return Date().timeIntervalSince(date) < 15
        }
    }

    static func parse(text: String) -> EnhancedMetrics {
        let cpu = power(named: "CPU Power", in: text)
        let gpu = power(named: "GPU Power", in: text)
        let ane = power(named: "ANE Power", in: text)
        let combined = power(named: "Combined Power", in: text)
        let gpuUsage = lastNumber(patterns: [
            #"GPU active residency:\s*([0-9.]+)%"#,
            #"GPU HW active residency:\s*([0-9.]+)%"#
        ], in: text)
        let aneUsage = ane.map { min(100, max(0, $0 / 8 * 100)) }
        let memoryRead = bandwidth(patterns: [
            #"DRAM read bandwidth:\s*([0-9.]+)\s*(GB/s|MB/s)"#,
            #"Memory read bandwidth:\s*([0-9.]+)\s*(GB/s|MB/s)"#
        ], in: text)
        let memoryWrite = bandwidth(patterns: [
            #"DRAM write bandwidth:\s*([0-9.]+)\s*(GB/s|MB/s)"#,
            #"Memory write bandwidth:\s*([0-9.]+)\s*(GB/s|MB/s)"#
        ], in: text)

        return EnhancedMetrics(
            cpuPowerWatts: cpu,
            gpuPowerWatts: gpu,
            anePowerWatts: ane,
            systemPowerWatts: combined ?? [cpu, gpu, ane].compactMap { $0 }.reduce(0, +),
            gpuUsage: gpuUsage,
            aneUsage: aneUsage,
            memoryReadGBps: memoryRead,
            memoryWriteGBps: memoryWrite
        )
    }

    private static func power(named name: String, in text: String) -> Double? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = escaped + #"[^\n:]*:\s*([0-9.]+)\s*(mW|W)"#
        guard let match = lastMatch(pattern: pattern, in: text), match.count >= 3,
              let number = Double(match[1]) else { return nil }
        return match[2] == "mW" ? number / 1_000 : number
    }

    private static func bandwidth(patterns: [String], in text: String) -> Double? {
        for pattern in patterns {
            guard let match = lastMatch(pattern: pattern, in: text), match.count >= 3,
                  let number = Double(match[1]) else { continue }
            return match[2] == "MB/s" ? number / 1_000 : number
        }
        return nil
    }

    private static func lastNumber(patterns: [String], in text: String) -> Double? {
        for pattern in patterns {
            if let match = lastMatch(pattern: pattern, in: text), match.count >= 2,
               let value = Double(match[1]) { return value }
        }
        return nil
    }

    private static func lastMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let result = regex.matches(in: text, range: range).last else { return nil }
        return (0..<result.numberOfRanges).map { index in
            guard let swiftRange = Range(result.range(at: index), in: text) else { return "" }
            return String(text[swiftRange])
        }
    }
}
