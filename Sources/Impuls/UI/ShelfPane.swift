import SwiftUI

struct ShelfPane: View {
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var tools: FileToolsCoordinator
    var isTargeted: Bool

    /// Which card the pointer is over — decided by the pane, not by the cards.
    ///
    /// Per-card `onHover` breaks on the shelf's most repetitive gesture:
    /// deleting cards one after another. Hover events are made of mouse
    /// movement, and when a deleted card's neighbour slides under a pointer
    /// that has not moved, there are no events — the neighbour never learns it
    /// is hovered, its ✕ never appears, and the click meant to delete it
    /// selects it instead, until a stray wiggle of the mouse fixes everything.
    /// So the pane tracks the pointer and every card's frame itself, and
    /// re-decides on either change: the pointer moving, or the cards moving
    /// under it. Scrolling the strip is the same case and heals the same way.
    @State private var hoveredID: UUID?
    @State private var hoverPoint: CGPoint?
    @State private var frames: [UUID: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            if shelf.items.isEmpty {
                dropHint
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(shelf.items) { item in
                            ShelfCard(
                                item: item,
                                shelf: shelf,
                                tools: tools,
                                isHovered: hoveredID == item.id
                            )
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: CardFramesKey.self,
                                            value: [item.id: geo.frame(in: .named("shelf"))]
                                        )
                                    }
                                )
                        }
                    }
                    .padding(.horizontal, 2)
                    .frame(maxHeight: .infinity)
                }
                .coordinateSpace(name: "shelf")
                .onContinuousHover(coordinateSpace: .named("shelf")) { phase in
                    switch phase {
                    case .active(let point):
                        hoverPoint = point
                        rehit()
                    case .ended:
                        hoverPoint = nil
                        hoveredID = nil
                    }
                }
                .onPreferenceChange(CardFramesKey.self) { new in
                    frames = new
                    rehit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        .padding(.top, Theme.Space.hair)
    }

    /// The one decision both signals feed: which frame holds the last known
    /// pointer position.
    private func rehit() {
        guard let hoverPoint else { return }
        hoveredID = frames.first(where: { $0.value.contains(hoverPoint) })?.key
    }

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .strokeBorder(
                isTargeted ? Theme.primary.opacity(0.6) : Theme.hairline,
                style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
            )
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(isTargeted ? Theme.surface : .clear)
            )
            .overlay(
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(Theme.Glyph.hero)
                    .foregroundStyle(isTargeted ? Theme.primary : Theme.tertiary)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel(localized("Drop files here to put them on the shelf"))
            .animation(Theme.motion(Theme.contentAnimation), value: isTargeted)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if tools.isWorking {
                ProgressView()
                    .controlSize(.mini)
                Text(tools.statusMessage ?? localized("Working…"))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            } else if let message = tools.statusMessage {
                Image(systemName: tools.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(tools.statusIsError ? Color.orange : Color.green)
                Text(message)
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            if !shelf.selection.isEmpty {
                Text(localized("Selected: %d", shelf.selection.count))
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer()
            if !shelf.selection.isEmpty {
                ShelfToolsMenu(
                    urls: shelf.selectedURLs,
                    renameItem: shelf.selection.count == 1
                        ? shelf.items.first(where: { shelf.selection.contains($0.id) })
                        : nil,
                    tools: tools
                )
                Button("Deselect") { shelf.clearSelection() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(Theme.secondary)
            } else if shelf.items.count > 1 {
                Button("Select All") { shelf.selectAll() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(Theme.secondary)
            }
            if tools.canUndo {
                Button("Undo") { tools.undoLastOperation() }
                    .buttonStyle(.plain)
                    .font(Theme.Typo.captionStrong)
                    .foregroundStyle(Theme.secondary)
                    .disabled(tools.isWorking)
            }
            Button("Clear") { shelf.clear() }
                .buttonStyle(.plain)
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.secondary)
        }
        .padding(.top, 2)
    }
}

private struct CardFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct ShelfCard: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var tools: FileToolsCoordinator
    /// Handed down from the pane, which is the one place that can know it
    /// correctly when cards move under a stationary pointer.
    let isHovered: Bool

    private var isSelected: Bool { shelf.isSelected(item) }

    var body: some View {
        VStack(spacing: Theme.Space.xs + 2) {
            // Fit, not fill: a screenshot is landscape and a file icon is
            // square, and forcing either into the other's box is what squashed
            // the wide ones. The box is wide enough for a 16:10 frame, so a
            // square icon simply centres in it.
            Image(nsImage: item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 68, height: 40)
            Text(item.name)
                .font(Theme.Typo.caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 24, alignment: .top)
        }
        .padding(.horizontal, Theme.Space.xs + 2)
        .padding(.vertical, Theme.Space.s)
        .frame(width: 86, height: 92)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(isSelected ? Theme.selection : (isHovered ? Theme.surfaceHover : Theme.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(isSelected ? Theme.selectionStroke : Color.clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        // Owns clicks and drags: a group drag needs one dragging item per file,
        // which SwiftUI's onDrag cannot express. It must stay *below* the close
        // button, otherwise it swallows every click aimed at it.
        .overlay(
            ShelfDragSource(
                urls: { shelf.dragURLs(startingAt: item) },
                onClick: { modifiers in shelf.select(item, modifiers: modifiers) },
                onDoubleClick: { shelf.open(item) }
            )
        )
        .overlay(alignment: .topLeading) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(Theme.Typo.body)
                    .foregroundStyle(Theme.primary)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button { shelf.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.Typo.body)
                        .foregroundStyle(Theme.primary.opacity(0.75))
                }
                .buttonStyle(.plain)
                .padding(Theme.Space.xs)
                .help(localized("Remove from Shelf"))
                // The card carries this as an accessibility action already;
                // exposing the glyph too would announce it twice.
                .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(localized("Opens the file"))
        .accessibilityAction { shelf.open(item) }
        .accessibilityAction(named: isSelected ? localized("Deselect") : localized("Select")) {
            shelf.select(item, modifiers: [])
        }
        .accessibilityAction(named: localized("Show in Finder")) { shelf.reveal(item) }
        .accessibilityAction(named: localized("Remove from Shelf")) { shelf.remove(item) }
        .contextMenu {
            let operationURLs = shelf.operationURLs(startingAt: item)
            Button("Copy") { shelf.copy(item) }
            Button("Open") { shelf.open(item) }
            Button("Quick Look") { tools.quickLook(operationURLs) }
            Button("Show in Finder") { shelf.reveal(item) }
            ShelfToolsMenu(
                urls: operationURLs,
                renameItem: operationURLs.count == 1 ? item : nil,
                tools: tools
            )
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .animation(Theme.motion(Theme.contentAnimation), value: isHovered)
        .animation(Theme.motion(Theme.contentAnimation), value: isSelected)
    }
}

private struct ShelfToolsMenu: View {
    let urls: [URL]
    let renameItem: ShelfItem?
    @ObservedObject var tools: FileToolsCoordinator

    private var images: [URL] { FileToolsService.imageURLs(urls) }
    private var singleImage: URL? { images.count == 1 ? images.first : nil }

    var body: some View {
        Menu {
            Button("Copy Path") { tools.copyPath(urls) }
            Button("Quick Look") { tools.quickLook(urls) }
            Button("AirDrop") { tools.airDrop(urls) }
            Button("Share…") { tools.share(urls) }
            Divider()

            if !images.isEmpty {
                Button(localized(images.count == 1 ? "Recognize Text" : "Recognize Text in Images")) {
                    tools.recognizeText(in: images)
                }
                Menu("Convert Image") {
                    ForEach(ImageOutputFormat.allCases) { format in
                        Button(format.title) { tools.convert(images, to: format) }
                    }
                }
                Menu("Reduce Image") {
                    ForEach(ImageResizePreset.allCases) { preset in
                        Button(preset.title) { tools.resize(images, preset: preset) }
                    }
                }
                Button(localized(images.count == 1 ? "Remove Background" : "Remove Backgrounds")) {
                    tools.removeBackground(from: images)
                }
            }

            if images.count >= 2 {
                Button("Combine Images into PDF") { tools.combineIntoPDF(images) }
            }

            if let renameItem {
                if singleImage != nil || images.count >= 2 { Divider() }
                Button("Rename…") { tools.requestRename(renameItem) }
            }
        } label: {
            Label("Tools", systemImage: "wand.and.stars")
                .font(Theme.Typo.captionStrong)
                .foregroundStyle(Theme.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(tools.isWorking || urls.isEmpty)
    }
}
