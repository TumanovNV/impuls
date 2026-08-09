import Foundation

/// Small, allocation-bounded text projections for rows and search surfaces.
/// User content remains intact; only the transient representation used by a
/// compact UI or an index is shortened.
enum BoundedText {
    static func firstLine(_ text: String, maximumCharacters: Int) -> String {
        precondition(maximumCharacters >= 0)
        guard maximumCharacters > 0, !text.isEmpty else { return "" }

        var output = String()
        output.reserveCapacity(min(maximumCharacters, 256))
        var appended = 0
        var inspected = 0
        // Do not walk an arbitrarily long run of leading whitespace just to
        // render a one-line row. The extra allowance preserves ordinary
        // indentation and blank lines while keeping the work deterministic.
        let inspectionLimit = maximumCharacters <= Int.max - 1_024
            ? maximumCharacters + 1_024
            : Int.max

        for character in text {
            guard inspected < inspectionLimit, appended < maximumCharacters else { break }
            inspected += 1
            if output.isEmpty, character.isWhitespace { continue }
            if character.isNewline { break }
            output.append(character)
            appended += 1
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prefix(_ text: String, maximumCharacters: Int) -> String {
        precondition(maximumCharacters >= 0)
        return String(text.prefix(maximumCharacters))
    }
}
