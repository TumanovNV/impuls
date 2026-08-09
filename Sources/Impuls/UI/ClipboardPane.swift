import SwiftUI

struct ClipboardPane: View {
    @ObservedObject var clipboard: ClipboardStore

    var body: some View {
        VStack(spacing: 0) {
            if clipboard.items.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: clipboard.isPaused ? "pause.circle" : "list.clipboard")
                        .font(.system(size: 20, weight: .light))
                    if clipboard.isPaused {
                        Text("Monitoring Paused")
                            .font(.system(size: 10))
                    }
                }
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(clipboard.items) { item in
                            ClipRow(item: item, clipboard: clipboard)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            footer
        }
        .padding(.top, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(clipboard.isPaused ? localized("Resume") : localized("Pause")) {
                clipboard.togglePause()
            }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(clipboard.isPaused ? Color.orange : Theme.secondary)
            Spacer(minLength: 6)
            Button("Clear Unpinned") { clipboard.clearUnpinned() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .disabled(!clipboard.items.contains { !$0.isPinned })
        }
        .padding(.top, 2)
    }
}

private struct ClipRow: View {
    let item: ClipItem
    @ObservedObject var clipboard: ClipboardStore
    @State private var hovering = false
    @State private var justCopied = false


    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: justCopied ? "checkmark" : item.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(justCopied ? Color.green : Theme.tertiary)
                .frame(width: 14)
            Text(item.preview)
                .font(.system(size: 11))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if item.isPinned || hovering {
                Button { clipboard.togglePinned(item) } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(item.isPinned ? Color.orange : Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? localized("Unpin") : localized("Pin"))
            }
            if hovering {
                Button { clipboard.remove(item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Theme.surfaceHover : Theme.surface)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            clipboard.copy(item)
            justCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { justCopied = false }
        }
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: justCopied)
    }
}
