import SwiftUI

/// Scratch notes: the list on the left, the note itself on the right.
struct NotesPane: View {
    @ObservedObject var notes: NoteStore
    /// Whether the panel holds the keyboard, so the editor can follow it.
    @Binding var wantsKeyboard: Bool

    @FocusState private var focused: Bool

    /// A share of the pane rather than a flat 170 pt, which was 30% of the
    /// compact panel and 24% of the large one — the same layout reading as two
    /// designs depending on a setting meant only to change the outer size.
    ///
    /// Read straight off the geometry the pane is being laid out in, not
    /// measured into `@State` from a background reader. That measure-then-store
    /// round trip costs a frame: the first pass has nothing stored yet, so it
    /// draws at a fallback and snaps to the real width once the state lands —
    /// visibly, on every arrival at this tab. The clamp is what handles a
    /// degenerate proposal, so there is no fallback constant to get wrong.
    private func listWidth(in paneWidth: CGFloat) -> CGFloat {
        min(210, max(150, paneWidth * 0.32))
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: Theme.Space.s) {
                list
                    .frame(width: listWidth(in: geo.size.width))
                editor
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .padding(.top, Theme.Space.hair)
        // Arriving means arriving to type. With nothing to select, an empty
        // note is created on the spot: a welcome screen with a button would be
        // slower than the editor window this tab exists to replace.
        .onAppear {
            if notes.notes.isEmpty {
                notes.add()
            } else if notes.selected == nil {
                notes.selected = notes.notes.first?.id
            }
        }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: Theme.Space.xs - 1) {
            Button {
                notes.add()
                focused = true
            } label: {
                HStack(spacing: Theme.Space.xs + 2) {
                    Image(systemName: "plus")
                        .font(Theme.Typo.captionSemibold)
                    Text("New Note")
                        .font(Theme.Typo.labelStrong)
                }
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Theme.Size.input)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.surface)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            }
            .buttonStyle(.plain)

            ScrollView(showsIndicators: false) {
                VStack(spacing: Theme.Space.xs - 1) {
                    ForEach(notes.notes) { note in
                        NoteRow(
                            note: note,
                            isSelected: notes.selected == note.id,
                            select: {
                                notes.selected = note.id
                                focused = true
                            },
                            delete: {
                                notes.remove(note.id)
                                // The tab's invariant: there is always a note
                                // under the caret.
                                if notes.notes.isEmpty { notes.add() }
                            }
                        )
                    }
                }
                .padding(.bottom, Theme.Space.hair)
            }
        }
    }

    // MARK: - Editor

    private var currentText: String {
        guard let id = notes.selected else { return "" }
        return notes.notes.first(where: { $0.id == id })?.text ?? ""
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { currentText },
            set: { text in
                guard let id = notes.selected else { return }
                notes.update(id, text: text)
            }
        )
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: editorBinding)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .font(Theme.Typo.body)
                .foregroundStyle(Theme.primary)
                .tint(Theme.secondary)
                .focused($focused)
                .accessibilityLabel(localized("Note text"))
                // The editor insets its text by a few points of its own; pull
                // that back so the first character lines up with the padding.
                .padding(.leading, -5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // One editor for all notes, deliberately NOT remounted per
                // note. A remount (`.id(selected)`) tears the focused view
                // down, and SwiftUI's cleanup for "the focused view
                // disappeared" clears the FocusState at a moment of its own
                // choosing — racing, and regularly beating, every way of
                // re-requesting focus: a plain set, a deferred set, even
                // `defaultFocus`. All three were tried; the new note kept
                // arriving without a caret. With one long-lived editor the
                // text swaps inside a view that never dies, so there is no
                // cleanup and nothing to race. AppKit clamps the caret to the
                // new text's length — for a fresh note that is position zero,
                // exactly where it belongs.
                //
                // A shared undo stack looked like the price of this, but
                // measurement says otherwise: ⌘Z undoes typing fine within a
                // note, and after switching notes the old actions are simply
                // inert — deleted text does not resurface in the neighbour,
                // in either note, on any press. The programmatic text swap
                // leaves the stale actions unable to apply. Verified by
                // driving the real app: type, delete, switch, ⌘Z twice,
                // read the store after each step.
                //
                // Asked in onAppear because on arrival at the tab the request
                // must come from a view that exists (see SnippetsPane).
                .onAppear {
                    DispatchQueue.main.async { focused = wantsKeyboard }
                }
                .onKeyPress(.escape) {
                    // Esc hands the keyboard back, and only that. It never
                    // clears: this pane holds the one kind of text that cannot
                    // be re-derived from anywhere.
                    wantsKeyboard = false
                    return .handled
                }

            if currentText.isEmpty {
                Text("Jot something down…")
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.tertiary)
                    .allowsHitTesting(false)
                    // The editor above already carries the label; a placeholder
                    // read out as a second element would double every note.
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !currentText.isEmpty {
                CopyNoteButton(text: currentText)
            }
        }
        .padding(Theme.Space.s)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.surface)
        )
    }
}

private struct NoteRow: View {
    let note: Note
    let isSelected: Bool
    let select: () -> Void
    let delete: () -> Void

    @State private var hovering = false
    @FocusState private var isFocused: Bool

    /// Focus reveals the delete button as well as hover: behind `if hovering`
    /// alone it was unreachable without a mouse and invisible to VoiceOver.
    private var showsControls: Bool { hovering || isFocused }

    var body: some View {
        HStack(spacing: Theme.Space.xs + 2) {
            Text(preview)
                .font(isSelected ? Theme.Typo.labelStrong : Theme.Typo.label)
                .foregroundStyle(isSelected ? Theme.primary : Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.xs)
            if showsControls {
                Button(action: delete) {
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
                .fill(isSelected ? Theme.surfaceHover : showsControls ? Theme.surface : .clear)
        )
        .notchFocusRing(isFocused)
        .contentShape(Rectangle())
        .focusable()
        .focused($isFocused)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .onKeyPress(.return) {
            select()
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(preview)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select() }
        .accessibilityAction(named: localized("Delete")) { delete() }
        .animation(Theme.motion(Theme.contentAnimation), value: showsControls)
    }

    /// The first line stands in for a title — notes here are too short-lived
    /// to deserve naming as a separate step.
    private var preview: String {
        note.preview.isEmpty ? localized("Empty note") : note.preview
    }
}

private struct CopyNoteButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
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
        .animation(Theme.motion(Theme.contentAnimation), value: copied)
    }
}
