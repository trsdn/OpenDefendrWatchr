import Combine
import Foundation

/// Observable state driving the menu bar UI.
@MainActor
public final class WatchdogModel: ObservableObject {
    public enum State: Equatable {
        case starting
        case running(MemorySample, Severity)
        case processNotRunning(MemorySample)
        case failed(String)
    }

    @Published public private(set) var state: State = .starting
    @Published public private(set) var lastUpdate: Date?
    @Published public private(set) var peakBytes: UInt64 = 0

    public let preferences: Preferences
    public let log: SampleCSVLog

    private let sampler: MemorySampling
    private let notifier: AlertNotifying
    private let processName: String
    private var monitor: ThresholdMonitor
    private var pollTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    public init(
        preferences: Preferences = Preferences(),
        sampler: MemorySampling = DefenderMemorySampler(),
        notifier: AlertNotifying = UserNotificationAlertNotifier(),
        log: SampleCSVLog = SampleCSVLog(directory: SampleCSVLog.defaultDirectory()),
        policy: MonitorPolicy = MonitorPolicy(),
        processName: String = DefenderMemorySampler.defaultExecutableName
    ) {
        self.preferences = preferences
        self.sampler = sampler
        self.notifier = notifier
        self.log = log
        self.processName = processName
        self.monitor = ThresholdMonitor(thresholds: preferences.thresholds, policy: policy)

        preferences.$warningGigabytes
            .combineLatest(preferences.$criticalGigabytes)
            .sink { [weak self] _, _ in
                guard let self else { return }
                Task { @MainActor in self.monitor.updateThresholds(self.preferences.thresholds) }
            }
            .store(in: &cancellables)

        preferences.$pollInterval
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.restartPolling() }
            }
            .store(in: &cancellables)
    }

    public var severity: Severity {
        if case .running(_, let severity) = state { return severity }
        return .normal
    }

    /// Short menu-bar title, e.g. `18.9G` or `—` when Defender is not running.
    public var menuBarTitle: String {
        switch state {
        case .running(let sample, _): return ByteFormatting.compact(sample.processResidentBytes)
        case .processNotRunning: return "—"
        case .starting: return "…"
        case .failed: return "!"
        }
    }

    public var statusLine: String {
        switch state {
        case .starting:
            return "Sampling \(processName)…"
        case .processNotRunning:
            return "\(processName) is not running"
        case .failed(let message):
            return "Sampling failed: \(message)"
        case .running(let sample, let severity):
            let count = sample.process?.processCount ?? 1
            let suffix = count > 1 ? " (\(count) processes)" : ""
            return
                "\(processName): \(ByteFormatting.detailed(sample.processResidentBytes))\(suffix) — \(severity.title)"
        }
    }

    public var systemLine: String {
        guard let sample = currentSample else { return "System memory unknown" }
        let system = sample.system
        return
            "System: \(ByteFormatting.detailed(system.freeBytes)) free (\(ByteFormatting.percent(system.freeFraction))), \(ByteFormatting.detailed(system.compressedBytes)) compressed of \(ByteFormatting.detailed(system.totalBytes))"
    }

    public var peakLine: String {
        peakBytes == 0 ? "Peak: —" : "Peak this session: \(ByteFormatting.detailed(peakBytes))"
    }

    public var currentSample: MemorySample? {
        switch state {
        case .running(let sample, _), .processNotRunning(let sample): return sample
        case .starting, .failed: return nil
        }
    }

    public func start() {
        notifier.requestAuthorization()
        restartPolling()
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Sends a visible test notification using the latest reading, so the alert path can
    /// be verified before an incident rather than during one.
    public func sendTestNotification(
        completion: @escaping @MainActor (NotificationDeliveryStatus) -> Void
    ) {
        notifier.deliverTest(sample: currentSample) { status in
            Task { @MainActor in completion(status) }
        }
    }

    private func restartPolling() {
        pollTask?.cancel()
        let interval = preferences.pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    /// One poll tick. Sampling happens off the main actor so a slow `ps` cannot stutter
    /// the menu bar.
    public func pollOnce() async {
        let sampler = self.sampler
        let result: Result<MemorySample, Error> = await Task.detached(priority: .utility) {
            do { return .success(try sampler.sample()) } catch { return .failure(error) }
        }.value

        switch result {
        case .failure(let error):
            state = .failed(String(describing: error))
        case .success(let sample):
            apply(sample)
        }
        lastUpdate = Date()
    }

    private func apply(_ sample: MemorySample) {
        let alert = monitor.evaluate(sample)
        let severity = monitor.currentSeverity
        peakBytes = max(peakBytes, sample.processResidentBytes)
        state = sample.isProcessRunning ? .running(sample, severity) : .processNotRunning(sample)
        log.append(sample: sample, severity: severity)
        if let alert { notifier.deliver(alert) }
    }
}
