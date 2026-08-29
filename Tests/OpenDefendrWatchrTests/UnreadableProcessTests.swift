import XCTest

@testable import OpenDefendrWatchrKit

/// Regression tests for the 2026-08-28 blind window.
///
/// Between 03:53 and 07:57 the process table was exhausted machine-wide (796 failed
/// spawns across four unrelated applications). Reading `wdavdaemon`'s RSS requires
/// spawning setuid-root `/bin/ps`, so every one of those ticks failed — and the app
/// responded by writing nothing at all. The result was a 221-minute hole in the CSV that
/// is indistinguishable from the app being dead, which is exactly how a 30-hour outage
/// went unnoticed later. These tests pin the three properties that make the blindness
/// visible instead of silent.
final class UnreadableProcessTests: XCTestCase {

    private struct ThrowingProcessReader: ProcessMemoryReading {
        let error: Error
        func usage(forExecutableNamed name: String) throws -> ProcessMemoryUsage? {
            throw error
        }
    }

    private struct StubSystemReader: SystemMemoryReading {
        let usage: SystemMemoryUsage
        func read() throws -> SystemMemoryUsage { usage }
    }

    private struct StubStallProbe: SystemStallProbing {
        let reading: StallReading
        func measure() -> StallReading? { reading }
    }

    // MARK: - The sampler keeps what it managed to measure

    /// A failed `ps` spawn must not discard the two readings that never needed a fork.
    /// Losing them is what made the app blind to the *machine* as well as to Defender,
    /// precisely when the machine was the thing in trouble.
    func testForkFailureKeepsTheForkFreeReadings() throws {
        let sampler = DefenderMemorySampler(
            processReader: ThrowingProcessReader(
                error: CommandSpawnError.resourceUnavailable(executable: "/bin/ps")),
            systemReader: StubSystemReader(usage: Fixture.pressuredSystem),
            stallProbe: StubStallProbe(reading: Fixture.stalledFilesystem),
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let sample = try sampler.sample()

        XCTAssertFalse(sample.isProcessReadable)
        XCTAssertEqual(sample.system.freeBytes, Fixture.pressuredSystem.freeBytes)
        XCTAssertEqual(sample.stall?.medianSeconds, Fixture.stalledFilesystem.medianSeconds)
    }

    /// EAGAIN is the process-table-exhaustion signal. It has to reach the log by name,
    /// because that condition is itself the more valuable finding when it occurs.
    func testExhaustedProcessTableIsNamedInTheReason() throws {
        let sampler = DefenderMemorySampler(
            processReader: ThrowingProcessReader(
                error: CommandSpawnError.resourceUnavailable(executable: "/bin/ps")),
            systemReader: StubSystemReader(usage: Fixture.healthySystem),
            stallProbe: StubStallProbe(reading: Fixture.healthyStall),
            clock: { Date(timeIntervalSince1970: 0) }
        )

        let reason = try XCTUnwrap(sampler.sample().processUnreadableReason)
        XCTAssertTrue(
            reason.lowercased().contains("process table"),
            "reason should name the condition, got: \(reason)")
        XCTAssertTrue(reason.contains("EAGAIN"), "reason should keep the errno, got: \(reason)")
    }

    // MARK: - Unreadable is not the same as absent

    /// Constraint: "not running" is a distinct state and must never be faked. Reporting an
    /// unmeasurable process as absent is the same class of lie as reporting it as `0 B`.
    func testUnreadableIsNotReportedAsNotRunning() {
        let blind = Fixture.unreadableSample()
        let absent = Fixture.sample(bytes: nil)

        XCTAssertFalse(blind.isProcessRunning)
        XCTAssertFalse(absent.isProcessRunning)
        XCTAssertNotNil(blind.processUnreadableReason)
        XCTAssertNil(absent.processUnreadableReason)
        XCTAssertNotEqual(blind.readout, absent.readout)
    }

    /// A measurement that could not be taken must not manufacture an alert, but the
    /// machine verdicts still have to come through unchanged.
    func testUnreadableProcessNeitherAlarmsNorMasksTheMachine() {
        let evaluator = SeverityEvaluator()
        let calm = Fixture.unreadableSample(system: Fixture.healthySystem, stall: Fixture.healthyStall)
        XCTAssertEqual(evaluator.severity(for: calm, thresholds: Thresholds()), .normal)

        let stalled = Fixture.unreadableSample(
            system: Fixture.healthySystem, stall: Fixture.stalledFilesystem)
        XCTAssertEqual(evaluator.severity(for: stalled, thresholds: Thresholds()), .critical)
    }

    // MARK: - The blindness reaches the log and the menu bar

    /// The whole point: a blind tick still produces a row. A gap in the CSV means the app
    /// is gone; it must never also mean "the app is running but could not see".
    func testBlindTickStillWritesADistinguishableRow() {
        let row = SampleCSVLog.row(
            sample: Fixture.unreadableSample(),
            severity: .normal,
            processName: "wdavdaemon",
            formatter: ISO8601DateFormatter()
        )
        let fields = row.components(separatedBy: ",")

        XCTAssertEqual(fields.count, SampleCSVLog.header.components(separatedBy: ",").count)
        XCTAssertEqual(fields[2], "", "no RSS may be invented for a reading that failed")
        XCTAssertTrue(fields[3].hasPrefix("unreadable:"), "got: \(fields[3])")
        XCTAssertNotEqual(fields[3], "not running")
    }

    /// Free-form failure text must not be able to shift every later column.
    func testReasonCannotBreakTheColumnCount() {
        let row = SampleCSVLog.row(
            sample: Fixture.unreadableSample(reason: "spawn failed: a, b\nc"),
            severity: .normal,
            processName: "wdavdaemon",
            formatter: ISO8601DateFormatter()
        )
        XCTAssertEqual(
            row.components(separatedBy: ",").count,
            SampleCSVLog.header.components(separatedBy: ",").count)
        XCTAssertFalse(row.contains("\n"))
    }
}
