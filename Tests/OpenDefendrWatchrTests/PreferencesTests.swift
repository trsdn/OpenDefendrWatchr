import XCTest

@testable import OpenDefendrWatchrKit

final class PreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "OpenDefendrWatchrTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsMatchThe24GBMachineTheAppWasWrittenFor() {
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.pollInterval, 30)
        XCTAssertEqual(preferences.thresholds.warningBytes, 8 * Fixture.gb)
        XCTAssertEqual(preferences.thresholds.criticalBytes, 12 * Fixture.gb)
    }

    func testValuesPersistAcrossInstances() {
        let first = Preferences(defaults: defaults)
        first.pollInterval = 15
        first.warningGigabytes = 6
        first.criticalGigabytes = 10

        let second = Preferences(defaults: defaults)
        XCTAssertEqual(second.pollInterval, 15)
        XCTAssertEqual(second.thresholds.warningBytes, 6 * Fixture.gb)
        XCTAssertEqual(second.thresholds.criticalBytes, 10 * Fixture.gb)
    }

    func testPollIntervalIsClamped() {
        let preferences = Preferences(defaults: defaults)
        preferences.pollInterval = 0
        XCTAssertEqual(preferences.pollInterval, Preferences.minimumPollInterval)
        preferences.pollInterval = 999_999
        XCTAssertEqual(preferences.pollInterval, Preferences.maximumPollInterval)
    }

    func testRaisingWarningAboveCriticalPushesCriticalUp() {
        // Otherwise the user silently loses the critical alert entirely.
        let preferences = Preferences(defaults: defaults)
        preferences.warningGigabytes = 20
        XCTAssertEqual(preferences.criticalGigabytes, 20)
        XCTAssertEqual(preferences.thresholds.criticalBytes, 20 * Fixture.gb)
    }

    func testLoweringCriticalBelowWarningIsRejected() {
        let preferences = Preferences(defaults: defaults)
        preferences.criticalGigabytes = 1
        XCTAssertEqual(preferences.criticalGigabytes, preferences.warningGigabytes)
    }

    func testCorruptedStoredIntervalFallsBackToSomethingUsable() {
        defaults.set(-5.0, forKey: Preferences.Key.pollInterval)
        XCTAssertEqual(Preferences(defaults: defaults).pollInterval, Preferences.minimumPollInterval)
    }

    func testGigabyteConversionUsesBinaryGigabytes() {
        XCTAssertEqual(Preferences.bytes(fromGigabytes: 1), 1_073_741_824)
        XCTAssertEqual(Preferences.bytes(fromGigabytes: 0.5), 536_870_912)
        XCTAssertEqual(Preferences.bytes(fromGigabytes: -3), 0)
    }

    // The watchdog died once because nobody could tell it was gone. Registration state has
    // to be reportable, and "awaiting approval" must not be reported as plain "off" — that
    // is the one failure the user can actually act on.
    func testOnlyEnabledCountsAsEnabled() {
        XCTAssertTrue(LaunchAtLoginStatus.enabled.isEnabled)
        for status in [
            LaunchAtLoginStatus.notRegistered, .requiresApproval, .notFound, .unknown,
        ] {
            XCTAssertFalse(status.isEnabled, "\(status) must not be reported as enabled")
        }
    }

    func testApprovalAndMissingBundleAreDistinguishable() {
        XCTAssertNotEqual(
            LaunchAtLoginStatus.requiresApproval.title, LaunchAtLoginStatus.notRegistered.title)
        XCTAssertTrue(LaunchAtLoginStatus.requiresApproval.title.contains("approval"))
        XCTAssertTrue(LaunchAtLoginStatus.notFound.title.contains("not found"))
    }

    func testEverySystemStatusMapsToADistinctCase() {
        XCTAssertEqual(LaunchAtLoginStatus(.enabled), .enabled)
        XCTAssertEqual(LaunchAtLoginStatus(.notRegistered), .notRegistered)
        XCTAssertEqual(LaunchAtLoginStatus(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LaunchAtLoginStatus(.notFound), .notFound)
    }
}
