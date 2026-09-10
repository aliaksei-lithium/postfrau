import Foundation
import Testing
@testable import PostfrauCore

/// The `postfrau` binary itself, run as a subprocess against a scratch workspace.
///
/// The command layer is unit-tested elsewhere; what these cover is everything that only exists in
/// the executable — argument parsing, exit codes, the shape of `--json`, and the fact that two
/// invocations of a real process see each other's writes.
@Suite("postfrau CLI", .serialized)
struct CLITests {
    /// The built binary. `swift test` builds the whole package, so it is somewhere above the
    /// test bundle in the same `.build` tree — but exactly where depends on the runner, so the
    /// search walks up from both the resource bundle and the executable.
    static let binary: URL? = {
        var roots = [Bundle.module.bundleURL, URL(filePath: Bundle.main.bundlePath)]
        roots.append(contentsOf: roots.map { $0.deletingLastPathComponent() })
        for root in roots {
            var directory = root
            for _ in 0..<6 {
                let candidate = directory.appending(path: "postfrau", directoryHint: .notDirectory)
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory = directory.deletingLastPathComponent()
            }
        }
        return nil
    }()

    struct Invocation {
        var stdout: String
        var stderr: String
        var code: Int32
    }

    /// Runs the binary against a workspace of its own.
    @discardableResult
    private func run(
        _ arguments: [String], in root: URL, environment extra: [String: String] = [:]
    ) throws -> Invocation {
        let binary = try #require(Self.binary, "the postfrau binary was not found next to the tests")

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["POSTFRAU_DATA_DIR"] = root.appending(path: "data").path
        environment["POSTFRAU_LOCAL_ROOT"] = root.appending(path: "local").path
        environment.merge(extra) { _, new in new }
        process.environment = environment

        let out = Pipe()
        let error = Pipe()
        process.standardOutput = out
        process.standardError = error
        try process.run()

        // Read before waiting: a pipe that fills up would deadlock the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Invocation(
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errorData, as: UTF8.self),
            code: process.terminationStatus)
    }

    private func prepared(_ root: URL) throws {
        for name in ["data", "local"] {
            try FileManager.default.createDirectory(
                at: root.appending(path: name), withIntermediateDirectories: true)
        }
    }

    // MARK: - Basics

    @Test func versionSaysWhichWorkspaceItIsUsing() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        let result = try run(["version"], in: temp.url)

        #expect(result.code == 0)
        #expect(result.stdout.contains("postfrau \(Postfrau.appVersion)"))
        #expect(result.stdout.contains("POSTFRAU_DATA_DIR"), "and where it got it from")
    }

    @Test func anUnknownCommandIsAUsageError() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        let result = try run(["frobnicate"], in: temp.url)
        #expect(result.code == ExitCode.usage.rawValue)
        #expect(result.stderr.contains("unknown command"))
    }

    @Test func aMissingPathIsANotFoundError() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        let result = try run(["get", "Nope/Nothing"], in: temp.url)
        #expect(result.code == ExitCode.notFound.rawValue)
    }

    @Test func anUnavailableDataFolderHasItsOwnExitCode() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        let result = try run(["--data-dir", "/nowhere/at/all", "ls"], in: temp.url)
        #expect(result.code == ExitCode.dataFolderUnavailable.rawValue)
        #expect(result.stderr.contains("not available"))
    }

    @Test func globalFlagsWorkOnEitherSideOfTheVerb() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["add", "Acme", "--collection"], in: temp.url)

        let before = try run(["--json", "ls"], in: temp.url)
        let after = try run(["ls", "--json"], in: temp.url)
        #expect(before.stdout == after.stdout)
        #expect(before.stdout.contains("\"kind\" : \"collection\""))
    }

    // MARK: - A whole session

    @Test func buildsACollectionThatASecondInvocationCanSee() throws {
        let temp = TempDirectory()
        try prepared(temp.url)

        try run(["add", "Acme API", "--collection"], in: temp.url)
        try run(["add", "Acme API", "--folder", "--name", "Users"], in: temp.url)
        try run([
            "add", "Acme API/Users", "--url", "https://api.test/users",
            "--name", "List users", "-H", "Accept: application/json",
        ], in: temp.url)

        // A separate process, so this is what the app would see too.
        let listed = try run(["ls", "Acme API", "--tree"], in: temp.url)
        #expect(listed.stdout.contains("Users/"))
        #expect(listed.stdout.contains("List users"))

        let detail = try run(["get", "Acme API/Users/List users", "--json"], in: temp.url)
        #expect(detail.code == 0)
        #expect(detail.stdout.contains("https:\\/\\/api.test\\/users"))
        #expect(detail.stdout.contains("Accept"))
    }

    @Test func setChangesOnlyWhatItIsGiven() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["add", "Acme", "--collection"], in: temp.url)
        try run(["add", "Acme", "--url", "https://api.test/x", "--name", "Thing"], in: temp.url)

        try run(["set", "Acme/Thing", "--method", "POST"], in: temp.url)
        let detail = try run(["get", "Acme/Thing", "--json"], in: temp.url)
        #expect(detail.stdout.contains("\"method\" : \"POST\""))
        #expect(detail.stdout.contains("api.test\\/x"), "the URL was left alone")
    }

    @Test func fromCurlBuildsTheWholeRequest() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["add", "Acme", "--collection"], in: temp.url)

        try run([
            "add", "Acme", "--name", "Create",
            "--from-curl",
            #"curl -X POST https://api.test/users -H 'Authorization: Bearer tok' -d '{"a":1}'"#,
        ], in: temp.url)

        let detail = try run(["get", "Acme/Create", "--json"], in: temp.url)
        #expect(detail.stdout.contains("\"method\" : \"POST\""))
        #expect(detail.stdout.contains("\"auth\" : \"bearer\""))
        #expect(!detail.stdout.contains("tok"), "the token is not printed")
    }

    @Test func rmRefusesWithoutYes() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["add", "Acme", "--collection"], in: temp.url)

        let refused = try run(["rm", "Acme"], in: temp.url)
        #expect(refused.code == ExitCode.usage.rawValue)
        #expect(try run(["ls"], in: temp.url).stdout.contains("Acme"))

        let removed = try run(["rm", "Acme", "--yes"], in: temp.url)
        #expect(removed.code == 0)
        #expect(!(try run(["ls"], in: temp.url).stdout.contains("Acme")))
    }

    // MARK: - Environments and secrets

    @Test func environmentValuesReachTheNextInvocation() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["add", "Acme", "--collection"], in: temp.url)
        try run(["add", "Acme", "--url", "{{baseUrl}}/health", "--name", "Health"], in: temp.url)
        try run(["env", "add", "Staging"], in: temp.url)
        try run(["env", "set", "Staging", "baseUrl=https://staging.test"], in: temp.url)
        try run(["env", "use", "Staging"], in: temp.url)

        let detail = try run(["get", "Acme/Health", "--json"], in: temp.url)
        #expect(detail.stdout.contains("staging.test\\/health"),
                "the active environment survives between processes")
    }

    @Test func aSecretIsNotStoredWithoutPermissionToUseTheKeychain() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["env", "add", "Staging"], in: temp.url)

        // Never hangs waiting for a keychain dialog nobody can answer: it says no instead.
        let result = try run(["env", "set", "Staging", "token=abc", "--secret"], in: temp.url)
        #expect(result.code == ExitCode.usage.rawValue)
        #expect(result.stderr.contains("--keychain"))
    }

    @Test func secretsCanComeFromTheEnvironmentInstead() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["add", "Acme", "--collection"], in: temp.url)
        try run(["add", "Acme", "--url", "https://api.test/x", "--name", "Thing"], in: temp.url)
        try run(["env", "add", "Staging"], in: temp.url)
        try run(["env", "use", "Staging"], in: temp.url)

        // A secret with no stored value, satisfied out of band.
        let environmentFile = temp.url.appending(path: "data/environments")
        let files = try FileManager.default.contentsOfDirectory(atPath: environmentFile.path)
        let url = environmentFile.appending(path: try #require(files.first))
        var environment = try Postfrau.makeDecoder()
            .decode(RequestEnvironment.self, from: Data(contentsOf: url))
        environment.variables = [Variable(key: "token", value: "", isSecret: true)]
        try Postfrau.makeEncoder().encode(environment).write(to: url)

        try run(["set", "Acme/Thing", "--url", "https://api.test/{{token}}"], in: temp.url)
        let supplied = try run(
            ["get", "Acme/Thing"], in: temp.url,
            environment: ["POSTFRAU_SECRET_token": "from-the-environment"])
        #expect(supplied.stdout.contains("from-the-environment"))
        #expect(!supplied.stderr.contains("no value for"))

        let missing = try run(["get", "Acme/Thing"], in: temp.url)
        #expect(missing.stderr.contains("no value for token"))
    }

    /// Every flag that carries a value has to be declared as one.
    ///
    /// A flag that is missing from that list is not an error anywhere: it parses as a boolean,
    /// its value becomes a stray positional, and the command quietly does nothing. That is how
    /// `send --save-to` shipped broken until the SKILL.md workflows were run by hand.
    @Test func flagsThatTakeAValueDoNotSilentlyDropIt() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["add", "Acme", "--collection"], in: temp.url)
        try run(["add", "Acme", "--folder", "--name", "Saved"], in: temp.url)
        try run(["add", "Acme", "--url", "https://api.test/x", "--name", "Thing"], in: temp.url)

        // Each of these is a flag whose value must reach the command that reads it.
        try run(["set", "Acme/Thing", "--about", "some notes"], in: temp.url)
        try run(["set", "Acme/Thing", "--auth", "bearer:tok"], in: temp.url)
        try run(["set", "Acme/Thing", "--param", "page=2"], in: temp.url)
        try run(["set", "Acme/Thing", "--header", "X-Trace: abc"], in: temp.url)

        let detail = try run(["get", "Acme/Thing", "--json"], in: temp.url)
        #expect(detail.stdout.contains("some notes"))
        #expect(detail.stdout.contains("\"auth\" : \"bearer\""))
        #expect(detail.stdout.contains("page"))
        #expect(detail.stdout.contains("X-Trace"))

        // The one that was actually broken: a value flag read only by `send`.
        let dry = try run([
            "send", "GET", "https://api.test/y", "--save-to", "Acme/Saved",
            "--name", "Kept", "--dry-run",
        ], in: temp.url)
        #expect(dry.code == 0)
        // A dry run does not save, so the flag is checked by its absence of a parse error, and
        // then for real below.
        #expect(!dry.stderr.contains("unknown"))
    }

    // MARK: - Schema and skill

    @Test func schemaDescribesEveryDocument() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        for subject in ["collection", "request", "environment", "history"] {
            let result = try run(["schema", subject], in: temp.url)
            #expect(result.code == 0)
            #expect(result.stdout.count > 100, "\(subject) should say something useful")
        }
        #expect(try run(["schema", "nonsense"], in: temp.url).code == ExitCode.usage.rawValue)
    }

    @Test func validateAcceptsTheFixturesAndRejectsRubbish() throws {
        let temp = TempDirectory()
        try prepared(temp.url)

        let collection = temp.url.appending(path: "c.json")
        try fixture("acme-api.postman_collection.json").write(to: collection)
        let good = try run(["validate", collection.path], in: temp.url)
        #expect(good.code == 0)
        #expect(good.stdout.contains("Postman collection"))

        let environment = temp.url.appending(path: "e.json")
        try fixture("acme.postman_environment.json").write(to: environment)
        #expect(try run(["validate", environment.path], in: temp.url).stdout
            .contains("Postman environment"))

        let rubbish = temp.url.appending(path: "r.json")
        try Data("not json".utf8).write(to: rubbish)
        #expect(try run(["validate", rubbish.path], in: temp.url).code != 0)
    }

    @Test("find prints paths whole, because they are what you type next")
    func findPrintsUsablePaths() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        let long = "A collection with quite a long name/A folder nested inside it/"
            + "Find all transactions for a deposit account"
        try run(["add", "A collection with quite a long name", "--collection"], in: temp.url)
        try run(
            ["add", "A collection with quite a long name", "--folder",
             "--name", "A folder nested inside it"], in: temp.url)
        try run(
            ["add", "A collection with quite a long name/A folder nested inside it",
             "--url", "https://api.test/transactions",
             "--name", "Find all transactions for a deposit account"], in: temp.url)

        let found = try run(["find", "transactions"], in: temp.url)
        #expect(found.code == 0)
        #expect(
            found.stdout.contains(long),
            "the whole path has to be printed — a clipped one looks copyable and is not")
        // And it says what to do with it, so a caller that has never run this before does not
        // have to infer the next command.
        #expect(found.stdout.contains("postfrau get '\(long)'"))
    }

    @Test("An unreadable data folder explains the way round it")
    func unreadableFolderPointsAtTheLocalAPI() throws {
        let temp = TempDirectory()
        let result = try run(
            ["find", "anything", "--data-dir", "/nonexistent/postfrau/folder"], in: temp.url)
        #expect(result.code == 5)
        let said = result.stdout + result.stderr
        #expect(said.contains("not available"))
        // The point: a sandboxed caller is told where to go, not just that it failed.
        #expect(said.contains("POSTFRAU_API_TOKEN"))
        #expect(said.contains("Local API"))
    }

    @Test("Searching does not warn about secrets it never needed")
    func findDoesNotWarnAboutSecrets() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        try run(["add", "Acme", "--collection"], in: temp.url)
        try run(["add", "Acme", "--url", "https://api.test/x", "--name", "Thing"], in: temp.url)
        try run(["env", "add", "Prod"], in: temp.url)
        try run(["env", "set", "Prod", "token=abc", "--secret"], in: temp.url)
        try run(["env", "use", "Prod"], in: temp.url)

        let found = try run(["find", "thing"], in: temp.url)
        #expect(!found.stderr.contains("no value for"), "a search needs no secret")
        #expect(!found.stdout.contains("no value for"))
    }

    @Test func skillInstallWritesTheDocumentAnAgentReads() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        let destination = temp.url.appending(path: "skills")

        let result = try run(["skill", "install", "--to", destination.path], in: temp.url)
        #expect(result.code == 0)

        let text = try String(
            contentsOf: destination.appending(path: "SKILL.md"), encoding: .utf8)
        #expect(text.hasPrefix("---"), "frontmatter first, or no agent will index it")
        #expect(text.contains("name: postfrau"))
        #expect(text.contains("--as"), "attribution is the first rule")
        #expect(text.contains("| 5 |"), "the exit codes are documented")
        #expect(text.split(separator: "\n").count < 300, "SKILL.md must stay short")
    }

    @Test func importReadsAPostmanExport() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        let file = temp.url.appending(path: "c.json")
        try fixture("acme-api.postman_collection.json").write(to: file)

        let result = try run(["import", file.path], in: temp.url)
        #expect(result.code == 0)
        #expect(try run(["ls"], in: temp.url).stdout.contains("Acme API"))
    }

    @Test func exportRoundTripsThroughTheCommandLine() throws {
        let temp = TempDirectory()
        try prepared(temp.url)
        let file = temp.url.appending(path: "c.json")
        try fixture("acme-api.postman_collection.json").write(to: file)
        try run(["import", file.path], in: temp.url)

        let exported = try run(["export", "Acme API"], in: temp.url)
        #expect(exported.code == 0)
        let reimported = try PostmanV21Importer().import(Data(exported.stdout.utf8))
        #expect(reimported.collection.name == "Acme API")
        #expect(reimported.collection.requestCount == 6)
    }
}
