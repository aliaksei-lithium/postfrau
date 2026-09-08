import Foundation
import PostfrauCore

/// `schema` and `validate` — so an agent can learn the file format without being handed it.
///
/// The point is that `SKILL.md` stays short: it links here rather than pasting a schema that would
/// then drift out of date.
enum Schema {
    static func run(_ arguments: Arguments, _ out: Output) -> ExitCode {
        let subject = arguments.positional(0) ?? "all"
        let documents: [String: String] = [
            "collection": collection,
            "request": request,
            "environment": environment,
            "history": history,
        ]

        if subject == "all" {
            out.emit(documents.keys.sorted().joined(separator: "\n"))
            return .ok
        }
        guard let document = documents[subject] else {
            out.error("schema takes collection, request, environment or history.")
            return .usage
        }
        out.emit(document)
        return .ok
    }

    static let collection = """
    {
      "id": "uuid",
      "name": "string",
      "description": "string?",
      "auth": "see: auth, below",
      "variables": [{ "key": "string", "value": "string", "enabled": true, "isSecret": false }],
      "items": ["a request or a folder; folders nest"],
      "revision": "int, bumped on every write",
      "createdAt": "ISO-8601",
      "updatedAt": "ISO-8601",
      "extras": "anything an import carried that Postfrau does not model"
    }

    A folder: { "id", "name", "description?", "auth", "variables", "items" }
    """

    static let request = """
    {
      "id": "uuid",
      "name": "string",
      "method": "GET | POST | PUT | PATCH | DELETE | HEAD | OPTIONS | ...",
      "url": "string, may contain {{variables}}",
      "params": [{ "key": "string", "value": "string", "enabled": true }],
      "headers": [{ "key": "string", "value": "string", "enabled": true }],
      "auth": {
        "type": "none | inherit | bearer | basic | apikey",
        "token": "bearer only",
        "username": "basic only", "password": "basic only",
        "key": "apikey only", "value": "apikey only", "location": "header | query"
      },
      "body": {
        "type": "none | raw | urlEncoded | formData | binary",
        "text": "raw only", "language": "json | xml | html | javascript | text",
        "fields": "urlEncoded and formData"
      },
      "settings": {
        "followRedirects": true, "maxRedirects": 10, "timeoutSeconds": 30,
        "verifyTLS": true, "sendCookies": true, "encodeURL": true
      }
    }

    `auth.type` of "inherit" takes the auth from the nearest folder or collection that sets one.
    """

    static let environment = """
    {
      "id": "uuid",
      "name": "string",
      "variables": [
        { "key": "string", "value": "string", "enabled": true, "isSecret": false }
      ]
    }

    A variable with "isSecret": true has an empty "value" on disk — the real one is in the
    Keychain. `postfrau env get` prints ••• for it unless you pass --reveal.
    """

    static let history = """
    {
      "id": "uuid",
      "sentAt": "ISO-8601",
      "method": "string",
      "resolvedURL": "string, with secrets already replaced by •••",
      "statusCode": "int?, absent when the request never got a response",
      "durationMs": "double",
      "responseBytes": "int",
      "source": { "type": "app | cli | agent", "name": "agent only" },
      "recordLevel": "off | metadata | headers | full",
      "requestHeaders": "headers and above",
      "responseHeaders": "headers and above",
      "requestBody": "full only: { data (base64), truncated, originalBytes, mimeType }",
      "responseBody": "full only",
      "error": "string?, why it failed"
    }

    `postfrau history --json` returns a flattened summary of these, not the whole entry;
    `postfrau history show <id> --json` returns the entry above.
    """
}

/// `validate <file>` — is this a file Postfrau can read?
enum Validate {
    static func run(_ arguments: Arguments, _ out: Output) -> ExitCode {
        guard let path = arguments.positional(0) else {
            out.error("validate needs a file.")
            return .usage
        }
        guard let data = try? Data(contentsOf: URL(filePath: path)) else {
            out.error("could not read \(path).")
            return .notFound
        }
        guard let root = try? Postfrau.makeDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            out.error("\(path) is not a JSON object.")
            return .usage
        }

        // Checked before Postman and before Postfrau's own format: an OpenAPI document has an
        // `info` block, and both of those decoders are lenient enough to accept it and report
        // something misleading.
        if OpenAPIImporter.looksLikeOpenAPI(object) {
            do {
                let result = try OpenAPIImporter().import(object)
                out.print(
                    "ok: an OpenAPI document, \(result.collection.requestCount) operation(s)")
                for warning in result.warnings { out.warning(warning) }
                return .ok
            } catch {
                out.error(CommandRunner.message(for: error))
                return .usage
            }
        }

        if PostmanEnvironment.looksLikeEnvironment(object) {
            do {
                let environment = try PostmanEnvironment.import(object)
                out.print("ok: a Postman environment, \(environment.variables.count) variable(s)")
                return .ok
            } catch {
                out.error(CommandRunner.message(for: error))
                return .usage
            }
        }

        do {
            let result = try PostmanV21Importer().import(object)
            out.print("ok: a Postman collection, \(result.collection.requestCount) request(s)")
            for warning in result.warnings { out.warning(warning) }
            return .ok
        } catch {
            // Not a Postman file: it may still be one of Postfrau's own documents.
            if (try? Postfrau.makeDecoder().decode(RequestCollection.self, from: data)) != nil {
                out.print("ok: a Postfrau collection")
                return .ok
            }
            if (try? Postfrau.makeDecoder().decode(RequestItem.self, from: data)) != nil {
                out.print("ok: a Postfrau request")
                return .ok
            }
            out.error(CommandRunner.message(for: error))
            return .usage
        }
    }
}
