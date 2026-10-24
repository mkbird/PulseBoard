import Foundation
import Testing
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
    #expect(session.snapshot.cpu.current == nil) // The exiting process's tail is unknown.
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

@Test func cmsPartialReadsNeverBecomeCompleteTotalsOrFalseExits() {
    var session = CMSProcessSession(startedAt: epoch)
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

@Test func cmsUnidentifiableProcessesInvalidateGroupMembership() {
    var session = CMSProcessSession(startedAt: epoch)
    session.consume(sample(0, [process()]))
    session.consume(sample(1, unreadable: 1))
    #expect(!session.snapshot.isComplete)
    #expect(session.snapshot.cpu.current == nil)
    #expect(session.snapshot.memory.current == nil)
    #expect(session.snapshot.processes.first?.state == .unavailable)
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
        for key in ["cms.title", "cms.statistics_note", "cms.state_exited", "cms.incomplete", "cms.average"] {
            #expect(L10n.text(key, language: language) != key)
        }
    }
}
