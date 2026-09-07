import Foundation

/// The auth a request will actually use, plus where it came from so the UI can say
/// "inherited from *Users*".
public struct EffectiveAuth: Sendable, Hashable {
    public var auth: Auth
    public var source: Source

    public enum Source: Sendable, Hashable {
        case request
        case folder(name: String)
        case collection(name: String)
        /// Nothing in the chain defined auth, so nothing is sent.
        case none

        public var displayName: String? {
            switch self {
            case .request: nil
            case .folder(let name): name
            case .collection(let name): name
            case .none: nil
            }
        }
    }

    public init(auth: Auth, source: Source) {
        self.auth = auth
        self.source = source
    }

    /// True when the auth came from somewhere above the request.
    public var isInherited: Bool {
        switch source {
        case .request, .none: false
        case .folder, .collection: true
        }
    }
}

/// Walks `.inherit` up the folder chain to the collection.
///
/// A collection whose own auth is `.inherit` (which the model normalizes away, but an
/// imported file might still carry) behaves as `.none`.
public enum AuthResolver {
    /// - Parameter folderChain: outermost-first, as `RequestCollection.folderChain(to:)` returns it.
    public static func effective(
        requestAuth: Auth,
        folderChain: [Folder],
        collection: RequestCollection?
    ) -> EffectiveAuth {
        if requestAuth != .inherit {
            return EffectiveAuth(auth: requestAuth, source: .request)
        }
        for folder in folderChain.reversed() where folder.auth != .inherit {
            return EffectiveAuth(auth: folder.auth, source: .folder(name: folder.name))
        }
        if let collection, collection.auth != .inherit, collection.auth != .none {
            return EffectiveAuth(auth: collection.auth, source: .collection(name: collection.name))
        }
        return EffectiveAuth(auth: .none, source: .none)
    }

    /// Convenience for a request that is known to live in `collection`.
    public static func effective(
        for request: RequestItem,
        in collection: RequestCollection
    ) -> EffectiveAuth {
        let chain = (collection.folderChain(to: request.id) ?? [])
            .compactMap { collection.folder(withID: $0) }
        return effective(requestAuth: request.auth, folderChain: chain, collection: collection)
    }

    /// The header or query parameter an auth value puts on the wire, after variable resolution.
    ///
    /// Returns nil for `.none` / `.inherit` and for values whose required fields are empty.
    public static func wireValue(for auth: Auth, resolver: VariableResolver) -> AuthWireValue? {
        switch auth {
        case .none, .inherit:
            return nil
        case .basic(let username, let password):
            let user = resolver.resolved(username)
            let pass = resolver.resolved(password)
            if user.isEmpty && pass.isEmpty { return nil }
            let encoded = Data("\(user):\(pass)".utf8).base64EncodedString()
            return .header(name: "Authorization", value: "Basic \(encoded)")
        case .bearer(let token):
            let resolved = resolver.resolved(token)
            if resolved.isEmpty { return nil }
            return .header(name: "Authorization", value: "Bearer \(resolved)")
        case .apiKey(let key, let value, let location):
            let resolvedKey = resolver.resolved(key)
            if resolvedKey.isEmpty { return nil }
            let resolvedValue = resolver.resolved(value)
            return location == .header
                ? .header(name: resolvedKey, value: resolvedValue)
                : .query(name: resolvedKey, value: resolvedValue)
        }
    }
}

/// What an auth helper contributes to the outgoing request.
public enum AuthWireValue: Sendable, Hashable {
    case header(name: String, value: String)
    case query(name: String, value: String)

    public var name: String {
        switch self {
        case .header(let name, _), .query(let name, _): name
        }
    }

    public var value: String {
        switch self {
        case .header(_, let value), .query(_, let value): value
        }
    }
}
