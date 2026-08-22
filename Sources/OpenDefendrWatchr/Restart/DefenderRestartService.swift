import Foundation

/// Manual, user-initiated attempt to restart Microsoft Defender's daemon.
///
/// Design constraints, decided deliberately:
/// - **Never automatic.** Defender's tamper protection is in `block` mode on the machine
///   this app was written for. An unattended restart loop would fight the security
///   product and could look like an attack to the user's IT/security team.
/// - **No privileged helper.** No `SMJobBless`, no installed daemon. The attempt is a
///   one-shot `launchctl kickstart` elevated through the standard macOS authorization
///   prompt (`osascript ... with administrator privileges`). That is the smallest thing
///   that can work, and it keeps the app free of a persistent root component.
/// - **Report the truth.** stdout, stderr and the exit code are surfaced verbatim,
///   because "it probably failed" is exactly the information an IT ticket needs.
public struct DefenderRestartService: Sendable {
    /// launchd label of the Defender daemon.
    public static let launchdLabel = "system/com.microsoft.fresno"

    /// The command a user can paste into Terminal themselves.
    public static var manualCommand: String {
        "sudo launchctl kickstart -k \(launchdLabel)"
    }

    /// The command run inside the elevated AppleScript bridge. No `sudo`: the script is
    /// already running as root, and `sudo` there would try to prompt on a dead tty.
    public static var elevatedShellCommand: String {
        "/bin/launchctl kickstart -k \(launchdLabel)"
    }

    /// AppleScript source for the elevated attempt.
    public static func appleScriptSource() -> String {
        let escaped = elevatedShellCommand.replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    private let shell: CommandRunning

    public init(shell: CommandRunning = ProcessCommandRunner()) {
        self.shell = shell
    }

    public struct Outcome: Sendable, Equatable {
        public let result: CommandResult
        public let command: String

        public init(result: CommandResult, command: String) {
            self.result = result
            self.command = command
        }

        public var userCancelled: Bool {
            // osascript reports a cancelled authorization prompt as -128.
            result.exitCode == 1
                && (result.standardError.contains("-128")
                    || result.standardError.localizedCaseInsensitiveContains("User canceled"))
        }

        /// Human-readable outcome, including the raw output. Never a bare "success".
        public var summary: String {
            if userCancelled { return "Cancelled before the restart was attempted." }
            var lines = ["Command: \(command)", "Exit code: \(result.exitCode)"]
            let out = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let err = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("stdout: " + (out.isEmpty ? "(empty)" : out))
            lines.append("stderr: " + (err.isEmpty ? "(empty)" : err))
            if result.succeeded {
                lines.append(
                    "launchctl reported success. Verify in the menu bar that the process actually restarted — tamper protection can make a kickstart look successful while Defender restores itself.")
            } else {
                lines.append(
                    "The attempt failed. This is the expected result while tamper protection is set to 'block'; escalate to your IT/security team instead.")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Runs the elevated attempt. Caller is responsible for having obtained explicit
    /// user confirmation first.
    public func attemptRestart() throws -> Outcome {
        let result = try shell.run("/usr/bin/osascript", ["-e", Self.appleScriptSource()])
        return Outcome(result: result, command: Self.manualCommand)
    }

    /// Current tamper protection mode as reported by `mdatp`, e.g. `block`.
    /// Returns `nil` when `mdatp` is unavailable.
    public func tamperProtectionMode() -> String? {
        let path = "/usr/local/bin/mdatp"
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        guard
            let result = try? shell.run(path, ["health", "--field", "tamper_protection"]),
            result.succeeded
        else { return nil }
        return result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\"", with: "")
    }
}
