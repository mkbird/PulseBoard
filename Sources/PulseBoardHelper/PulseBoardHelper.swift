import Darwin
import Foundation

@main
enum PulseBoardHelper {
    private static let supportDirectory = URL(fileURLWithPath: "/Library/Application Support/PulseBoard", isDirectory: true)
    private static let destination = supportDirectory.appendingPathComponent("powermetrics.txt")
    private static let processDestination = supportDirectory.appendingPathComponent("processmetrics.plist")

    static func main() {
        do {
            try prepareDirectory()
        } catch {
            FileHandle.standardError.write(Data("PulseBoardHelper: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }

        while true {
            autoreleasepool {
                collectOneSample()
                collectProcessSample()
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: supportDirectory.path)
    }

    private static func collectOneSample() {
        let temporary = supportDirectory.appendingPathComponent("powermetrics-\(getpid()).tmp")
        try? FileManager.default.removeItem(at: temporary)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = [
            "--samplers", "cpu_power,gpu_power,ane_power",
            "--show-extra-power-info",
            "--sample-count", "1",
            "--sample-rate", "1000",
            "--buffer-size", "1",
            "--output-file", temporary.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: temporary.path) else {
                try? FileManager.default.removeItem(at: temporary)
                Thread.sleep(forTimeInterval: 2)
                return
            }

            chmod(temporary.path, 0o644)
            let result = temporary.path.withCString { source in
                destination.path.withCString { target in rename(source, target) }
            }
            if result != 0 { try? FileManager.default.removeItem(at: temporary) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            Thread.sleep(forTimeInterval: 2)
        }
    }

    private static func collectProcessSample() {
        let temporary = supportDirectory.appendingPathComponent("processmetrics-\(getpid()).tmp")
        try? FileManager.default.removeItem(at: temporary)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = [
            "--samplers", "tasks",
            "--show-process-gpu",
            "--show-process-netstats",
            "--show-process-energy",
            "--show-process-samp-norm",
            "--handle-invalid-values",
            "--format", "plist",
            "--sample-count", "1",
            "--sample-rate", "1000",
            "--buffer-size", "1",
            "--output-file", temporary.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: temporary.path) else {
                try? FileManager.default.removeItem(at: temporary)
                return
            }
            chmod(temporary.path, 0o644)
            let result = temporary.path.withCString { source in
                processDestination.path.withCString { target in rename(source, target) }
            }
            if result != 0 { try? FileManager.default.removeItem(at: temporary) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
