import Foundation

/// Measures how much disk space Clipto's data directory occupies on the user's Mac
/// (`~/Library/Application Support/com.clipto.mac`). Uses allocated (on-disk) size, like Finder/du.
struct StorageSnapshot: Codable, Sendable, Equatable {
    let timestamp: Date
    let path: String
    let allocatedBytes: Double
    let fileCount: Int
    /// Top-level children of the directory → allocated bytes (largest first in reports).
    let breakdown: [String: Double]
}

enum StorageScanner {
    /// `~/Library/Application Support/com.clipto.mac` (parent of the default `dagsc_data`).
    static var cliptoDataDirectory: URL {
        let (_, dagscDir) = SystemEnvironmentService.detectUserAndDefaultDagscDir()
        return URL(fileURLWithPath: dagscDir).standardizedFileURL.deletingLastPathComponent()
    }

    /// Walks the directory tree once. Symlinks are not followed; unreadable entries are skipped.
    static func scan(_ root: URL = cliptoDataDirectory) -> StorageSnapshot? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return nil }

        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        var breakdown: [String: Double] = [:]
        var total: Double = 0
        var files = 0

        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [])) ?? []
        for child in children {
            var childBytes: Double = 0
            let (bytes, count) = size(of: child, keys: keys)
            childBytes += bytes
            files += count
            total += childBytes
            breakdown[child.lastPathComponent] = childBytes
        }
        return StorageSnapshot(timestamp: Date(), path: root.path, allocatedBytes: total, fileCount: files, breakdown: breakdown)
    }

    private static func size(of url: URL, keys: [URLResourceKey]) -> (Double, Int) {
        let fm = FileManager.default
        func allocated(_ u: URL) -> (Double, Bool) {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return (0, false) }
            guard v.isRegularFile == true else { return (0, false) }
            return (Double(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0), true)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, 0) }
        if !isDir.boolValue {
            let (b, isFile) = allocated(url)
            return (b, isFile ? 1 : 0)
        }
        var total: Double = 0
        var count = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) {
            for case let u as URL in e {
                let (b, isFile) = allocated(u)
                if isFile { total += b; count += 1 }
            }
        }
        return (total, count)
    }
}
