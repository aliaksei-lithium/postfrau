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

/// Where an item should land when it is dropped.
public struct DropTarget: Sendable, Hashable {
    /// The folder to drop into, or nil for the collection's root.
    public var parentID: UUID?
    /// Position among that parent's children, or nil to append.
    public var index: Int?

    public init(parentID: UUID?, index: Int? = nil) {
        self.parentID = parentID
        self.index = index
    }
}

extension RequestCollection {
    /// Moves an item within this collection.
    ///
    /// Returns false when the move is impossible or meaningless: the item is not here, the target
    /// folder does not exist, or the item is a folder being dropped inside itself — which would
    /// detach that whole subtree from the tree.
    @discardableResult
    public mutating func move(itemWithID id: UUID, to target: DropTarget) -> Bool {
        guard item(withID: id) != nil else { return false }
        if let parentID = target.parentID {
            guard folder(withID: parentID) != nil else { return false }
            // Dropping a folder into itself or into one of its own descendants would orphan it.
            if item(withID: id)?.asFolder != nil,
               folder(parentID, isInsideOrEqualTo: id) { return false }
        }

        // The index is expressed against the parent's children *before* the removal, so a move
        // within one parent has to account for the item vanishing from earlier in the list.
        var adjustedIndex = target.index
        if let index = target.index, currentParentID(of: id) == target.parentID,
           let currentIndex = currentIndex(of: id), currentIndex < index {
            adjustedIndex = index - 1
        }

        guard let removed = remove(itemWithID: id) else { return false }
        guard insert(removed, into: target.parentID, at: adjustedIndex) else {
            // Put it back rather than losing it.
            insert(removed, into: currentParentID(of: id), at: nil)
            return false
        }
        return true
    }

    /// The folder containing `id`, or nil when it sits at the collection's root.
    public func currentParentID(of id: UUID) -> UUID? {
        folderChain(to: id)?.last
    }

    /// The item's position among its siblings.
    public func currentIndex(of id: UUID) -> Int? {
        let siblings: [CollectionItem]
        if let parentID = currentParentID(of: id) {
            siblings = folder(withID: parentID)?.items ?? []
        } else {
            siblings = items
        }
        return siblings.firstIndex { $0.id == id }
    }

    /// A collection of `requestCount` requests spread over a three-level folder tree, for
    /// measuring the sidebar at the scale `PLAN.md` §1 calls for.
    public static func makeStressCollection(
        requestCount: Int = 5000, name: String = "Stress Test"
    ) -> RequestCollection {
        let perFolder = 25
        let foldersNeeded = max(1, (requestCount + perFolder - 1) / perFolder)
        let groupsNeeded = max(1, Int(Double(foldersNeeded).squareRoot().rounded(.up)))

        var remaining = requestCount
        var groups: [CollectionItem] = []

        for groupIndex in 0..<groupsNeeded where remaining > 0 {
            var folders: [CollectionItem] = []
            for folderIndex in 0..<groupsNeeded where remaining > 0 {
                var requests: [CollectionItem] = []
                for _ in 0..<min(perFolder, remaining) {
                    let number = requestCount - remaining
                    requests.append(.request(RequestItem(
                        name: "Request \(number)",
                        method: HTTPMethod.allCases[number % HTTPMethod.allCases.count],
                        url: "{{baseUrl}}/group\(groupIndex)/folder\(folderIndex)/item\(number)",
                        params: [KeyValue(key: "page", value: "\(number % 10)")])))
                    remaining -= 1
                }
                folders.append(.folder(Folder(name: "Folder \(folderIndex)", items: requests)))
            }
            groups.append(.folder(Folder(name: "Group \(groupIndex)", items: folders)))
        }

        return RequestCollection(
            name: name,
            description: "Generated for performance testing. Safe to delete.",
            variables: [Variable(key: "baseUrl", value: "https://example.test")],
            items: groups)
    }
}
