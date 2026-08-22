import XCTest

@testable import OpenDefendrWatchrKit

final class SeverityEvaluatorTests: XCTestCase {
    private let thresholds = Thresholds()  // 8 GB warning / 12 GB critical
    private let evaluator = SeverityEvaluator()

    func testClassifiesByProcessSizeOnAHealthyMachine() {
        XCTAssertEqual(severity(bytes: 100 * 1024 * 1024), .normal)
        XCTAssertEqual(severity(bytes: 8 * Fixture.gb - 1), .normal)
        XCTAssertEqual(severity(bytes: 8 * Fixture.gb), .warning)
        XCTAssertEqual(severity(bytes: 12 * Fixture.gb - 1), .warning)
        XCTAssertEqual(severity(bytes: 12 * Fixture.gb), .critical)
        XCTAssertEqual(severity(bytes: 18 * Fixture.gb), .critical)
    }

    func testWarningEscalatesToCriticalWhenTheMachineIsUnderPressure() {
        // Same process size, different machine state: 9 GB is "warning" on a healthy box
        // but "critical" when the kernel is already reporting pressure, as at 06:40.
        XCTAssertEqual(severity(bytes: 9 * Fixture.gb, system: Fixture.healthySystem), .warning)
        XCTAssertEqual(severity(bytes: 9 * Fixture.gb, system: Fixture.jetsamSystem), .critical)
    }

    func testSystemPressureAlarmsEvenWhenTheWatchedProcessIsInnocent() {
        // Regression test for the 22:43 WindowServer watchdog panic: wdavdaemon sat at
        // 55.69 MB while the machine died. Anchoring severity to the watched process meant
        // the app logged "normal" for all 1260 samples up to 70 seconds before the panic.
        let sample = Fixture.sample(bytes: 55_690_000, system: Fixture.prePanicSystem)
        XCTAssertEqual(evaluator.severity(for: sample, thresholds: thresholds), .critical)
        XCTAssertEqual(evaluator.cause(for: sample, thresholds: thresholds), .systemPressure)
    }

    func testOrdinaryLowFreeMemoryIsNotAnAlarm() {
        // macOS deliberately keeps the free list nearly empty: in a real 1260-sample log
        // `free < 5%` held 99.3% of the time during healthy operation. Alarming on that
        // would fire practically every tick.
        let sample = Fixture.sample(bytes: 55_690_000, system: Fixture.ordinaryBusySystem)
        XCTAssertLessThan(Fixture.ordinaryBusySystem.freeFraction, 0.05)
        XCTAssertGreaterThan(Fixture.ordinaryBusySystem.compressedFraction, 0.30)
        XCTAssertEqual(evaluator.severity(for: sample, thresholds: thresholds), .normal)
    }

    func testPressureAndProcessTakeTheWorseOfTheTwo() {
        // A large process on a calm machine, and a small process on a dying one, must both
        // be reported — severity is the worse of the two verdicts, never just the process.
        let bigProcessCalmMachine = Fixture.sample(
            bytes: 13 * Fixture.gb, system: Fixture.healthySystem)
        XCTAssertEqual(evaluator.severity(for: bigProcessCalmMachine, thresholds: thresholds), .critical)
        XCTAssertEqual(evaluator.cause(for: bigProcessCalmMachine, thresholds: thresholds), .process)

        let warnPressure = Fixture.system(
            freeBytes: 1 * Fixture.gb, compressedBytes: 5 * Fixture.gb, pressure: .warning)
        let smallProcess = Fixture.sample(bytes: 60 * 1024 * 1024, system: warnPressure)
        XCTAssertEqual(evaluator.severity(for: smallProcess, thresholds: thresholds), .warning)
        XCTAssertEqual(evaluator.cause(for: smallProcess, thresholds: thresholds), .systemPressure)
    }

    func testProcessNotRunningStillReportsSystemPressure() {
        // "Defender isn't running" must not mask a dying machine.
        let sample = Fixture.sample(bytes: nil, system: Fixture.jetsamSystem)
        XCTAssertEqual(evaluator.severity(for: sample, thresholds: thresholds), .critical)
        XCTAssertFalse(sample.isProcessRunning)
        XCTAssertEqual(sample.processResidentBytes, 0)
    }

    func testProcessNotRunningOnAHealthyMachineIsNormal() {
        let sample = Fixture.sample(bytes: nil, system: Fixture.healthySystem)
        XCTAssertEqual(evaluator.severity(for: sample, thresholds: thresholds), .normal)
    }

    func testThresholdsClampCriticalBelowWarning() {
        // A critical threshold under the warning threshold would make .warning unreachable.
        let clamped = Thresholds(warningBytes: 10 * Fixture.gb, criticalBytes: 2 * Fixture.gb)
        XCTAssertEqual(clamped.criticalBytes, 10 * Fixture.gb)
        XCTAssertEqual(
            evaluator.severity(for: Fixture.sample(bytes: 11 * Fixture.gb), thresholds: clamped),
            .critical
        )
    }

    private func severity(
        bytes: UInt64, system: SystemMemoryUsage = Fixture.healthySystem
    ) -> Severity {
        evaluator.severity(for: Fixture.sample(bytes: bytes, system: system), thresholds: thresholds)
    }
}
