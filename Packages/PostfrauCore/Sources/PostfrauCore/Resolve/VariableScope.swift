import Foundation

/// Where a variable came from. Drives the "source" column in the quick-look popover.
public enum VariableSource: Sendable, Hashable {
    case environment(name: String)
    case folder(name: String)
    case collection(name: String)
    case globals

    public var displayName: String {
        switch self {
        case .environment(let name): name
        case .folder(let name): name
        case .collection(let name): name
        case .globals: "Globals"
        }
    }

    public var categoryName: String {
        switch self {
        case .environment: "Environment"
        case .folder: "Folder"
        case .collection: "Collection"
        case .globals: "Globals"
        }
    }
}

/// One precedence level of variables.
public struct VariableLayer: Sendable, Hashable {
    public var source: VariableSource
    public var variables: [Variable]

    public init(source: VariableSource, variables: [Variable]) {
        self.source = source
        self.variables = variables
    }
}

/// A variable as the resolver sees it, with the layer it came from.
public struct ResolvedVariable: Sendable, Hashable {
    public var key: String
    public var value: String
    public var source: VariableSource
    public var isSecret: Bool
    /// True when a higher-precedence layer defines the same key.
    public var isShadowed: Bool

    public init(key: String, value: String, source: VariableSource, isSecret: Bool, isShadowed: Bool) {
        self.key = key
        self.value = value
        self.source = source
        self.isSecret = isSecret
        self.isShadowed = isShadowed
    }
}

/// The ordered set of variable layers visible to one request.
///
/// Precedence, highest first: active environment → folder chain (innermost first) →
/// collection → globals.
public struct VariableScope: Sendable, Hashable {
    public var layers: [VariableLayer]

    public init(layers: [VariableLayer] = []) {
        self.layers = layers
    }

    /// The winning value for each key.
    public func effectiveValues() -> [String: String] {
        var out: [String: String] = [:]
        for layer in layers {
            for variable in layer.variables where variable.enabled && !variable.key.isEmpty {
                if out[variable.key] == nil { out[variable.key] = variable.value }
            }
        }
        return out
    }

    /// Every visible variable including shadowed duplicates, in precedence order.
    /// Disabled rows and rows with an empty key are dropped.
    public func allVariables() -> [ResolvedVariable] {
        var seen: Set<String> = []
        var out: [ResolvedVariable] = []
        for layer in layers {
            for variable in layer.variables where variable.enabled && !variable.key.isEmpty {
                let shadowed = seen.contains(variable.key)
                out.append(ResolvedVariable(
                    key: variable.key,
                    value: variable.value,
                    source: layer.source,
                    isSecret: variable.isSecret,
                    isShadowed: shadowed))
                seen.insert(variable.key)
            }
        }
        return out
    }

    /// Builds the scope for a request in a collection, given the folder chain that contains it.
    ///
    /// `folderChain` is outermost-first (as `RequestCollection.folderChain(to:)` returns it);
    /// the innermost folder therefore wins.
    public static func build(
        environment: RequestEnvironment?,
        collection: RequestCollection?,
        folderChain: [Folder],
        globals: Globals
    ) -> VariableScope {
        var layers: [VariableLayer] = []
        if let environment {
            layers.append(VariableLayer(
                source: .environment(name: environment.name), variables: environment.variables))
        }
        for folder in folderChain.reversed() {
            layers.append(VariableLayer(
                source: .folder(name: folder.name), variables: folder.variables))
        }
        if let collection {
            layers.append(VariableLayer(
                source: .collection(name: collection.name), variables: collection.variables))
        }
        layers.append(VariableLayer(source: .globals, variables: globals.variables))
        return VariableScope(layers: layers)
    }
}
