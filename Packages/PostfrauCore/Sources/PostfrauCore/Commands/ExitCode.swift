import Foundation

/// What `postfrau` exits with.
///
/// Part of the tool's contract, documented in `SKILL.md` so an agent can branch on it — which is
/// why it lives in Core rather than in the executable: the tests that pin the contract have to be
/// able to name these too.
public enum ExitCode: Int32, Sendable {
    case ok = 0
    case usage = 1
    case notFound = 2
    case transport = 3
    /// An HTTP status of 400 or more, and `--fail` was given.
    case httpFailure = 4
    case dataFolderUnavailable = 5
}
