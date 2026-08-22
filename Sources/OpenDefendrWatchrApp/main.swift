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

WatchrApp.main()
