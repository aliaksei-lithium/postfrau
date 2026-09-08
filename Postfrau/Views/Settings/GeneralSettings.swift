import SwiftUI
import PostfrauCore

/// Settings ▸ General: how the app looks, and what a new request starts out as.
struct GeneralSettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Editor text size") {
                    HStack(spacing: 8) {
                        Slider(
                            value: setting(\.editorFontSize),
                            in: 9...20, step: 1)
                        .frame(width: 180)
                        Text("\(Int(state.settings.editorFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .accessibilityLabel("Editor text size in points")

                Picker("Response pane", selection: setting(\.responseLayout)) {
                    ForEach(ResponseLayout.allCases, id: \.self) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                Toggle("Wrap long response lines", isOn: setting(\.wrapResponseLines))
                Toggle("Show line numbers", isOn: setting(\.showResponseLineNumbers))
            }

            Section {
                LabeledContent("Timeout") {
                    HStack(spacing: 8) {
                        // The label is hidden: `LabeledContent` already says "Timeout", and a
                        // second one wraps to "Sec/ond/s" in the narrow trailing column.
                        TextField(
                            "Seconds",
                            value: setting(\.defaultTimeoutSeconds),
                            format: .number.precision(.fractionLength(0)))
                        .labelsHidden()
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
                Toggle("Verify TLS certificates", isOn: setting(\.defaultVerifyTLS))
            } header: {
                Text("New requests")
            } footer: {
                Text(
                    "These are the settings a newly created request starts with. Changing them "
                        + "here does not alter requests you have already saved — each one keeps "
                        + "its own, on its Settings tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Allow JavaScript in the HTML preview", isOn: setting(\.allowPreviewJavaScript))
            } header: {
                Text("Preview")
            } footer: {
                Text(
                    "Off by default. With it on, a previewed response can run scripts and load "
                        + "images, fonts and trackers from the network — which means a response "
                        + "you are only looking at can tell someone you looked.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setting<Value>(
        _ keyPath: WritableKeyPath<AppSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: {
                state.settings[keyPath: keyPath] = $0
                state.markSettingsDirty()
            })
    }
}
