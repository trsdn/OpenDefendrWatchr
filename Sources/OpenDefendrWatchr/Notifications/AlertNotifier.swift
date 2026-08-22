import Foundation
import UserNotifications

/// Outcome of a delivery attempt. Notifications failing silently is the one bug this app
/// cannot afford — a denied permission would make the whole watchdog useless without any
/// visible symptom — so the test path reports back what actually happened.
public enum NotificationDeliveryStatus: Sendable, Equatable {
    case delivered
    case notAuthorized
    case unavailable(String)
    case failed(String)

    public var isSuccess: Bool { self == .delivered }

    public var userDescription: String {
        switch self {
        case .delivered:
            return "Notification delivered. If you did not see a banner, check Notification Centre and System Settings ▸ Notifications ▸ OpenDefendrWatchr, and make sure a Focus mode is not suppressing it."
        case .notAuthorized:
            return "macOS is blocking notifications for OpenDefendrWatchr. Enable them in System Settings ▸ Notifications ▸ OpenDefendrWatchr — otherwise threshold alerts will never reach you."
        case .unavailable(let reason):
            return "Notifications are unavailable: \(reason)"
        case .failed(let message):
            return "Delivery failed: \(message)"
        }
    }
}

/// Delivers threshold alerts to the user.
public protocol AlertNotifying: Sendable {
    func requestAuthorization()
    func deliver(_ alert: ThresholdAlert)
    /// Sends a visible test notification reflecting the current reading, and reports
    /// whether it could actually be delivered.
    func deliverTest(
        sample: MemorySample?,
        completion: @escaping @Sendable (NotificationDeliveryStatus) -> Void
    )
}

/// Builds the user-facing text for an alert. Pure, so wording is covered by tests and
/// cannot silently regress into something useless like "Warning: threshold crossed".
public enum AlertPresentation {
    public static func title(for alert: ThresholdAlert, processName: String) -> String {
        switch alert.cause {
        case .systemPressure:
            switch alert.severity {
            case .critical: return "System memory critical"
            case .warning: return "System memory under pressure"
            case .normal: return "System memory normal"
            }
        case .process:
            switch alert.severity {
            case .critical: return "\(processName) memory critical"
            case .warning: return "\(processName) memory high"
            case .normal: return "\(processName) memory normal"
            }
        case .systemStall:
            switch alert.severity {
            case .critical: return "System is stalling"
            case .warning: return "System slowing down"
            case .normal: return "System responsive"
            }
        }
    }

    public static func body(for alert: ThresholdAlert, processName: String) -> String {
        let free = ByteFormatting.detailed(alert.sample.system.freeBytes)
        let compressed = ByteFormatting.detailed(alert.sample.system.compressedBytes)

        var text: String
        switch alert.cause {
        case .systemPressure:
            // Name the watched process explicitly even though it is innocent, so the user
            // does not waste the next ten minutes suspecting Defender.
            text = "The kernel reports memory pressure \(alert.sample.system.pressureLevel.title). "
            if alert.sample.isProcessRunning {
                let used = ByteFormatting.detailed(alert.sample.processResidentBytes)
                text += "\(processName) is not the cause (\(used)). "
            }
            text += "System free \(free), compressed \(compressed)."
        case .process:
            let used = ByteFormatting.detailed(alert.sample.processResidentBytes)
            let limit = ByteFormatting.detailed(alert.thresholdBytes)
            text = "\(processName) is using \(used) (threshold \(limit)). "
            text += "System free \(free), compressed \(compressed)."
        case .systemStall:
            // Memory is fine here, so say so — otherwise the user checks the wrong thing.
            let median = alert.sample.stall.map { Self.duration($0.medianSeconds) } ?? "—"
            text = "Basic file operations are taking \(median) instead of microseconds. "
            text += "That is a stalled Endpoint Security extension blocking threads "
            text += "system-wide, not a memory problem. "
            text += "Memory pressure is \(alert.sample.system.pressureLevel.title)."
        }

        if alert.severity == .critical {
            text += " Save your work and consider rebooting deliberately."
        }
        return text
    }

    public static let testTitle = "OpenDefendrWatchr test notification"

    /// Human-readable latency. Sub-millisecond values are the normal case and read better
    /// in microseconds.
    public static func duration(_ seconds: Double) -> String {
        if seconds < 0.001 { return String(format: "%.0f µs", seconds * 1_000_000) }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        return String(format: "%.1f s", seconds)
    }

    /// The test body deliberately carries the live figures, so the user sees exactly the
    /// shape of a real alert rather than a content-free "this is a test".
    public static func testBody(sample: MemorySample?, processName: String) -> String {
        guard let sample else {
            return "Alerts are working. No \(processName) reading yet."
        }
        guard sample.isProcessRunning else {
            return "Alerts are working. \(processName) is not running; system free "
                + "\(ByteFormatting.detailed(sample.system.freeBytes))."
        }
        return "Alerts are working. \(processName) is at "
            + "\(ByteFormatting.detailed(sample.processResidentBytes)); system free "
            + "\(ByteFormatting.detailed(sample.system.freeBytes)), compressed "
            + "\(ByteFormatting.detailed(sample.system.compressedBytes))."
    }
}

/// `UNUserNotificationCenter` requires a real bundle identity. When the executable is run
/// straight from SwiftPM (`swift run`) there is no bundle, and touching the notification
/// center would trap — so it degrades to logging instead of crashing.
public final class UserNotificationAlertNotifier: AlertNotifying {
    private let processName: String
    private let isBundled: Bool

    public init(processName: String = DefenderMemorySampler.defaultExecutableName) {
        self.processName = processName
        self.isBundled = Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundleURL.pathExtension == "app"
    }

    public func requestAuthorization() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
        }
    }

    public func deliver(_ alert: ThresholdAlert) {
        let title = AlertPresentation.title(for: alert, processName: processName)
        let body = AlertPresentation.body(for: alert, processName: processName)

        guard isBundled else {
            FileHandle.standardError.write(Data("[alert] \(title): \(body)\n".utf8))
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = alert.severity == .critical ? .defaultCritical : .default

        let request = UNNotificationRequest(
            identifier: "threshold-\(alert.severity.rawValue)-\(Int(alert.sample.timestamp.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    public func deliverTest(
        sample: MemorySample?,
        completion: @escaping @Sendable (NotificationDeliveryStatus) -> Void
    ) {
        let title = AlertPresentation.testTitle
        let body = AlertPresentation.testBody(sample: sample, processName: processName)

        guard isBundled else {
            FileHandle.standardError.write(Data("[test] \(title): \(body)\n".utf8))
            completion(
                .unavailable(
                    "the app is running without a bundle (swift run). Install OpenDefendrWatchr.app and launch it from there."
                ))
            return
        }

        let center = UNUserNotificationCenter.current()
        // Ask first: a prior denial is silent otherwise, and "no banner appeared" would
        // leave the user unable to tell a broken app from a blocked permission.
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                completion(.failed(error.localizedDescription))
                return
            }
            guard granted else {
                completion(.notAuthorized)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request) { addError in
                completion(addError.map { .failed($0.localizedDescription) } ?? .delivered)
            }
        }
    }
}
