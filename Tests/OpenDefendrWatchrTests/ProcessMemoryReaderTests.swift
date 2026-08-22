import XCTest

@testable import OpenDefendrWatchrKit

/// Captured from `ps -Ao rss=,comm=` on the affected machine. Note the executable paths
/// containing spaces and the three `wdavdaemon*` siblings that must NOT be conflated.
private let realPSOutput = """
      556    908 /usr/sbin/distnoted
      557 116208 /Applications/Microsoft Defender.app/Contents/MacOS/wdavdaemon
      592  33424 /Library/SystemExtensions/37687808-6529-4B0F-9338-20E702622FEB/com.microsoft.wdav.netext.systemextension/Contents/MacOS/netext
      682 108656 /Applications/Microsoft Defender.app/Contents/MacOS/wdavdaemon_enterprise.app/Contents/MacOS/wdavdaemon_enterprise
     1869 282560 /Applications/Microsoft Defender.app/Contents/MacOS/wdavdaemon_unprivileged.app/Contents/MacOS/wdavdaemon_unprivileged
"""

final class PSOutputParserTests: XCTestCase {
    /// The real `ps -Ao rss=,comm=` format is `<rss> <command>` with no PID column; the
    /// fixture above includes a leading PID column to prove the parser is not silently
    /// picking the wrong field. Strip it to get the true format.
    private var processTableOutput: String {
        realPSOutput
            .split(separator: "\n")
            .map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let space = trimmed.firstIndex(of: " ") else { return trimmed }
                return String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(
                    in: .whitespaces)
            }
            .joined(separator: "\n")
    }

    func testParsesRSSAndExecutableName() {
        let rows = PSOutputParser.parseProcessTable(processTableOutput)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[1].name, "wdavdaemon")
        XCTAssertEqual(rows[1].residentBytes, 116_208 * 1024, "ps reports kibibytes")
    }

    func testHandlesExecutablePathsContainingSpaces() {
        let rows = PSOutputParser.parseProcessTable(processTableOutput)
        XCTAssertTrue(
            rows.contains { $0.name == "wdavdaemon_enterprise" },
            "'/Applications/Microsoft Defender.app/...' must not be split on its space"
        )
    }

    func testDoesNotConfuseSiblingDefenderExecutables() {
        let rows = PSOutputParser.parseProcessTable(processTableOutput)
        let usage = PSOutputParser.aggregate(rows, matching: "wdavdaemon")
        XCTAssertEqual(usage?.processCount, 1)
        XCTAssertEqual(
            usage?.residentBytes, 116_208 * 1024,
            "wdavdaemon_enterprise and wdavdaemon_unprivileged must be excluded"
        )
    }

    func testAggregatesMultipleMatchingProcesses() {
        let output = """
            100 /usr/bin/wdavdaemon
            200 /opt/wdavdaemon
            """
        let usage = PSOutputParser.aggregate(
            PSOutputParser.parseProcessTable(output), matching: "wdavdaemon")
        XCTAssertEqual(usage?.processCount, 2)
        XCTAssertEqual(usage?.residentBytes, 300 * 1024)
    }

    func testReturnsNilWhenTheProcessIsAbsent() {
        // Distinct from "0 bytes": the UI shows a dedicated "not running" state.
        let usage = PSOutputParser.aggregate(
            PSOutputParser.parseProcessTable(processTableOutput), matching: "wdavdaemon")
        XCTAssertNotNil(usage)
        XCTAssertNil(
            PSOutputParser.aggregate(
                PSOutputParser.parseProcessTable("100 /usr/sbin/distnoted"),
                matching: "wdavdaemon"))
    }

    func testIgnoresMalformedLines() {
        let output = """

            not-a-number /usr/bin/wdavdaemon
            42
            123 /usr/bin/wdavdaemon
            """
        let rows = PSOutputParser.parseProcessTable(output)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].residentBytes, 123 * 1024)
    }

    func testParsesBareResidentSizeList() {
        XCTAssertEqual(
            PSOutputParser.parseResidentSizes(" 116208\n 108656\n"),
            [116_208 * 1024, 108_656 * 1024]
        )
        XCTAssertEqual(PSOutputParser.parseResidentSizes(""), [])
    }
}

