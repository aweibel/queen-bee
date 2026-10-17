import QueenBeeCore
import SwiftUI

/// What editing a flow adds outside the canvas: the bar, the list a held finger brings up, and the questions
/// asked before something is deleted or renamed. What each offers is decided in `Editing.swift`.

/// The editing bar, over the run bar while the flow is being edited: Undo and Redo, by the names the Mac's
/// Edit menu gives them just now, then adding a card, selecting and tidying, then Done.
///
/// Where every name fits, every name is shown. Where they don't, Undo, Redo and adding become their symbols.
/// Narrower still, as on an iPhone, Select and Tidy Up do too, and only Done keeps its word: nothing has to
/// be put away in a menu at any width.
struct EditBar: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        let items = client.editBar
        // One button, Edit, is the way in, and that one is on the run bar.
        if items.count > 1 {
            ViewThatFits(in: .horizontal) {
                row(items, symbols: [])
                row(items, symbols: [.undo, .redo, .add])
                row(items, symbols: [.undo, .redo, .add, .select, .tidy])
            }
            .padding(Theme.Space.xs)
            .floatingPanel()
            .transition(.opacity)
        }
    }

    private func row(_ items: [EditBarItem], symbols: Set<EditBarItem.Kind>) -> some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(items) { item in
                if item.kind == .add || item.kind == .done {
                    Rectangle().fill(Theme.hairline.ui).frame(width: 1, height: Theme.Touch.target - Theme.Space.s).accessibilityHidden(true)
                }
                Button { client.press(item.kind) } label: {
                    if symbols.contains(item.kind) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 16, weight: .medium))
                            .frame(minWidth: Theme.Touch.target - Theme.Space.s * 2)
                    } else {
                        Text(item.title)
                    }
                }
                .buttonStyle(.panel(item.kind == .done ? .filled : item.isOn ? .toolOn : .tool))
                .disabled(!item.isEnabled)
                .accessibilityLabel(item.title)
                .accessibilityHint(item.hint)
                .accessibilityAddTraits(item.isOn ? .isSelected : [])
                // While cards are being selected, all of them can be, as with the Mac's Select All.
                if item.kind == .select, client.edit.isSelecting {
                    Button("Select All") { Task { await client.act(.selectAll) } }
                        .buttonStyle(.panel(.tool))
                        .accessibilityHint("Selects every card in the flow.")
                }
                if item.kind == .tidy { EditMore() }
            }
        }
    }
}

/// What the editing bar keeps out of the way: Paste, Select All, and whether a dragged card snaps to the others and
/// the grid, which is the Mac's Option key held down.
private struct EditMore: View {
    @Environment(RemoteClient.self) private var client

    var body: some View {
        let edit = client.edit
        Menu {
            if edit.clipboard != nil {
                Button { Task { await client.act(.paste(at: nil)) } } label: { Label(edit.clipboard?.pasteTitle ?? "Paste", systemImage: "doc.on.clipboard") }
                    .disabled(client.isBusy(.paste(at: nil)))
            }
            Button { Task { await client.act(.selectAll) } } label: { Label("Select All", systemImage: "checklist") }
            Divider()
            Toggle(isOn: Binding { edit.snaps } set: { edit.snaps = $0 }) {
                Label("Snap to Cards and Grid", systemImage: "square.grid.3x3")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .frame(minWidth: Theme.Touch.target - Theme.Space.s * 2, minHeight: Theme.Touch.target - Theme.Space.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.panel(.tool))
        .accessibilityLabel("More")
        .accessibilityHint("Paste, Select All, and whether dragged cards snap to the others and the grid.")
    }

}

/// The list a held finger brings up, where the finger was: what can be done to a card, a link or a group, or
/// the kinds of card that can be added. A tap anywhere else puts it away. Drawn as the rest of the app is,
/// a panel on the paper, where the system's own menu would be a sheet of frosted glass.
struct EditMenuLayer: View {
    @Environment(RemoteClient.self) private var client
    /// How much of the canvas's foot the bars cover. A list asked for from the bar sits just above them.
    let foot: CGFloat
    /// How tall the list's rows come to, once they have been laid out.
    @State private var rowsHeight: CGFloat = 0

    private static let width: CGFloat = 264

    var body: some View {
        if let menu = client.edit.menu {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global), margin = Theme.Space.m
                let room = CGSize(width: proxy.size.width - margin * 2, height: proxy.size.height - margin * 2)
                // A guess until the rows have been measured: a title and a row for each thing.
                let wanted = rowsHeight > 0 ? rowsHeight : CGFloat(menu.items.count + 1) * (Theme.Touch.target + 1)
                let size = CGSize(width: min(Self.width, room.width), height: min(wanted, max(Theme.Touch.target * 3, room.height - (menu.anchor == nil ? foot : 0))))
                // Beside the finger, and wholly on screen.
                let wantedAt = menu.anchor.map { CGPoint(x: $0.x - frame.minX + Theme.Space.s, y: $0.y - frame.minY + Theme.Space.s) }
                    ?? CGPoint(x: proxy.size.width, y: proxy.size.height - foot - size.height)
                let origin = CGPoint(x: min(max(wantedAt.x, margin), max(margin, proxy.size.width - margin - size.width)),
                                     y: min(max(wantedAt.y, margin), max(margin, proxy.size.height - margin - size.height)))
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { client.edit.menu = nil }
                        .accessibilityLabel("Close")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { client.edit.menu = nil }
                    EditMenuPanel(menu: menu) { rowsHeight = $0 }
                        .frame(width: size.width, height: size.height)
                        .offset(x: origin.x, y: origin.y)
                }
            }
            .transition(.opacity)
            .onChange(of: menu.items.count) { rowsHeight = 0 }
        }
    }
}

