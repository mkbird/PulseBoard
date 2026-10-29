import Foundation
import Testing
@testable import CliptoPulseCore
@testable import PulseBoard

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func process(_ pid: Int32 = 10, start: UInt64 = 1, cpu: Double? = 0, memory: Double? = 10) -> CMSProcessReading {
    CMSProcessReading(id: CMSProcessID(pid: pid, startTime: start), name: "cms_\(pid)", cpuSeconds: cpu, memoryBytes: memory)
}

private func sample(_ time: Double, _ processes: [CMSProcessReading] = [], complete: Bool = true, unreadable: Int = 0) -> CMSRawSnapshot {
    CMSRawSnapshot(timestamp: epoch.addingTimeInterval(time), monotonicSeconds: time, processes: processes,
                   enumerationValid: complete, unreadableCount: unreadable)
}

@Test func cmsTimeWeightedStatisticsUseActualIntervals() throws {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process(cpu: 0, memory: 10)]))
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.current == 10)
    #expect(session.snapshot.memory.average == nil)
    session.consume(sample(1, [process(cpu: 0.1, memory: 30)]))
    session.consume(sample(10, [process(cpu: 2.8, memory: 30)]))
    let result = session.snapshot
    #expect(abs(try #require(result.cpu.average) - 28) < 0.0001)
    #expect(abs(try #require(result.cpu.peak) - 30) < 0.0001)
    #expect(result.memory.average == 28) // Previous footprint held for each interval.
    #expect(result.memory.peak == 30)
    #expect(result.cpu.validDuration == 10)
    #expect(result.processes.first?.memory.average == result.memory.average)
}

@Test func cmsTotalsAggregateSimultaneousValuesAndAllowMulticoreCPU() throws {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process(1), process(2)]))
    session.consume(sample(1, [process(1, cpu: 2, memory: 100), process(2, cpu: 0, memory: 10)]))
    session.consume(sample(2, [process(1, cpu: 2, memory: 10), process(2, cpu: 2, memory: 100)]))
    let result = session.snapshot
    #expect(result.cpu.current == 200)
    #expect(result.cpu.peak == 200)
    #expect(result.processes.compactMap(\.cpu.peak).reduce(0, +) == 400)
    #expect(result.memory.current == 110)
    #expect(result.memory.peak == 110)
    #expect(result.processes.compactMap(\.memory.peak).reduce(0, +) == 200)
}

@Test func cmsNewAndExitedProcessesUseTheMonitoringSession() throws {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0))
    session.consume(sample(1))
    session.consume(sample(2, [process(cpu: 12, memory: 100)]))
    // Earlier CPU consumption must not leak into this session's first delta.
    #expect(session.snapshot.processes.first?.cpu.current == nil)
    session.consume(sample(3, [process(cpu: 13, memory: 100)]))
    #expect(session.snapshot.processes.first?.cpu.average == 50) // 1s absent + 1s measured.
    session.consume(sample(4))
    #expect(session.snapshot.cpu.current == 0) // No observed processes remain in this frame.
    #expect(session.snapshot.memory.current == 0)
    #expect(session.snapshot.processes.first?.state == .exited)
    #expect(session.snapshot.processes.first?.cpu.current == 0)
    session.consume(sample(5))
    let result = session.snapshot
    #expect(result.runningCount == 0)
    #expect(result.processes.count == 1)
    #expect(result.cpu.current == 0)
    #expect(abs(try #require(result.processes.first?.cpu.average) - 100.0 / 3) < 0.0001)
    #expect(result.processes.first?.cpu.peak == 100)
    #expect(result.memory.peak == 100)
}

@Test func cmsPIDReuseCreatesSeparateInstancesWithoutSpikes() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process(start: 1, cpu: 100)]))
    session.consume(sample(1, [process(start: 1, cpu: 101)]))
    session.consume(sample(2, [process(start: 2, cpu: 50)]))
    let rows = session.snapshot.processes
    #expect(rows.count == 2)
    #expect(rows.first { $0.id.startTime == 1 }?.state == .exited)
    #expect(rows.first { $0.id.startTime == 2 }?.cpu.current == nil)
    session.consume(sample(3, [process(start: 2, cpu: 50.5)]))
    #expect(session.snapshot.processes.first { $0.id.startTime == 2 }?.cpu.current == 50)
    #expect(session.snapshot.cpu.peak == 100)
}

