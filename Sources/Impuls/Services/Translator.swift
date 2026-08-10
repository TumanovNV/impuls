import AppKit
import Translation

/// Apple's on-device translator, driven from the panel.
///
/// The session is not ours to create: `translationTask` hands one over and owns
/// its lifetime, so everything here is about deciding *what* to translate and
/// holding the result. `TranslatePane` supplies the session.
@MainActor
final class Translator: ObservableObject {
    static let russian = Locale.Language(identifier: "ru")
    static let english = Locale.Language(identifier: "en")
    static let maximumInputCharacters = 20_000
    static let pairKey = "translate.pair.v1"

    /// Both ends are always named. Leaving the source to the framework looks
    /// tempting, but its identifier is a separate asset that is not installed
    /// either — auto-detection fails with `unableToIdentifyLanguage`, and the
    /// translation that follows hangs instead of returning an error.
    struct Route: Equatable {
        var source: Locale.Language
        var target: Locale.Language
    }

    /// The two languages in play, without a direction. Which way a given piece
    /// of text runs is decided per keystroke from its alphabet.
    struct Pair: Equatable {
        var first: Locale.Language
        var second: Locale.Language

        /// Both sides are reduced to a bare language on the way in.
        ///
        /// The framework's own list hands back regional variants — "en-GB" and
        /// "en-US" sit in it separately — and asking it whether it can
        /// translate Russian into *British* English gets "unsupported" back for
        /// a pair it translates perfectly well. Region is not a thing this
        /// panel offers, so it is not a thing it should carry around.
        init(first: Locale.Language, second: Locale.Language) {
            self.first = Translator.base(first)
            self.second = Translator.base(second)
        }

        /// True when the two sides are written differently, which is what makes
        /// the direction readable from the text itself.
        var isDirectionDetectable: Bool {
            guard let a = TranslationScript.of(first), let b = TranslationScript.of(second) else {
                return false
            }
            return a != b
        }

        func replacing(_ language: Locale.Language, with replacement: Locale.Language) -> Pair {
            guard !Translator.same(language, replacement) else { return self }
            // Picking the language already on the other side means the user
            // wants the two swapped, not a pair of one language.
            if Translator.same(first, language) {
                return Translator.same(second, replacement)
                    ? Pair(first: second, second: first)
                    : Pair(first: replacement, second: second)
            }
            if Translator.same(second, language) {
                return Translator.same(first, replacement)
                    ? Pair(first: second, second: first)
                    : Pair(first: first, second: replacement)
            }
            return self
        }

        var swapped: Pair { Pair(first: second, second: first) }
    }

    /// Keyed by the pane's debounced task. The counter is what makes a retry of
    /// unchanged text a new request rather than a no-op.
    struct Request: Equatable {
        var text: String
        var attempt: Int
        var pair: String
    }

    @Published var input = "" {
        didSet {
            let end = input.index(
                input.startIndex,
                offsetBy: Self.maximumInputCharacters,
                limitedBy: input.endIndex
            )
            if let end, end < input.endIndex { input = String(input[..<end]) }
        }
    }
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    /// The failure is a missing language pack, which is a thing the user can
    /// go and fix — so the pane offers the button that takes them there.
    @Published private(set) var needsDownload = false
    @Published private(set) var pair: Pair
    /// Every language macOS can translate, one entry per language rather than
    /// per region, ordered the way the panel will show them.
    @Published private(set) var supported: [Locale.Language] = []

    /// What would happen if a language were chosen, given the one that would
    /// stay on the other side.
    ///
    /// Three outcomes rather than two: macOS translates a *pair*, not a
    /// language, and most of its pairs run through English. Russian and German
    /// are each supported and cannot be translated into one another, so
    /// "downloadable" and "impossible" have to look different in the menu —
    /// offering a pair that can never work is worse than not offering it.
    enum Readiness: Equatable {
        case installed
        case downloadable
        case unsupported

        init(_ forward: LanguageAvailability.Status, _ backward: LanguageAvailability.Status) {
            if forward == .installed || backward == .installed { self = .installed }
            else if forward == .supported || backward == .supported { self = .downloadable }
            else { self = .unsupported }
        }
    }

