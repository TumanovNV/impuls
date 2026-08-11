import SwiftUI

struct ActionsPane: View {
    @ObservedObject var actions: ImpulsActionsStore
    @ObservedObject var clipboard: ClipboardStore
    @ObservedObject var snippets: SnippetStore
    @ObservedObject var notes: NoteStore
    @Binding var wantsKeyboard: Bool
    let perform: (ImpulsActionCommand, ImpulsActionResult) -> String?

    @FocusState private var focused: Bool
    @State private var selectedID: String?
    @State private var feedback: String?

    private var results: [ImpulsActionResult] {
        actions.results(
            clipboard: clipboard.items,
            snippets: snippets.items,
            notes: notes.notes
        )
    }

    var body: some View {
        // SwiftUI may ask several child builders for their value in one render
        // pass. Search is the expensive part, so compute the shared snapshot
        // once instead of rebuilding it for the list, footer and selection.
        let currentResults = results
        let currentSelected = selected(in: currentResults)
        VStack(spacing: Theme.Space.xs + 2) {
            search
            resultList(currentResults, selected: currentSelected)
            footer(currentSelected)
        }
        .padding(.top, Theme.Space.hair)
        .onAppear {
            selectedID = currentResults.first?.id
            focused = wantsKeyboard
        }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
        .onChange(of: actions.query) { _, _ in
            selectedID = currentResults.first?.id
            feedback = nil
        }
        .onChange(of: currentResults.map(\.id)) { _, identifiers in
            guard !identifiers.isEmpty else {
                selectedID = nil
                return
            }
            if let selectedID, identifiers.contains(selectedID) { return }
            selectedID = identifiers.first
        }
    }

    private var search: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.tertiary)
            TextField(localized("Search clipboard, snippets, and notes"), text: $actions.query)
                .accessibilityLabel(localized("Search clipboard, snippets, and notes"))
                .textFieldStyle(.plain)
                .font(Theme.Typo.label)
                .foregroundStyle(Theme.primary)
                .tint(Theme.secondary)
                .focused($focused)
                .onSubmit { runDefault() }
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
            if !actions.query.isEmpty {
                Button { actions.query = "" } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Typo.captionSemibold)
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Clear Search"))
            }
            Text("↑↓ · ↩")
                .font(Theme.Typo.captionMono)
                .foregroundStyle(Theme.tertiary)
                // A drawn hint for the eye. Spelling the arrows out to
                // VoiceOver would read as punctuation, not as help.
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Size.input)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    @ViewBuilder
    private func resultList(
        _ results: [ImpulsActionResult],
        selected: ImpulsActionResult?
    ) -> some View {
        if results.isEmpty {
            VStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.Glyph.large)
                Text("No matching content")
                    .font(Theme.Typo.caption)
            }
            .foregroundStyle(Theme.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(results) { result in
                            ActionResultRow(
                                result: result,
                                isSelected: selected?.id == result.id,
                                select: { selectedID = result.id },
                                run: {
                                    selectedID = result.id
                                    run(.copy, result)
                                }
                            )
                            .id(result.id)
                        }
                    }
                    .padding(.bottom, 2)
                }
                .onChange(of: selectedID) { _, identifier in
                    guard let identifier else { return }
                    withAnimation(Theme.contentAnimation) {
                        proxy.scrollTo(identifier, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func footer(_ selected: ImpulsActionResult?) -> some View {
        if let selected {
            HStack(spacing: 5) {
                if let feedback {
                    Label(feedback, systemImage: "checkmark")
                        .font(Theme.Typo.captionStrong)
                        .foregroundStyle(Color.green)
                        .lineLimit(1)
                } else {
                    Label(selected.source.title, systemImage: selected.source.symbol)
                        .font(Theme.Typo.captionStrong)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                ViewThatFits(in: .horizontal) {
                    commandButtons(for: selected, compact: false)
                    commandButtons(for: selected, compact: true)
                }
            }
            .frame(height: Theme.Size.footer)
        }
    }

    private func commandButtons(for result: ImpulsActionResult, compact: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(result.commands) { command in
                Button { run(command, result) } label: {
                    Group {
                        if compact {
                            Image(systemName: command.symbol)
                                .frame(width: 12)
                        } else {
                            Label(command.title, systemImage: command.symbol)
                        }
                    }
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .fill(Theme.surface)
                    )
                }
                .buttonStyle(.plain)
                .help(command.title)
                .accessibilityLabel(command.title)
            }
        }
    }

    private func moveSelection(by offset: Int) {
        let currentResults = results
        guard !currentResults.isEmpty else { return }
        let current = currentResults.firstIndex(where: { $0.id == selectedID }) ?? 0
        let destination = (current + offset + currentResults.count) % currentResults.count
        selectedID = currentResults[destination].id
    }

    private func runDefault() {
        guard let selected = selected(in: results) else { return }
        run(.copy, selected)
    }

    private func selected(in results: [ImpulsActionResult]) -> ImpulsActionResult? {
        results.first(where: { $0.id == selectedID }) ?? results.first
    }

    private func run(_ command: ImpulsActionCommand, _ result: ImpulsActionResult) {
        guard let message = perform(command, result) else { return }
        feedback = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            if feedback == message { feedback = nil }
        }
    }
}

private struct ActionResultRow: View {
    let result: ImpulsActionResult
    let isSelected: Bool
    let select: () -> Void
    let run: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: result.contentKind.symbol)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.tertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.title.replacingOccurrences(of: "\n", with: " "))
                    .font(isSelected ? Theme.Typo.labelStrong : Theme.Typo.label)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !result.detail.isEmpty {
                    Text(result.detail.replacingOccurrences(of: "\n", with: " "))
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if result.isPinned {
                Image(systemName: "pin.fill")
                    .font(Theme.Glyph.chevron)
                    .foregroundStyle(Color.orange)
            }

            if hovering || isSelected {
                Image(systemName: "return")
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: result.detail.isEmpty ? 26 : 32)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(isSelected ? Theme.surfaceHover : hovering ? Theme.surface : .clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(result.title.replacingOccurrences(of: "\n", with: " "))
        .accessibilityValue(result.detail.replacingOccurrences(of: "\n", with: " "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(localized("Copies to the clipboard"))
        .accessibilityAction { run() }
        // Hover is only a visual affordance. If it changed selection, moving
        // from a result near the top of the list to its command bar would
        // select every intervening row and replace the commands before the
        // pointer could reach them.
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        // Keep the first click immediate and let the second one retain the
        // keyboard's default action. The gestures are simultaneous on
        // purpose: selecting twice is harmless, while making the single tap
        // wait for the double-click interval makes the command bar feel late.
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded { run() }
        )
        .animation(Theme.motion(Theme.contentAnimation), value: hovering)
        .animation(Theme.motion(Theme.contentAnimation), value: isSelected)
    }
}
