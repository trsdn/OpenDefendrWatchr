import Foundation
import OpenDefendrWatchrKit

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

WatchrApp.main()