    @Published private(set) var readiness: [String: Readiness] = [:]

    private let defaults: UserDefaults
    private var attempt = 0
    private var availabilityTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pair = Self.storedPair(in: defaults) ?? Pair(first: Self.russian, second: Self.english)
    }

    var request: Request {
        Request(text: input, attempt: attempt, pair: Self.identifier(of: pair))
    }
    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    var route: Route { route(for: trimmed) }

    /// Text written like the second language goes back to the first; anything
    /// else goes out to the second.
    ///
    /// Decided by alphabet rather than by language detection: a single word is
    /// far too short to identify reliably. When both sides are written the same
    /// way there is nothing to read, so the pair keeps its stated direction and
    /// the user swaps it by hand.
    func route(for text: String) -> Route {
        // `pair` normalises both sides, so the session is always configured
        // with bare languages — never "en-GB", which the framework refuses to
        // pair with Russian even though it translates "en" fine.
        guard pair.isDirectionDetectable,
              let script = TranslationScript.of(text),
              script == TranslationScript.of(pair.second) else {
            return Route(source: pair.first, target: pair.second)
        }
        return Route(source: pair.second, target: pair.first)
    }

    // MARK: - Choosing languages

    /// Replaces one side of the pair, keeping the other. The caller names the
    /// language being replaced rather than a position, because which side is
    /// the source depends on what is currently typed.
    func select(_ replacement: Locale.Language, replacing language: Locale.Language) {
        apply(pair.replacing(language, with: replacement))
    }

    func swap() {
        apply(pair.swapped)
    }

    private func apply(_ new: Pair) {
        guard new != pair else { return }
        pair = new
        defaults.set(Self.identifier(of: new), forKey: Self.pairKey)
        clear()
        refreshAvailability()
    }

    nonisolated static func identifier(of pair: Pair) -> String {
        "\(code(pair.first))|\(code(pair.second))"
    }

    private static func storedPair(in defaults: UserDefaults) -> Pair? {
        let parts = (defaults.string(forKey: pairKey) ?? "").split(separator: "|")
        guard parts.count == 2, parts[0] != parts[1] else { return nil }
        return Pair(
            first: Locale.Language(identifier: String(parts[0])),
            second: Locale.Language(identifier: String(parts[1]))
        )
    }

    /// Nonisolated on purpose. `Pair` is a nested type and does not inherit the
    /// class's actor, and these are pure functions over a value — nothing here
    /// touches state that needs the main thread.
    nonisolated static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        code(a) == code(b)
    }

    /// Region and script are dropped throughout: the panel offers languages,
    /// not locales, and "en-GB" beside "en-US" is a distinction nobody asked
    /// this translator to make.
    nonisolated static func code(_ language: Locale.Language) -> String {
        language.languageCode?.identifier ?? language.minimalIdentifier
    }

    /// The language itself, with any region or script dropped.
    nonisolated static func base(_ language: Locale.Language) -> Locale.Language {
        Locale.Language(identifier: code(language))
    }

    // MARK: - What macOS can actually translate

    /// Loads the language list once, then the install status of every candidate
    /// against the current pair. Both are framework queries; neither touches
    /// the network from Impuls.
    func loadSupportedLanguages() {
        guard supported.isEmpty else { return }
        Task { [weak self] in
            let languages = await LanguageAvailability().supportedLanguages
            var seen: Set<String> = []
            let unique = languages
                .filter { seen.insert(Translator.code($0)).inserted }
                .map(Translator.base)
                .sorted {
                    Translator.name($0).localizedStandardCompare(Translator.name($1)) == .orderedAscending
                }
            guard let self else { return }
            self.supported = unique
            self.refreshAvailability()
        }
    }

    private func refreshAvailability() {
        availabilityTask?.cancel()
        let candidates = supported
        let current = pair
        guard !candidates.isEmpty else { return }
        availabilityTask = Task { [weak self] in
            let availability = LanguageAvailability()
            var result: [String: Readiness] = [:]
            // Both directions count: a pack downloaded one way round translates
            // the other way too, and the panel flips direction by itself.
            for candidate in candidates {
                for other in [current.first, current.second] {
                    if Task.isCancelled { return }
                    guard !Translator.same(candidate, other) else { continue }
                    let forward = await availability.status(from: candidate, to: other)
                    let backward = await availability.status(from: other, to: candidate)
                    result[Translator.readinessKey(candidate, other)] = Readiness(forward, backward)
                }
            }
            if Task.isCancelled { return }
            guard let self else { return }
            self.readiness = result
        }
    }

    nonisolated static func readinessKey(
        _ candidate: Locale.Language,
        _ other: Locale.Language
    ) -> String {
        "\(code(candidate))>\(code(other))"
    }

    /// Readiness of the pair that choosing `candidate` in place of `language`
    /// would produce — that is, `candidate` against whichever side stays put.
    func readiness(
        choosing candidate: Locale.Language,
        replacing language: Locale.Language
    ) -> Readiness {
        // The language already shown, and the one on the other side, are both
        // part of a pair the user is already using.
        guard !Self.same(candidate, language) else { return .installed }
        let staying = Self.same(language, pair.first) ? pair.second : pair.first
        guard !Self.same(candidate, staying) else { return .installed }
        // Unknown until the scan lands. Offering it is the kinder default: the
        // pane says what is missing the moment it is tried.
        return self.readiness[Self.readinessKey(candidate, staying)] ?? .downloadable
    }

    // MARK: - Running

    func retry() {
        attempt += 1
    }

    func clear() {
        output = ""
        failure = nil
        needsDownload = false
    }

    func reset() {
        input = ""
        clear()
    }

    func run(_ session: TranslationSession) async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        guard let source = session.sourceLanguage, let target = session.targetLanguage else {
            NSLog("Impuls: translate session arrived without languages")
            return
        }

        // Changing the language leaves the previous session in flight, and its
        // answer is about a pair the user has already moved on from. Letting it
        // land is what made a working translator start reporting the failure of
        // a pair no longer on screen.
        let expected = Self.identifier(of: pair)
        let wanted = route(for: text)
        guard Self.same(source, wanted.source), Self.same(target, wanted.target) else {
            NSLog("Impuls: translate ignoring stale \(Self.code(source)) → \(Self.code(target)) session")
            return
        }

        // No language pack ships installed. `prepareTranslation()` is what asks
        // for one, but it blocks until its system prompt is answered — and that
        // prompt has nowhere to appear over a borderless panel of an app that
        // never activates, so it would hang forever. Check instead, and send
        // the user to the one place that can actually install it.
        let status = await LanguageAvailability().status(from: source, to: target)
        guard !Task.isCancelled else { return }
        guard status == .installed else {
            NSLog("""
            Impuls: translate \(source.maximalIdentifier) → \(target.maximalIdentifier) \
            unavailable, status \(String(describing: status))
            """)
            output = ""
            needsDownload = status == .supported
            failure = needsDownload
                ? localized("The %@ → %@ language pack is not installed.", Self.name(source), Self.name(target))
                : localized("macOS does not translate this pair of languages.")
            return
        }

        // The session belongs to the modifier that handed it over and dies with
        // it. Changing the language tears that task down, so anything resuming
        // from the await above has to check that its pair is still the one on
        // screen before touching the session again.
        guard Self.identifier(of: pair) == expected, !Task.isCancelled else { return }

        do {
            let response = try await session.translate(text)
            guard !Task.isCancelled else { return }
            output = response.targetText
            failure = nil
            needsDownload = false
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsDownload = false
            failure = error.localizedDescription
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    /// "Русский", "English" — for the column headers. Named in the language the
    /// panel itself is in, not in the system's: those two can differ, and a
    /// column headed in one language above a button worded in another reads as
    /// a mistake.
    nonisolated static func name(_ language: Locale.Language) -> String {
        guard let name = Locale(identifier: appLanguage).localizedString(forLanguageCode: code(language)) else {
            return code(language).uppercased()
        }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// System Settings → General → Language & Region, which is where the
    /// "Translation Languages…" button lives.
    static func openLanguageSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
