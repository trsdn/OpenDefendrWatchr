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
/// The 2026-08-22 incident was not dangerous because one process was large in the
/// abstract — it was dangerous because free memory had collapsed to ~139 MB while the
/// compressor held ~9.4 GB. So a process above the warning threshold is escalated to
/// critical once the machine itself is starving, even if the process has not yet reached
/// the critical byte threshold.
public struct SeverityEvaluator: Sendable, Equatable {
    /// Free RAM fraction under which the machine is considered starving.
    public var starvingFreeFraction: Double
    /// Compressor fraction over which the machine is considered starving.
    public var starvingCompressedFraction: Double

    public init(starvingFreeFraction: Double = 0.05, starvingCompressedFraction: Double = 0.30) {
        self.starvingFreeFraction = starvingFreeFraction
        self.starvingCompressedFraction = starvingCompressedFraction
    }

    public func systemIsStarving(_ system: SystemMemoryUsage) -> Bool {
        system.freeFraction < starvingFreeFraction
            && system.compressedFraction > starvingCompressedFraction
    }

    public func severity(for sample: MemorySample, thresholds: Thresholds) -> Severity {
        guard sample.isProcessRunning else { return .normal }
        let bytes = sample.processResidentBytes

        if bytes >= thresholds.criticalBytes { return .critical }
        if bytes >= thresholds.warningBytes {
            return systemIsStarving(sample.system) ? .critical : .warning
        }
        return .normal
    }
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
