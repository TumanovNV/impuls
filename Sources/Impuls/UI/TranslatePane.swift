import SwiftUI
import Translation

/// Two columns, the way every translator is laid out: source on the left,
/// result on the right. The left one sits on a surface — that is the whole
/// signal that it can be typed into, since a caret only shows up once there
/// is something in it.
struct TranslatePane: View {
    @ObservedObject var translator: Translator
    /// Whether the panel holds the keyboard. Drops to false when the user
    /// clicks into another app, and the field follows it — the caret has to
    /// stop blinking here when it has genuinely gone elsewhere.
    @Binding var wantsKeyboard: Bool

    @FocusState private var focused: Bool
    @State private var configuration: TranslationSession.Configuration?
    @State private var copied = false
    /// Measured once, off the layout path. See `body`.
    @State private var paneSize: CGSize = .zero

    /// Largest first. Four rungs, far enough apart that a change is always a
    /// deliberate-looking drop rather than a wobble.
    /// Aligned with `Theme.Typo`: 28 is the hero size, 21 the display size,
  ///  15 the title size and 12 the body size. The ladder fits text to the
  /// column, but it should still land on sizes the rest of the panel uses.
    private let ladder: [CGFloat] = [28, 21, 15, 12]

    var body: some View {
        let font = fontSize(in: paneSize)
        HStack(alignment: .top, spacing: Theme.Space.s) {
            source(font)
            result(font)
        }
        // Measured from a background layer rather than by wrapping the content
        // in a GeometryReader. Wrapped, the type size depends on a measurement
        // that depends on the very text being sized, so every wrap onto a new
        // line costs a second layout pass — which is exactly the hitch one sees
        // at the moment a line breaks. The panel never changes size, so this
        // reads once and then stays put.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { paneSize = proxy.size }
                    .onChange(of: proxy.size) { _, new in paneSize = new }
            }
        )
        .padding(.top, Theme.Space.hair)
        // One task for both the text and the retry counter: a keystroke
        // cancels the pending sleep, so only a pause actually translates.
        .task(id: translator.request) { await schedule() }
        .translationTask(configuration) { session in
            await translator.run(session)
        }
        .onAppear {
            focused = wantsKeyboard
            translator.loadSupportedLanguages()
        }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
    }

    // MARK: - Left

    private func source(_ font: CGFloat) -> some View {
        column(translator.route.source) {
            if !translator.input.isEmpty {
                Button { translator.reset() } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Typo.captionSemibold)
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Clear"))
                .accessibilityLabel(localized("Clear"))
            }
        } content: {
            // A `TextField(axis: .vertical)` grows to fit its text, and growing
            // means reporting a new intrinsic size, which invalidates layout
            // all the way to the root of the panel — once per wrapped line,
            // which is precisely when the hitch showed. An editor takes the
            // rectangle it is given and re-wraps inside it, so a new line
            // costs nothing outside its own bounds.
            TextEditor(text: $translator.input)
                .accessibilityLabel(localized("Text to translate"))
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .font(.system(size: font))
                .foregroundStyle(Theme.primary)
                // Grey rather than the system accent: the caret has to say
                // where typing lands without being the brightest thing in a
                // panel that is mostly dark and mostly still.
                .tint(Theme.secondary)
                .focused($focused)
                // The editor insets its text by a few points of its own; pull
                // that back so the first character lines up with the title.
                .padding(.leading, -5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onKeyPress(.escape) {
                    translator.reset()
                    return .handled
                }
        }
        .padding(Theme.Space.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: - Right

    private func result(_ font: CGFloat) -> some View {
        column(translator.route.target) {
            if !translator.output.isEmpty {
                Button {
                    translator.copyOutput()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(Theme.Typo.captionSemibold)
                        .foregroundStyle(copied ? Color.green : Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Copy"))
                .accessibilityLabel(localized("Copy"))
            }
        } content: {
            outcome(font)
        }
        .padding(10)
        .animation(Theme.motion(Theme.contentAnimation), value: copied)
    }

    @ViewBuilder
    private func outcome(_ font: CGFloat) -> some View {
        if let failure = translator.failure {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure)
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if translator.needsDownload {
                        Button("Translation Languages…") { Translator.openLanguageSettings() }
                    }
                    Button("Retry") { translator.retry() }
                    Button("Swap Languages") { translator.swap() }
                }
                .buttonStyle(.plain)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if !translator.output.isEmpty {
            ScrollView(showsIndicators: false) {
                Text(translator.output)
                    .font(.system(size: font))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .accessibilityLabel(localized("Translation"))
                    .accessibilityValue(translator.output)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // Nothing while it works. The translation lands in a fraction of a
            // second, so a status would be a word that flashes up and leaves —
            // more movement in the column than the result it announces.
            Color.clear
        }
    }

    // MARK: - Type size
    //
    // A word should read like a headline and a paragraph has to fit, so the
    // size has to move — but it moves in steps, not continuously. Sizing the
    // type to the exact text length means every keystroke re-breaks every line
    // for a fraction of a point nobody asked for, and that reads as the text
    // shaking rather than as anything smooth. One decisive drop, rarely, is
    // both calmer to look at and easier to trust.

    /// What the text actually gets to occupy inside one column: half the pane
    /// minus the gap, minus the padding, minus the title row above it.
    private func textArea(in size: CGSize) -> CGSize {
        CGSize(
            width: max(40, (size.width - 10) / 2 - 20),
            height: max(40, size.height - 40)
        )
    }

    /// The largest rung the text still fits on. Both columns share it, computed
    /// from whichever side is longer — sides set at different scales stop
    /// looking like a pair.
    private func fontSize(in size: CGSize) -> CGFloat {
        let count = CGFloat(max(translator.trimmed.count, translator.output.count))
        // Before the first measurement lands there is nothing to fit type to,
        // and the pane is empty anyway.
        guard count > 0, size.width > 0, size.height > 0 else { return ladder[0] }
        // A glyph runs about half its point size wide and 1.3 of it tall with
        // leading, so roughly `area / (0.76 · s²)` characters fit at size `s`.
        // The 0.95 keeps the last line from being the one that overflows.
        let area = textArea(in: size)
        let usable = area.width * area.height * 0.95
        return ladder.first { count <= usable / (0.76 * $0 * $0) } ?? ladder[ladder.count - 1]
    }

    // MARK: - Shared

    private func column<Accessory: View, Content: View>(
        _ language: Locale.Language,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                languageMenu(for: language)
                Spacer(minLength: 4)
                accessory()
            }
            .frame(height: 14)

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The column heading is the control. There is no room in the panel for a
    /// row of pickers above two columns that are already short, and the heading
    /// was already naming the language it would now let you change.
    private func languageMenu(for language: Locale.Language) -> some View {
        Menu {
            Button(localized("Swap Languages"), action: translator.swap)
            Divider()
            ForEach(translator.supported, id: \.maximalIdentifier) { candidate in
                let readiness = translator.readiness(choosing: candidate, replacing: language)
                Button {
                    translator.select(candidate, replacing: language)
                } label: {
                    entry(candidate, current: language, readiness: readiness)
                }
                // macOS translates a pair, not a language, and most of its
                // pairs run through English. A language it cannot pair with the
                // other side is shown greyed rather than hidden — the point is
                // that the user can see it was considered.
                .disabled(readiness == .unsupported)
            }
        } label: {
            HStack(spacing: 3) {
                Text(Translator.name(language).uppercased())
                    .font(Theme.Typo.captionSemibold)
                    .tracking(0.8)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(Theme.Glyph.chevron)
            }
            .foregroundStyle(Theme.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(localized("Language"))
        .accessibilityValue(Translator.name(language))
    }

    /// A tick for the language already shown, a download mark for a pair whose
    /// pack is still missing, and nothing for one that is ready. Without the
    /// middle mark every choice looks equally usable, and none of the packs
    /// ships installed.
    @ViewBuilder
    private func entry(
        _ candidate: Locale.Language,
        current: Locale.Language,
        readiness: Translator.Readiness
    ) -> some View {
        let name = Translator.name(candidate)
        if Translator.same(candidate, current) {
            Label(name, systemImage: "checkmark")
        } else {
            switch readiness {
            case .installed: Text(name)
            case .downloadable: Label(name, systemImage: "arrow.down.circle")
            case .unsupported: Text(name)
            }
        }
    }

    // MARK: - Scheduling

    private func schedule() async {
        let text = translator.trimmed
        guard !text.isEmpty else {
            configuration = nil
            translator.clear()
            return
        }
        // Wait out the typing: a word is a handful of keystrokes, and a session
        // per letter would be both wasteful and visibly jumpy.
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }

        let route = translator.route(for: text)
        // Compared by language, not by identity: the framework hands the
        // configuration back with its own resolved value — "en-US" for the
        // "en" it was given — so an exact comparison never matches and a fresh
        // session gets built on every keystroke.
        if var current = configuration,
           let source = current.source, let target = current.target,
           Translator.same(source, route.source), Translator.same(target, route.target) {
            // Same pair, different text. The modifier only re-runs when the
            // configuration changes, and invalidating is how one says "again".
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: route.source, target: route.target)
        }
    }
}
