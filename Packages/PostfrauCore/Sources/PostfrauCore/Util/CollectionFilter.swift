import Foundation

/// Filters a collection tree for the sidebar's search field.
///
/// A request matches on its name, its URL or its method. A folder is kept when its own name
/// matches *or* when anything inside it does — otherwise filtering would hide the very thing you
/// searched for behind a folder whose name happens not to contain the query.
public enum CollectionFilter {
    /// A pruned copy of `collection`, or nil when nothing in it matches.
    /// An empty query returns the collection unchanged.
    public static func filter(_ collection: RequestCollection, query: String) -> RequestCollection? {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return collection }

        let items = filter(items: collection.items, needle: needle)
        // A collection whose own name matches stays visible even when nothing inside does, so the
        // user can still see (and expand) it.
        if items.isEmpty, !collection.name.lowercased().contains(needle) { return nil }

        var pruned = collection
        pruned.items = items
        return pruned
    }

    /// The ids of every folder that has to be expanded for the matches to be visible.
    public static func expansionIDs(for collection: RequestCollection, query: String) -> Set<UUID> {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard let filtered = filter(collection, query: query) else { return [] }

        var ids: Set<UUID> = [filtered.id]
        func walk(_ items: [CollectionItem]) {
            for case .folder(let folder) in items {
                ids.insert(folder.id)
                walk(folder.items)
            }
        }
        walk(filtered.items)
        return ids
    }

    private static func filter(items: [CollectionItem], needle: String) -> [CollectionItem] {
        items.compactMap { item in
            switch item {
            case .request(let request):
                return matches(request, needle: needle) ? item : nil
            case .folder(var folder):
                let children = filter(items: folder.items, needle: needle)
                if !children.isEmpty {
                    folder.items = children
                    return .folder(folder)
                }
                // A folder whose own name matches is kept, with its real contents, so it can be
                // opened and browsed.
                return folder.name.lowercased().contains(needle) ? item : nil
            }
        }
    }

    private static func matches(_ request: RequestItem, needle: String) -> Bool {
        request.name.lowercased().contains(needle)
            || request.url.lowercased().contains(needle)
            || request.method.rawValue.lowercased() == needle
    }
}

/// The whole sidebar's filtered state, produced in one traversal.
public struct FilteredCollections: Sendable {
    public var collections: [RequestCollection]
    /// Folders that must be forced open for the matches to be visible.
    public var forcedOpenIDs: Set<UUID>
    /// How many requests matched, including any beyond the limit.
    public var totalMatches: Int
    /// True when `collections` holds only the first `limit` matches.
    public var isTruncated: Bool

    public init(
        collections: [RequestCollection], forcedOpenIDs: Set<UUID> = [],
        totalMatches: Int = 0, isTruncated: Bool = false
    ) {
        self.collections = collections
        self.forcedOpenIDs = forcedOpenIDs
        self.totalMatches = totalMatches
        self.isTruncated = isTruncated
    }
}

extension CollectionFilter {
    /// Filters every collection at once, capping how many matching requests are kept.
    ///
    /// The cap exists because a broad query ("i") matches thousands of requests, and drawing
    /// thousands of force-expanded outline rows is what makes the sidebar stall — not the
    /// filtering itself, which is a few tens of milliseconds over 5 000 requests. Nobody reads
    /// 5 000 search results; the UI says how many were left out.
    public static func filter(
        _ collections: [RequestCollection], query: String, limit: Int = 200
    ) -> FilteredCollections {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return FilteredCollections(collections: collections) }

        var kept: [RequestCollection] = []
        var forced: Set<UUID> = []
        var matches = 0

        for collection in collections {
            var budget = max(0, limit - matches)
            let items = prune(collection.items, needle: needle, budget: &budget, matched: &matches)
            let nameMatches = collection.name.lowercased().contains(needle)
            guard !items.isEmpty || nameMatches else { continue }

            var pruned = collection
            pruned.items = items
            kept.append(pruned)
            forced.insert(collection.id)
            collectFolderIDs(items, into: &forced)
        }

        return FilteredCollections(
            collections: kept,
            forcedOpenIDs: forced,
            totalMatches: matches,
            isTruncated: matches > limit)
    }

    /// Keeps matching requests (up to `budget`) and the folders leading to them.
    /// `matched` counts every match, including those past the budget, so the UI can say how many.
    private static func prune(
        _ items: [CollectionItem], needle: String, budget: inout Int, matched: inout Int
    ) -> [CollectionItem] {
        var kept: [CollectionItem] = []
        for item in items {
            switch item {
            case .request(let request):
                guard matches(request, needle: needle) else { continue }
                matched += 1
                if budget > 0 {
                    budget -= 1
                    kept.append(item)
                }
            case .folder(var folder):
                let children = prune(folder.items, needle: needle, budget: &budget, matched: &matched)
                if !children.isEmpty {
                    folder.items = children
                    kept.append(.folder(folder))
                } else if folder.name.lowercased().contains(needle) {
                    // A folder whose own name matches is kept with its real contents.
                    kept.append(item)
                }
            }
        }
        return kept
    }

    private static func collectFolderIDs(_ items: [CollectionItem], into ids: inout Set<UUID>) {
        for case .folder(let folder) in items {
            ids.insert(folder.id)
            collectFolderIDs(folder.items, into: &ids)
        }
    }
}
