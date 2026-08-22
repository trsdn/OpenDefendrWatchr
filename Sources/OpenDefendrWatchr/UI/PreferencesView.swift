import SwiftUI

public struct PreferencesView: View {
    @ObservedObject var preferences: Preferences
    @State private var launchAtLogin: Bool

    public init(preferences: Preferences) {
        self.preferences = preferences
        _launchAtLogin = State(initialValue: preferences.launchAtLoginEnabled)
    }

    public var body: some View {
        Form {
            Section("Sampling") {
                LabeledContent("Poll interval") {
                    HStack {
                        TextField(
                            "Seconds",
                            value: $preferences.pollInterval,
                            format: .number.precision(.fractionLength(0))
                        )
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        Text("seconds")
                    }
                }
            }

            Section("Thresholds") {
                thresholdRow("Warning at", value: $preferences.warningGigabytes)
                thresholdRow("Critical at", value: $preferences.criticalGigabytes)
                Text(
                    "Defaults assume 24 GB of RAM. The critical threshold is never allowed below the warning threshold."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .disabled(!preferences.launchAtLoginAvailable)
                    .onChange(of: launchAtLogin) { _, newValue in
                        preferences.launchAtLoginEnabled = newValue
                        launchAtLogin = preferences.launchAtLoginEnabled
                    }
                if !preferences.launchAtLoginAvailable {
                    Text("Available only when running the installed OpenDefendrWatchr.app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.vertical, 8)
    }

    private func thresholdRow(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                TextField(
                    "GB", value: value, format: .number.precision(.fractionLength(0...1))
                )
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
                Text("GB")
            }
        }
    }
}
