import Foundation

/// A notification the user should actually see.
public struct ThresholdAlert: Sendable, Equatable {
    public let severity: Severity
    public let sample: MemorySample
    public let thresholdBytes: UInt64
    /// Whether the watched process or the machine itself triggered this.
    public let cause: AlertCause

    public init(
        severity: Severity,
        sample: MemorySample,
        thresholdBytes: UInt64,
        cause: AlertCause = .process
    ) {
        self.severity = severity
        self.sample = sample
        self.thresholdBytes = thresholdBytes
        self.cause = cause
    }
}

/// Debounce/hysteresis tuning.
public struct MonitorPolicy: Sendable, Equatable {
    /// A severity must persist for this many consecutive samples before it takes effect.
    /// Stops a single spiky reading from firing a notification.
    public var confirmationSamples: Int
    /// Once a level has fired, usage must fall below `threshold * releaseFraction`
    /// before that level can fire again. Prevents notification storms when usage
    /// oscillates around a threshold.
    public var releaseFraction: Double

    public init(confirmationSamples: Int = 2, releaseFraction: Double = 0.9) {
        self.confirmationSamples = max(1, confirmationSamples)
        self.releaseFraction = min(max(releaseFraction, 0.1), 1.0)
    }
}

/// Threshold state machine with hysteresis.
///
/// Rules, in the order they matter:
/// 1. A severity only becomes *effective* after `confirmationSamples` consecutive samples.
/// 2. Each level fires at most once per crossing; it re-arms only after usage drops
///    below `threshold * releaseFraction`.
/// 3. Firing critical also disarms warning, so a machine on its way down does not
///    produce a pointless "warning" notification after the critical one.
public struct ThresholdMonitor: Sendable {
    public private(set) var currentSeverity: Severity = .normal

    private let evaluator: SeverityEvaluator
    private let policy: MonitorPolicy
    private var thresholds: Thresholds

    private var warningArmed = true
    private var criticalArmed = true
    private var candidateSeverity: Severity = .normal
    private var candidateStreak = 0

    public init(
        thresholds: Thresholds = Thresholds(),
        policy: MonitorPolicy = MonitorPolicy(),
        evaluator: SeverityEvaluator = SeverityEvaluator()
    ) {
        self.thresholds = thresholds
        self.policy = policy
        self.evaluator = evaluator
    }

    /// Applies new thresholds. Both levels re-arm, because the user just told us what
    /// they consider dangerous and deserves to hear about it under the new rules.
    public mutating func updateThresholds(_ newThresholds: Thresholds) {
        guard newThresholds != thresholds else { return }
        thresholds = newThresholds
        warningArmed = true
        criticalArmed = true
        candidateStreak = 0
        candidateSeverity = currentSeverity
    }

    /// Feeds one sample in. Returns an alert only when the user should be notified.
    @discardableResult
    public mutating func evaluate(_ sample: MemorySample) -> ThresholdAlert? {
        let observed = evaluator.severity(for: sample, thresholds: thresholds)

        if observed == candidateSeverity {
            candidateStreak += 1
        } else {
            candidateSeverity = observed
            candidateStreak = 1
        }

        rearmIfRecovered(sample)

        // De-escalation is immediate: it never notifies, and pretending the machine is
        // still critical would keep the menu bar lying to the user.
        if observed < currentSeverity {
            currentSeverity = observed
            return nil
        }

        guard candidateStreak >= policy.confirmationSamples else { return nil }
        let previous = currentSeverity
        currentSeverity = observed
        guard observed > previous || shouldRefire(observed) else { return nil }

        let cause = evaluator.cause(for: sample, thresholds: thresholds)

        switch observed {
        case .normal:
            return nil
        case .warning:
            guard warningArmed else { return nil }
            warningArmed = false
            return ThresholdAlert(
                severity: .warning, sample: sample, thresholdBytes: thresholds.warningBytes,
                cause: cause)
        case .critical:
            guard criticalArmed else { return nil }
            criticalArmed = false
            warningArmed = false
            return ThresholdAlert(
                severity: .critical, sample: sample, thresholdBytes: thresholds.criticalBytes,
                cause: cause)
        }
    }

    /// A level that has re-armed (usage dropped and climbed back) may fire again even
    /// though the effective severity did not change in this tick.
    private func shouldRefire(_ severity: Severity) -> Bool {
        switch severity {
        case .normal: return false
        case .warning: return warningArmed
        case .critical: return criticalArmed
        }
    }

    /// Re-arms a level only once *both* drivers have receded.
    ///
    /// The process condition alone is not sufficient: when an alert is driven by system
    /// pressure or a stall the watched process may sit at a few megabytes, which would
    /// satisfy the byte rule on every single tick and turn a sustained episode into a
    /// notification storm — the exact failure this monitor exists to prevent.
    private mutating func rearmIfRecovered(_ sample: MemorySample) {
        let bytes = sample.processResidentBytes
        let machine = evaluator.machineSeverity(for: sample)

        if Double(bytes) < Double(thresholds.warningBytes) * policy.releaseFraction,
            machine < .warning
        {
            warningArmed = true
        }
        if Double(bytes) < Double(thresholds.criticalBytes) * policy.releaseFraction,
            machine < .critical
        {
            criticalArmed = true
        }
    }
}
