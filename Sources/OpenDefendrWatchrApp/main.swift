import Foundation
import OpenDefendrWatchrKit

final class ResultBox: @unchecked Sendable {
    var status: NotificationDeliveryStatus?
}

// `--probe` prints one sample as text and exits, without starting the menu bar app.
// Useful for verifying the reader from a terminal and for pasting into a support ticket.
if CommandLine.arguments.contains("--probe") {
    do {
        let sample = try DefenderMemorySampler().sample()
        let severity = SeverityEvaluator().severity(for: sample, thresholds: Preferences().thresholds)
        if let process = sample.process {
            print(
                "wdavdaemon: \(ByteFormatting.detailed(process.residentBytes)) "
                    + "(\(ByteFormatting.compact(process.residentBytes))) "
                    + "across \(process.processCount) process(es), pids \(process.pids)")
        } else if let reason = sample.processUnreadableReason {
            print("wdavdaemon: could not be measured — \(reason)")
        } else {
            print("wdavdaemon: not running")
        }
        let system = sample.system
        print(
            "system: free \(ByteFormatting.detailed(system.freeBytes)) "
                + "(\(ByteFormatting.percent(system.freeFraction))), "
                + "compressed \(ByteFormatting.detailed(system.compressedBytes)), "
                + "total \(ByteFormatting.detailed(system.totalBytes)), "
                + "page size \(system.pageSize)")
        print(
            "memory pressure: \(system.pressureLevel.title) "
                + "(available \(system.availableFraction.map { "\(Int($0 * 100))%" } ?? "unknown"), "
                + "raw dispatch level \(system.kernelPressureLevel.title))")
        if let stall = sample.stall {
            print(
                "file latency: median \(AlertPresentation.duration(stall.medianSeconds)), "
                    + "worst \(AlertPresentation.duration(stall.worstSeconds)) "
                    + "over \(stall.sampleCount) opens")
        } else {
            print("file latency: unavailable")
        }
        print("severity: \(severity.title)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
        exit(1)
    }
}

// `--notify-test` sends one test notification and exits, reporting whether macOS actually
// accepted it. Must be run from the installed .app: notifications need a bundle identity.
if CommandLine.arguments.contains("--notify-test") {
    let sample = try? DefenderMemorySampler().sample()
    let notifier = UserNotificationAlertNotifier()
    let box = ResultBox()

    notifier.deliverTest(sample: sample) { status in
        box.status = status
    }

    // The authorization callback needs the main run loop to turn, so pump it rather than
    // blocking on the semaphore alone.
    let deadline = Date().addingTimeInterval(30)
    while box.status == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    guard let status = box.status else {
        FileHandle.standardError.write(Data("notify-test: timed out waiting for macOS\n".utf8))
        exit(1)
    }
    print(status.userDescription)
    exit(status.isSuccess ? 0 : 1)
}

// `--login-item [enable|disable|status]` reports or changes the launch-at-login
// registration and exits. This exists because a menu bar watchdog that silently failed to
// register is indistinguishable from one that registered fine, and the whole point of the
// app is to not fail silently. Must be run from the installed .app: `SMAppService` needs a
// real bundle identity.
if let index = CommandLine.arguments.firstIndex(of: "--login-item") {
    let preferences = Preferences()
    let action = CommandLine.arguments.dropFirst(index + 1).first ?? "status"

    guard preferences.launchAtLoginAvailable else {
        FileHandle.standardError.write(
            Data(
                "login-item: unavailable — run the installed .app, not a bare binary\n".utf8))
        exit(1)
    }

    switch action {
    case "enable":
        preferences.launchAtLoginEnabled = true
    case "disable":
        preferences.launchAtLoginEnabled = false
    case "status":
        break
    default:
        FileHandle.standardError.write(
            Data("login-item: expected enable, disable or status\n".utf8))
        exit(2)
    }

    let status = preferences.launchAtLoginStatus
    print("launch at login: \(status.title)")
    print("bundle: \(Bundle.main.bundleURL.path)")
    exit(status.isEnabled == (action != "disable") ? 0 : 1)
}

WatchrApp.main()
