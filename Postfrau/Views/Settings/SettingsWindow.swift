import SwiftUI
import PostfrauCore

/// The Settings window (⌘,).
///
/// Data and History so far; General and Advanced arrive with the Phase 12 polish pass.
struct SettingsWindow: View {
    var body: some View {
        TabView {
            Tab("Data", systemImage: "folder") {
                DataSettings()
            }
            Tab("History", systemImage: "clock.arrow.circlepath") {
                HistorySettings()
            }
        }
        .frame(width: 580, height: 500)
    }
}

/// What Postfrau keeps about the requests you send.
struct HistorySettings: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                Picker("Record", selection: recording) {
                    ForEach(HistoryRecordLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Text(state.settings.historyRecording.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if state.settings.historyRecording.recordsBodies {
                    Picker("Body size limit", selection: bodyCap) {
                        ForEach(Self.bodyCaps, id: \.self) { bytes in
                            Text(ByteCount.format(bytes)).tag(bytes)
                        }
                    }
                    .help("Larger bodies are recorded up to this size and marked truncated.")
                }
            } header: {
                Text("Recording")
            } footer: {
                Text(
                    "Credentials are replaced with \(HistoryRedactor.placeholder) before anything "
                        + "is written, at every level. History never leaves this Mac: it is stored "
                        + "outside the synced data folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Storage") {
                Picker("Keep at most", selection: maxEntries) {
                    ForEach(Self.entryCaps, id: \.self) { count in
                        Text("\(count) sends").tag(count)
                    }
                }
                LabeledContent("Recorded now") {
                    Text("\(state.historyEntries.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Delete All History…", role: .destructive) {
                    state.isConfirmingClearHistory = true
                }
                .disabled(state.historyEntries.isEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete all history?",
            isPresented: Binding(
                get: { state.isConfirmingClearHistory },
                set: { state.isConfirmingClearHistory = $0 }),
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { state.clearHistory() }
            Button("Cancel", role: .cancel) {}
        }
    }

    static let bodyCaps = [64 * 1024, 256 * 1024, 1024 * 1024, 8 * 1024 * 1024]
    static let entryCaps = [100, 500, 1000, 5000, 20_000]

    private var recording: Binding<HistoryRecordLevel> {
        setting(\.historyRecording)
    }

    private var bodyCap: Binding<Int> {
        setting(\.historyBodyCapBytes)
    }

    /// Changing the cap has to reach the store too, or the next prune uses the old number.
    private var maxEntries: Binding<Int> {
        Binding(
            get: { state.settings.maxHistoryEntries },
            set: { newValue in
                state.settings.maxHistoryEntries = newValue
                state.markSettingsDirty()
                Task { await state.history.setMaxEntries(newValue) }
            })
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
