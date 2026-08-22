import XCTest

@testable import OpenDefendrWatchrKit

/// The point of this app is to warn *once*, early. A monitor that re-notifies every
/// 30 seconds gets muted by the user and then the next incident goes unnoticed — so the
/// debounce and hysteresis rules are the most important logic in the package.
final class ThresholdMonitorTests: XCTestCase {
    private let thresholds = Thresholds()  // 8 GB warning / 12 GB critical

    private func makeMonitor(
        confirmationSamples: Int = 2,
        releaseFraction: Double = 0.9
    ) -> ThresholdMonitor {
        ThresholdMonitor(
            thresholds: thresholds,
            policy: MonitorPolicy(
                confirmationSamples: confirmationSamples, releaseFraction: releaseFraction)
        )
    }

    func testDoesNotFireBeforeTheSeverityIsConfirmed() {
        var monitor = makeMonitor(confirmationSamples: 2)
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: 9 * Fixture.gb)))
        XCTAssertEqual(monitor.currentSeverity, .normal, "unconfirmed severity must not stick")
        XCTAssertNotNil(monitor.evaluate(Fixture.sample(bytes: 9 * Fixture.gb)))
        XCTAssertEqual(monitor.currentSeverity, .warning)
    }

    func testSingleSpikeNeverNotifies() {
        var monitor = makeMonitor(confirmationSamples: 2)
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: 1 * Fixture.gb)))
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: 13 * Fixture.gb)), "spike")
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: 1 * Fixture.gb)))
        XCTAssertEqual(monitor.currentSeverity, .normal)
    }

    func testWarningFiresOnceWhileUsageKeepsClimbingBelowCritical() {
        var monitor = makeMonitor()
        var alerts: [ThresholdAlert] = []
        for gb in [8.0, 8.5, 9.0, 9.5, 10.0, 11.0, 11.9] {
            if let alert = monitor.evaluate(Fixture.sample(bytes: bytes(gb))) { alerts.append(alert) }
        }
        XCTAssertEqual(alerts.count, 1, "warning must not re-notify on every poll")
        XCTAssertEqual(alerts.first?.severity, .warning)
        XCTAssertEqual(alerts.first?.thresholdBytes, 8 * Fixture.gb)
    }

    func testCriticalFiresOnceAfterWarning() {
        var monitor = makeMonitor()
        var alerts: [ThresholdAlert] = []
        for gb in [9.0, 9.0, 10.0, 12.0, 13.0, 15.0, 18.9] {
            if let alert = monitor.evaluate(Fixture.sample(bytes: bytes(gb))) { alerts.append(alert) }
        }
        XCTAssertEqual(alerts.map(\.severity), [.warning, .critical])
        XCTAssertEqual(monitor.currentSeverity, .critical)
    }

    func testJumpingStraightToCriticalDoesNotAlsoFireWarning() {
        var monitor = makeMonitor()
        var alerts: [ThresholdAlert] = []
        for gb in [0.1, 18.9, 18.9, 19.0] {
            if let alert = monitor.evaluate(Fixture.sample(bytes: bytes(gb))) { alerts.append(alert) }
        }
        XCTAssertEqual(alerts.map(\.severity), [.critical])
    }

    func testOscillationAroundAThresholdDoesNotSpam() {
        // 8 GB warning, release at 7.2 GB: bouncing between 7.9 and 8.1 must stay quiet
        // after the first alert.
        var monitor = makeMonitor()
        var alerts: [ThresholdAlert] = []
        for gb in [8.1, 8.1, 7.9, 7.9, 8.1, 8.1, 7.9, 7.9, 8.1, 8.1] {
            if let alert = monitor.evaluate(Fixture.sample(bytes: bytes(gb))) { alerts.append(alert) }
        }
        XCTAssertEqual(alerts.count, 1)
    }

    func testReArmsOnlyAfterAMeaningfulDrop() {
        var monitor = makeMonitor()
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: bytes(8.5))))
        XCTAssertNotNil(monitor.evaluate(Fixture.sample(bytes: bytes(8.5))))

        // Drop below 90% of the warning threshold (7.2 GB) — this re-arms the level.
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: bytes(1.0))))
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: bytes(1.0))))
        XCTAssertEqual(monitor.currentSeverity, .normal)

        // Climbing back up is a genuinely new incident and must notify again.
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: bytes(8.5))))
        XCTAssertNotNil(monitor.evaluate(Fixture.sample(bytes: bytes(8.5))))
    }

    func testDeEscalationIsImmediateAndSilent() {
        var monitor = makeMonitor()
        _ = monitor.evaluate(Fixture.sample(bytes: bytes(13)))
        _ = monitor.evaluate(Fixture.sample(bytes: bytes(13)))
        XCTAssertEqual(monitor.currentSeverity, .critical)

        // The menu bar must stop claiming "critical" the moment the process shrinks,
        // without waiting for a confirmation streak and without notifying.
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: bytes(0.2))))
        XCTAssertEqual(monitor.currentSeverity, .normal)
    }

    func testDefenderDisappearingIsTreatedAsNormalAndReArms() {
        var monitor = makeMonitor()
        _ = monitor.evaluate(Fixture.sample(bytes: bytes(13)))
        _ = monitor.evaluate(Fixture.sample(bytes: bytes(13)))

        _ = monitor.evaluate(Fixture.sample(bytes: nil))
        _ = monitor.evaluate(Fixture.sample(bytes: nil))
        XCTAssertEqual(monitor.currentSeverity, .normal)

        var alerts: [ThresholdAlert] = []
        for _ in 0..<2 {
            if let alert = monitor.evaluate(Fixture.sample(bytes: bytes(13))) { alerts.append(alert) }
        }
        XCTAssertEqual(alerts.map(\.severity), [.critical], "a restarted daemon can alert again")
    }

    func testSystemStarvationEscalatesAnAlreadyWarnedProcessToCritical() {
        var monitor = makeMonitor()
        _ = monitor.evaluate(Fixture.sample(bytes: bytes(9)))
        _ = monitor.evaluate(Fixture.sample(bytes: bytes(9)))
        XCTAssertEqual(monitor.currentSeverity, .warning)

        var alerts: [ThresholdAlert] = []
        for _ in 0..<2 {
            let sample = Fixture.sample(bytes: bytes(9), system: Fixture.jetsamSystem)
            if let alert = monitor.evaluate(sample) { alerts.append(alert) }
        }
        XCTAssertEqual(alerts.map(\.severity), [.critical])
    }

    func testChangingThresholdsReArmsBothLevels() {
        var monitor = makeMonitor()
        _ = monitor.evaluate(Fixture.sample(bytes: bytes(9)))
        XCTAssertNotNil(monitor.evaluate(Fixture.sample(bytes: bytes(9))))
        XCTAssertNil(monitor.evaluate(Fixture.sample(bytes: bytes(9))), "already warned")

        // The user lowered the warning threshold to 4 GB; at 9 GB they should hear about
        // it under the new rules rather than be silenced by the old crossing.
        monitor.updateThresholds(Thresholds(warningBytes: 4 * Fixture.gb, criticalBytes: 12 * Fixture.gb))
        _ = monitor.evaluate(Fixture.sample(bytes: bytes(9)))
        XCTAssertNotNil(monitor.evaluate(Fixture.sample(bytes: bytes(9))))
    }

    func testConfirmationOfOneFiresImmediately() {
        var monitor = makeMonitor(confirmationSamples: 1)
        XCTAssertNotNil(monitor.evaluate(Fixture.sample(bytes: bytes(13))))
    }

    func testPolicyClampsNonsenseValues() {
        let policy = MonitorPolicy(confirmationSamples: 0, releaseFraction: 5)
        XCTAssertEqual(policy.confirmationSamples, 1)
        XCTAssertEqual(policy.releaseFraction, 1.0)
    }

    private func bytes(_ gigabytes: Double) -> UInt64 {
        UInt64(gigabytes * Double(Fixture.gb))
    }
}
