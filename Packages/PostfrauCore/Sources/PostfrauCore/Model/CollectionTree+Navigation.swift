import Foundation

/// Where an item sits in a collection: the ids of the folders containing it, outermost first.
public struct ItemPath: Sendable, Hashable {
    public var collectionID: UUID
    public var folderIDs: [UUID]
    public var itemID: UUID

    public init(collectionID: UUID, folderIDs: [UUID], itemID: UUID) {
        self.collectionID = collectionID
        self.folderIDs = folderIDs
        self.itemID = itemID
    }
}

/// A node that owns an ordered list of `CollectionItem`s: a collection or a folder.
public protocol ItemContainer {
    var items: [CollectionItem] { get set }
    var containerVariables: [Variable] { get }
    var containerAuth: Auth { get }
}

extension Folder: ItemContainer {
    public var containerVariables: [Variable] { variables }
    public var containerAuth: Auth { auth }
}

extension RequestCollection: ItemContainer {
    public var containerVariables: [Variable] { variables }
    public var containerAuth: Auth { auth }
}

extension RequestCollection {
    /// Every request in the tree, depth-first, paired with the folder chain that contains it.
    public func allRequests() -> [(request: RequestItem, folderIDs: [UUID])] {
        var out: [(RequestItem, [UUID])] = []
        func walk(_ items: [CollectionItem], _ chain: [UUID]) {
            for item in items {
                switch item {
                case .request(let request): out.append((request, chain))
                case .folder(let folder): walk(folder.items, chain + [folder.id])
                }
            }
        }
        walk(items, [])
        return out
    }

    /// Number of requests anywhere in the tree.
    public var requestCount: Int {
        func count(_ items: [CollectionItem]) -> Int {
            items.reduce(0) { total, item in
                switch item {
                case .request: total + 1
                case .folder(let folder): total + count(folder.items)
                }
            }
        }
        return count(items)
    }

    /// The folder chain leading to `id`, outermost first, or nil when the id is not in this tree.
    public func folderChain(to id: UUID) -> [UUID]? {
        func search(_ items: [CollectionItem], _ chain: [UUID]) -> [UUID]? {
            for item in items {
                if item.id == id { return chain }
                if case .folder(let folder) = item,
                   let found = search(folder.items, chain + [folder.id]) {
                    return found
                }
            }
            return nil
        }
        return search(items, [])
    }

    public func request(withID id: UUID) -> RequestItem? {
        item(withID: id)?.asRequest
    }

    public func folder(withID id: UUID) -> Folder? {
        item(withID: id)?.asFolder
    }

    public func item(withID id: UUID) -> CollectionItem? {
        func search(_ items: [CollectionItem]) -> CollectionItem? {
            for item in items {
                if item.id == id { return item }
                if case .folder(let folder) = item, let found = search(folder.items) {
                    return found
                }
            }
            return nil
        }
        return search(items)
    }

    /// Replaces the item with the same id anywhere in the tree. Returns false if it was not found.
    @discardableResult
    public mutating func replace(_ replacement: CollectionItem) -> Bool {
        func replace(in items: inout [CollectionItem]) -> Bool {
            for index in items.indices {
                if items[index].id == replacement.id {
                    items[index] = replacement
                    return true
                }
                if case .folder(var folder) = items[index] {
                    var children = folder.items
                    if replace(in: &children) {
                        folder.items = children
                        items[index] = .folder(folder)
                        return true
                    }
                }
            }
            return false
        }
        var copy = items
        let didReplace = replace(in: &copy)
        if didReplace { items = copy }
        return didReplace
    }

    /// Removes the item with `id` anywhere in the tree and returns it.
    @discardableResult
    public mutating func remove(itemWithID id: UUID) -> CollectionItem? {
        func remove(from items: inout [CollectionItem]) -> CollectionItem? {
            for index in items.indices {
                if items[index].id == id {
                    return items.remove(at: index)
                }
                if case .folder(var folder) = items[index] {
                    var children = folder.items
                    if let removed = remove(from: &children) {
                        folder.items = children
                        items[index] = .folder(folder)
                        return removed
                    }
                }
            }
            return nil
        }
        var copy = items
        let removed = remove(from: &copy)
        if removed != nil { items = copy }
        return removed
    }

    /// Inserts `item` into the folder with `parentID` (or the root when nil) at `index`
    /// (or at the end when nil). Returns false when the parent does not exist.
    @discardableResult
    public mutating func insert(_ item: CollectionItem, into parentID: UUID?, at index: Int? = nil) -> Bool {
        guard let parentID else {
            items.insert(item, at: min(index ?? items.count, items.count))
            return true
        }
        func insert(into items: inout [CollectionItem]) -> Bool {
            for position in items.indices {
                if case .folder(var folder) = items[position] {
                    if folder.id == parentID {
                        folder.items.insert(item, at: min(index ?? folder.items.count, folder.items.count))
                        items[position] = .folder(folder)
                        return true
                    }
                    var children = folder.items
                    if insert(into: &children) {
                        folder.items = children
                        items[position] = .folder(folder)
                        return true
                    }
                }
            }
            return false
        }
        var copy = items
        let didInsert = insert(into: &copy)
        if didInsert { items = copy }
        return didInsert
    }

    /// True when `folderID` is `ancestorID` or lives inside it — used to reject illegal drags.
    public func folder(_ folderID: UUID, isInsideOrEqualTo ancestorID: UUID) -> Bool {
        if folderID == ancestorID { return true }
        guard let chain = folderChain(to: folderID) else { return false }
        return chain.contains(ancestorID)
    }

    /// A deep copy with fresh identifiers throughout.
    public func duplicated(named newName: String? = nil) -> RequestCollection {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? "\(name) copy"
        copy.variables = variables.map { var v = $0; v.id = UUID(); return v }
        copy.items = RequestCollection.reidentify(items)
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.revision = 1
        return copy
    }

    /// Recursively assigns new ids to a subtree.
    public static func reidentify(_ items: [CollectionItem]) -> [CollectionItem] {
        items.map { item in
            switch item {
            case .request(let request):
                var copy = request.duplicated(named: request.name)
                copy.id = UUID()
                return .request(copy)
            case .folder(var folder):
                folder.id = UUID()
                folder.variables = folder.variables.map { var v = $0; v.id = UUID(); return v }
                folder.items = reidentify(folder.items)
                return .folder(folder)
            }
        }
    }
}

extension Folder {
    public func folder(withID id: UUID) -> Folder? {
        for item in items {
            if case .folder(let folder) = item {
                if folder.id == id { return folder }
                if let found = folder.folder(withID: id) { return found }
            }
        }
        return nil
    }
}
