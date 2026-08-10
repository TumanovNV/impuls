import Foundation

/// Which alphabet a piece of text is written in.
///
/// The translator picks its direction from this rather than from language
/// identification: a single word is far too short to identify reliably, and
/// "привет" comes back as Bulgarian often enough to matter. An alphabet, by
/// contrast, is right there in the code points.
enum TranslationScript: String, CaseIterable {
    case latin = "Latn"
    case cyrillic = "Cyrl"
    case greek = "Grek"
    case hebrew = "Hebr"
    case arabic = "Arab"
    case devanagari = "Deva"
    case thai = "Thai"
    case han = "Hani"
    case kana = "Kana"
    case hangul = "Hang"

    /// Ranges are deliberately coarse. This has one job — telling two sides of
    /// a language pair apart — and a precise Unicode script table would be a
    /// large amount of code to answer the same question no better.
    private var ranges: [ClosedRange<UInt32>] {
        switch self {
        case .latin: return [0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F]
        case .cyrillic: return [0x0400...0x04FF, 0x0500...0x052F]
        case .greek: return [0x0370...0x03FF, 0x1F00...0x1FFF]
        case .hebrew: return [0x0590...0x05FF]
        case .arabic: return [0x0600...0x06FF, 0x0750...0x077F]
        case .devanagari: return [0x0900...0x097F]
        case .thai: return [0x0E00...0x0E7F]
        case .han: return [0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF]
        case .kana: return [0x3040...0x309F, 0x30A0...0x30FF]
        case .hangul: return [0x1100...0x11FF, 0xAC00...0xD7AF]
        }
    }

    private func contains(_ scalar: Unicode.Scalar) -> Bool {
        ranges.contains { $0.contains(scalar.value) }
    }

    /// The alphabet most of the text is in, ignoring digits, spaces and
    /// punctuation. Nil when there is nothing alphabetic to go on.
    ///
    /// Majority rather than first match: a Russian sentence quoting an English
    /// product name is still a Russian sentence, and translating it as English
    /// because of one Latin word is the mistake this avoids.
    static func of(_ text: String) -> TranslationScript? {
        var counts: [TranslationScript: Int] = [:]
        // Bounded: direction is decided from the opening of the text, and a
        // 20 000-character paste should not be walked twice on every keystroke.
        for scalar in text.unicodeScalars.prefix(2_048) {
            guard let script = allCases.first(where: { $0.contains(scalar) }) else { continue }
            counts[script, default: 0] += 1
        }
        // Japanese mixes kana with han; kana is the part that identifies it, so
        // any kana at all outweighs the han characters beside it.
        if counts[.kana] != nil { return .kana }
        return counts.max { $0.value < $1.value }?.key
    }

    /// The alphabet a language is written in.
    ///
    /// `Locale.Language` carries a script only when one was spelled out, so
    /// "ru" alone has none. Maximising the identifier fills it in — "ru"
    /// becomes "ru-Cyrl-RU" — which is exactly the inference needed here.
    static func of(_ language: Locale.Language) -> TranslationScript? {
        let maximal = Locale.Language(identifier: language.maximalIdentifier)
        guard let identifier = maximal.script?.identifier else { return nil }
        if let exact = TranslationScript(rawValue: identifier) { return exact }
        // Aliases the maximal identifier uses for writing systems this treats
        // as one: simplified and traditional Han, and the Japanese mixture.
        switch identifier {
        case "Hans", "Hant", "Hanb": return .han
        case "Jpan", "Hira": return .kana
        case "Kore": return .hangul
        default: return nil
        }
    }
}
