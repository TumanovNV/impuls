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

    private var selected: ImpulsActionResult? {
        results.first(where: { $0.id == selectedID }) ?? results.first
    }

    var body: some View {
        VStack(spacing: 6) {
            search
            resultList
            footer
        }
        .padding(.top, 2)
        .onAppear {
            selectedID = results.first?.id
            focused = wantsKeyboard
        }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
        .onChange(of: actions.query) { _, _ in
            selectedID = results.first?.id
            feedback = nil
        }
        .onChange(of: results.map(\.id)) { _, identifiers in
            guard !identifiers.isEmpty else {
                selectedID = nil
                return
            }
            if let selectedID, identifiers.contains(selectedID) { return }
            selectedID = identifiers.first
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField(localized("Search clipboard, snippets, and notes"), text: $actions.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
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
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help(localized("Clear Search"))
            }
            Text("↑↓ · ↩")
                .font(.system(size: 9, weight: .medium).monospaced())
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.surface)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    @ViewBuilder
    private var resultList: some View {
        if results.isEmpty {
            VStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .light))
                Text("No matching content")
                    .font(.system(size: 10))
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
    private var footer: some View {
        if let selected {
            HStack(spacing: 5) {
                if let feedback {
                    Label(feedback, systemImage: "checkmark")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.green)
                        .lineLimit(1)
                } else {
                    Label(selected.source.title, systemImage: selected.source.symbol)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                ViewThatFits(in: .horizontal) {
                    commandButtons(for: selected, compact: false)
                    commandButtons(for: selected, compact: true)
                }
            }
            .frame(height: 24)
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
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.surface)
                    )
                }
                .buttonStyle(.plain)
                .help(command.title)
            }
        }
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex(where: { $0.id == selectedID }) ?? 0
        let destination = (current + offset + results.count) % results.count
        selectedID = results[destination].id
    }

    private func runDefault() {
        guard let selected else { return }
        run(.copy, selected)
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
        HStack(spacing: 9) {
            Image(systemName: result.contentKind.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(result.title.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !result.detail.isEmpty {
                    Text(result.detail.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if result.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }

            if hovering || isSelected {
                Image(systemName: "return")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: result.detail.isEmpty ? 26 : 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.surfaceHover : hovering ? Theme.surface : .clear)
        )
        .contentShape(Rectangle())
        .onHover {
            hovering = $0
            if $0 { select() }
        }
        .onTapGesture(perform: run)
        .animation(Theme.contentAnimation, value: hovering)
        .animation(Theme.contentAnimation, value: isSelected)
    }
}