final class CompositeProcessMemoryReaderTests: XCTestCase {
    private struct StubShell: CommandRunning {
        let result: CommandResult
        let recorder: Recorder

        final class Recorder: @unchecked Sendable {
            var invocations: [(String, [String])] = []
        }

        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
            recorder.invocations.append((executable, arguments))
            return result
        }
    }

    private func reader(
        processes: [RunningProcess],
        direct: @escaping @Sendable (Int32) -> UInt64?,
        shellOutput: String,
        recorder: StubShell.Recorder = .init()
    ) -> (CompositeProcessMemoryReader, StubShell.Recorder) {
        let shell = StubShell(
            result: CommandResult(exitCode: 0, standardOutput: shellOutput, standardError: ""),
            recorder: recorder
        )
        return (
            CompositeProcessMemoryReader(
                lister: { processes }, directResidentBytes: direct, shell: shell),
            recorder
        )
    }

    private func process(_ pid: Int32, _ name: String) -> RunningProcess {
        RunningProcess(pid: pid, executableName: name, executablePath: "/usr/bin/" + name)
    }

    func testUsesLibprocAndAvoidsSpawningPSWhenPermitted() throws {
        let (subject, recorder) = reader(
            processes: [process(557, "wdavdaemon"), process(682, "wdavdaemon_enterprise")],
            direct: { $0 == 557 ? 1024 : 4096 },
            shellOutput: ""
        )
        let usage = try subject.usage(forExecutableNamed: "wdavdaemon")
        XCTAssertEqual(usage?.residentBytes, 1024)
        XCTAssertEqual(usage?.pids, [557])
        XCTAssertTrue(recorder.invocations.isEmpty, "no subprocess should be spawned")
    }

    func testFallsBackToPSForRootOwnedProcesses() throws {
        // proc_pid_rusage returns EPERM for root daemons such as wdavdaemon.
        let (subject, recorder) = reader(
            processes: [process(557, "wdavdaemon")],
            direct: { _ in nil },
            shellOutput: "116208\n"
        )
        let usage = try subject.usage(forExecutableNamed: "wdavdaemon")
        XCTAssertEqual(usage?.residentBytes, 116_208 * 1024)
        XCTAssertEqual(recorder.invocations.count, 1)
        XCTAssertEqual(recorder.invocations.first?.1, ["-o", "rss=", "-p", "557"])
    }

    func testFallsBackToFullProcessTableWhenEnumerationFindsNothing() throws {
        let (subject, recorder) = reader(
            processes: [],
            direct: { _ in nil },
            shellOutput: "116208 /Applications/Microsoft Defender.app/Contents/MacOS/wdavdaemon\n"
        )
        let usage = try subject.usage(forExecutableNamed: "wdavdaemon")
        XCTAssertEqual(usage?.residentBytes, 116_208 * 1024)
        XCTAssertEqual(recorder.invocations.first?.1, ["-Ao", "rss=,comm="])
    }

    func testReportsNotRunningWhenNothingMatchesAnywhere() throws {
        let (subject, _) = reader(
            processes: [], direct: { _ in nil }, shellOutput: "908 /usr/sbin/distnoted\n")
        XCTAssertNil(try subject.usage(forExecutableNamed: "wdavdaemon"))
    }
}

final class LibprocProcessListerTests: XCTestCase {
    func testEnumeratesTheCurrentProcess() {
        // Guards the pid-count/byte-count ambiguity in proc_listallpids: an off-by-4x
        // truncation there silently hides processes with high PIDs.
        let processes = LibprocProcessLister.allProcesses()
        XCTAssertGreaterThan(processes.count, 10)
        let ownPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(
            processes.contains { $0.pid == ownPID },
            "the test process itself must be enumerated"
        )
    }

    func testReadsResidentMemoryOfTheCurrentProcess() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let bytes = LibprocProcessLister.residentBytes(for: ownPID)
        XCTAssertNotNil(bytes)
        XCTAssertGreaterThan(bytes ?? 0, 1024 * 1024)
    }
}
