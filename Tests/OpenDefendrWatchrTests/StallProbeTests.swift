import XCTest

@testable import OpenDefendrWatchrKit

/// The stall probe is the only signal in this app that would have caught the 2026-08-22
/// evening kernel panic, so it gets tested against a real filesystem rather than only
/// through fixtures.
final class FileOpenStallProbeTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stall-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testProbeMeasuresRealAndPlausibleLatency() throws {
        let probe = FileOpenStallProbe(directory: directory, iterations: 50)
        let reading = try XCTUnwrap(probe.measure())

        XCTAssertEqual(reading.sampleCount, 50)
        // A warm open on a healthy machine is microseconds. Anything at or above the
        // warning threshold here would mean the probe is measuring its own overhead
        // instead of kernel authorisation latency, which would make it useless.
        XCTAssertGreaterThan(reading.medianSeconds, 0)
        XCTAssertLessThan(reading.medianSeconds, StallThresholds.defaultWarningSeconds)
        XCTAssertGreaterThanOrEqual(reading.worstSeconds, reading.medianSeconds)
    }

    func testProbeCreatesItsOwnTargetAndIsRepeatable() throws {
        let probe = FileOpenStallProbe(directory: directory, iterations: 10)
        XCTAssertNotNil(probe.measure())
        // Second run must reuse the file rather than depend on any external state.
        XCTAssertNotNil(probe.measure())
        let created = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(created, ["com.opendefendrwatchr.stallprobe"])
    }

    func testProbeReturnsNilWhenItCannotMeasure() {
        // A non-existent, non-creatable directory yields no data. Reporting a fast reading
        // here would silently disable the alarm.
        let unusable = URL(fileURLWithPath: "/dev/null/nowhere", isDirectory: true)
        XCTAssertNil(FileOpenStallProbe(directory: unusable).measure())
    }

    func testIterationCountIsClampedToSomethingMeasurable() throws {
        // A median over one sample is noise; the probe must refuse to be configured that way.
        let reading = try XCTUnwrap(
            FileOpenStallProbe(directory: directory, iterations: 1).measure())
        XCTAssertGreaterThanOrEqual(reading.sampleCount, 3)
    }
}

final class StallThresholdsTests: XCTestCase {
    func testCriticalNeverSitsBelowWarning() {
        // Otherwise the warning band is unreachable and the user only ever sees critical.
        let thresholds = StallThresholds(warningSeconds: 0.5, criticalSeconds: 0.1)
        XCTAssertEqual(thresholds.criticalSeconds, 0.5)
    }
}

/// A sustained stall must notify once, not once per poll. With the process innocent, the
/// byte-based re-arm would otherwise be satisfied on every single tick.
final class StallNotificationStormTests: XCTestCase {
    func testASustainedStallNotifiesOnlyOnce() {
        var monitor = ThresholdMonitor()
        var alerts: [ThresholdAlert] = []

        for tick in 0..<40 {
            let sample = Fixture.sample(
                bytes: 55_690_000,
                system: Fixture.prePanicSystem,
                stall: Fixture.stalledFilesystem,
                at: TimeInterval(tick) * 30
            )
            if let alert = monitor.evaluate(sample) { alerts.append(alert) }
        }

        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.severity, .critical)
        XCTAssertEqual(alerts.first?.cause, .systemStall)
    }

    func testRecoveryRearmsSoASecondStallIsReported() {
        var monitor = ThresholdMonitor()
        var alerts: [ThresholdAlert] = []

        func feed(_ stall: StallReading?, times: Int) {
            for _ in 0..<times {
                let sample = Fixture.sample(
                    bytes: 55_690_000, system: Fixture.prePanicSystem, stall: stall)
                if let alert = monitor.evaluate(sample) { alerts.append(alert) }
            }
        }

        feed(Fixture.stalledFilesystem, times: 5)
        feed(Fixture.healthyStall, times: 5)
        feed(Fixture.stalledFilesystem, times: 5)

        XCTAssertEqual(alerts.count, 2)
        XCTAssertTrue(alerts.allSatisfy { $0.cause == .systemStall })
    }
}

final class StallAlertWordingTests: XCTestCase {
    private func alert(_ stall: StallReading) -> ThresholdAlert {
        ThresholdAlert(
            severity: .critical,
            sample: Fixture.sample(
                bytes: 55_690_000, system: Fixture.prePanicSystem, stall: stall),
            thresholdBytes: Thresholds.defaultCriticalBytes,
            cause: .systemStall
        )
    }

    func testStallAlertNamesTheRealFaultAndDoesNotBlameMemory() {
        let body = AlertPresentation.body(
            for: alert(Fixture.stalledFilesystem), processName: "wdavdaemon")
        XCTAssertTrue(body.contains("Endpoint Security"))
        XCTAssertTrue(body.contains("not a memory problem"))
        // The measured latency has to be in the text; "something is slow" is not evidence.
        XCTAssertTrue(body.contains("1.8 s"))
        XCTAssertTrue(body.contains("Save your work"))
    }

    func testStallAlertTitleIsDistinctFromTheMemoryTitles() {
        let stallTitle = AlertPresentation.title(
            for: alert(Fixture.stalledFilesystem), processName: "wdavdaemon")
        XCTAssertEqual(stallTitle, "System is stalling")
        XCTAssertFalse(stallTitle.contains("memory"))
    }

    func testDurationIsReadableAcrossTheWholeRange() {
        XCTAssertEqual(AlertPresentation.duration(0.0000085), "8 µs")
        XCTAssertEqual(AlertPresentation.duration(0.030), "30 ms")
        XCTAssertEqual(AlertPresentation.duration(1.8), "1.8 s")
    }
}
