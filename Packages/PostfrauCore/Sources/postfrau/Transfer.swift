import Foundation
import PostfrauCore

/// `import`, `export`, `open` — moving whole documents in and out.
enum Transfer {
    static func importFile(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("import needs a file.")
            return .usage
        }
        guard let data = try? Data(contentsOf: URL(filePath: path)) else {
            out.error("could not read \(path).")
            return .notFound
        }

        guard let root = try? Postfrau.makeDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            out.error(
                OpenAPIImporter.looksLikeYAML(data)
                    ? OpenAPIImporter.ImportError.looksLikeYAML.localizedDescription
                    : "\(path) is not JSON. For a curl command, use `postfrau add --from-curl`.")
            return .usage
        }

        if PostmanEnvironment.looksLikeEnvironment(object) {
            let environment = try PostmanEnvironment.import(object)
            _ = try await runner.addEnvironment(named: environment.name)
            for variable in environment.variables {
                _ = try await runner.setVariable(
                    variable.key, to: variable.value,
                    inEnvironmentNamed: environment.name, isSecret: variable.isSecret)
            }
            if out.isJSON {
                out.json(["kind": "environment", "name": environment.name,
                          "variables": "\(environment.variables.count)"])
            } else {
                out.print("imported environment \(out.bold(environment.name)) "
                    + out.dim("(\(environment.variables.count) variables)"))
            }
            return .ok
        }

        // OpenAPI before Postman: both have an `info` block, and the Postman importer would
        // accept an OpenAPI document and produce a collection with nothing in it.
        let result = OpenAPIImporter.looksLikeOpenAPI(object)
            ? try OpenAPIImporter().import(object).asPostmanResult
            : try PostmanV21Importer().import(object)
        try await runner.importCollection(result.collection)
        for warning in result.warnings { out.warning(warning) }

        if out.isJSON {
            out.json([
                "kind": "collection", "name": result.collection.name,
                "requests": "\(result.collection.requestCount)",
                "warnings": "\(result.warnings.count)",
            ])
        } else {
            out.print("imported \(out.bold(result.collection.name)) "
                + out.dim("(\(result.collection.requestCount) requests)"))
        }
        return .ok
    }

    static func export(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("export needs a collection or environment name.")
            return .usage
        }

        let data: Data
        let suggested: String
        if let environment = try? await runner.environment(named: path) {
            data = try PostmanEnvironment.data(for: environment)
            suggested = "\(environment.name).postman_environment.json"
        } else {
            let resolved = try await runner.resolve(path)
            guard case .collection(let collection) = resolved else {
                out.error("export takes a whole collection or an environment, not a \(resolved.kind).")
                return .usage
            }
            data = try PostmanV21Exporter().data(for: collection)
            suggested = "\(collection.name).postman_collection.json"
        }

        guard let destination = arguments.value("--out") else {
            // No --out means stdout, so the export can be piped.
            out.emit(String(decoding: data, as: UTF8.self))
            return .ok
        }
        // A directory as the destination gets the suggested name inside it.
        var url = URL(filePath: destination)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            url = url.appending(path: suggested, directoryHint: .notDirectory)
        }
        try data.write(to: url, options: [.atomic])
        if !out.isJSON { out.print("wrote \(url.path)") }
        return .ok
    }
}

/// `open` — hands a path to the app, which brings it up in a tab.
enum Open {
    static func run(
        _ arguments: Arguments, _ runner: CommandRunner, _ out: Output
    ) async throws -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("open needs a path.")
            return .usage
        }
        let resolved = try await runner.resolve(path)

        // The id rather than the path: a URL with a name in it needs escaping the app would then
        // have to undo, and an id is unambiguous.
        guard let url = URL(string: "postfrau://open?id=\(resolved.id.uuidString)") else {
            out.error("could not build a postfrau:// URL for that item.")
            return .usage
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            out.error("could not open Postfrau. Is it installed?")
            return .notFound
        }
        if !out.isJSON { out.print("opened \(out.bold(resolved.name)) in Postfrau") }
        return .ok
    }
}
