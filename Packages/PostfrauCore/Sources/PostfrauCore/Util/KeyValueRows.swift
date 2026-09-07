import Foundation

/// Editing rules shared by every key/value table in the UI.
///
/// The tables always show one blank row at the bottom to type into, which means the blank row is
/// part of the edited model. These helpers keep that invariant in one testable place instead of
/// scattered through view code.
public enum KeyValueRows {
    /// Exactly one blank row, at the end. Blank rows anywhere else are dropped, which is what
    /// happens when the user clears a row they no longer want.
    public static func withTrailingBlank(_ rows: [KeyValue]) -> [KeyValue] {
        var kept = rows.filter { !$0.isEmpty }
        // Reuse the existing blank row's identity when there is one, so the field the user is
        // typing in does not lose focus.
        kept.append(rows.last(where: { $0.isEmpty }) ?? KeyValue())
        return kept
    }

    /// The rows worth persisting: everything the user actually typed.
    public static func stripped(_ rows: [KeyValue]) -> [KeyValue] {
        rows.filter { !$0.isEmpty }
    }
}

extension [FormField] {
    /// The form-data equivalent of `KeyValueRows.withTrailingBlank`.
    public var withTrailingBlank: [FormField] {
        var kept = filter { !$0.isEmpty }
        kept.append(last(where: { $0.isEmpty }) ?? FormField())
        return kept
    }

    public var stripped: [FormField] {
        filter { !$0.isEmpty }
    }
}

extension RequestItem {
    /// The request with editor scaffolding removed: blank rows dropped everywhere.
    ///
    /// Dirty tracking compares normalized requests, so simply *looking* at the Params tab — which
    /// adds a blank row to type into — does not mark a tab as having unsaved changes.
    public func normalized() -> RequestItem {
        var copy = self
        copy.params = KeyValueRows.stripped(params)
        copy.headers = KeyValueRows.stripped(headers)
        switch body {
        case .urlEncoded(let rows):
            copy.body = .urlEncoded(KeyValueRows.stripped(rows))
        case .formData(let fields):
            copy.body = .formData(fields.stripped)
        case .none, .raw, .binary:
            break
        }
        return copy
    }
}
