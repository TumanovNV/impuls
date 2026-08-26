import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// Rebuilt per render on purpose: it holds no state of its own, only the
    /// two system seams and closures onto the store.
    private var fileActions: SnippetFileActions {
        SnippetFileActions(
            pasteboard: SystemFilePasteboard(),
            workspace: SystemWorkspace(),
            resolve: { [snippets] snippet in snippets.resolveFile(snippet) },
            onRefreshedReference: { [snippets] snippet, url, bookmark in
                snippets.updateFileReference(for: snippet, resolvedURL: url, bookmark: bookmark)
            }
        )
    }

    /// One drop is one gesture, not an import. The cap keeps a stray drag of a
    /// whole folder's worth of files from turning into hundreds of rows.
    private static let maximumFilesPerDrop = 20

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
            // A second small button rather than a menu on `+`: turning the
            // existing button into a menu would put an extra click in front of
            // the flow people already use, to make room for the rarer one.
            Button { chooseFile() } label: {
                Image(systemName: "doc.badge.plus")
                    .font(Theme.Typo.labelSemibold)
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Pin a file"))
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

    // MARK: - Files

    /// The standard picker. It selects a file; it does not open one, and it
    /// asks for no permission Impuls does not already have.
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = localized("Pin")
        panel.message = localized("Choose a file to pin.")
        // Cancel leaves everything exactly as it was.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = snippets.addFile(url)
    }

    /// Accepts local files only. A remote URL, a plain string or a provider
    /// that fails to load is ignored rather than becoming an empty row: nothing
    /// is written unless a real file resolved.
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            .prefix(Self.maximumFilesPerDrop)
        guard !candidates.isEmpty else { return false }
        for provider in candidates {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    // `addFile` re-checks that this is a readable regular file,
                    // so a dropped folder or dead alias adds nothing.
                    _ = snippets.addFile(url)
                }
            }
        }
        return true
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
                        SnippetRow(item: item, snippets: snippets, fileActions: fileActions)
                    }
                }
                .padding(.bottom, Theme.Space.hair)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: nil, perform: receiveDrop)
        }
    }
}

/// Gives a file row AppKit's click count without changing how a text row
/// behaves. SwiftUI's tap gesture reports that a tap happened, not whether it
/// was the first or the second of a double, and the difference is the whole
/// feature here.
private struct SnippetRowClickModifier: ViewModifier {
    let isFile: Bool
    let onTap: () -> Void
    let onClick: (Int) -> Void

    func body(content: Content) -> some View {
        if isFile {
            content.overlay(ClickCountCatcher(onClick: onClick))
        } else {
            content.onTapGesture(perform: onTap)
        }
    }
}

/// A transparent view that reports `NSEvent.clickCount` on mouse up.
///
/// Right-click is deliberately not handled, so it falls through to the
/// SwiftUI `.contextMenu` on the row underneath.
private struct ClickCountCatcher: NSViewRepresentable {
    let onClick: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onClick = onClick
    }

    final class CatcherView: NSView {
        var onClick: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            // Accepted so the matching mouseUp is delivered here.
        }

        override func mouseUp(with event: NSEvent) {
            onClick?(event.clickCount)
        }

        override func rightMouseDown(with event: NSEvent) {
            super.rightMouseDown(with: event)
        }
    }
}

private struct SnippetRow: View {
    let item: Snippet
    @ObservedObject var snippets: SnippetStore
    let fileActions: SnippetFileActions
    @State private var hovering = false
    @State private var justCopied = false
    /// One arbiter per row, so two rows clicked in quick succession do not
    /// cancel each other's pending single click.
    @State private var arbiter = ClickArbiter()
    /// Resolved lazily — on appear and after an action that found the file
    /// gone. Nothing polls it.
    @State private var isMissing = false
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
            // A file shows its name, not the whole path: the path is what is
            // stored and searched, but a row is read at a glance.
            Text(item.isFile ? item.fileName : item.preview)
                .font(Theme.Typo.label)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
            if isMissing {
                Text(localized("File Unavailable"))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
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
        // A text snippet keeps the plain single tap it has always had. A file
        // needs the click *count*, which SwiftUI's tap gesture does not report,
        // so those rows go through a small AppKit bridge instead.
        .modifier(SnippetRowClickModifier(isFile: item.isFile, onTap: copy, onClick: handleClick))
        .onKeyPress(.return) {
            copy()
            return .handled
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.displayLabel.isEmpty ? item.preview : "\(item.displayLabel), \(item.preview)")
        .accessibilityHint(localized("Copies to the clipboard"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { copy() }
        .accessibilityAction(named: localized("Delete")) { snippets.remove(item) }
        // Double-click is a pointer gesture. Everything it does is reachable
        // without one.
        .accessibilityActions {
            if item.isFile {
                Button(localized("Open")) { runFile(fileActions.open) }
                Button(localized("Show in Finder")) { runFile(fileActions.reveal) }
                Button(localized("Choose File Again")) { chooseAgain() }
            }
        }
        .help(item.isFile ? localized("Click to copy the file, double-click to open it.") : "")
        // Lazy availability: once per appearance, never on a timer.
        .task(id: item.id) {
            guard item.isFile else { return }
            isMissing = !fileActions.isAvailable(item)
        }
        .animation(Theme.motion(Theme.contentAnimation), value: showsControls)
        .animation(Theme.motion(Theme.contentAnimation), value: justCopied)
    }

    private var valueColor: Color {
        if isMissing { return Theme.tertiary }
        return item.displayLabel.isEmpty ? Theme.primary : Theme.secondary
    }

    @ViewBuilder
    private var contextMenu: some View {
        if item.isFile {
            Button(localized("Copy")) { runFile(fileActions.copy) }
            Button(localized("Open")) { runFile(fileActions.open) }
            Button(localized("Show in Finder")) { runFile(fileActions.reveal) }
            Divider()
            Button(localized("Choose File Again")) { chooseAgain() }
            Button(localized("Delete")) { snippets.remove(item) }
        } else {
            Button(localized("Copy")) { copy() }
            Button(localized("Delete")) { snippets.remove(item) }
        }
    }

    /// The whole single-versus-double decision for a file row.
    private func handleClick(count: Int) {
        arbiter.click(
            count: count,
            single: { runFile(fileActions.copy, markCopied: true) },
            double: { runFile(fileActions.open) }
        )
    }

    /// Every file action goes through here so "the file is gone" is handled in
    /// one place: the action reports that it did nothing, and the row says so
    /// instead of pretending it worked.
    private func runFile(_ action: (Snippet) -> Bool, markCopied: Bool = false) {
        let acted = action(item)
        isMissing = !acted
        guard acted else { return }
        if markCopied {
            justCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { justCopied = false }
        }
    }

    private func chooseAgain() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = localized("Pin")
        panel.message = localized("Choose a file to pin.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if snippets.replaceFile(item, with: url) { isMissing = false }
    }

    private func copy() {
        // A file row never reaches here through the pointer, but Return and the
        // accessibility action both land on it.
        if item.isFile {
            runFile(fileActions.copy, markCopied: true)
            snippets.query = ""
            return
        }
        snippets.copy(item)
        justCopied = true
        // Emptying the search lets go of the panel: nothing is being typed
        // any more, so nothing needs to hold it open.
        snippets.query = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { justCopied = false }
    }
}
