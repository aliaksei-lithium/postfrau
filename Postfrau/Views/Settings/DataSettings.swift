import SwiftUI
import PostfrauCore

/// Settings ▸ Data: where the workspace lives, and whether secrets ride iCloud Keychain.
struct DataSettings: View {
    @Environment(AppState.self) private var state

    /// A folder the user picked that already holds a workspace: the sheet asks what to do with it.
    @State private var pendingFolder: URL?
    @State private var isRelocating = false
    /// Asked once rather than on every redraw of the window.
    @State private var iCloudDrive: URL?

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(
                            state.dataFolder.isDefault
                                ? "Inside Postfrau" : state.dataFolder.root.lastPathComponent,
                            systemImage: state.dataFolder.provider.symbolName)
                        Text(displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                    }
                }

                LabeledContent("Status") { StatusLine(folder: state.dataFolder) }

                if let problem = state.dataFolderProblem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }

                // Two rows: four buttons on one line truncate their titles at this width, and
                // "Use iCloud Driv…" is not a label anyone can act on.
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if iCloudDrive != nil {
                            Button("Use iCloud Drive…") { choose(startingAtICloud: true) }
                        }
                        Button("Choose Folder…") { choose(startingAtICloud: false) }
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Button("Reveal in Finder") { FileDialogs.reveal(state.dataFolder.root) }
                            .disabled(state.dataFolder.status != .ok)
                        Button("Use Default Location") {
                            Task { await state.useDefaultDataFolder() }
                        }
                        .disabled(state.dataFolder.isDefault)
                        Spacer(minLength: 0)
                    }
                }
                .disabled(isRelocating)
            } header: {
                Text("Data folder")
            } footer: {
                Text(
                    "Collections, environments and globals live here. Point it at a folder your "
                        + "sync client watches and another Mac picks the changes up. "
                        + "History and settings always stay on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Keep secrets in", selection: secretStorage) {
                    ForEach(SecretStorage.allCases) { storage in
                        Text(storage.displayName).tag(storage)
                    }
                }
                Text(state.settings.secretStorage.explanation)
                    .font(.callout)
                    .foregroundStyle(
                        state.settings.secretStorage == .dataFolder ? .orange : .secondary)

                if state.settings.secretStorage == .keychain {
                    Toggle("Sync secrets via iCloud Keychain", isOn: iCloudKeychain)
                }
                if let error = state.secretsError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Secrets")
            } footer: {
                Text(
                    "Changing this moves the secrets you already have. The Keychain ties its "
                        + "permission to the app's signature, so an unsigned build has to ask "
                        + "again after every update; the data folder never asks, and pays for it "
                        + "by holding the values in the clear.")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { iCloudDrive = FileDialogs.iCloudDriveRoot }
        .sheet(item: $pendingFolder) { folder in
            RelocationSheet(folder: folder) { choice in
                pendingFolder = nil
                guard let choice else { return }
                isRelocating = true
                Task {
                    await state.relocateDataFolder(to: folder, choice: choice)
                    isRelocating = false
                }
            }
        }
    }

    private var displayPath: String {
        state.dataFolder.root.path.replacingOccurrences(
            of: NSHomeDirectory(), with: "~")
    }

    private func choose(startingAtICloud: Bool) {
        let picked = FileDialogs.chooseFolder(
            prompt: "Use This Folder",
            message: startingAtICloud
                ? "Choose or create a folder in iCloud Drive for Postfrau to keep its collections in."
                : "Choose a folder for Postfrau to keep its collections in.",
            suggestedName: "Postfrau",
            startingAt: startingAtICloud ? iCloudDrive : nil)
        guard let picked else { return }

        Task {
            // An empty folder needs no question: there is nothing there to lose.
            if await AppState.containsWorkspace(picked) {
                pendingFolder = picked
            } else {
                isRelocating = true
                await state.relocateDataFolder(to: picked, choice: .moveDataHere)
                isRelocating = false
            }
        }
    }

    private var secretStorage: Binding<SecretStorage> {
        Binding(
            get: { state.settings.secretStorage },
            set: { storage in Task { await state.setSecretStorage(storage) } })
    }

    private var iCloudKeychain: Binding<Bool> {
        Binding(
            get: { state.settings.syncSecretsViaICloudKeychain },
            set: { state.setSecretsSyncEnabled($0) })
    }
}

/// The data folder's health, in a line.
struct StatusLine: View {
    var folder: DataFolder

    var body: some View {
        switch folder.status {
        case .ok:
            Label("Watching for changes", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .missing:
            Label("The folder is not there", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unreadable(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .staleBookmark:
            Label("Using the local copy", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

/// Asks what to do about the workspace already in the folder the user chose.
struct RelocationSheet: View {
    var folder: URL
    var onChoose: (RelocationChoice?) -> Void

    @State private var choice: RelocationChoice = .merge

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("“\(folder.lastPathComponent)” already holds a Postfrau workspace")
                    .font(.headline)
                Text("Nothing is deleted whichever you choose: the version that loses is kept "
                     + "as a copy you can open later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Picker("What should happen", selection: $choice) {
                ForEach(RelocationChoice.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(choice.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onChoose(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { onChoose(choice) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// `sheet(item:)` needs an `Identifiable`; a URL is a perfectly good identity for a folder.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
