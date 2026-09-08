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
        case .collection(let collection, let warnings):
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

    /// The formats File ▸ Import understands.
    enum ImportOutcome: Sendable {
        case collection(RequestCollection, warnings: [String])
        case environment(RequestEnvironment)
        case request(RequestItem, warnings: [String])
        case failure(String)
    }

    /// Sniffing and parsing, off the main thread: a large Postman export is a real parse.
    @concurrent
    static func decodeImport(_ data: Data, named name: String) async -> ImportOutcome {
        // A YAML OpenAPI document is neither curl nor JSON; say what to do about it rather than
        // letting it fall through to "this is not JSON".
        if OpenAPIImporter.looksLikeYAML(data) {
            return .failure(
                OpenAPIImporter.ImportError.looksLikeYAML.localizedDescription)
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
                "“\(name)” is neither JSON nor a curl command.")
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
                return .collection(result.collection, warnings: result.warnings)
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
