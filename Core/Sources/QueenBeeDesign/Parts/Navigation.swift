import SwiftUI

/// A row in the sidebar: an icon or a status dot, a name, and something at its end, such as a count.
/// The selected row is filled; a row under the pointer is lightly filled.
public struct NavRow<Leading: View, Trailing: View>: View {
    let title: String
    let isSelected: Bool
    let leading: Leading
    let trailing: Trailing

    public init(_ title: String, selected: Bool = false,
                @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.isSelected = selected
        self.leading = leading()
        self.trailing = trailing()
    }

    @Environment(\.density) private var density
    @State private var isHovered = false

    public var body: some View {
        HStack(spacing: DS.Space.s) {
            leading
                .frame(width: 16)
                .foregroundStyle((isSelected ? Palette.text : Palette.textMuted).color)
            Text(title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: DS.Space.xs)
            trailing
        }
        .textRole(density == .desk ? .body : .label)
        .foregroundStyle((isSelected ? Palette.text : Palette.textMuted).color)
        .padding(.horizontal, DS.Space.s)
        .frame(minHeight: density == .desk ? DS.Size.navRow : DS.Size.touchTarget)
        .background(fill.color, in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(DS.Motion.quick, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Shade {
        isSelected ? Palette.selected : (isHovered ? Palette.hover : Palette.chrome.opacity(0))
    }
}

extension NavRow where Trailing == EmptyView {
    public init(_ title: String, selected: Bool = false, @ViewBuilder leading: () -> Leading) {
        self.init(title, selected: selected, leading: leading) { EmptyView() }
    }
}

/// A row of rounded tabs, as under a view's header: Canvas · Runs · Schedule · Settings.
/// The chosen one is filled; the others are text. A count may follow a title.
public struct PillTabs<Value: Hashable>: View {
    public struct Tab: Identifiable {
        public let value: Value
        public let title: String
        public let count: Int?
        public var id: Value { value }

        public init(_ value: Value, _ title: String, count: Int? = nil) {
            self.value = value
            self.title = title
            self.count = count
        }
    }

    let tabs: [Tab]
    @Binding var selection: Value

    public init(_ tabs: [Tab], selection: Binding<Value>) {
        self.tabs = tabs
        _selection = selection
    }

    @Environment(\.density) private var density

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            ForEach(tabs) { tab in
                let isOn = tab.value == selection
                Button { selection = tab.value } label: {
                    HStack(spacing: 5) {
                        Text(tab.title)
                        if let count = tab.count {
                            Text("\(count)").foregroundStyle(Palette.textFaint.color).monospacedDigit()
                        }
                    }
                    .textRole(.label)
                    .foregroundStyle((isOn ? Palette.text : Palette.textMuted).color)
                    .padding(.horizontal, density == .desk ? 10 : 14)
                    .frame(minHeight: density == .desk ? 26 : 36)
                    .background((isOn ? Palette.selected : Palette.panel.opacity(0)).color, in: Capsule())
                    .overlay(Capsule().strokeBorder((isOn ? Palette.hairlineStrong : Palette.hairline.opacity(0)).color))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .animation(DS.Motion.quick, value: selection)
    }
}
