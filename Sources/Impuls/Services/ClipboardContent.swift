import Foundation
import UniformTypeIdentifiers

enum ClipboardContentKind: String, Codable, Equatable {
    case text
    case link
    case email
    case phone
    case color
    case json
    case code
    case file
    case image

    var title: String {
        switch self {
        case .text: return localized("Text")
        case .link: return localized("Link")
        case .email: return localized("Email Address")
        case .phone: return localized("Phone Number")
        case .color: return localized("Color")
        case .json: return "JSON"
        case .code: return localized("Code")
        case .file: return localized("File")
        case .image: return localized("Image")
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        case .color: return "paintpalette"
        case .json: return "curlybraces"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .file: return "doc"
        case .image: return "photo"
        }
    }
}

enum ClipboardContentClassifier {
    static let maximumStructuredTextBytes = 64 * 1_024
    private static let maximumCodeSampleCharacters = 16 * 1_024

    static func kind(for text: String) -> ClipboardContentKind {
        // URL/JSON parsing and case-insensitive token searches can allocate a
        // second copy of their input. Large clipboard entries remain usable as
        // plain text, but only a bounded prefix is inspected for code markers.
        guard text.lengthOfBytes(using: .utf8) <= maximumStructuredTextBytes else {
            let sample = String(text.prefix(maximumCodeSampleCharacters))
            return looksLikeCode(sample) ? .code : .text
        }
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return .text }
        if webURL(from: candidate) != nil { return .link }
        if emailURL(from: candidate) != nil { return .email }
        if phoneURL(from: candidate) != nil { return .phone }
        if isColor(candidate) { return .color }
        if prettyPrintedJSON(candidate) != nil { return .json }
        if looksLikeCode(candidate) { return .code }
        return .text
    }

    static func kind(for url: URL) -> ClipboardContentKind {
        guard let ext = url.pathExtension.isEmpty ? nil : url.pathExtension,
              let type = UTType(filenameExtension: ext) else { return .file }
        return type.conforms(to: .image) ? .image : .file
    }

    static func webURL(from text: String) -> URL? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else { return nil }
        return components.url
    }

    static func emailURL(from text: String) -> URL? {
        let pattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
        guard text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = text
        return components.url
    }

    static func phoneURL(from text: String) -> URL? {
        let pattern = #"^\+?[0-9() .-]{7,24}$"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let digits = text.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return nil }
        var components = URLComponents()
        components.scheme = "tel"
        components.path = (text.hasPrefix("+") ? "+" : "") + digits
        return components.url
    }

    static func prettyPrintedJSON(_ text: String) -> String? {
        guard let first = text.first, first == "{" || first == "[",
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let formatted = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: formatted, encoding: .utf8)
    }

    private static func isColor(_ text: String) -> Bool {
        text.range(
            of: #"^#(?:[0-9A-F]{3}|[0-9A-F]{4}|[0-9A-F]{6}|[0-9A-F]{8})$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let tokens = [
            "func ", "class ", "struct ", "enum ", "protocol ", "import ",
            "let ", "var ", "def ", "function ", "const ", "SELECT ",
            "INSERT ", "UPDATE ", "#!/", "<?xml", "<html", "</"
        ]
        if tokens.contains(where: { text.localizedCaseInsensitiveContains($0) }) { return true }
        let hasBraces = text.contains("{") && text.contains("}")
        let hasCodePunctuation = text.contains(";") || text.contains("=>") || text.contains("::")
        return text.contains("\n") && hasBraces && hasCodePunctuation
    }
}
