import SwiftUI

/// One choice in a `SearchPicker`.
public struct SearchPickerItem<ID: Hashable>: Identifiable {
    public let id: ID
    public let title: String
    /// A muted second line, like "Has a worktree".
    public let note: String?
    /// Why this choice can't be picked. When it is set the row is greyed out and the reason replaces the note.
    public let disabledReason: String?
    /// Pinned choices are listed first.
    public let isPinned: Bool

    public init(id: ID, title: String, note: String? = nil, disabledReason: String? = nil, isPinned: Bool = false) {
        self.id = id
        self.title = title
        self.note = note
        self.disabledReason = disabledReason
        self.isPinned = isPinned
    }

    var isPickable: Bool { disabledReason == nil }
}

extension SearchPickerItem: Sendable where ID: Sendable {}

/// Decides which choices a `SearchPicker` shows for what has been typed.
public enum SearchPickerFilter {
    /// Choices whose title contains the query, ignoring case; all of them when the query is empty or only spaces.
    /// Pinned choices come first and the rest follow, each group in the order it was given.
    public static func visible<ID: Hashable>(_ items: [SearchPickerItem<ID>], query: String) -> [SearchPickerItem<ID>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = needle.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        return matches.filter(\.isPinned) + matches.filter { !$0.isPinned }
    }
}

/// A field that opens a searchable list of choices: pick a branch out of dozens. Closed, it looks like a text
/// field showing the current choice. Open, it shows a search box over the list; arrow keys move, Return picks,
/// Escape closes.
public struct SearchPicker<ID: Hashable>: View {
    let items: [SearchPickerItem<ID>]
    let selection: ID?
    let placeholder: String
    let prompt: String
    let onPick: (ID) -> Void

    public init(_ items: [SearchPickerItem<ID>], selection: ID?, placeholder: String, prompt: String = "Search",
                onPick: @escaping (ID) -> Void) {
        self.items = items
        self.selection = selection
        self.placeholder = placeholder
        self.prompt = prompt
        self.onPick = onPick
    }

    @Environment(\.density) private var density
    @State private var isOpen = false

    private var selectedTitle: String? { items.first { $0.id == selection }?.title }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
        Button { isOpen.toggle() } label: {
            HStack(spacing: DS.Space.s) {
                Text(selectedTitle ?? placeholder)
                    .textRole(.body)
                    .foregroundStyle((selectedTitle == nil ? Palette.textFaint : Palette.text).color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: density == .desk ? 10 : 12, weight: .medium))
                    .foregroundStyle(Palette.textFaint.color)
            }
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: density == .desk ? DS.Size.control : DS.Size.touchTarget)
            .background(Palette.raised.color, in: shape)
            .overlay(shape.strokeBorder(Palette.hairlineStrong.color, lineWidth: DS.Stroke.hairline))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedTitle ?? placeholder)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            SearchPickerList(items: items, selection: selection, prompt: prompt) { id in
                onPick(id)
                isOpen = false
            } onClose: {
                isOpen = false
            }
            .presentationBackground(Palette.overlay.color)
        }
    }
}

private enum PickerMetric {
    static let width: CGFloat = 300
    static let listMaxHeight: CGFloat = 320
}

/// What the picker shows once it is open.
private struct SearchPickerList<ID: Hashable>: View {
    let items: [SearchPickerItem<ID>]
    let selection: ID?
    let prompt: String
    let onPick: (ID) -> Void
    let onClose: () -> Void

    @Environment(\.density) private var density
    @State private var query = ""
    @State private var highlighted: ID?
    @FocusState private var isSearching: Bool

    private var rows: [SearchPickerItem<ID>] { SearchPickerFilter.visible(items, query: query) }
    private var pickable: [SearchPickerItem<ID>] { rows.filter(\.isPickable) }

    var body: some View {
        VStack(spacing: 0) {
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .textRole(.body)
                .foregroundStyle(Palette.text.color)
                .focused($isSearching)
                .padding(.horizontal, DS.Space.m)
                .frame(minHeight: density == .desk ? DS.Size.listRow : DS.Size.touchTarget)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.return) { pickHighlighted(); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onSubmit(pickHighlighted)
            DSDivider()
            if rows.isEmpty {
                Text("Nothing matches")
                    .textRole(.body)
                    .foregroundStyle(Palette.textMuted.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.m)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { item in
                                row(item)
                            }
                        }
                        .padding(DS.Space.xs)
                    }
                    .frame(maxHeight: PickerMetric.listMaxHeight)
                    .onChange(of: highlighted) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(width: PickerMetric.width)
        .background(Palette.overlay.color)
        .onAppear {
            highlighted = selection.flatMap { id in pickable.first { $0.id == id }?.id } ?? pickable.first?.id
            isSearching = true
        }
        .onChange(of: query) {
            if let current = highlighted, pickable.contains(where: { $0.id == current }) { return }
            highlighted = pickable.first?.id
        }
    }

    private func row(_ item: SearchPickerItem<ID>) -> some View {
        let canPick = item.isPickable
        return Button {
            if canPick { onPick(item.id) }
        } label: {
            HStack(spacing: DS.Space.s) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(item.title)
                        .textRole(.body)
                        .foregroundStyle((canPick ? Palette.text : Palette.textFaint).color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail = item.disabledReason ?? item.note {
                        Text(detail)
                            .textRole(.caption)
                            .foregroundStyle((canPick ? Palette.textMuted : Palette.textFaint).color)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.id == selection {
                    Image(systemName: "checkmark")
                        .font(.system(size: density == .desk ? 11 : 13, weight: .semibold))
                        .foregroundStyle(Palette.accent.color)
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
            .frame(minHeight: density == .desk ? DS.Size.navRow : DS.Size.touchTarget)
            .background(highlighted == item.id && canPick ? Palette.hover.color : .clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPick)
        .id(item.id)
        .onHover { inside in
            if inside && canPick { highlighted = item.id }
        }
        .accessibilityAddTraits(item.id == selection ? .isSelected : [])
    }

    private func move(_ step: Int) {
        guard !pickable.isEmpty else { return }
        guard let current = highlighted, let index = pickable.firstIndex(where: { $0.id == current }) else {
            highlighted = (step > 0 ? pickable.first : pickable.last)?.id
            return
        }
        highlighted = pickable[min(max(index + step, 0), pickable.count - 1)].id
    }

    private func pickHighlighted() {
        guard let id = highlighted, pickable.contains(where: { $0.id == id }) else { return }
        onPick(id)
    }
}
