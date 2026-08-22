import XCTest

@testable import OpenDefendrWatchrKit

final class DefenderRestartServiceTests: XCTestCase {
    private final class SpyShell: CommandRunning, @unchecked Sendable {
        var result: CommandResult
        var invocations: [(String, [String])] = []

        init(result: CommandResult) { self.result = result }

        func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
            invocations.append((executable, arguments))
            return result
        }
    }

    func testTargetsTheDefenderLaunchdLabel() {
        XCTAssertEqual(DefenderRestartService.launchdLabel, "system/com.microsoft.fresno")
        XCTAssertEqual(
            DefenderRestartService.manualCommand,
            "sudo launchctl kickstart -k system/com.microsoft.fresno"
        )
    }

    func testElevatedCommandDoesNotUseSudoInsideTheAuthorizationBridge() {
        // The AppleScript body already runs as root; a nested `sudo` would try to prompt
        // on a tty that does not exist and hang.
        XCTAssertFalse(DefenderRestartService.elevatedShellCommand.contains("sudo"))
        let script = DefenderRestartService.appleScriptSource()
        XCTAssertEqual(
            script,
            "do shell script \"/bin/launchctl kickstart -k system/com.microsoft.fresno\" with administrator privileges"
        )
    }

    func testAttemptRunsOsascriptExactlyOnce() throws {
        let shell = SpyShell(result: CommandResult(exitCode: 0, standardOutput: "", standardError: ""))
        _ = try DefenderRestartService(shell: shell).attemptRestart()
        XCTAssertEqual(shell.invocations.count, 1)
        XCTAssertEqual(shell.invocations.first?.0, "/usr/bin/osascript")
        XCTAssertEqual(shell.invocations.first?.1.first, "-e")
    }

    func testFailureSummaryReportsTheRealOutputAndBlamesTamperProtection() throws {
        let shell = SpyShell(
            result: CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "Could not find service \"com.microsoft.fresno\": 113"
            ))
        let outcome = try DefenderRestartService(shell: shell).attemptRestart()

        XCTAssertFalse(outcome.result.succeeded)
        XCTAssertFalse(outcome.userCancelled)
        XCTAssertTrue(outcome.summary.contains("Exit code: 1"))
        XCTAssertTrue(outcome.summary.contains("113"), "raw stderr must survive to the user")
        XCTAssertTrue(outcome.summary.lowercased().contains("tamper protection"))
    }

    func testSuccessSummaryStillTellsTheUserToVerify() throws {
        let shell = SpyShell(
            result: CommandResult(exitCode: 0, standardOutput: "", standardError: ""))
        let outcome = try DefenderRestartService(shell: shell).attemptRestart()
        XCTAssertTrue(outcome.summary.contains("Exit code: 0"))
        XCTAssertTrue(outcome.summary.contains("stdout: (empty)"))
        XCTAssertTrue(outcome.summary.lowercased().contains("verify"))
    }

    func testCancelledAuthorizationIsNotReportedAsAFailedRestart() throws {
        let shell = SpyShell(
            result: CommandResult(
                exitCode: 1,
                standardOutput: "",
                standardError: "execution error: User canceled. (-128)"
            ))
        let outcome = try DefenderRestartService(shell: shell).attemptRestart()
        XCTAssertTrue(outcome.userCancelled)
        XCTAssertEqual(outcome.summary, "Cancelled before the restart was attempted.")
    }
}

final class AlertPresentationTests: XCTestCase {
    func testCriticalBodyCarriesTheNumbersAndAnActionableInstruction() {
        let alert = ThresholdAlert(
            severity: .critical,
            sample: MemorySample(
                timestamp: Date(timeIntervalSince1970: 0),
                process: ProcessMemoryUsage(residentBytes: 20_303_237_939, processCount: 1),
                system: Fixture.jetsamSystem
            ),
            thresholdBytes: 12 * Fixture.gb
        )

        XCTAssertEqual(
            AlertPresentation.title(for: alert, processName: "wdavdaemon"),
            "wdavdaemon memory critical")

        let body = AlertPresentation.body(for: alert, processName: "wdavdaemon")
        XCTAssertTrue(body.contains("18.91 GB"), body)
        XCTAssertTrue(body.contains("12.00 GB"), body)
        XCTAssertTrue(body.contains("132.67 MB"), "free memory belongs in the alert")
        XCTAssertTrue(body.contains("8.73 GB"), "compressor size belongs in the alert")
        XCTAssertTrue(body.contains("Save your work"))
    }

    func testWarningBodyDoesNotTellTheUserToReboot() {
        let alert = ThresholdAlert(
            severity: .warning,
            sample: Fixture.sample(bytes: 9 * Fixture.gb),
            thresholdBytes: 8 * Fixture.gb
        )
        let body = AlertPresentation.body(for: alert, processName: "wdavdaemon")
        XCTAssertFalse(body.contains("Save your work"))
        XCTAssertTrue(body.contains("9.00 GB"))
    }

    func testTestBodyShowsLiveFiguresRatherThanAContentFreePlaceholder() {
        let body = AlertPresentation.testBody(
            sample: Fixture.sample(bytes: 9 * Fixture.gb), processName: "wdavdaemon")
        XCTAssertTrue(body.contains("9.00 GB"), body)
        XCTAssertTrue(body.contains("free"), body)
    }

    func testTestBodyHandlesDefenderNotRunningAndNoSampleYet() {
        let notRunning = AlertPresentation.testBody(
            sample: Fixture.sample(bytes: nil), processName: "wdavdaemon")
        XCTAssertTrue(notRunning.contains("not running"), notRunning)

        let noSample = AlertPresentation.testBody(sample: nil, processName: "wdavdaemon")
        XCTAssertTrue(noSample.contains("No wdavdaemon reading yet"), noSample)
    }

    func testBlockedPermissionsExplainWhereToFixIt() {
        // A silently denied permission would make the entire watchdog useless, so the
        // message has to name the exact place to re-enable it.
        let description = NotificationDeliveryStatus.notAuthorized.userDescription
        XCTAssertTrue(description.contains("System Settings"), description)
        XCTAssertFalse(NotificationDeliveryStatus.notAuthorized.isSuccess)
        XCTAssertTrue(NotificationDeliveryStatus.delivered.isSuccess)
    }
}
