import Foundation

/// Append-only CSV log of the growth curve, with size-based rotation.
///
/// This file is the evidence for an IT ticket: one row per poll, plain CSV, no quoting
/// games, directly loadable into a spreadsheet or `gnuplot`.
public final class SampleCSVLog: @unchecked Sendable {
    public static let header =
        "timestamp,process,rss_bytes,rss_human,process_count,system_total_bytes,system_free_bytes,system_compressed_bytes,page_size,severity"

    public let fileURL: URL
    private let maxBytes: UInt64
    private let keepRotations: Int
    private let processName: String
    private let queue = DispatchQueue(label: "com.opendefendrwatchr.csvlog")
    private let formatter: ISO8601DateFormatter

    public init(
        directory: URL,
        fileName: String = "wdavdaemon-memory.csv",
        processName: String = DefenderMemorySampler.defaultExecutableName,
        maxBytes: UInt64 = 4 * 1024 * 1024,
        keepRotations: Int = 3
    ) {
        self.fileURL = directory.appendingPathComponent(fileName)
        self.maxBytes = maxBytes
        self.keepRotations = keepRotations
        self.processName = processName
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.formatter = formatter

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Default location: `~/Library/Application Support/OpenDefendrWatchr/`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("OpenDefendrWatchr", isDirectory: true)
    }

    public func append(sample: MemorySample, severity: Severity) {
        let line = Self.row(
            sample: sample, severity: severity, processName: processName, formatter: formatter)
        queue.sync {
            rotateIfNeeded()
            write(line: line)
        }
    }

    /// Formats one CSV row. Pure, so the on-disk format is pinned by tests.
    public static func row(
        sample: MemorySample,
        severity: Severity,
        processName: String,
        formatter: ISO8601DateFormatter
    ) -> String {
        let rss = sample.processResidentBytes
        let fields: [String] = [
            formatter.string(from: sample.timestamp),
            processName,
            sample.isProcessRunning ? String(rss) : "",
            sample.isProcessRunning ? ByteFormatting.detailed(rss) : "not running",
            String(sample.process?.processCount ?? 0),
            String(sample.system.totalBytes),
            String(sample.system.freeBytes),
            String(sample.system.compressedBytes),
            String(sample.system.pageSize),
            severity.title.lowercased(),
        ]
        return fields.joined(separator: ",")
    }

    private func write(line: String) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            let contents = Self.header + "\n" + line + "\n"
            try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func rotateIfNeeded() {
        let manager = FileManager.default
        guard
            let attributes = try? manager.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? UInt64,
            size >= maxBytes
        else { return }

        // Drop the oldest, then shift each rotation one slot down.
        let oldest = rotatedURL(index: keepRotations)
        try? manager.removeItem(at: oldest)
        for index in stride(from: keepRotations - 1, through: 1, by: -1) {
            let source = rotatedURL(index: index)
            guard manager.fileExists(atPath: source.path) else { continue }
            try? manager.moveItem(at: source, to: rotatedURL(index: index + 1))
        }
        try? manager.moveItem(at: fileURL, to: rotatedURL(index: 1))
    }

    private func rotatedURL(index: Int) -> URL {
        fileURL.deletingPathExtension()
            .appendingPathExtension("\(index)")
            .appendingPathExtension(fileURL.pathExtension)
    }
}