@Test func cmsLegacyPartialReadsNeverBecomeCompleteTotalsOrFalseExits() {
    var session = CMSProcessSession(startedAt: epoch, statisticsVersion: 1)
    session.consume(sample(0, [process(1), process(2)]))
    session.consume(sample(1, [process(1, cpu: 1), process(2, cpu: nil, memory: nil)]))
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.current == nil)
    #expect(!session.snapshot.isComplete)
    #expect(session.snapshot.processes.first { $0.id.pid == 1 }?.cpu.current == 100)
    #expect(session.snapshot.processes.first { $0.id.pid == 2 }?.state == .unavailable)
    session.consume(sample(2, complete: false))
    #expect(session.snapshot.processes.allSatisfy { $0.state == .unavailable })
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.validDuration == 0)
    session.consume(sample(3, [process(1, cpu: 3), process(2, cpu: 3)]))
    #expect(session.snapshot.cpu.current == nil)
    session.consume(sample(4, [process(1, cpu: 4), process(2, cpu: 4)]))
    #expect(session.snapshot.cpu.current == 200)
    #expect(session.snapshot.cpu.validDuration == 1)
    #expect(session.snapshot.memory.validDuration == 1)
}

@Test func cmsLegacyUnidentifiableProcessesInvalidateGroupMembership() {
    var session = CMSProcessSession(startedAt: epoch, statisticsVersion: 1)
    session.consume(sample(0, [process()]))
    session.consume(sample(1, unreadable: 1))
    #expect(!session.snapshot.isComplete)
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.current == nil)
    #expect(session.snapshot.processes.first?.state == .unavailable)
}

@Test func cmsObservedTotalsIgnoreUnrelatedUnreadableProcesses() throws {
    var session = CMSProcessSession(startedAt: epoch)
    for tick in 0...2 {
        let readings = (1...8).map { pid in
            process(Int32(pid), cpu: Double(pid * tick) / 100, memory: Double(pid * (tick + 1) * 100))
        }
        session.consume(sample(Double(tick), readings, unreadable: 1))
    }
    let result = session.snapshot
    #expect(result.statisticsVersion == 2)
    #expect(result.isComplete)
    #expect(result.runningCount == 8)
    #expect(result.processes.count == 8)
    #expect(abs(try #require(result.cpu.current) - 36) < 0.0001)
    #expect(abs(try #require(result.cpu.average) - 36) < 0.0001)
    #expect(abs(try #require(result.cpu.peak) - 36) < 0.0001)
    #expect(abs(try #require(result.cpu.current) - result.processes.compactMap(\.cpu.current).reduce(0, +)) < 0.0001)
    #expect(result.memory.current == 10_800)
    #expect(result.memory.average == 5_400)
    #expect(result.memory.peak == 10_800)
    #expect(result.cpu.validDuration == 2)
    #expect(result.memory.validDuration == 2)
}

@Test func cmsObservedTotalsSumAvailableCPUAndMemoryIndependently() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process(1, memory: 10), process(2, memory: 20)], unreadable: 1))
    session.consume(sample(1, [process(1, cpu: 1, memory: nil), process(2, cpu: nil, memory: 40)], unreadable: 1))
    #expect(session.snapshot.isComplete)
    #expect(session.snapshot.cpu.current == 100)
    #expect(session.snapshot.cpu.average == 100)
    #expect(session.snapshot.memory.current == 40)
    #expect(session.snapshot.memory.average == 30)
    #expect(session.snapshot.processes.allSatisfy { $0.state == .unavailable })

    session.consume(sample(2, [process(1, cpu: 2, memory: 30), process(2, cpu: 2, memory: 50)], unreadable: 1))
    #expect(session.snapshot.cpu.current == 100) // Process 2 needs its own fresh CPU baseline.
    #expect(session.snapshot.cpu.average == 100)
    #expect(session.snapshot.memory.current == 80)
    #expect(session.snapshot.memory.average == 35)
    #expect(session.snapshot.memory.peak == 80)
    #expect(session.snapshot.cpu.validDuration == 2)
    #expect(session.snapshot.memory.validDuration == 2)
}

