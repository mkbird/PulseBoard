import Foundation
import Testing
@testable import PulseBoard

@Test func cmsCSVPreservesProcessIdentityMissingValuesAndQuotedNames() throws {
    let firstID = CMSProcessID(pid: 42, startTime: 1_800_000_000_123_456)
    let secondID = CMSProcessID(pid: 42, startTime: 1_800_000_000_654_321)
    let name = "CMS, \"quoted\"\nworker"
    let frame = cmsExportFrame(processes: [
        CMSProcessReading(id: firstID, name: name, cpuSeconds: 123.456789123, memoryBytes: 2_147_483_648),
        CMSProcessReading(id: secondID, name: "cms-unavailable", cpuSeconds: nil, memoryBytes: nil)
    ], enumerationValid: false, unreadableCount: 1, processCPU: [firstID: 205.25])

    let csv = CMSCSVExporter.csv(frames: [frame])
    let rows = try cmsExportRows(csv)
    #expect(rows.count == 3)
    #expect(rows[0]["row_type"] == "total")
    #expect(rows[0]["cpu_percent"] == "")
    #expect(rows[0]["memory_bytes"] == "")
    #expect(rows[0]["pid"] == "")
    #expect(rows[1]["row_type"] == "process")
    #expect(rows[1]["process_name"] == name)
    #expect(csv.contains("\"CMS, \"\"quoted\"\"\nworker\""))
    #expect(rows[1]["pid"] == "42")
    #expect(rows[1]["process_start_time_us"] == "1800000000123456")
    #expect(rows[2]["process_start_time_us"] == "1800000000654321")
    #expect(rows[1]["cpu_percent"] == "205.25")
    #expect(rows[1]["cpu_seconds"].flatMap(Double.init) == 123.456789123)
    #expect(rows[2]["cpu_percent"] == "")
    #expect(rows[2]["memory_bytes"] == "")
    #expect(rows[2]["cpu_seconds"] == "")
    #expect(rows.allSatisfy { $0["enumeration_valid"] == "false" && $0["unreadable_count"] == "1" })
}

@Test func cmsCSVEmptyFramesStillExportTotalsAndReconstructionMetadata() throws {
    let frame = cmsExportFrame(totalCPU: 0, totalMemory: 0)
    let rows = try cmsExportRows(CMSCSVExporter.csv(frames: [frame]))
    let total = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(total["row_type"] == "total")
    #expect(total["cpu_percent"].flatMap(Double.init) == 0)
    #expect(total["memory_bytes"].flatMap(Double.init) == 0)
    #expect(total["cpu_seconds"] == "")
    #expect(total["session_id"] == frame.sessionID)
    #expect(total["sequence"] == "18")
    #expect(total["segment"] == "3")
    #expect(total["maximum_gap_seconds"].flatMap(Double.init) == 12.5)
    #expect(total["monotonic_seconds"].flatMap(Double.init) == frame.raw.monotonicSeconds)
    #expect(total["timestamp_unix_seconds"].flatMap(Double.init) == frame.raw.timestamp.timeIntervalSince1970)
    #expect(total["session_started_unix_seconds"].flatMap(Double.init) == frame.sessionStartedAt.timeIntervalSince1970)
    #expect(total["timestamp"] == "2027-01-15T08:00:00.123Z")
    #expect(total["enumeration_valid"] == "true")
    #expect(total["unreadable_count"] == "0")
}

@Test func cmsCSVNoFramesProducesHeaderAndNonfiniteReadingsStayMissing() throws {
    #expect(try cmsExportRows(CMSCSVExporter.csv(frames: [])).isEmpty)
    let rows = try cmsExportRows(CMSCSVExporter.csv(frames: [cmsExportFrame(totalCPU: .nan, totalMemory: .infinity)]))
    #expect(rows.first?["cpu_percent"] == "")
    #expect(rows.first?["memory_bytes"] == "")
    #expect(L10n.text("cms.export_history", language: "en") == "Export CMS history")
    #expect(L10n.text("cms.export_history", language: "zh-Hans") == "导出 CMS 历史")
}

@Test func cmsCSVPagesConcatenateWithoutDuplicateHeaders() {
    let first = cmsExportFrame()
    let second = cmsExportFrame(totalCPU: 0, totalMemory: 0)
    let paged = CMSCSVExporter.csv(frames: [first])
        + CMSCSVExporter.csv(frames: [second], includeHeader: false)
    #expect(paged == CMSCSVExporter.csv(frames: [first, second]))
    #expect(CMSCSVExporter.csv(frames: [], includeHeader: false).isEmpty)
}

private func cmsExportFrame(
    processes: [CMSProcessReading] = [], enumerationValid: Bool = true, unreadableCount: Int = 0,
    totalCPU: Double? = nil, totalMemory: Double? = nil, processCPU: [CMSProcessID: Double] = [:]
) -> CMSHistoryFrame {
    CMSHistoryFrame(
        sessionID: "session,\"export\"", sessionStartedAt: Date(timeIntervalSince1970: 1_799_999_000.987654),
        sequence: 18, segment: 3, maximumGap: 12.5,
        raw: CMSRawSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000.123456), monotonicSeconds: 987.123456789,
            processes: processes, enumerationValid: enumerationValid, unreadableCount: unreadableCount
        ), totalCPUPercent: totalCPU, totalMemoryBytes: totalMemory, processCPUPercent: processCPU
    )
}

/// Parse independently so assertions cover column alignment and embedded line breaks.
private func cmsExportRows(_ csv: String) throws -> [[String: String]] {
    let characters = Array(csv)
    var records: [[String]] = []
    var record: [String] = []
    var field = ""
    var quoted = false
    var index = 0
    while index < characters.count {
        let character = characters[index]
        if character == "\"" {
            if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                field.append("\"")
                index += 1
            } else {
                quoted.toggle()
            }
        } else if character == ",", !quoted {
            record.append(field)
            field = ""
        } else if character == "\n", !quoted {
            record.append(field)
            records.append(record)
            record = []
            field = ""
        } else {
            field.append(character)
        }
        index += 1
    }
    #expect(!quoted)
    if !record.isEmpty || !field.isEmpty { records.append(record + [field]) }
    let header = try #require(records.first)
    #expect(header.count == 18)
    #expect(Set(header).count == header.count)
    return try records.dropFirst().map { values in
        try #require(values.count == header.count)
        return Dictionary(uniqueKeysWithValues: zip(header, values))
    }
}
