import Foundation

/// Where an item sits among the sidebar's rows, counted the way the outline draws them.
///
/// The sidebar is a `List` over an `NSTableView`, and `List` only hands its selection to rows it
/// has built — a request a few thousand rows down has no selected row to scroll to. The rows are
/// a pure function of the collections and what is open, though, so the index can be worked out
/// here and given to the table directly. See `docs/decisions.md` D68.
public enum SidebarRows {
    /// The row of `id` and the number of rows above the sidebar's trailing extras, or nil when
    /// `id` is not on a visible row.
    public static func position(
        of id: UUID, in collections: [RequestCollection], isOpen: (UUID) -> Bool
    ) -> (row: Int, total: Int)? {
        var count = 0
        var found: Int?
        func walk(_ items: [CollectionItem]) {
            for item in items {
                if item.id == id { found = count }
                count += 1
                if case .folder(let folder) = item, isOpen(folder.id) { walk(folder.items) }
            }
        }
        for collection in collections {
            if collection.id == id { found = count }
            count += 1
            if isOpen(collection.id) { walk(collection.items) }
        }
        return found.map { ($0, count) }
    }
}
