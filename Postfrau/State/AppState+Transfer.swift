import Foundation
import PostfrauCore

extension AppState {
    /// What an import produced, so the sheet can say what happened before anything is kept.
    struct ImportReport: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        var warnings: [String]
    }

    /// An OpenAPI spec whose title matches a collection that is already here: the user is asked
    /// whether it is a newer version of that one or a separate collection.
    struct PendingSpecUpdate: Identifiable {
        let id = UUID()
        var incoming: RequestCollection
        var warnings: [String]
        var targetID: UUID
        var targetName: String
        var fileName: String
    }

    // MARK: - Importing

    /// File ▸ Import…: one panel for every format Postfrau reads.
    func runImportPanel() {
        guard let url = FileDialogs.chooseFileForImport() else { return }
        Task { await importFile(at: url) }
    }

    /// Reads a file and works out what it is, rather than making the user say.
    ///
    /// A Postman collection, a Postman environment and a saved curl command are all things people
    /// have lying around; asking which one this is would be asking a question the file answers.
    func importFile(at url: URL) async {
        let didOpen = url.startAccessingSecurityScopedResource()
        defer { if didOpen { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            importReport = ImportReport(
                title: "Could not read the file",
                detail: "Postfrau could not open “\(url.lastPathComponent)”.",
                warnings: [])
            return
        }
        await importData(data, named: url.lastPathComponent)
    }

    func importData(_ data: Data, named name: String) async {
        let outcome = await Self.decodeImport(data, named: name)

        switch outcome {
        case .openAPI(let collection, let warnings):
            // The same API again is far more often a newer spec than a second copy, so ask.
            if let existing = workspace.collections.first(where: {
                $0.name.localizedCaseInsensitiveCompare(collection.name) == .orderedSame
            }) {
                pendingSpecUpdate = PendingSpecUpdate(
                    incoming: collection, warnings: warnings, targetID: existing.id,
                    targetName: existing.name, fileName: name)
            } else {
                addImportedCollection(collection, warnings: warnings, from: name)
            }

        case .collection(let collection, let warnings):
            addImportedCollection(collection, warnings: warnings, from: name)

        case .environment(let environment):
            workspace.environments.append(environment)
            workspace.environments.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            markDirty(environment: environment.id)
            persistSecrets(for: environment)
            importReport = ImportReport(
                title: "Imported “\(environment.name)”",
                detail: "\(environment.variables.count) variable(s) in \(name).",
                warnings: environment.variables.contains(where: \.isSecret)
                    ? ["Secret values were moved into this Mac's keychain."]
                    : [])

        case .request(let request, let warnings):
            let tab = newTab()
            tab.draft = request
            tab.markSaved()
            importReport = warnings.isEmpty
                ? nil
                : ImportReport(
                    title: "Imported a curl command",
                    detail: request.url,
                    warnings: warnings)

        case .failure(let message):
            importReport = ImportReport(
                title: "Could not import \(name)", detail: message, warnings: [])
        }
    }

    func addImportedCollection(_ collection: RequestCollection, warnings: [String], from name: String) {
        workspace.collections.append(collection)
        workspace.collections.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        expandedIDs.insert(collection.id)
        markDirty(collection: collection.id)
        invalidateSidebarCache()
        sidebarSection = .collections
        importReport = ImportReport(
            title: "Imported “\(collection.name)”",
            detail: "\(collection.requestCount) request(s) in \(name).",
            warnings: warnings)
    }

    /// Answers `pendingSpecUpdate`: merge into the matching collection, or add a new one.
    func resolvePendingSpecUpdate(updating: Bool) {
        guard let pending = pendingSpecUpdate else { return }
        pendingSpecUpdate = nil
        if updating {
            Task {
                await applySpecUpdate(
                    pending.incoming, warnings: pending.warnings, into: pending.targetID,
                    from: pending.fileName)
            }
        } else {
            addImportedCollection(pending.incoming, warnings: pending.warnings, from: pending.fileName)
        }
    }

    // MARK: - Updating from OpenAPI

    /// The collection menu's Update from OpenAPI…: a newer spec merged into this collection.
    func runUpdateFromOpenAPIPanel(collectionID: UUID) {
        guard let url = FileDialogs.chooseOpenAPISpec() else { return }
        Task { await updateCollection(collectionID, fromSpecAt: url) }
    }

    func updateCollection(_ collectionID: UUID, fromSpecAt url: URL) async {
        let didOpen = url.startAccessingSecurityScopedResource()
        defer { if didOpen { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            importReport = ImportReport(
                title: "Could not read the file",
                detail: "Postfrau could not open “\(name)”.", warnings: [])
            return
        }
        switch await Self.decodeImport(data, named: name) {
        case .openAPI(let incoming, let warnings):
            await applySpecUpdate(incoming, warnings: warnings, into: collectionID, from: name)
        case .failure(let message):
            importReport = ImportReport(title: "Could not read \(name)", detail: message, warnings: [])
        default:
            importReport = ImportReport(
                title: "\(name) is not an OpenAPI document",
                detail: "Update from OpenAPI reads an OpenAPI 3 spec, in JSON or YAML.",
                warnings: [])
        }
    }

    /// Merges a newer spec into a collection as one undoable step, and reports what changed.
    ///
    /// Dropped operations are moved to a folder rather than deleted: nothing the user typed is
    /// lost by an update, and deleting the folder afterwards is one click. See D66.
    func applySpecUpdate(
        _ incoming: RequestCollection, warnings: [String], into collectionID: UUID,
        from name: String
    ) async {
        guard let existing = workspace.collection(withID: collectionID) else { return }
        let (merged, report) = await Self.mergeSpec(existing, incoming)
        // The workspace may have moved on while the merge ran; a stale result would undo that.
        guard workspace.collection(withID: collectionID) == existing else {
            importReport = ImportReport(
                title: "“\(existing.name)” changed during the update",
                detail: "Nothing was applied. Try again.", warnings: [])
            return
        }
        replace(collection: merged, actionName: "Update from OpenAPI")
        invalidateSidebarCache()
        expandedIDs.insert(collectionID)
        sidebarSection = .collections
        importReport = ImportReport(
            title: "Updated “\(merged.name)” from \(name)",
            detail: report.summary + ".",
            warnings: warnings + report.details)
    }

    @concurrent
    static func mergeSpec(
        _ existing: RequestCollection, _ incoming: RequestCollection
    ) async -> (RequestCollection, OpenAPISync.Report) {
        let (merged, report) = OpenAPISync.update(existing, from: incoming)
        return (merged, report)
    }

    /// The formats File ▸ Import understands.
    enum ImportOutcome: Sendable {
        case collection(RequestCollection, warnings: [String])
        /// A collection read from an OpenAPI document, which can also update an existing one.
        case openAPI(RequestCollection, warnings: [String])
        case environment(RequestEnvironment)
        case request(RequestItem, warnings: [String])
        case failure(String)
    }

    /// Sniffing and parsing, off the main thread: a large Postman export is a real parse.
    @concurrent
    static func decodeImport(_ data: Data, named name: String) async -> ImportOutcome {
        // A YAML OpenAPI document is neither curl nor JSON.
        if OpenAPIImporter.looksLikeYAML(data) {
            do {
                let result = try OpenAPIImporter().import(data)
                return .openAPI(result.collection, warnings: result.warnings)
            } catch {
                return .failure(message(for: error))
            }
        }

        // curl first: a saved command is text, and text is never valid JSON here.
        if let text = String(data: data, encoding: .utf8), CurlParser.looksLikeCurl(text) {
            do {
                let result = try CurlParser().parse(text)
                return .request(result.request, warnings: result.warnings)
            } catch {
                return .failure(message(for: error))
            }
        }

        guard let root = try? Postfrau.makeDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            return .failure(
                "“\(name)” is not JSON, YAML or a curl command.")
        }

        if PostmanEnvironment.looksLikeEnvironment(object) {
            do { return .environment(try PostmanEnvironment.import(object)) }
            catch { return .failure(message(for: error)) }
        }

        // Checked before Postman: an OpenAPI document has an `info` block too, so the Postman
        // importer would accept it and produce a collection with no requests in it.
        if OpenAPIImporter.looksLikeOpenAPI(object) {
            do {
                let result = try OpenAPIImporter().import(object)
                return .openAPI(result.collection, warnings: result.warnings)
            } catch {
                return .failure(message(for: error))
            }
        }

        do {
            let result = try PostmanV21Importer().import(object)
            return .collection(result.collection, warnings: result.warnings)
        } catch {
            return .failure(message(for: error))
        }
    }

    /// Pasting a curl command into the URL bar fills in the whole request.
    ///
    /// - Returns: true when the text was a curl command and was consumed.
    @discardableResult
    func handlePastedCurl(_ text: String, into tab: RequestTab) -> Bool {
        guard CurlParser.looksLikeCurl(text) else { return false }
        guard let result = try? CurlParser().parse(text) else { return false }

        var request = result.request
        // The tab keeps its own name if it has one worth keeping.
        if !tab.draft.name.isEmpty && tab.draft.name != "New Request" {
            request.name = tab.draft.name
        }
        request.id = tab.draft.id
        tab.draft = request
        if !result.warnings.isEmpty {
            importReport = ImportReport(
                title: "Imported a curl command", detail: request.url,
                warnings: result.warnings)
        }
        return true
    }

    // MARK: - Exporting

    func exportCollection(_ id: UUID) {
        guard let collection = workspace.collection(withID: id) else { return }
        guard let data = try? PostmanV21Exporter().data(for: collection) else { return }
        FileDialogs.save(
            data, suggestedName: "\(Self.fileName(for: collection.name)).postman_collection.json")
    }

    func exportEnvironment(_ id: UUID) {
        guard let environment = workspace.environments.first(where: { $0.id == id }) else { return }
        guard let data = try? PostmanEnvironment.data(for: environment) else { return }
        FileDialogs.save(
            data, suggestedName: "\(Self.fileName(for: environment.name)).postman_environment.json")
    }

    /// ⌘⇧C — the request as a curl command, ready to paste.
    func copyAsCurl(_ tab: RequestTab, handling: CurlFormatter.VariableHandling = .resolved) {
        let command = CurlFormatter().format(
            tab.draft,
            resolver: resolver(for: tab),
            effectiveAuth: effectiveAuth(for: tab).auth,
            handling: handling)
        Pasteboard.copy(command)
    }

    /// Strips what a file name cannot hold, so a collection called "GET /users" can be saved.
    static func fileName(for name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}

extension AppState {
    /// The collection File ▸ Export Collection… would write: whatever the sidebar or the open tab
    /// is pointing at, so the menu item means something without a separate picker.
    var exportableCollectionID: UUID? {
        if let tab = selectedTab {
            if tab.kind == .collection, let id = tab.subjectID { return id }
            if let id = tab.collectionID { return id }
        }
        // The sidebar selects by item id, which may be a collection, a folder or a request.
        if let selected = sidebarSelection {
            if workspace.collection(withID: selected) != nil { return selected }
            if let owner = workspace.collectionContaining(itemID: selected) { return owner.id }
        }
        return workspace.collections.count == 1 ? workspace.collections.first?.id : nil
    }
}
