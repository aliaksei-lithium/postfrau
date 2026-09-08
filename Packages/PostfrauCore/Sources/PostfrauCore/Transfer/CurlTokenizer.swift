import Foundation

/// Splits a shell command line into arguments the way `sh` would.
///
/// Only the parts of the shell a pasted `curl` actually uses: single and double quotes,
/// backslash escapes, `$'…'` (which is how browsers copy a body containing newlines), and `\`
/// at end of line for continuations. No expansion of variables, globs or substitutions — a
/// pasted command is text to read, never something to evaluate.
public enum CurlTokenizer {
    public static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasCurrent = false
        let characters = Array(command)
        var index = 0

        func flush() {
            if hasCurrent { tokens.append(current) }
            current = ""
            hasCurrent = false
        }

        while index < characters.count {
            let character = characters[index]

            switch character {
            case " ", "\t", "\n", "\r":
                flush()
                index += 1

            case "\\":
                // A backslash before a newline continues the line; before anything else it
                // escapes that character.
                if index + 1 < characters.count {
                    let next = characters[index + 1]
                    if next == "\n" || next == "\r" {
                        index += 2
                        // \r\n counts once.
                        if next == "\r", index < characters.count, characters[index] == "\n" {
                            index += 1
                        }
                    } else {
                        current.append(next)
                        hasCurrent = true
                        index += 2
                    }
                } else {
                    index += 1
                }

            case "'":
                // Single quotes are literal all the way to the closing quote.
                hasCurrent = true
                index += 1
                while index < characters.count, characters[index] != "'" {
                    current.append(characters[index])
                    index += 1
                }
                index += 1  // the closing quote, or the end of the string

            case "\"":
                hasCurrent = true
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        // Inside double quotes the shell only honours a few escapes; every other
                        // backslash is literal, which matters for JSON bodies full of \".
                        let next = characters[index + 1]
                        if next == "\"" || next == "\\" || next == "$" || next == "`" {
                            current.append(next)
                            index += 2
                            continue
                        }
                        if next == "\n" {
                            index += 2
                            continue
                        }
                    }
                    current.append(characters[index])
                    index += 1
                }
                index += 1

            case "$" where index + 1 < characters.count && characters[index + 1] == "'":
                // `$'…'` — ANSI-C quoting. Chrome copies request bodies this way.
                hasCurrent = true
                index += 2
                while index < characters.count, characters[index] != "'" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        current.append(Self.ansiEscape(characters[index + 1]))
                        index += 2
                        continue
                    }
                    current.append(characters[index])
                    index += 1
                }
                index += 1

            case "$" where index + 1 < characters.count && characters[index + 1] == "\"":
                // `$"…"` is a localised string in bash; the quotes are all that matters here.
                index += 1

            default:
                current.append(character)
                hasCurrent = true
                index += 1
            }
        }

        flush()
        return tokens
    }

    /// The escapes `$'…'` understands. Anything else stands for itself.
    private static func ansiEscape(_ character: Character) -> Character {
        switch character {
        case "n": "\n"
        case "t": "\t"
        case "r": "\r"
        case "0": "\0"
        case "a": "\u{07}"
        case "b": "\u{08}"
        case "f": "\u{0C}"
        case "v": "\u{0B}"
        case "e": "\u{1B}"
        default: character
        }
    }
}
