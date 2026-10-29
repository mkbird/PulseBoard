import Darwin
import Foundation

enum SystemEnvironmentService {
    static let cliptoDagscRelativeSuffix = "Library/Application Support/com.clipto.mac/dagsc_data"

    static func current(webPort: Int, historyDBURL: URL) -> SystemEnvironmentInfo {
        let chip = sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "Apple Silicon"
        let memBytes = ProcessInfo.processInfo.physicalMemory
        let memGB = Double(memBytes) / (1024 * 1024 * 1024)
        let memText = memGB.rounded() == memGB ? String(format: "%.0f GB", memGB) : String(format: "%.1f GB", memGB)
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let macOS = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"
        let hostname = ProcessInfo.processInfo.hostName
        let (username, defaultDir) = detectUserAndDefaultDagscDir()
        let dbSize: Int64 = {
            var total: Int64 = 0
            for suffix in ["", "-wal", "-shm"] {
                let p = suffix.isEmpty ? historyDBURL.path : historyDBURL.path + suffix
                if let attrs = try? FileManager.default.attributesOfItem(atPath: p),
                   let size = attrs[.size] as? NSNumber {
                    total += size.int64Value
                }
            }
            return total
        }()

        return SystemEnvironmentInfo(
            platform: "macos",
            osName: "macOS",
            osVersion: macOS,
            chipModel: chip,
            physicalMemoryBytes: memBytes,
            physicalMemoryText: memText,
            logicalCores: cores,
            hostname: hostname,
            username: username,
            lanIPs: lanIPv4Addresses(),
            webPort: webPort,
            defaultDagscDir: defaultDir,
            historyDBPath: historyDBURL.path,
            historyDBSizeBytes: dbSize,
            metricCapabilities: .macOS,
            metricSemantics: .macOS
        )
    }

    static func detectUserAndDefaultDagscDir() -> (username: String, defaultDir: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let parts = home.pathComponents
        var username = ""
        if parts.count >= 3, parts[0] == "/", parts[1] == "Users" {
            username = parts[2]
        }
        if username.isEmpty {
            username = NSUserName()
        }
        let userHome = username.isEmpty ? home : URL(fileURLWithPath: "/Users/\(username)", isDirectory: true)
        let dir = userHome.appendingPathComponent(cliptoDagscRelativeSuffix, isDirectory: true).path + "/"
        return (username, dir)
    }

    static func lanIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var ips: [String] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = current {
            let item = iface.pointee
            let flags = Int32(item.ifa_flags)
            if let addr = item.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) != 0,
               (flags & IFF_LOOPBACK) == 0 {
                var hostBuffer = [UInt8](repeating: 0, count: Int(NI_MAXHOST))
                let ok = hostBuffer.withUnsafeMutableBytes { rawBuf -> Int32 in
                    guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
                    return getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        base,
                        socklen_t(rawBuf.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                }
                if ok == 0 {
                    let ip = String(decoding: hostBuffer.prefix { $0 != 0 }, as: UTF8.self)
                    let name = String(cString: item.ifa_name)
                    if !ip.hasPrefix("127."), !ip.hasPrefix("169.254."), !ips.contains(ip) {
                        if name.hasPrefix("en") {
                            ips.insert(ip, at: 0)
                        } else {
                            ips.append(ip)
                        }
                    }
                }
            }
            current = item.ifa_next
        }
        return ips
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
