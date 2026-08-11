import SwiftUI

struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardStore

    var body: some View {
        VStack(spacing: 0) {
            if clipboard.items.isEmpty {
                VStack(spacing: Theme.Space.xs) {
                    Image(systemName: clipboard.isPaused ? "pause.circle" : "list.clipboard")
                        .font(Theme.Glyph.hero)
                    if clipboard.isPaused {
                        Text("Monitoring Paused")
                            .font(Theme.Typo.caption)
                    }
                }
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: Theme.Space.xs - 1) {
                        ForEach(clipboard.items) { item in
                            ClipRow(item: item, clipboard: clipboard)
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                }
            }
            footer
        }
        .padding(.top, Theme.Space.hair)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Button(clipboard.isPaused ? localized("Resume") : localized("Pause")) {
                clipboard.togglePause()
            }
                .buttonStyle(.plain)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(clipboard.isPaused ? Color.orange : Theme.secondary)
            Spacer(minLength: Theme.Space.xs)
            Button("Clear Unpinned") { clipboard.clearUnpinned() }
                .buttonStyle(.plain)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.secondary)
                .disabled(!clipboard.items.contains { !$0.isPinned })
        }
        .padding(.top, Theme.Space.hair)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @State private var hovering = false
    @State private var justCopied = false
    @FocusState private var isFocused: Bool

    /// Pin and delete used to appear on hover alone, which made them mouse-only
    /// controls: a keyboard user could not reach them and VoiceOver could not
    /// see them, because a view behind `if hovering` is not in the hierarchy at
    /// all. Focus reveals them too, and the row carries both as accessibility
    /// actions regardless, so the buttons are an affordance rather than the
    /// only route to the function.
    private var showsControls: Bool { hovering || isFocused }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            Text(item.preview)
                .font(Theme.Typo.label)
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xs)
            if item.isPinned || showsControls {
                Button { clipboard.togglePinned(item) } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(Theme.Typo.captionSemibold)
                        .foregroundStyle(item.isPinned ? Color.orange : Theme.secondary)
                        .frame(width: Theme.Size.touchTarget, height: Theme.Size.touchTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? localized("Unpin") : localized("Pin"))
                .accessibilityHidden(true)
            }
            if showsControls {
                Button { clipboard.remove(item) } label: {
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
        // One element to VoiceOver, not four: the row is the control, and the
        // buttons inside it are shortcuts to actions the row already offers.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.preview)
        .accessibilityValue(item.isPinned ? localized("Pinned") : "")
        .accessibilityHint(localized("Copies to the clipboard"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { copy() }
        .accessibilityAction(named: item.isPinned ? localized("Unpin") : localized("Pin")) {
            clipboard.togglePinned(item)
        }
        .accessibilityAction(named: localized("Delete")) {
            clipboard.remove(item)
        }
        .animation(Theme.motion(Theme.contentAnimation), value: showsControls)
        .animation(Theme.motion(Theme.contentAnimation), value: justCopied)
    }

    private func copy() {
        clipboard.copy(item)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { justCopied = false }
    }
}
