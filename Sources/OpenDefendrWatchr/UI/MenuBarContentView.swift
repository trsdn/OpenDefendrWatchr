import AppKit
import SwiftUI

/// Contents of the menu bar menu.
public struct MenuBarContentView: View {
    @ObservedObject var model: WatchdogModel
    @ObservedObject var updates: UpdateManager
    private let restartService = DefenderRestartService()

    public init(model: WatchdogModel, updates: UpdateManager) {
        self.model = model
        self.updates = updates
    }

    public var body: some View {
        Text(model.statusLine)
        Text(model.systemLine)
        Text(model.pressureLine)
        Text(model.stallLine)
        Text(model.peakLine)
        if let lastUpdate = model.lastUpdate {
            Text("Updated \(lastUpdate.formatted(date: .omitted, time: .standard))")
        }

        Divider()

        Button("Refresh Now") {
            Task { await model.pollOnce() }
        }
        Button("Reveal Log in Finder") {
            revealLog()
        }
        Button("Send Test Notification") {
            model.sendTestNotification { status in
                presentResult(
                    title: status.isSuccess
                        ? "Test notification sent" : "Test notification not delivered",
                    message: status.userDescription
                )
            }
        }

        Divider()

        Button("Try Restart Defender…") {
            attemptRestart()
        }
        Button("Copy Restart Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(DefenderRestartService.manualCommand, forType: .string)
        }

        Divider()

        updateItems

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit OpenDefendrWatchr") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private var updateItems: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking for updates…")
        case .upToDate:
            Text("OpenDefendrWatchr is up to date")
        case .downloading(let version):
            Text("Downloading update \(version)…")
        case .readyToInstall(let version):
            Button("Install Update \(version) and Restart") {
                installUpdate()
            }
            Button("Later") {
                Task { await updates.dismiss() }
            }
        case .installing:
            Text("Installing update…")
        case .failed(let message):
            Text("Update failed: \(message)")
        }
        Button("Check for Updates…") {
            checkForUpdates()
        }
        .disabled(updates.isBusy || updates.hasPreparedUpdate)
        Toggle("Check for Updates Automatically", isOn: $updates.automaticChecksEnabled)
    }

    /// The menu closes on click, so the answer to a check the user asked for comes as an
    /// alert rather than as menu text they may never reopen the menu to see.
    private func checkForUpdates() {
        Task {
            await updates.check(userInitiated: true)
            switch updates.state {
            case .upToDate:
                presentResult(
                    title: "OpenDefendrWatchr is up to date",
                    message: "You are running the newest release."
                )
            case .failed(let message):
                presentResult(title: "Update check failed", message: message)
            case .readyToInstall(let version):
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "OpenDefendrWatchr \(version) is ready to install"
                alert.informativeText =
                    "OpenDefendrWatchr quits, updates itself and opens again. Monitoring pauses for a few seconds."
                alert.addButton(withTitle: "Install and Restart")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    installUpdate()
                }
            default:
                break
            }
        }
    }

    /// Stops polling first so the process is not replaced mid-sample. If installation
    /// fails the app keeps running, so polling resumes: a watchdog that silently stopped
    /// watching would be worse than no update.
    private func installUpdate() {
        Task {
            model.stop()
            if await !updates.installAndRelaunch() {
                model.start()
                if case .failed(let message) = updates.state {
                    presentResult(title: "Update could not be installed", message: message)
                }
            }
        }
    }

    private func revealLog() {
        let url = model.log.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func attemptRestart() {
        NSApp.activate(ignoringOtherApps: true)
        let mode = restartService.tamperProtectionMode()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Attempt to restart Microsoft Defender?"
        var info = """
            This runs:

            \(DefenderRestartService.manualCommand)

            You will be asked for administrator credentials.

            This will most likely FAIL: Defender's tamper protection actively blocks its own \
            daemon from being stopped or restarted. The attempt may also raise a tamper alert \
            with your IT or security team.
            """
        if let mode {
            info += "\n\nReported tamper protection mode: \(mode)."
        }
        info += "\n\nOpenDefendrWatchr never does this automatically."
        alert.informativeText = info
        alert.addButton(withTitle: "Attempt Restart")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let outcome: DefenderRestartService.Outcome
        do {
            outcome = try restartService.attemptRestart()
        } catch {
            presentResult(
                title: "Restart could not be started",
                message: "\(error)\n\nRun this manually instead:\n\(DefenderRestartService.manualCommand)"
            )
            return
        }

        presentResult(
            title: outcome.result.succeeded
                ? "Restart command completed" : "Restart attempt failed",
            message: outcome.summary
        )
    }

    private func presentResult(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Details")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message, forType: .string)
        }
    }
}
