import Foundation

/// Updates a collection that was imported from an OpenAPI document from a newer version of it.
///
/// Requests are matched by operation — method plus path template, with parameter names ignored,
/// so `/deposits/{id}` and `/deposits/{depositId}` are the same operation. Each import stamps
/// every request with that key and a fingerprint of each field as the spec produced it, which
/// makes the update a three-way merge per field: a field the user has not touched since the
/// import takes the spec's new value; a field the user changed keeps the user's value, and is
/// reported when the spec changed it too. Params and headers merge row by row, so a new query
/// parameter in the spec arrives even in a request whose other params were filled in by hand.
///
/// Operations new to the spec are added beside their siblings; operations the spec no longer has
/// are moved into a "Removed from spec" folder, or deleted with `.remove`. See `docs/decisions.md`
/// D66 for the whole policy, including collections imported before the stamp existed.
public enum OpenAPISync {
    /// Where the stamp lives, in `extras` of each request and of the collection.
    public static let metadataKey = "x-postfrau-openapi"
    /// The folder that operations dropped from the spec are moved into.
    public static let removedFolderName = "Removed from spec"

    public enum DroppedPolicy: Sendable {
        /// Move them into the "Removed from spec" folder, so nothing the user wrote is lost.
        case flag
        /// Delete them — only requests carrying the import stamp; anything else is flagged.
        case remove
    }

    public struct Report: Sendable, Equatable {
        public var added: [String] = []
        public var updated: [String] = []
        public var unchanged = 0
        /// Requests where the user's edits were kept although the spec changed the same field,
        /// with the fields named: `"List pets (body, params)"`.
        public var keptEdits: [String] = []
        public var flagged: [String] = []
        public var removed: [String] = []
        public var warnings: [String] = []

        public init() {}

        /// One line for a sheet or a terminal.
        public var summary: String {
            var parts = ["\(added.count) added", "\(updated.count) updated",
                         "\(unchanged) unchanged"]
            if !flagged.isEmpty { parts.append("\(flagged.count) moved to “\(OpenAPISync.removedFolderName)”") }
            if !removed.isEmpty { parts.append("\(removed.count) removed") }
            if !keptEdits.isEmpty { parts.append("\(keptEdits.count) kept your edits") }
            return parts.joined(separator: ", ")
        }

        /// The details worth reading, as a list of lines.
        public var details: [String] {
            var lines: [String] = []
            lines += added.map { "Added “\($0)”." }
            lines += keptEdits.map { "Kept your edits to \($0); the spec changed them too." }
            lines += flagged.map {
                "“\($0)” is no longer in the spec; moved to “\(OpenAPISync.removedFolderName)”."
            }
            lines += removed.map { "Removed “\($0)”, which is no longer in the spec." }
            return warnings + lines
        }
    }

    // MARK: - Operation keys

    /// `GET /deposits/{}` — the method and the path template with parameter names erased.
    public static func operationKey(method: String, path: String) -> String {
        var out = ""
        var inside = false
        for c in path {
            if c == "{" {
                if !inside { out += "{}" }
                inside = true
            } else if c == "}" {
                inside = false
            } else if !inside {
                out.append(c)
            }
        }
        return "\(method.uppercased()) \(out)"
    }

    /// The key the import stamped on a request.
    public static func stampedKey(of request: RequestItem) -> String? {
        request.extras[metadataKey]?["operation"]?.stringValue
    }

    /// The key a request would have, worked out from its URL — for collections imported before
    /// requests were stamped. Only `{{baseUrl}}/…` URLs qualify, since that is what the importer
    /// writes.
    static func derivedKey(of request: RequestItem) -> String? {
        let prefix = "{{baseUrl}}"
        let url = URLQuery.stripQuery(from: request.url)
        guard url.hasPrefix(prefix) else { return nil }
        let path = String(url.dropFirst(prefix.count))
        // `{{id}}` → `{}`; the erasing in `operationKey` handles the doubled braces.
        return operationKey(method: request.method.rawValue, path: path)
    }

    // MARK: - Stamping

    /// Records the operation and a fingerprint of each field, as imported.
    static func stamp(_ request: inout RequestItem, operation: String) {
        request.extras[metadataKey] = .object([
            "operation": .string(operation),
            "base": .object(fingerprints(of: request)),
        ])
    }

    static func stamp(_ collection: inout RequestCollection) {
        collection.extras[metadataKey] = .object([
            "base": .object(fingerprints(of: collection)),
        ])
    }

