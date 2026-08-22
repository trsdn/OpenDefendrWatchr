import Foundation
import ServiceManagement

/// User settings, persisted in `UserDefaults`.
public final class Preferences: ObservableObject {
    public enum Key {
        public static let pollInterval = "pollIntervalSeconds"
        public static let warningBytes = "warningThresholdBytes"
        public static let criticalBytes = "criticalThresholdBytes"
    }

    public static let defaultPollInterval: TimeInterval = 30
    public static let minimumPollInterval: TimeInterval = 5
    public static let maximumPollInterval: TimeInterval = 3600

    private let defaults: UserDefaults

    /// Clamping happens in `didSet` rather than in the setter because SwiftUI binds
    /// directly to these properties. Each clamp re-assigns at most once and the second
    /// pass is a no-op, so the observers cannot recurse.
    @Published public var pollInterval: TimeInterval {
        didSet {
            let clamped = Self.clampInterval(pollInterval)
            if clamped != pollInterval {
                pollInterval = clamped
                return
            }
            defaults.set(pollInterval, forKey: Key.pollInterval)
        }
    }

    /// Stored in gibibytes because that is what the user types.
    @Published public var warningGigabytes: Double {
        didSet {
            let clamped = max(0.1, warningGigabytes)
            if clamped != warningGigabytes {
                warningGigabytes = clamped
                return
            }
            defaults.set(warningGigabytes, forKey: Key.warningBytes)
            // Raising the warning threshold above critical would make critical unreachable.
            if criticalGigabytes < warningGigabytes { criticalGigabytes = warningGigabytes }
        }
    }

    @Published public var criticalGigabytes: Double {
        didSet {
            let clamped = max(warningGigabytes, criticalGigabytes)
            if clamped != criticalGigabytes {
                criticalGigabytes = clamped
                return
            }
            defaults.set(criticalGigabytes, forKey: Key.criticalBytes)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedInterval = defaults.object(forKey: Key.pollInterval) as? TimeInterval
        self.pollInterval = Self.clampInterval(storedInterval ?? Self.defaultPollInterval)
        self.warningGigabytes =
            defaults.object(forKey: Key.warningBytes) as? Double
            ?? Double(Thresholds.defaultWarningBytes) / 1_073_741_824
        self.criticalGigabytes =
            defaults.object(forKey: Key.criticalBytes) as? Double
            ?? Double(Thresholds.defaultCriticalBytes) / 1_073_741_824
    }

    public var thresholds: Thresholds {
        Thresholds(
            warningBytes: Self.bytes(fromGigabytes: warningGigabytes),
            criticalBytes: Self.bytes(fromGigabytes: criticalGigabytes)
        )
    }

    public static func bytes(fromGigabytes value: Double) -> UInt64 {
        UInt64((max(0, value) * 1_073_741_824).rounded())
    }

    public static func clampInterval(_ value: TimeInterval) -> TimeInterval {
        min(max(value, minimumPollInterval), maximumPollInterval)
    }

    // MARK: - Launch at login

    /// Uses `SMAppService` (macOS 13+), not a legacy login item.
    public var launchAtLoginEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("OpenDefendrWatchr: launch-at-login change failed: \(error)")
            }
        }
    }

    /// `SMAppService` only works for a real, installed `.app`. Running via `swift run`
    /// it always fails, so the UI disables the toggle rather than lying about it.
    public var launchAtLoginAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
}
