import XCTest

@testable import OpenDefendrWatchrKit

final class SampleCSVLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OpenDefendrWatchrTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritesHeaderOnceAndOneRowPerSample() throws {
        let log = SampleCSVLog(directory: directory)
        log.append(sample: Fixture.sample(bytes: Fixture.gb, at: 0), severity: .normal)
        log.append(sample: Fixture.sample(bytes: 9 * Fixture.gb, at: 30), severity: .warning)

        let lines = try String(contentsOf: log.fileURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(String(lines[0]), SampleCSVLog.header)
        XCTAssertEqual(lines.filter { $0 == SampleCSVLog.header }.count, 1)
    }

    func testRowIsPastableCSVWithTheFieldsAnITTicketNeeds() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        let sample = MemorySample(
            timestamp: Date(timeIntervalSince1970: 1_767_225_600),  // 2026-01-01T00:00:00Z
            process: ProcessMemoryUsage(residentBytes: 20_303_237_939, processCount: 1),
            system: Fixture.jetsamSystem
        )
        let row = SampleCSVLog.row(
            sample: sample, severity: .critical, processName: "wdavdaemon", formatter: formatter)
        let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

        XCTAssertEqual(
            fields.count, SampleCSVLog.header.split(separator: ",").count,
            "row and header must stay aligned")
        XCTAssertEqual(fields[0], "2026-01-01T00:00:00Z")
        XCTAssertEqual(fields[1], "wdavdaemon")
        XCTAssertEqual(fields[2], "20303237939")
        XCTAssertEqual(fields[3], "18.91 GB")
        XCTAssertEqual(fields[6], String(Fixture.jetsamSystem.freeBytes))
        XCTAssertEqual(fields[7], String(Fixture.jetsamSystem.compressedBytes))
        XCTAssertEqual(fields[8], "16384")
        XCTAssertEqual(fields[9], "3", "available percentage, the figure severity derives from")
        XCTAssertEqual(fields[10], "critical")
        XCTAssertEqual(
            fields[11], "warning",
            "the raw latched dispatch level is recorded as context, not as the verdict")
        XCTAssertFalse(row.contains("\""), "no quoting needed keeps the CSV trivially parseable")
    }

    func testNotRunningRowKeepsTheBytesFieldEmptyRatherThanZero() {
        let formatter = ISO8601DateFormatter()
        let row = SampleCSVLog.row(
            sample: Fixture.sample(bytes: nil), severity: .normal, processName: "wdavdaemon",
            formatter: formatter)
        let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(fields[2], "", "an empty cell plots as a gap, a 0 would plot as a drop")
        XCTAssertEqual(fields[3], "not running")
    }

    func testRotatesWhenTheFileGrowsPastTheLimit() throws {
        let log = SampleCSVLog(directory: directory, maxBytes: 512, keepRotations: 2)
        for index in 0..<40 {
            log.append(
                sample: Fixture.sample(bytes: Fixture.gb, at: TimeInterval(index)),
                severity: .normal)
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertTrue(files.contains("wdavdaemon-memory.csv"))
        XCTAssertTrue(files.contains("wdavdaemon-memory.1.csv"))
        XCTAssertLessThanOrEqual(files.count, 3, "old rotations must be pruned, not kept forever")

        let current = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(current.hasPrefix(SampleCSVLog.header), "rotated file restarts with a header")
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        let path = SampleCSVLog.defaultDirectory().path
        XCTAssertTrue(path.hasSuffix("/Library/Application Support/OpenDefendrWatchr"), path)
    }

    // A real log on disk was found carrying a 10-column header above 14-column rows: the
    // header is only written when the file is created, so columns added later never reached
    // it. The rows still parse, they just line up under the wrong names — the worst kind of
    // failure for a file whose entire purpose is to be read by someone else during an
    // incident.
    func testStaleHeaderIsRotatedAwayInsteadOfLeftAboveMismatchedRows() throws {
        let log = SampleCSVLog(directory: directory)
        let staleHeader = "timestamp,process,rss_bytes,rss_human,severity"
        try (staleHeader + "\n" + "2026-08-28T05:58:01Z,wdavdaemon,83066880,79.22 MB,normal\n")
            .write(to: log.fileURL, atomically: true, encoding: .utf8)

        log.append(sample: Fixture.sample(bytes: Fixture.gb), severity: .normal)

        let current = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(
            current.hasPrefix(SampleCSVLog.header),
            "the live file must restart with a header that matches the rows being written")
        XCTAssertFalse(current.contains(staleHeader), "the stale header must not survive")

        let rotated = log.fileURL.deletingPathExtension()
            .appendingPathExtension("1").appendingPathExtension("csv")
        let archived = try String(contentsOf: rotated, encoding: .utf8)
        XCTAssertTrue(
            archived.hasPrefix(staleHeader),
            "old rows keep their own header rather than being deleted")
    }

    func testHeaderMatchingTheRowsIsLeftAlone() throws {
        let log = SampleCSVLog(directory: directory)
        log.append(sample: Fixture.sample(bytes: Fixture.gb), severity: .normal)
        log.append(sample: Fixture.sample(bytes: Fixture.gb), severity: .normal)

        let rotated = log.fileURL.deletingPathExtension()
            .appendingPathExtension("1").appendingPathExtension("csv")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: rotated.path),
            "a current header must not trigger a rotation")

        let current = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertEqual(
            current.split(separator: "\n").filter { $0 == SampleCSVLog.header }.count, 1)
    }

    func testHeaderColumnCountMatchesTheRowsItLabels() {
        let row = SampleCSVLog.row(
            sample: Fixture.sample(bytes: Fixture.gb),
            severity: .normal,
            processName: "wdavdaemon",
            formatter: ISO8601DateFormatter())
        XCTAssertEqual(
            SampleCSVLog.header.split(separator: ",", omittingEmptySubsequences: false).count,
            row.split(separator: ",", omittingEmptySubsequences: false).count,
            "every column written must have a name in the header")
    }

    /// Swap is context, not alarm — but an unreadable swap sysctl must leave the columns
    /// empty rather than claim 0 bytes in use, the same rule that governs every other
    /// missing measurement here.
    func testSwapIsRecordedAndUnknownSwapIsNotWrittenAsZero() throws {
        let columns = SampleCSVLog.header.components(separatedBy: ",")
        let used = try XCTUnwrap(columns.firstIndex(of: "swap_used_bytes"))
        let percent = try XCTUnwrap(columns.firstIndex(of: "swap_used_pct"))

        let measured = SampleCSVLog.row(
            sample: Fixture.sample(
                bytes: Fixture.gb,
                system: Fixture.system(
                    freeBytes: Fixture.gb,
                    compressedBytes: Fixture.gb,
                    swap: SwapUsage(totalBytes: 18_432, usedBytes: 17_976))),
            severity: .normal,
            processName: "wdavdaemon",
            formatter: ISO8601DateFormatter()
        ).components(separatedBy: ",")
        XCTAssertEqual(measured[used], "17976")
        XCTAssertEqual(measured[percent], "97.5")

        let unknown = SampleCSVLog.row(
            sample: Fixture.sample(bytes: Fixture.gb),
            severity: .normal,
            processName: "wdavdaemon",
            formatter: ISO8601DateFormatter()
        ).components(separatedBy: ",")
        XCTAssertEqual(unknown[used], "")
        XCTAssertEqual(unknown[percent], "")
    }
}