    static func fingerprints(of request: RequestItem) -> [String: JSONValue] {
        [
            "name": .string(hash(request.name)),
            "description": .string(hash(request.description ?? "")),
            "path": .string(hash(URLQuery.stripQuery(from: request.url))),
            "auth": .string(hash(canonical(request.auth))),
            "body": .string(hash(canonical(request.body))),
            "params": .object(rowFingerprints(request.params, caseInsensitive: false)),
            "headers": .object(rowFingerprints(request.headers, caseInsensitive: true)),
        ]
    }

    static func fingerprints(of collection: RequestCollection) -> [String: JSONValue] {
        [
            "description": .string(hash(collection.description ?? "")),
            "auth": .string(hash(canonical(collection.auth))),
            "baseUrl": .string(hash(baseURL(of: collection) ?? "")),
        ]
    }

    static func rowFingerprints(_ rows: [KeyValue], caseInsensitive: Bool) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for row in rows {
            let key = caseInsensitive ? row.key.lowercased() : row.key
            if out[key] == nil { out[key] = .string(rowHash(row)) }
        }
        return out
    }

    static func rowHash(_ row: KeyValue) -> String {
        hash([row.key, row.value, String(row.enabled), row.description ?? ""]
            .joined(separator: "\u{1F}"))
    }

    static func baseURL(of collection: RequestCollection) -> String? {
        collection.variables.first { $0.key == "baseUrl" }?.value
    }

    /// Sorted-key JSON with every `id` removed: form rows get fresh UUIDs on every import, and
    /// they must not make an untouched body look edited.
    static func canonical<T: Encodable>(_ value: T) -> String {
        let encoder = Postfrau.makeEncoder(pretty: false)
        guard let data = try? encoder.encode(value),
              let json = try? Postfrau.makeDecoder().decode(JSONValue.self, from: data),
              let clean = try? encoder.encode(withoutIDs(json))
        else { return "" }
        return String(decoding: clean, as: UTF8.self)
    }

    private static func withoutIDs(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let fields):
            var out: [String: JSONValue] = [:]
            for (key, field) in fields where key != "id" { out[key] = withoutIDs(field) }
            return .object(out)
        case .array(let items):
            return .array(items.map(withoutIDs))
        default:
            return value
        }
    }

    /// FNV-1a, 64 bits. Stable across launches and machines, which `Hasher` is not.
    static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100_0000_01b3
        }
        return String(value, radix: 16)
    }

    // MARK: - Updating

    /// Merges a freshly imported collection into an existing one.
    ///
    /// - Parameters:
    ///   - existing: the collection in the workspace, with whatever the user has done to it.
    ///   - incoming: `OpenAPIImporter` output for the new version of the spec.
    public static func update(
        _ existing: RequestCollection,
        from incoming: RequestCollection,
        dropped: DroppedPolicy = .flag
    ) -> (collection: RequestCollection, report: Report) {
        var report = Report()
        var result = existing

        // The incoming operations, each with the folder the importer put it in.
        var remoteOps: [(key: String, request: RequestItem, folder: String?)] = []
        for item in incoming.items {
            switch item {
            case .request(let request):
                if let key = stampedKey(of: request) { remoteOps.append((key, request, nil)) }
            case .folder(let folder):
                for case .request(let request) in folder.items {
                    if let key = stampedKey(of: request) { remoteOps.append((key, request, folder.name)) }
                }
            }
        }
        let remoteKeys = Set(remoteOps.map(\.key))

        // The existing requests by operation. Once anything in a collection is stamped, only
        // stamped requests take part: anything else is the user's own and is left alone.
        let localRequests = existing.allRequests().map(\.request)
        let isLegacy = !localRequests.contains { stampedKey(of: $0) != nil }
        var localByKey: [String: [UUID]] = [:]
        var localOrder: [String] = []
        for request in localRequests {
            guard let key = stampedKey(of: request) ?? (isLegacy ? derivedKey(of: request) : nil)
            else { continue }
            if localByKey[key] == nil { localOrder.append(key) }
            localByKey[key, default: []].append(request.id)
        }
        if isLegacy && !localByKey.isEmpty {
            report.warnings.append(
                "This collection was imported before Postfrau kept a record of what the spec said, "
                    + "so requests were matched by URL and your values were kept; only new "
                    + "params, headers and descriptions came across. Later updates apply every "
                    + "change you have not edited.")
        }

        let nonEmptyFoldersBefore = Self.nonEmptyFolderIDs(in: existing.items)
        let removedFolderID = result.items.first {
            $0.asFolder?.name == removedFolderName
        }?.id
        var placements: [String: UUID?] = [:]

        func placement(for folderName: String?) -> UUID? {
            guard let folderName else { return nil }
            if let known = placements[folderName] { return known }
            // Beside the siblings the user already has, wherever they have put them.
            for op in remoteOps where op.folder == folderName {
                for id in localByKey[op.key] ?? [] {
                    guard let chain = result.folderChain(to: id),
                          !(chain.first.map { $0 == removedFolderID } ?? false)
                    else { continue }
                    placements[folderName] = chain.last
                    return chain.last
                }
            }
            // Else a top-level folder of that name, or a new one.
            let id: UUID
            if let existingFolder = result.items.first(where: {
                $0.asFolder?.name.caseInsensitiveCompare(folderName) == .orderedSame
            }) {
                id = existingFolder.id
            } else {
                let folder = Folder(name: folderName)
                let index = result.items.firstIndex { $0.id == removedFolderID } ?? result.items.count
                result.items.insert(.folder(folder), at: index)
                id = folder.id
            }
            placements[folderName] = id
            return id
        }

        // Matched and new operations.
        for op in remoteOps {
            guard let ids = localByKey[op.key] else {
                var request = op.request
                request.id = UUID()
                _ = result.insert(.request(request), into: placement(for: op.folder))
                report.added.append(request.name)
                continue
            }
            for id in ids {
                guard let local = result.request(withID: id) else { continue }
                let (merged, kept) = merge(local, with: op.request, legacy: stampedKey(of: local) == nil)
                result.replace(.request(merged))
                if !kept.isEmpty {
                    report.keptEdits.append("“\(merged.name)” (\(kept.joined(separator: ", ")))")
                }
                if Self.sameExceptExtras(merged, local) {
                    report.unchanged += 1
                } else {
                    report.updated.append(merged.name)
                }
                // Back in the spec: out of the "removed" folder, to where it belongs.
                if let removedFolderID,
                   result.folderChain(to: id)?.first == removedFolderID,
                   let moved = result.remove(itemWithID: id) {
                    _ = result.insert(moved, into: placement(for: op.folder))
                }
            }
        }

        // Operations the spec no longer has.
        for key in localOrder where !remoteKeys.contains(key) {
            for id in localByKey[key] ?? [] {
                guard let request = result.request(withID: id) else { continue }
                if dropped == .remove, stampedKey(of: request) != nil {
                    result.remove(itemWithID: id)
                    report.removed.append(request.name)
                    continue
                }
                let folderID: UUID
                if let existingID = result.items.first(where: {
                    $0.asFolder?.name == removedFolderName
                })?.id {
                    folderID = existingID
                } else {
                    let folder = Folder(name: removedFolderName)
                    result.items.append(.folder(folder))
                    folderID = folder.id
                }
                guard result.folderChain(to: id)?.first != folderID else { continue }
                if let moved = result.remove(itemWithID: id) {
                    _ = result.insert(moved, into: folderID)
                    report.flagged.append(request.name)
                }
            }
        }

        // Folders this update emptied go; ones the user left empty stay.
        result.items = Self.prune(result.items, emptiedFrom: nonEmptyFoldersBefore)

        // The collection itself.
        let base = existing.extras[metadataKey]?["base"]?.objectValue
        func pick<T>(_ field: String, _ local: T, _ remote: T, _ text: (T) -> String, legacyTakesRemote: Bool) -> T {
            let l = hash(text(local)), r = hash(text(remote))
            guard l != r else { return local }
            guard let b = base?[field]?.stringValue else { return legacyTakesRemote ? remote : local }
            return b == l ? remote : local
        }
        result.description = pick(
            "description", existing.description, incoming.description, { $0 ?? "" },
            legacyTakesRemote: true)
        result.auth = pick("auth", existing.auth, incoming.auth, canonical, legacyTakesRemote: false)
        if let remoteBase = baseURL(of: incoming) {
            if let index = result.variables.firstIndex(where: { $0.key == "baseUrl" }) {
                result.variables[index].value = pick(
                    "baseUrl", result.variables[index].value, remoteBase, { $0 },
                    legacyTakesRemote: false)
            } else {
                result.variables.append(Variable(key: "baseUrl", value: remoteBase))
            }
        }
        // What the importer keeps of the document, and the new stamp.
        result.extras = incoming.extras
        return (result, report)
    }

    /// The three-way merge of one request, field by field.
    ///
    /// - Returns: the merged request and the fields where the user's edit won over a change in
    ///   the spec.
    static func merge(
        _ local: RequestItem, with remote: RequestItem, legacy: Bool
    ) -> (RequestItem, kept: [String]) {
        let base = local.extras[metadataKey]?["base"]?.objectValue
        var kept: [String] = []
        var merged = local

        func pick<T>(_ field: String, _ l: T, _ r: T, _ text: (T) -> String, legacyTakesRemote: Bool = false) -> T {
            let lf = hash(text(l)), rf = hash(text(r))
            guard lf != rf else { return l }
            guard let bf = base?[field]?.stringValue else { return legacyTakesRemote ? r : l }
            if bf == lf { return r }
            if bf != rf { kept.append(field) }
            return l
        }

        merged.name = pick("name", local.name, remote.name, { $0 })
        merged.description = pick(
            "description", local.description, remote.description, { $0 ?? "" },
            legacyTakesRemote: true)
        merged.auth = pick("auth", local.auth, remote.auth, canonical)
        // A legacy request with no body takes the spec's: there was nothing of the user's to keep.
        merged.body = pick(
            "body", local.body, remote.body, canonical,
            legacyTakesRemote: local.body == .none)

        let (params, paramsKept) = mergeRows(
            local.params, remote.params, base: base?["params"]?.objectValue,
            caseInsensitive: false)
        let (headers, headersKept) = mergeRows(
            local.headers, remote.headers, base: base?["headers"]?.objectValue,
            caseInsensitive: true)
        merged.params = params
        merged.headers = headers
        if paramsKept { kept.append("params") }
        if headersKept { kept.append("headers") }

        let localPath = URLQuery.stripQuery(from: local.url)
        let path = pick("path", localPath, URLQuery.stripQuery(from: remote.url), { $0 })
        // The query mirrors the params table, so rebuild it only when either side moved.
        if path != localPath || params != local.params {
            merged.url = URLQuery.compose(base: path, params: KeyValueRows.stripped(params), encode: false)
        }

        // What the spec says about the operation that Postfrau does not model, and the new stamp.
        merged.extras = remote.extras
        return (merged, kept)
    }

    /// Row-by-row three-way merge of a key/value table.
    ///
    /// The spec's rows come first in the spec's order, then any rows only the user has.
    static func mergeRows(
        _ local: [KeyValue], _ remote: [KeyValue], base: [String: JSONValue]?,
        caseInsensitive: Bool
    ) -> ([KeyValue], kept: Bool) {
        func key(_ row: KeyValue) -> String { caseInsensitive ? row.key.lowercased() : row.key }
        var localByKey: [String: KeyValue] = [:]
        for row in local where localByKey[key(row)] == nil { localByKey[key(row)] = row }
        let remoteKeys = Set(remote.map(key))

        var out: [KeyValue] = []
        var kept = false
        var seen: Set<String> = []
        for row in remote {
            let k = key(row)
            guard seen.insert(k).inserted else { continue }
            let baseHash = base?[k]?.stringValue
            guard let mine = localByKey[k] else {
                // Deleted by the user since the import: stays deleted. New in the spec: added.
                if baseHash == nil { out.append(row) }
                continue
            }
            let lf = rowHash(mine), rf = rowHash(row)
            if lf == rf || baseHash == nil || baseHash != lf {
                out.append(mine)
                if lf != rf, let baseHash, baseHash != rf { kept = true }
            } else {
                var updated = row
                updated.id = mine.id
                out.append(updated)
            }
        }
        for row in local where !remoteKeys.contains(key(row)) {
            // Gone from the spec and untouched: it goes. Anything else is the user's.
            if let baseHash = base?[key(row)]?.stringValue, baseHash == rowHash(row) { continue }
            out.append(row)
        }
        return (out, kept)
    }

    // MARK: - Helpers

    static func sameExceptExtras(_ a: RequestItem, _ b: RequestItem) -> Bool {
        var a = a, b = b
        a.extras = [:]
        b.extras = [:]
        return a == b
    }

    static func nonEmptyFolderIDs(in items: [CollectionItem]) -> Set<UUID> {
        var out: Set<UUID> = []
        for case .folder(let folder) in items where !folder.items.isEmpty {
            out.insert(folder.id)
            out.formUnion(nonEmptyFolderIDs(in: folder.items))
        }
        return out
    }

    static func prune(_ items: [CollectionItem], emptiedFrom before: Set<UUID>) -> [CollectionItem] {
        items.compactMap { item in
            guard case .folder(var folder) = item else { return item }
            folder.items = prune(folder.items, emptiedFrom: before)
            if folder.items.isEmpty, before.contains(folder.id) { return nil }
            return .folder(folder)
        }
    }
}