private struct EditMenuPanel: View {
    @Environment(RemoteClient.self) private var client
    let menu: EditMenu
    let measured: (CGFloat) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(menu.title)
                    .dsMono(Theme.Touch.caption, .medium)
                    .foregroundStyle(Theme.inkSecondary.ui)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Space.m)
                    .frame(maxWidth: .infinity, minHeight: Theme.Touch.target - Theme.Space.m, alignment: .leading)
                    .background(Theme.bar.ui)
                    .accessibilityAddTraits(.isHeader)
                ForEach(menu.items) { item in
                    Hairline()
                    Button {
                        Task { await client.act(item.action) }
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            if let symbol = item.symbol {
                                Image(systemName: symbol)
                                    .font(.system(size: 14, weight: .medium))
                                    .frame(width: 24)
                                    .accessibilityHidden(true)
                            }
                            Text(item.title).dsMono(Theme.Touch.body, .medium).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle((item.isDestructive ? Theme.failInk : Theme.ink).ui)
                        .padding(.horizontal, Theme.Space.m)
                        .frame(minHeight: Theme.Touch.target)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isEnabled)
                    .opacity(item.isEnabled ? 1 : 0.45)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .floatingPanel()
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .accessibilityAddTraits(.isModal)
    }
}

/// Asks before a delete that takes more than one thing, and asks a group's new name.
private struct AsksBeforeEditing: ViewModifier {
    @Environment(RemoteClient.self) private var client
    /// True for the one inside the details' sheet on an iPhone, which asks while that sheet is up. The one on
    /// the whole app asks the rest of the time: a question put up under a sheet is never seen.
    let overSheet: Bool
    @State private var name = ""

    private var isMine: Bool { overSheet || !client.panel.isSheetUp }

    private var delete: EditAsk? {
        if case .delete = client.edit.asking, isMine { client.edit.asking } else { nil }
    }

    private var rename: EditAsk? {
        if case .renameGroup = client.edit.asking, isMine { client.edit.asking } else { nil }
    }

    /// A name for a new role or a new sub-flow, which may be left empty for the card's own.
    private var naming: EditAsk? {
        switch client.edit.asking {
        case .saveRole, .newSubflow: isMine ? client.edit.asking : nil
        default: nil
        }
    }

    private var deletingRole: EditAsk? {
        if case .deleteRole = client.edit.asking, isMine { client.edit.asking } else { nil }
    }

    private func isAsking(_ ask: EditAsk?) -> Binding<Bool> {
        Binding { ask != nil } set: { if !$0, ask != nil, client.edit.asking == ask { client.edit.asking = nil } }
    }

    func body(content: Content) -> some View {
        content
            .alert(deleteTitle, isPresented: isAsking(delete), presenting: delete) { ask in
                Button("Delete", role: .destructive) { client.confirm(ask) }
                Button("Cancel", role: .cancel) {}
            } message: { ask in
                if case .delete(_, _, _, let message) = ask { Text(message) }
            }
            .alert("Rename Group", isPresented: isAsking(rename), presenting: rename) { ask in
                TextField("Name", text: $name)
                Button("Rename") { client.confirm(ask, name: name) }
                Button("Cancel", role: .cancel) {}
            }
            .alert(namingTitle, isPresented: isAsking(naming), presenting: naming) { ask in
                TextField("Name (optional)", text: $name)
                if case .saveRole = ask { Button("Save Role") { client.confirm(ask, name: name) } } else { Button("Make Sub-flow") { client.confirm(ask, name: name) } }
                Button("Cancel", role: .cancel) {}
            } message: { ask in
                if case .saveRole(_, let card) = ask {
                    Text("Saves this agent's instructions, model, effort and permissions on your Mac, so more agents like it can be made in any flow. Left empty, it is called \(card).")
                } else if case .newSubflow(_, let card) = ask {
                    Text("Makes a flow with an Input and an Output on your Mac, which this card then runs. Left empty, it is called \(card).")
                }
            }
            .alert(deleteRoleTitle, isPresented: isAsking(deletingRole), presenting: deletingRole) { ask in
                Button("Delete Role", role: .destructive) { client.confirm(ask) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The role is deleted on your Mac. Cards that were given it keep their settings.")
            }
            .onChange(of: client.edit.asking, initial: true) { _, ask in
                switch ask {
                case .renameGroup(_, let current): name = current
                // Left empty, the Mac names it after the card, as the message says.
                case .saveRole, .newSubflow: name = ""
                default: break
                }
            }
            // What was being asked about may have gone while the question was up: editing turned itself off.
            .onChange(of: client.isEditing) { _, isEditing in
                if !isEditing, isMine { client.edit.asking = nil }
            }
    }

    private var deleteTitle: String {
        if case .delete(_, _, let title, _) = client.edit.asking { title } else { "Delete?" }
    }

    private var namingTitle: String {
        if case .newSubflow = client.edit.asking { "New sub-flow" } else { "Save as a New Role" }
    }

    private var deleteRoleTitle: String {
        if case .deleteRole(_, let name) = client.edit.asking { "Delete the role “\(name)”?" } else { "Delete the role?" }
    }
}

extension View {
    /// Puts up the questions that are asked before an edit is sent.
    func asksBeforeEditing(overSheet: Bool = false) -> some View { modifier(AsksBeforeEditing(overSheet: overSheet)) }
}
