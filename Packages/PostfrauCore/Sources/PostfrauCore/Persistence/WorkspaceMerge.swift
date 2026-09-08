import Foundation

/// What to do with the data already in a folder the user is switching to.
public enum RelocationChoice: Sendable, Hashable, CaseIterable {
    /// The folder is empty, or the user wants it to hold what this Mac has: copy everything over.
    case moveDataHere
    /// The folder already holds a workspace and it wins: adopt it, leaving local data in place.
    case useDataInFolder
    /// Combine the two: ids only on one side come across, same-id documents keep the newer
    /// revision and the loser is written to `conflicts/`.
    case merge

    public var displayName: String {
        switch self {
        case .moveDataHere: "Move My Data Here"
        case .useDataInFolder: "Use the Data in This Folder"
        case .merge: "Merge Both"
        }
    }

    public var explanation: String {
        switch self {
        case .moveDataHere:
            "Copies the collections and environments from this Mac into the folder. "
                + "Anything already in the folder is kept as a conflict copy."
        case .useDataInFolder:
            "Opens what is already in the folder. The data on this Mac is left where it is, "
                + "and a backup is written next to it."
        case .merge:
            "Keeps everything from both sides. Where the same item exists twice, the newer one "
                + "wins and the other is saved as a conflict copy."
        }
    }
}

/// The result of merging two sides of a workspace.
public struct MergeResult<Document: Sendable>: Sendable {
    /// What the workspace should hold afterwards.
    public var merged: [Document]
    /// Versions that lost and must be written to `conflicts/` before they are dropped.
    public var conflicts: [Document]

    public init(merged: [Document], conflicts: [Document] = []) {
        self.merged = merged
        self.conflicts = conflicts
    }
}

/// A document that can take part in a merge: it has an identity and a revision to compare.
public protocol MergeableDocument: Sendable, Identifiable where ID == UUID {
    var revision: Int { get }
    var updatedAt: Date { get }
    var name: String { get }
}

extension RequestCollection: MergeableDocument {}
extension RequestEnvironment: MergeableDocument {}

/// Combining two sides of a workspace when the data folder moves.
public enum WorkspaceMerge {
    /// Merges `incoming` (what is in the chosen folder) into `local` (what this Mac has).
    ///
    /// Ids present on only one side come across untouched. Where both sides have the same id, the
    /// higher `revision` wins; `updatedAt` breaks a tie, because two Macs that edited the same
    /// document while apart can easily land on the same revision number. The loser is returned in
    /// `conflicts` rather than discarded — the caller writes it to `conflicts/`.
    public static func merge<Document: MergeableDocument>(
        local: [Document], incoming: [Document]
    ) -> MergeResult<Document> {
        var byID: [UUID: Document] = [:]
        var order: [UUID] = []
        var conflicts: [Document] = []

        for document in local {
            if byID[document.id] == nil { order.append(document.id) }
            byID[document.id] = document
        }

        for document in incoming {
            guard let mine = byID[document.id] else {
                order.append(document.id)
                byID[document.id] = document
                continue
            }
            if wins(document, over: mine) {
                byID[document.id] = document
                conflicts.append(mine)
            } else {
                conflicts.append(document)
            }
        }

        return MergeResult(merged: order.compactMap { byID[$0] }, conflicts: conflicts)
    }

    /// True when `candidate` is the newer of the two.
    static func wins<Document: MergeableDocument>(
        _ candidate: Document, over existing: Document
    ) -> Bool {
        if candidate.revision != existing.revision { return candidate.revision > existing.revision }
        return candidate.updatedAt > existing.updatedAt
    }
}
