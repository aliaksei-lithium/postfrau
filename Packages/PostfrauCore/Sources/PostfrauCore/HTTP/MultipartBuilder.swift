import Foundation

/// Assembles a `multipart/form-data` body.
///
/// Text-only forms are built in memory. As soon as one part is a file the whole body is written to
/// a temporary file and streamed, so attaching a 2 GB video does not mean holding 2 GB of `Data`.
public enum MultipartBuilder {
    static let crlf = Data("\r\n".utf8)

    /// A boundary that cannot appear in the payload by accident.
    public static func makeBoundary() -> String {
        "----PostfrauBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func build(
        fields: [FormField],
        boundary: String,
        resolver: VariableResolver,
        warnings: inout [String],
        accessed: inout [URL]
    ) throws -> BodyPayload {
        let hasFiles = fields.contains { if case .file = $0.value { return true } else { return false } }
        return hasFiles
            ? try buildStreamed(fields, boundary: boundary, resolver: resolver,
                                warnings: &warnings, accessed: &accessed)
            : .data(buildInMemory(fields, boundary: boundary, resolver: resolver))
    }

    private static func buildInMemory(
        _ fields: [FormField], boundary: String, resolver: VariableResolver
    ) -> Data {
        var body = Data()
        for field in fields {
            guard case .text(let value) = field.value else { continue }
            body.append(textPartHeader(field, boundary: boundary, resolver: resolver))
            body.append(Data(resolver.resolved(value).utf8))
            body.append(crlf)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func buildStreamed(
        _ fields: [FormField],
        boundary: String,
        resolver: VariableResolver,
        warnings: inout [String],
        accessed: inout [URL]
    ) throws -> BodyPayload {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "postfrau-upload-\(UUID().uuidString)", directoryHint: .notDirectory)
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }

        for field in fields {
            switch field.value {
            case .text(let value):
                try handle.write(contentsOf: textPartHeader(field, boundary: boundary, resolver: resolver))
                try handle.write(contentsOf: Data(resolver.resolved(value).utf8))
                try handle.write(contentsOf: crlf)

            case .file(let reference):
                guard let bookmark = reference.bookmark else {
                    warnings.append(
                        "Skipped “\(field.key)”: no file is attached"
                            + (reference.displayName.isEmpty ? "." : " for “\(reference.displayName)”."))
                    continue
                }
                let fileURL = try SecurityScopedFile.resolve(
                    bookmark: bookmark, displayName: reference.displayName, accessed: &accessed)
                let filename = reference.displayName.isEmpty
                    ? fileURL.lastPathComponent : reference.displayName
                let contentType = field.contentType ?? MIMEType.forExtension(fileURL.pathExtension)

                let disposition = "Content-Disposition: form-data;"
                    + " name=\"\(escape(resolver.resolved(field.key)))\";"
                    + " filename=\"\(escape(filename))\"\r\n"
                try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
                try handle.write(contentsOf: Data(disposition.utf8))
                try handle.write(contentsOf: Data("Content-Type: \(contentType)\r\n\r\n".utf8))
                try copy(from: fileURL, into: handle)
                try handle.write(contentsOf: crlf)
            }
        }
        try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        return .file(temporary)
    }

    private static func textPartHeader(
        _ field: FormField, boundary: String, resolver: VariableResolver
    ) -> Data {
        var header = "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"\(escape(resolver.resolved(field.key)))\"\r\n"
        if let contentType = field.contentType, !contentType.isEmpty {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "\r\n"
        return Data(header.utf8)
    }

    /// Copies in 1 MB chunks so memory stays flat regardless of file size.
    private static func copy(from url: URL, into handle: FileHandle) throws {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }
    }

    /// RFC 7578 says to escape quotes and newlines in a part's name.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

/// Resolves security-scoped bookmarks and keeps the access open for the caller.
///
/// Inside the sandbox, a file the user picked in an `NSOpenPanel` is only readable again after a
/// relaunch if we stored a bookmark and re-open access around every read.
public enum SecurityScopedFile {
    /// - Parameter accessed: URLs whose security scope was opened; the caller must call
    ///   `stopAccessing` on each once the request completes.
    static func resolve(
        bookmark: Data, displayName: String, accessed: inout [URL]
    ) throws -> URL {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        else {
            throw RequestBuilder.BuildError.unreadableFile(displayName)
        }
        if url.startAccessingSecurityScopedResource() {
            accessed.append(url)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            accessed.removeAll { $0 == url }
            throw RequestBuilder.BuildError.unreadableFile(
                displayName.isEmpty ? url.lastPathComponent : displayName)
        }
        return url
    }

    /// Closes every scope opened by a build.
    public static func stopAccessing(_ urls: [URL]) {
        for url in urls { url.stopAccessingSecurityScopedResource() }
    }
}

/// A small extension → MIME map, so a picked file gets a sensible `Content-Type`.
public enum MIMEType {
    public static func forExtension(_ ext: String) -> String {
        table[ext.lowercased()] ?? "application/octet-stream"
    }

    /// The values offered in the `Content-Type` autocomplete (Phase 4).
    public static let common = [
        "application/json", "application/xml", "application/x-www-form-urlencoded",
        "multipart/form-data", "text/plain", "text/html", "text/csv",
        "application/octet-stream", "application/pdf", "image/png", "image/jpeg",
        "application/graphql", "application/javascript",
    ]

    private static let table: [String: String] = [
        "json": "application/json", "xml": "application/xml", "txt": "text/plain",
        "html": "text/html", "htm": "text/html", "csv": "text/csv", "md": "text/markdown",
        "js": "application/javascript", "css": "text/css", "pdf": "application/pdf",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "heic": "image/heic", "ico": "image/x-icon",
        "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4",
        "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
        "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar",
        "yaml": "application/yaml", "yml": "application/yaml", "toml": "application/toml",
    ]
}
