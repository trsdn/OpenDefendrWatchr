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

    func testWarningEscalatesToCriticalWhenTheMachineIsStarving() {
        // Same process size, different machine state: 9 GB is "warning" on a healthy box
        // but "critical" when free memory has collapsed the way it did at 06:40.
        XCTAssertEqual(severity(bytes: 9 * Fixture.gb, system: Fixture.healthySystem), .warning)
        XCTAssertEqual(severity(bytes: 9 * Fixture.gb, system: Fixture.jetsamSystem), .critical)
    }

    func testStarvationAloneDoesNotEscalateASmallProcess() {
        // The app watches wdavdaemon. If the machine is starving because of something
        // else entirely, blaming Defender would be a false alarm.
        XCTAssertEqual(severity(bytes: 200 * 1024 * 1024, system: Fixture.jetsamSystem), .normal)
    }

    func testStarvationNeedsBothLowFreeAndHighCompressorUse() {
        // Low free memory with an idle compressor is ordinary macOS behaviour (the OS
        // keeps free memory low on purpose), not danger.
        let lowFreeOnly = Fixture.system(freeBytes: 500 * 1024 * 1024, compressedBytes: 1 * Fixture.gb)
        XCTAssertFalse(evaluator.systemIsStarving(lowFreeOnly))
        XCTAssertEqual(severity(bytes: 9 * Fixture.gb, system: lowFreeOnly), .warning)

        let compressorHeavyButFree = Fixture.system(
            freeBytes: 6 * Fixture.gb, compressedBytes: 9 * Fixture.gb)
        XCTAssertFalse(evaluator.systemIsStarving(compressorHeavyButFree))
    }

    func testProcessNotRunningIsAlwaysNormal() {
        let sample = Fixture.sample(bytes: nil, system: Fixture.jetsamSystem)
        XCTAssertEqual(evaluator.severity(for: sample, thresholds: thresholds), .normal)
        XCTAssertFalse(sample.isProcessRunning)
        XCTAssertEqual(sample.processResidentBytes, 0)
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
