import XCTest

@testable import OpenDefendrWatchrKit

private struct StubSampler: MemorySampling {
    final class Script: @unchecked Sendable {
        var samples: [MemorySample]
        var error: Error?
        var index = 0
        init(samples: [MemorySample], error: Error? = nil) {
            self.samples = samples
            self.error = error
        }
    }

    let script: Script

    func sample() throws -> MemorySample {
        if let error = script.error { throw error }
        let sample = script.samples[min(script.index, script.samples.count - 1)]
        script.index += 1
        return sample
    }
}

private final class SpyNotifier: AlertNotifying, @unchecked Sendable {
    var delivered: [ThresholdAlert] = []
    var authorizationRequested = false
    var testSamples: [MemorySample?] = []
    var testStatus: NotificationDeliveryStatus = .delivered

    func requestAuthorization() { authorizationRequested = true }
    func deliver(_ alert: ThresholdAlert) { delivered.append(alert) }
    func deliverTest(
        sample: MemorySample?,
        completion: @escaping @Sendable (NotificationDeliveryStatus) -> Void
    ) {
        testSamples.append(sample)
        completion(testStatus)
    }
}

private struct StubError: Error, CustomStringConvertible {
    var description: String { "host_statistics64 failed" }
}

@MainActor
final class WatchdogModelTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenDefendrWatchrModelTests-\(UUID().uuidString)")
        suiteName = "OpenDefendrWatchrModelTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel(
        samples: [MemorySample],
        error: Error? = nil,
        notifier: SpyNotifier = SpyNotifier()
    ) -> (WatchdogModel, SpyNotifier) {
        let model = WatchdogModel(
            preferences: Preferences(defaults: defaults),
            sampler: StubSampler(script: .init(samples: samples, error: error)),
            notifier: notifier,
            log: SampleCSVLog(directory: directory),
            policy: MonitorPolicy(confirmationSamples: 1)
        )
        return (model, notifier)
    }

    func testMenuBarTitleShowsCompactUsage() async {
        let (model, _) = makeModel(samples: [Fixture.sample(bytes: 20_303_237_939)])
        await model.pollOnce()
        XCTAssertEqual(model.menuBarTitle, "18.9G")
        XCTAssertEqual(model.severity, .critical)
        XCTAssertTrue(model.statusLine.contains("18.91 GB"))
    }

    func testNotRunningIsADistinctStateAndNotZeroBytes() async {
        let (model, notifier) = makeModel(samples: [Fixture.sample(bytes: nil)])
        await model.pollOnce()

        guard case .processNotRunning = model.state else {
            return XCTFail("expected processNotRunning, got \(model.state)")
        }
        XCTAssertEqual(model.menuBarTitle, "—")
        XCTAssertNotEqual(model.menuBarTitle, "0B")
        XCTAssertTrue(model.statusLine.contains("not running"))
        XCTAssertTrue(notifier.delivered.isEmpty)
        // System memory is still known and shown even without Defender running.
        XCTAssertTrue(model.systemLine.contains("free"))
    }

    func testSamplingFailureIsSurfacedInsteadOfCrashing() async {
        let (model, _) = makeModel(samples: [], error: StubError())
        await model.pollOnce()

        guard case .failed(let message) = model.state else {
            return XCTFail("expected failed, got \(model.state)")
        }
        XCTAssertTrue(message.contains("host_statistics64"))
        XCTAssertEqual(model.menuBarTitle, "!")
        XCTAssertNotNil(model.lastUpdate)
    }

    func testNotifiesOnceAndLogsEveryPoll() async {
        let (model, notifier) = makeModel(samples: [Fixture.sample(bytes: 13 * Fixture.gb)])
        for _ in 0..<4 { await model.pollOnce() }

        XCTAssertEqual(notifier.delivered.count, 1, "no notification spam")
        XCTAssertEqual(notifier.delivered.first?.severity, .critical)

        let rows = try? String(contentsOf: model.log.fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(rows?.count, 5, "header plus one row per poll")
    }

    func testTracksSessionPeakEvenAfterUsageDrops() async {
        let (model, _) = makeModel(
            samples: [Fixture.sample(bytes: 18 * Fixture.gb), Fixture.sample(bytes: Fixture.gb)])
        await model.pollOnce()
        await model.pollOnce()

        XCTAssertEqual(model.severity, .normal, "current state follows reality")
        XCTAssertEqual(model.peakBytes, 18 * Fixture.gb, "peak is the number for the ticket")
        XCTAssertTrue(model.peakLine.contains("18.00 GB"))
    }

    func testStartRequestsNotificationAuthorization() async {
        let (model, notifier) = makeModel(samples: [Fixture.sample(bytes: Fixture.gb)])
        model.start()
        model.stop()
        XCTAssertTrue(notifier.authorizationRequested)
    }

    func testTestNotificationCarriesTheLatestReading() async {
        // Deliberately below the warning threshold, so any entry in `delivered` can only
        // have come from the test path.
        let (model, notifier) = makeModel(samples: [Fixture.sample(bytes: 2 * Fixture.gb)])
        await model.pollOnce()

        var status: NotificationDeliveryStatus?
        model.sendTestNotification { status = $0 }
        // The stub calls back synchronously, but the hop to the main actor is a Task.
        await Task.yield()

        XCTAssertEqual(status, .delivered)
        XCTAssertEqual(notifier.testSamples.count, 1)
        XCTAssertEqual(notifier.testSamples.first??.processResidentBytes, 2 * Fixture.gb)
        XCTAssertTrue(notifier.delivered.isEmpty, "a test must not count as a threshold alert")
    }

    func testTestNotificationReportsBlockedPermissions() async {
        let notifier = SpyNotifier()
        notifier.testStatus = .notAuthorized
        let (model, _) = makeModel(
            samples: [Fixture.sample(bytes: Fixture.gb)], notifier: notifier)

        var status: NotificationDeliveryStatus?
        model.sendTestNotification { status = $0 }
        await Task.yield()

        XCTAssertEqual(status, .notAuthorized)
        XCTAssertFalse(status?.isSuccess ?? true)
    }
}
