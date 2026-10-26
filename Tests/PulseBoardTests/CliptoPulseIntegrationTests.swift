import Foundation
import SQLite3
import Testing
@testable import PulseBoard

@Test func dagscAnalyzerSplitsMultiDayBatchesAndCalculatesAccurateSpeedup() throws {
    try SelfTestSuite.verifyDAGSCBatchAndDaySlicing()
}

@Test func alignedHardwareAndMarkdownReportGeneration() throws {
    try SelfTestSuite.verifyAlignedHardwareAndMarkdownReport()
}