@Test func cmsObservedTotalsKeepAllMissingReadingsUnknown() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process(cpu: nil, memory: nil)], unreadable: 1))
    session.consume(sample(1, [process(cpu: nil, memory: nil)], unreadable: 1))
    #expect(session.snapshot.isComplete) // The list was read; the individual row failed.
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.cpu.average == nil)
    #expect(session.snapshot.cpu.peak == nil)
    #expect(session.snapshot.memory.current == nil)
    #expect(session.snapshot.memory.average == nil)
    #expect(session.snapshot.memory.peak == nil)
    #expect(session.snapshot.cpu.validDuration == 0)
    #expect(session.snapshot.memory.validDuration == 0)
}

@Test func cmsObservedEmptyFramesAreZeroWithoutInventingProcessExits() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process()], unreadable: 1))
    session.consume(sample(1, unreadable: 1))
    #expect(session.snapshot.isComplete)
    #expect(session.snapshot.runningCount == 0)
    #expect(session.snapshot.cpu.current == 0)
    #expect(session.snapshot.memory.current == 0)
    #expect(session.snapshot.processes.first?.state == .unavailable)
    #expect(session.snapshot.processes.first?.cpu.current == nil)
    #expect(session.snapshot.processes.first?.memory.current == nil)
}

@Test func cmsObservedEnumerationFailureDoesNotReuseRowsOrRecordZero() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process()], unreadable: 1))
    session.consume(sample(1, [process(cpu: 1)], unreadable: 1))
    session.consume(sample(2, complete: false))
    #expect(!session.snapshot.isComplete)
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.current == nil)
    #expect(session.snapshot.cpu.average == 100)
    #expect(session.snapshot.cpu.peak == 100)
    #expect(session.snapshot.cpu.validDuration == 1)
    #expect(session.snapshot.memory.validDuration == 1)
    #expect(session.snapshot.processes.first?.state == .unavailable)
    session.consume(sample(3))
    #expect(session.snapshot.cpu.current == 0)
    #expect(session.snapshot.memory.current == 0)
    #expect(session.snapshot.cpu.validDuration == 1) // Do not bridge the failed frame.
    #expect(session.snapshot.memory.validDuration == 1)
}

@Test func cmsLegacyExitFramesRetainOriginalStrictTotals() {
    var session = CMSProcessSession(startedAt: epoch, statisticsVersion: 1)
    session.consume(sample(0, [process()]))
    session.consume(sample(1, [process(cpu: 1)]))
    session.consume(sample(2))
    #expect(session.snapshot.statisticsVersion == 1)
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.current == 0)
    session.consume(sample(3))
    #expect(session.snapshot.cpu.current == 0)
}

@Test func cmsSleepAndLongGapsRebaselineWithoutClearingSession() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process()]))
    session.consume(sample(1, [process(cpu: 1)]))
    session.suspend()
    #expect(session.snapshot.isSuspended)
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.cpu.peak == 100)
    session.consume(sample(1_000, [process(cpu: 500, memory: 50)]))
    #expect(!session.snapshot.isSuspended)
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.validDuration == 1)
    session.consume(sample(1_001, [process(cpu: 500.5, memory: 50)]))
    #expect(session.snapshot.cpu.average == 75)
    #expect(session.snapshot.memory.average == 30)
    session.consume(sample(2_000, [process(cpu: 600, memory: 50)]))
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.cpu.validDuration == 2)
    #expect(session.snapshot.memory.validDuration == 2)
}

@Test func cmsCounterResetsAndInvalidReadingsDoNotCreateSpikes() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process(cpu: 10)]))
    session.consume(sample(1, [process(cpu: 1, memory: .infinity)]))
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.current == nil)
    session.consume(sample(2, [process(cpu: 1.1, memory: 10)]))
    #expect((session.snapshot.cpu.current ?? 1000) < 11)
    #expect(session.snapshot.memory.validDuration == 0)
}

@Test func cmsStatisticsUseMonotonicTimeNotWallClock() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process()]))
    session.consume(CMSRawSnapshot(timestamp: epoch.addingTimeInterval(-3_600), monotonicSeconds: 1,
                                  processes: [process(cpu: 1)], enumerationValid: true, unreadableCount: 0))
    #expect(session.snapshot.cpu.current == 100)
    #expect(session.snapshot.cpu.validDuration == 1)
}

@Test func cmsLocalizationsAreAvailable() {
    for language in ["en", "zh-Hans"] {
        for key in ["cms.title", "cms.statistics_note", "cms.total_scope", "cms.state_exited", "cms.read_failed", "cms.average"] {
            #expect(L10n.text(key, language: language) != key)
        }
    }
}
