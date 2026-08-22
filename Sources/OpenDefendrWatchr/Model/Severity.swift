import Foundation

/// How worried the user should be right now.
public enum Severity: Int, Sendable, Comparable, CaseIterable {
    case normal = 0
    case warning = 1
    case critical = 2

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// SF Symbol used in the menu bar. Severity is encoded in the *glyph shape*, not colour,
    /// so it stays legible as a template image in both light and dark menu bars.
    public var symbolName: String {
        switch self {
        case .normal: return "shield"
        case .warning: return "exclamationmark.shield"
        case .critical: return "exclamationmark.shield.fill"
        }
    }

    public var title: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// Turns a sample into a severity, taking both the process figure and real system
/// pressure into account.
///
/// Two rules, and the second one exists because the first was not enough:
///
/// 1. The watched process crossing a byte threshold is a warning, and is escalated to
///    critical once the machine itself is under pressure.
/// 2. **The machine being under pressure is an alert in its own right**, whatever the
///    watched process is doing. On 2026-08-22 the machine took a WindowServer watchdog
///    panic while `wdavdaemon` sat at 56 MB: anchoring severity to one process meant the
///    log recorded `normal` for all 1260 samples up to 70 seconds before the panic.
///
/// The pressure verdict comes from the kernel (`MemoryPressureLevel`), not from a
/// hand-rolled fraction of free pages — see that type for why free pages are worthless here.
public struct SeverityEvaluator: Sendable, Equatable {
    public init() {}

    /// Severity implied by the machine's own state, ignoring the watched process.
    public func systemSeverity(_ system: SystemMemoryUsage) -> Severity {
        switch system.pressureLevel {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        }
    }

    /// Severity implied by the watched process alone.
    public func processSeverity(for sample: MemorySample, thresholds: Thresholds) -> Severity {
        guard sample.isProcessRunning else { return .normal }
        let bytes = sample.processResidentBytes

        if bytes >= thresholds.criticalBytes { return .critical }
        if bytes >= thresholds.warningBytes {
            // A large process on an already-pressured machine is the 06:40 scenario.
            return systemSeverity(sample.system) >= .warning ? .critical : .warning
        }
        return .normal
    }

    public func severity(for sample: MemorySample, thresholds: Thresholds) -> Severity {
        max(processSeverity(for: sample, thresholds: thresholds), systemSeverity(sample.system))
    }

    /// What is actually driving the current severity — the process, or the machine.
    /// Alert wording depends on this: telling the user "wdavdaemon is using 56 MB" while
    /// the machine is dying would be worse than saying nothing.
    public func cause(for sample: MemorySample, thresholds: Thresholds) -> AlertCause {
        processSeverity(for: sample, thresholds: thresholds) >= systemSeverity(sample.system)
            ? .process : .systemPressure
    }
}

/// Why an alert fired.
public enum AlertCause: Sendable, Equatable {
    /// The watched process crossed a byte threshold.
    case process
    /// The machine as a whole is under memory pressure.
    case systemPressure
}

/// User-configurable byte thresholds. Defaults are tuned for a 24 GB machine.
public struct Thresholds: Sendable, Equatable {
    public static let defaultWarningBytes: UInt64 = 8 * 1024 * 1024 * 1024
    public static let defaultCriticalBytes: UInt64 = 12 * 1024 * 1024 * 1024

    public var warningBytes: UInt64
    public var criticalBytes: UInt64

    public init(
        warningBytes: UInt64 = Thresholds.defaultWarningBytes,
        criticalBytes: UInt64 = Thresholds.defaultCriticalBytes
    ) {
        // A critical threshold below the warning threshold would make the warning
        // state unreachable; clamp instead of trusting the stored defaults.
        self.warningBytes = warningBytes
        self.criticalBytes = max(criticalBytes, warningBytes)
    }

    public func threshold(for severity: Severity) -> UInt64? {
        switch severity {
        case .normal: return nil
        case .warning: return warningBytes
        case .critical: return criticalBytes
        }
    }
}
