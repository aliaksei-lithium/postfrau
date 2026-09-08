import Foundation

/// Removes credentials from an exchange before it is written to history.
///
/// Applied on every write, at every recording level — there is no "record it raw" option, because
/// a history file that contains a live bearer token is a liability that outlives the request. The
/// rules are deliberately blunt: whole header values go, not substrings, so a token cannot survive
/// inside a header Postfrau does not recognise the shape of.
public enum HistoryRedactor {
    /// What a redacted value is replaced with.
    public static let placeholder = "•••"

    /// Headers whose value is always a credential.
    static let sensitiveHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "x-api-key", "api-key", "x-auth-token", "x-amz-security-token",
    ]

    /// Redacts a header list: sensitive names lose their value entirely, and any header whose
    /// value happens to contain a secret has that secret replaced.
    public static func redact(
        headers: [HeaderField], secrets: Set<String> = []
    ) -> [HeaderField] {
        headers.map { header in
            if sensitiveHeaders.contains(header.name.lowercased()) {
                return HeaderField(name: header.name, value: placeholder)
            }
            return HeaderField(name: header.name, value: redact(text: header.value, secrets: secrets))
        }
    }

    /// Replaces every occurrence of a secret value with the placeholder.
    ///
    /// Empty and very short secrets are skipped: replacing every "1" in a body would destroy it
    /// while protecting nothing.
    public static func redact(text: String, secrets: Set<String>) -> String {
        var out = text
        for secret in secrets where secret.count >= 4 {
            out = out.replacingOccurrences(of: secret, with: placeholder)
        }
        return out
    }

    public static func redact(body: RecordedBody, secrets: Set<String>) -> RecordedBody {
        guard !secrets.isEmpty else { return body }
        var copy = body
        copy.data = Data(redact(text: body.text, secrets: secrets).utf8)
        return copy
    }

    /// Strips credentials out of a request before it is stored as a history snapshot.
    ///
    /// The auth helper's own fields are blanked rather than resolved: a snapshot that carries
    /// `{{apiToken}}` is re-sendable and harmless, whereas one carrying the resolved token is not.
    public static func redact(request: RequestItem, secrets: Set<String>) -> RequestItem {
        var copy = request
        copy.auth = redact(auth: request.auth)
        copy.headers = request.headers.map { row in
            var header = row
            if sensitiveHeaders.contains(row.key.lowercased()) {
                header.value = placeholder
            } else {
                header.value = redact(text: row.value, secrets: secrets)
            }
            return header
        }
        copy.params = request.params.map { row in
            var param = row
            param.value = redact(text: row.value, secrets: secrets)
            return param
        }
        copy.url = redact(text: request.url, secrets: secrets)
        switch request.body {
        case .raw(let text, let language):
            copy.body = .raw(text: redact(text: text, secrets: secrets), language: language)
        case .urlEncoded(let rows):
            copy.body = .urlEncoded(rows.map { row in
                var field = row
                field.value = redact(text: row.value, secrets: secrets)
                return field
            })
        case .none, .formData, .binary:
            break
        }
        return copy
    }

    /// Keeps the *shape* of the auth — which kind, and which header or parameter name — while
    /// dropping the credential itself.
    static func redact(auth: Auth) -> Auth {
        switch auth {
        case .inherit, .none:
            auth
        case .basic(let username, let password):
            .basic(username: username, password: password.isEmpty ? "" : placeholder)
        case .bearer(let token):
            .bearer(token: token.isEmpty ? "" : placeholder)
        case .apiKey(let key, let value, let location):
            .apiKey(key: key, value: value.isEmpty ? "" : placeholder, location: location)
        }
    }
}
