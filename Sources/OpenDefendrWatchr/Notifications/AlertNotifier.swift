import Foundation
import UserNotifications

/// Delivers threshold alerts to the user.
public protocol AlertNotifying: Sendable {
    func requestAuthorization()
    func deliver(_ alert: ThresholdAlert)
}

/// Builds the user-facing text for an alert. Pure, so wording is covered by tests and
/// cannot silently regress into something useless like "Warning: threshold crossed".
public enum AlertPresentation {
    public static func title(for alert: ThresholdAlert, processName: String) -> String {
        switch alert.severity {
        case .critical: return "\(processName) memory critical"
        case .warning: return "\(processName) memory high"
        case .normal: return "\(processName) memory normal"
        }
    }

    public static func body(for alert: ThresholdAlert, processName: String) -> String {
        let used = ByteFormatting.detailed(alert.sample.processResidentBytes)
        let limit = ByteFormatting.detailed(alert.thresholdBytes)
        let free = ByteFormatting.detailed(alert.sample.system.freeBytes)
        let compressed = ByteFormatting.detailed(alert.sample.system.compressedBytes)
        var text = "\(processName) is using \(used) (threshold \(limit)). "
        text += "System free \(free), compressed \(compressed)."
        if alert.severity == .critical {
            text += " Save your work and consider rebooting deliberately."
        }
        return text
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
}
