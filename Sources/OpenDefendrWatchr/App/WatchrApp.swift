import AppKit
import SwiftUI

/// Menu-bar-only app. No Dock icon, no window on launch.
public struct WatchrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = WatchdogModel()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(model: model)
        } label: {
            // Glyph + compact figure. The glyph changes shape (not just colour) with
            // severity so it stays readable as a template image in light and dark menu bars.
            Label(model.menuBarTitle, systemImage: model.severity.symbolName)
                .onAppear { model.start() }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView(preferences: model.preferences)
        }
    }
}

/// `LSUIElement` covers the bundled app; this covers `swift run`, where there is no
/// Info.plist to read.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
