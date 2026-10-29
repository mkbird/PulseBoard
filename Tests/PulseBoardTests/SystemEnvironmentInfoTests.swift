import Foundation
@testable import PulseBoard
import XCTest

final class SystemEnvironmentInfoTests: XCTestCase {
    func testLegacyEnvironmentJSONDecodesAndReencodesWithBothContracts() throws {
        let legacyJSON = #"""
        {
          "chip_model": "Apple M4",
          "physical_memory_bytes": 17179869184,
          "physical_memory_text": "16 GB",
          "logical_cores": 10,
          "macos_version": "macOS 15.1.2",
          "hostname": "test-host",
          "username": "tester",
          "lan_ips": ["192.168.1.8"],
          "web_port": 8766,
          "default_dagsc_dir": "/tmp/dagsc/",
          "history_db_path": "/tmp/history.sqlite",
          "history_db_size_bytes": 42
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SystemEnvironmentInfo.self, from: legacyJSON)
        XCTAssertEqual(decoded.platform, "macos")
        XCTAssertEqual(decoded.osName, "macOS")
        XCTAssertEqual(decoded.osVersion, "15.1.2")
        XCTAssertEqual(decoded.displayOSVersion, "macOS 15.1.2")
        XCTAssertTrue(decoded.metricCapabilities.systemGPU)
        XCTAssertEqual(decoded.metricSemantics.processMemory, "phys_footprint")

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertEqual(encoded?["platform"] as? String, "macos")
        XCTAssertEqual(encoded?["os_name"] as? String, "macOS")
        XCTAssertEqual(encoded?["os_version"] as? String, "15.1.2")
        XCTAssertEqual(encoded?["macos_version"] as? String, "macOS 15.1.2")
        XCTAssertNotNil(encoded?["metric_capabilities"])
        XCTAssertNotNil(encoded?["metric_semantics"])
    }

    func testGenericEnvironmentRoundTripsWithoutInventingMacCapabilities() throws {
        let source = SystemEnvironmentInfo(
            platform: "windows",
            osName: "Windows",
            osVersion: "11 24H2",
            chipModel: "Example CPU",
            physicalMemoryBytes: 32 * 1_024 * 1_024 * 1_024,
            physicalMemoryText: "32 GB",
            logicalCores: 16,
            hostname: "test-pc",
            username: "tester",
            lanIPs: [],
            webPort: 8766,
            defaultDagscDir: "C:\\Clipto\\dagsc_data\\",
            historyDBPath: "C:\\CliptoPulse\\history.sqlite",
            historyDBSizeBytes: 0,
            metricCapabilities: .generic,
            metricSemantics: .generic
        )

        let decoded = try JSONDecoder().decode(
            SystemEnvironmentInfo.self,
            from: JSONEncoder().encode(source)
        )

        XCTAssertEqual(decoded.platform, "windows")
        XCTAssertEqual(decoded.osName, "Windows")
        XCTAssertEqual(decoded.osVersion, "11 24H2")
        XCTAssertEqual(decoded.displayOSVersion, "Windows 11 24H2")
        XCTAssertFalse(decoded.metricCapabilities.systemGPU)
        XCTAssertFalse(decoded.metricCapabilities.power)
        XCTAssertEqual(decoded.metricSemantics.processMemory, "平台原生进程内存口径")
    }
}
