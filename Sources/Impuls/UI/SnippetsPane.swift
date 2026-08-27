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
    private let resolver: SnippetFileResolving = LiveSnippetFileResolver()

    /// One drop is one gesture, not an import. The cap keeps a stray drag of a
    /// whole folder's worth of files from turning into hundreds of rows.
    private static let maximumFilesPerDrop = 20

    var body: some View {
        let filtered = snippets.filtered
        return paneBody(filtered)
            // On the pane rather than on the populated list: attached to the
            // list it did not exist in the empty state — the one moment a new
            // user is most likely to try dropping a file.
            .onDrop(of: [.fileURL], isTargeted: nil, perform: receiveDrop)
    }

    @ViewBuilder
    private func paneBody(_ filtered: [Snippet]) -> some View {
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
        // Packages (.app, .rtfd, Pages documents) are directories. Letting the
        // panel treat them as folders means the user navigates into one rather
        // than selecting something that would then be silently refused.
        panel.treatsFilePackagesAsDirectories = true
        // The panel is non-activating, so a modal raised from it appears behind
        // the frontmost app without focus unless Impuls activates first.
        NSApp.activate(ignoringOtherApps: true)
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
                // Lazy on purpose since IMP-39: a non-lazy stack materialises
                // every row, so every pin would probe the filesystem the moment
                // the tab opened rather than only the ones on screen.
                LazyVStack(spacing: Theme.Space.xs - 1) {
                    ForEach(filtered) { item in
                        SnippetRow(item: item, snippets: snippets, resolver: resolver)
                    }
                }
                .padding(.bottom, Theme.Space.hair)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Gives a file row AppKit's click count without changing how a text row
/// behaves. SwiftUI's tap gesture reports that a tap happened, not whether it
/// was the first or the second of a double, and the difference is the whole
/// feature here.
private struct SnippetRowClickModifier: ViewModifier {
    let isFile: Bool
    let onClick: (Int) -> Void

    func body(content: Content) -> some View {
        if isFile {
            content.overlay(ClickCountCatcher(onClick: onClick))
        } else {
            // Nothing at all for a text row: its tap lives on the whole row,
            // exactly where it always did. Adding a second gesture here would
            // make which one fires a question rather than a fact.
            content
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
        private var isDragging = false

        /// The panel is non-activating and the app never becomes active, so
        /// without this the first click on a row would be spent activating
        /// Impuls instead of reaching the pin. `NotchRootView` and
        /// `ShelfDragSource` override it for the same reason.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            isDragging = true
        }

        override func mouseUp(with event: NSEvent) {
            // A press, drag and release is not a click, and must not copy.
            defer { isDragging = false }
            guard !isDragging else { return }
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
    let resolver: SnippetFileResolving
    @State private var hovering = false
    @State private var justCopied = false
    @State private var copyGeneration = 0
    /// Resolved lazily — on appear and after an action that found the file
    /// gone. Nothing polls it.
    @State private var isMissing = false
    /// Owns this row's resolved-URL cache and its click contract. Held as
    /// `@State` so it survives a redraw; it publishes nothing, because the two
    /// things the view draws from — `isMissing` and `justCopied` — are the
    /// view's own state.
    @State private var interaction: SnippetFilePinInteraction?
    @FocusState private var isFocused: Bool

    /// Revealed by focus as well as by hover. Behind `if hovering` alone the
    /// delete button was a mouse-only control and invisible to VoiceOver,
    /// because a view inside a false branch is not in the hierarchy at all.
    private var showsControls: Bool { hovering || isFocused }

    private var rowContent: some View {
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
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            // The click catcher covers this group only. Overlaying the whole
            // row put an opaque AppKit view on top of the delete button, so
            // clicking the cross on a file row copied the file instead.
            rowContent
                .contentShape(Rectangle())
                .modifier(SnippetRowClickModifier(isFile: item.isFile, onClick: handleClick))
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
        // A text snippet keeps the plain whole-row tap it has always had,
        // padding included. A file row must not have one: SwiftUI's tap gesture
        // does not report the click count, so a tap here could not tell a copy
        // from an open. Its clicks come from the AppKit bridge over the content
        // area instead, which does.
        .onTapGesture { if !item.isFile { copy() } }
        .onKeyPress(.return) {
            copy()
            return .handled
        }
        .contextMenu { contextMenu }
        .accessibilityElement(children: .ignore)
        // A file row is announced by the name it shows, not by the whole stored
        // path — `preview` is up to 240 characters of it.
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint(item.isFile
            ? localized("Copies the file to the clipboard")
            : localized("Copies to the clipboard"))
        // The label is the filename, so two pins called `report.pdf` in
        // different folders would be indistinguishable without this.
        .accessibilityValue(item.isFile ? item.text : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { copy() }
        .accessibilityAction(named: localized("Delete")) { snippets.remove(item) }
        // Double-click is a pointer gesture. Everything it does is reachable
        // without one.
        .accessibilityActions {
            if item.isFile {
                Button(localized("Open")) { act(.open) }
                Button(localized("Show in Finder")) { act(.reveal) }
                Button(localized("Choose File Again")) { chooseAgain() }
            }
        }
        .help(item.isFile ? localized("Click to copy the file, double-click to open it.") : "")
        // Availability, resolved once per reference and never on a timer.
        //
        // This is also what fills the cache the click path reads, so by the
        // time a visible row is clicked its URL is usually already known and
        // the click costs a pasteboard write. Off the main actor because the
        // path fallback ends in `fileExists`/`resourceValues`, which block for
        // the mount timeout on an unresponsive share; the key check keeps a
        // `LazyVStack` re-materialising rows from re-probing on every scroll.
        // Keyed by the reference, not by `item.id`: `Snippet.id` hashes the
        // label alone when a pin has one, so re-selecting a labeled pin leaves
        // the id unchanged — the probe would never re-run and the row's cache
        // would stay pointed at the file the user just replaced.
        .task(id: item.text) {
            guard item.isFile else { return }
            let interaction = makeInteractionIfNeeded()
            guard !interaction.hasResolved(reference: item.text) else { return }
            let url = await interaction.resolveAndPerform(nil, for: item, urgency: .probe)
            guard !Task.isCancelled else { return }
            isMissing = url == nil
        }
        .animation(Theme.motion(Theme.contentAnimation), value: showsControls)
        .animation(Theme.motion(Theme.contentAnimation), value: justCopied)
    }

    private var accessibilityDescription: String {
        let value = item.isFile ? item.fileName : item.preview
        return item.displayLabel.isEmpty ? value : "\(item.displayLabel), \(value)"
    }

    private var valueColor: Color {
        if isMissing { return Theme.tertiary }
        return item.displayLabel.isEmpty ? Theme.primary : Theme.secondary
    }

    @ViewBuilder
    private var contextMenu: some View {
        if item.isFile {
            // A pin whose file is gone offers only the two commands that can
            // still do something. The actions fail closed anyway, but showing
            // three that cannot work is not an honest menu.
            if !isMissing {
                Button(localized("Copy")) { act(.copy) }
                Button(localized("Open")) { act(.open) }
                Button(localized("Show in Finder")) { act(.reveal) }
                Divider()
            }
            Button(localized("Choose File Again")) { chooseAgain() }
            Button(localized("Delete")) { snippets.remove(item) }
        } else {
            Button(localized("Copy")) { copy() }
            Button(localized("Delete")) { snippets.remove(item) }
        }
    }

    /// A click acts on the click it is, immediately.
    ///
    /// The first click cannot know whether a second is coming, and the previous
    /// design answered that by waiting out `NSEvent.doubleClickInterval` — 500 ms
    /// on this machine — before copying. That is the wrong trade for this
    /// feature: it made every single click feel frozen to buy a double click
    /// that never copies. The accepted contract is now that a double click
    /// copies once and then opens once.
    ///
    /// A third click and beyond do nothing, so leaning on the mouse cannot
    /// produce a storm of opens.
    private func handleClick(count: Int) {
        guard let effect = SnippetFilePinInteraction.effect(forClickCount: count) else { return }
        act(effect)
    }

    /// The one path every file action takes — pointer, context menu, Return and
    /// VoiceOver alike, so none of them can drift onto a slower route.
    ///
    /// The fast path is the whole point: a row the probe has already resolved
    /// performs its effect synchronously, with no filesystem call between the
    /// click and the pasteboard. Only a cache miss suspends, and it suspends
    /// off the main actor rather than blocking it.
    private func act(_ effect: SnippetFileActions.Effect) {
        guard item.isFile else { return }
        let interaction = makeInteractionIfNeeded()
        // Fast path: already resolved, so this is a pasteboard write and
        // nothing else — no I/O, no suspension, same turn as the click.
        if interaction.performIfResolved(effect, for: item) {
            didAct(effect)
            return
        }
        // A miss. Resolution goes off the main actor on the user-action queue,
        // so it is never behind the speculative probes of other rows, and it
        // joins this row's own probe if one is already running.
        Task {
            let url = await interaction.resolveAndPerform(effect, for: item, urgency: .userAction)
            isMissing = url == nil
            if url != nil { didAct(effect) }
        }
    }

    private func makeInteractionIfNeeded() -> SnippetFilePinInteraction {
        if let interaction { return interaction }
        // Built once per row, lazily, rather than allocated on every body
        // evaluation — a fresh actions object per render made no row
        // structurally equal to its previous self.
        let made = SnippetFilePinInteraction(
            actions: SnippetFileActions(
                pasteboard: SystemFilePasteboard(),
                workspace: SystemWorkspace()
            ),
            resolver: resolver,
            onRefreshedReference: { [snippets, item] url, bookmark in
                snippets.updateFileReference(for: item, resolvedURL: url, bookmark: bookmark)
            }
        )
        interaction = made
        return made
    }

    /// Feedback is shown the moment the write has happened. The timer only
    /// clears it again — it never gates the copy itself.
    private func didAct(_ effect: SnippetFileActions.Effect) {
        guard effect == .copy else { return }
        justCopied = true
        // Generation-guarded, so a second copy inside the window is not cleared
        // early by the first copy's timer — the same rule the registry already
        // records for every other pane's "Copied" toast.
        copyGeneration += 1
        let generation = copyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard copyGeneration == generation else { return }
            justCopied = false
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
        panel.treatsFilePackagesAsDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if snippets.replaceFile(item, with: url) { isMissing = false }
    }

    private func copy() {
        // A file row never reaches here through the pointer, but Return and the
        // accessibility action both land on it.
        if item.isFile {
            act(.copy)
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
