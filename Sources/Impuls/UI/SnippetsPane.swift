import SwiftUI

struct SnippetsPane: View {
    @ObservedObject var snippets: SnippetStore
    /// Whether the panel holds the keyboard, so the fields can follow it.
    @Binding var wantsKeyboard: Bool

    /// Which field has the caret. One state for all three, because only one of
    /// them can be typed into at a time and the pane switches between them.
    private enum Field { case search, label, text }

    @FocusState private var focused: Field?
    @State private var isAdding = false
    @State private var draftLabel = ""
    @State private var draftText = ""

    var body: some View {
        let filtered = snippets.filtered
        VStack(spacing: Theme.Space.xs + 2) {
            if isAdding { editor } else { search }
            list(filtered)
        }
        .padding(.top, Theme.Space.hair)
        .onChange(of: wantsKeyboard) { _, wants in
            guard !wants else {
                focused = isAdding ? .text : .search
                return
            }
            focused = nil
        }
        .animation(Theme.motion(Theme.contentAnimation), value: isAdding)
    }

    // MARK: - Search

    private var search: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "magnifyingglass")
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.tertiary)
            TextField("", text: $snippets.query)
                .textFieldStyle(.plain)
                .font(Theme.Typo.label)
                .foregroundStyle(Theme.primary)
                .tint(Theme.secondary)
                .focused($focused, equals: .search)
                .onKeyPress(.escape) {
                    snippets.query = ""
                    return .handled
                }
            if !snippets.query.isEmpty {
                Button { snippets.query = "" } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Typo.captionSemibold)
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
            Button { beginAdding() } label: {
                Image(systemName: "plus")
                    .font(Theme.Typo.labelSemibold)
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Add a snippet"))
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Size.input)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = .search }
        // Same reason as the editor: the row asks for the caret once it is
        // actually on screen, so arriving on the tab and coming back from the
        // editor both land the same way.
        .onAppear { if wantsKeyboard { focused = .search } }
    }

    // MARK: - Adding

    /// Takes the place of the search row rather than sitting above it: the pane
    /// is two rows tall in a panel that never resizes, and one of the two is
    /// the list.
    private var editor: some View {
        HStack(spacing: Theme.Space.xs + 2) {
            // Each field on its own surface. A hairline between them read as a
            // caret sitting in the wrong place — exactly where one is expected,
            // which is the worst place for something that only looks like one.
            TextField(localized("Name"), text: $draftLabel)
                .textFieldStyle(.plain)
                .font(Theme.Typo.labelStrong)
                .foregroundStyle(Theme.primary)
                .tint(Theme.secondary)
                .padding(.horizontal, Theme.Space.s - 1)
                .frame(width: 104, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.surface)
                )
                .focused($focused, equals: .label)
                .onSubmit { commit() }

            TextField(localized("Text"), text: $draftText)
                .textFieldStyle(.plain)
                .font(Theme.Typo.label)
                .foregroundStyle(Theme.primary)
                .tint(Theme.secondary)
                .padding(.horizontal, Theme.Space.s - 1)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.surface)
                )
                .focused($focused, equals: .text)
                .onSubmit { commit() }

            Button { commit() } label: {
                Image(systemName: "checkmark")
                    .font(Theme.Typo.captionSemibold)
                    .foregroundStyle(draftText.isEmpty ? Theme.tertiary : Color.green)
            }
            .buttonStyle(.plain)
            .disabled(draftText.isEmpty)

            Button { cancelAdding() } label: {
                Image(systemName: "xmark")
                    .font(Theme.Typo.captionSemibold)
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
        // The same height as `search`, because it stands exactly where `search`
        // stood: the two swap places on `isAdding`, and a different number here
        // would shift the whole list down the moment + is pressed.
        .padding(.horizontal, Theme.Space.xs + 2)
        .frame(height: Theme.Size.input)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.surfaceHover)
        )
        // Asked for here rather than where the editor is switched on: at that
        // moment this field does not exist yet, and a focus request aimed at a
        // view that is not in the hierarchy is simply dropped. The row would
        // appear with no caret in it, and nothing to type into until clicked.
        //
        // The value is the part that cannot be left out, so the caret starts
        // there; the name is a step back for those who want one.
        .onAppear { focused = .text }
        // Escape leaves the draft rather than the tab. Caught on the row so it
        // works from either field.
        .onKeyPress(.escape) {
            cancelAdding()
            return .handled
        }
    }

    private func beginAdding() {
        draftLabel = ""
        draftText = ""
        // The search field goes away with the row, but the filter behind it
        // would not: a snippet added under a live filter lands in the list and
        // is hidden by it in the same breath, which looks like it was not added
        // at all.
        snippets.query = ""
        isAdding = true
        wantsKeyboard = true
    }

    private func cancelAdding() {
        isAdding = false
        draftLabel = ""
        draftText = ""
    }

    private func commit() {
        guard !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        snippets.add(label: draftLabel, text: draftText)
        // Straight into another one: adding snippets comes in runs, and the
        // list underneath already shows what has landed.
        draftLabel = ""
        draftText = ""
        focused = .text
    }

    // MARK: - List

    @ViewBuilder
    private func list(_ filtered: [Snippet]) -> some View {
        if filtered.isEmpty {
            VStack(spacing: Theme.Space.xs + 2) {
                Image(systemName: snippets.items.isEmpty ? "pin" : "magnifyingglass")
                    .font(Theme.Glyph.large)
                    .foregroundStyle(Theme.tertiary)
                if snippets.items.isEmpty, !isAdding {
                    Text("Nothing here yet — add with +")
                        .font(Theme.Typo.caption)
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(showsIndicators: false) {
                VStack(spacing: Theme.Space.xs - 1) {
                    ForEach(filtered) { item in
                        SnippetRow(item: item, snippets: snippets)
                    }
                }
                .padding(.bottom, Theme.Space.hair)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SnippetRow: View {
    let item: Snippet
    @ObservedObject var snippets: SnippetStore
    @State private var hovering = false
    @State private var justCopied = false
    @FocusState private var isFocused: Bool

    /// Revealed by focus as well as by hover. Behind `if hovering` alone the
    /// delete button was a mouse-only control and invisible to VoiceOver,
    /// because a view inside a false branch is not in the hierarchy at all.
    private var showsControls: Bool { hovering || isFocused }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            if !item.displayLabel.isEmpty {
                Text(item.displayLabel)
                    .font(Theme.Typo.labelStrong)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Text(item.preview)
                .font(Theme.Typo.label)
                .foregroundStyle(item.displayLabel.isEmpty ? Theme.primary : Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xs)
            // Only under the pointer or under focus: a permanent row of crosses
            // would compete with the snippets themselves for a glance.
            if showsControls {
                Button { snippets.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(Theme.Typo.captionSemibold)
                        .foregroundStyle(Theme.secondary)
                        .frame(width: Theme.Size.touchTarget, height: Theme.Size.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(localized("Delete"))
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.Size.row)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(showsControls ? Theme.surfaceHover : Theme.surface)
        )
        .notchFocusRing(isFocused)
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .onHover { hovering = $0 }
        .onTapGesture { copy() }
        .onKeyPress(.return) {
            copy()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayLabel.isEmpty ? item.preview : "\(item.displayLabel), \(item.preview)")
        .accessibilityHint(localized("Copies to the clipboard"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { copy() }
        .accessibilityAction(named: localized("Delete")) { snippets.remove(item) }
        .animation(Theme.motion(Theme.contentAnimation), value: showsControls)
        .animation(Theme.motion(Theme.contentAnimation), value: justCopied)
    }

    private func copy() {
        snippets.copy(item)
        justCopied = true
        // Emptying the search lets go of the panel: nothing is being typed
        // any more, so nothing needs to hold it open.
        snippets.query = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { justCopied = false }
    }
}
