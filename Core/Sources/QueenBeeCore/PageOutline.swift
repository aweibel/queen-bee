import Foundation

/// A web page as an agent reads it: an indented outline, with a number on each part it can act on.
public struct PageOutline: Equatable, Sendable {
    public var text: String
    /// Each numbered part's node in the page, as Chrome identifies it.
    public var refs: [Int: Int]

    /// The longest outline handed to an agent. A page longer than this is cut, and says so.
    static let longestText = 40_000
    static let longestLabel = 300

    /// Roles a person acts on. These get a number.
    static let actionable: Set<String> = [
        "button", "link", "textbox", "searchbox", "combobox", "checkbox", "radio", "switch", "slider", "spinbutton",
        "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "option", "treeitem", "listbox", "textField", "TextField",
        "PopUpButton", "DisclosureTriangle", "ColorWell", "Date", "DateTime", "InputTime", "ToggleButton",
    ]

    /// Roles that are only layout. They are left out and what is inside them is shown in their place.
    static let transparent: Set<String> = [
        "generic", "none", "presentation", "RootWebArea", "paragraph", "group", "Section", "LayoutTable", "LayoutTableRow",
        "LayoutTableCell", "div", "GenericContainer", "Iframe", "IframePresentational", "LineBreak", "list", "listitem",
        "ListMarker", "strong", "emphasis", "LabelText", "LayoutBlockFlow", "Pre", "Abbr", "Ruby", "mark", "subscript",
        "superscript", "time", "main", "banner", "contentinfo", "complementary", "region", "article", "form", "search",
        "navigation", "table", "row", "rowgroup", "cell", "gridcell", "figure", "blockquote", "code", "ignored",
    ]

    /// Landmarks worth a line of their own, so the agent can tell the menu from the page.
    static let landmarks: Set<String> = ["navigation", "main", "banner", "contentinfo", "complementary", "form", "search", "dialog", "alertdialog", "table", "row"]

    /// Builds the outline from the nodes of `Accessibility.getFullAXTree`.
    public static func build(from nodes: [JSONValue]) -> PageOutline {
        var byID: [String: JSONValue] = [:]
        var isChild = Set<String>()
        for node in nodes {
            guard let id = node["nodeId"]?.stringValue else { continue }
            byID[id] = node
            for child in node["childIds"]?.arrayValue ?? [] { if let child = child.stringValue { isChild.insert(child) } }
        }
        var lines: [String] = []
        var refs: [Int: Int] = [:]
        var length = 0
        var cut = false

        func label(_ value: JSONValue?) -> String {
            let raw = value?["value"]?.stringValue ?? value?["value"]?.doubleValue.map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? ""
            let flat = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
            return flat.count > longestLabel ? String(flat.prefix(longestLabel)) + "…" : flat
        }

        func property(_ node: JSONValue, _ name: String) -> JSONValue? {
            node["properties"]?.arrayValue?.first { $0["name"]?.stringValue == name }?["value"]?["value"]
        }

        /// False when the outline is already full, so the line was left out.
        @discardableResult
        func add(_ line: String, depth: Int) -> Bool {
            guard !cut else { return false }
            let full = String(repeating: "  ", count: min(depth, 8)) + line
            if length + full.count > longestText {
                cut = true
                lines.append("… the page goes on. Scroll, or open a more specific page, to see the rest.")
                return false
            }
            length += full.count + 1
            lines.append(full)
            return true
        }

        /// `covered` is the name of the nearest ancestor that was printed, so its own words aren't repeated below it.
        func walk(_ id: String, depth: Int, covered: String) {
            guard !cut, let node = byID[id] else { return }
            let children = (node["childIds"]?.arrayValue ?? []).compactMap(\.stringValue)
            let role = node["role"]?["value"]?.stringValue ?? ""
            if node["ignored"]?.boolValue == true || role == "InlineTextBox" {
                if role != "InlineTextBox" { children.forEach { walk($0, depth: depth, covered: covered) } }
                return
            }
            let name = label(node["name"])

            if role == "StaticText" {
                if !name.isEmpty, !covered.contains(name) { add("text \"\(name)\"", depth: depth) }
                return
            }

            let isActionable = actionable.contains(role)
            let isLandmark = landmarks.contains(role)
            // Layout with nothing to say is skipped, and so is a container whose name is only its contents read out.
            if !isActionable, transparent.contains(role), !(isLandmark && !name.isEmpty) || role == "RootWebArea" {
                children.forEach { walk($0, depth: depth, covered: covered) }
                return
            }
            if !isActionable, name.isEmpty, !isLandmark, role != "image", role != "img", role != "separator" {
                children.forEach { walk($0, depth: depth, covered: covered) }
                return
            }

            var line = ""
            let backend = isActionable ? node["backendDOMNodeId"]?.intValue : nil
            if backend != nil { line += "[\(refs.count + 1)] " }
            line += role.isEmpty ? "part" : role
            if role == "heading", let level = property(node, "level")?.intValue { line += " \(level)" }
            if !name.isEmpty { line += " \"\(name)\"" }
            let value = label(node["value"])
            if !value.isEmpty, value != name { line += " value \"\(value)\"" }
            if let checked = property(node, "checked") {
                let state = checked.stringValue ?? (checked.boolValue == true ? "true" : "false")
                if state != "false" { line += state == "mixed" ? " (partly checked)" : " (checked)" } else { line += " (not checked)" }
            }
            if property(node, "expanded")?.boolValue == true { line += " (expanded)" }
            if property(node, "selected")?.boolValue == true { line += " (selected)" }
            if property(node, "disabled")?.boolValue == true { line += " (disabled)" }
            // A part only gets its number once its line is in, so every number the agent sees can be used.
            guard add(line, depth: depth) else { return }
            if let backend { refs[refs.count + 1] = backend }
            children.forEach { walk($0, depth: depth + 1, covered: name.isEmpty ? covered : name) }
        }

        for node in nodes {
            guard let id = node["nodeId"]?.stringValue, !isChild.contains(id) else { continue }
            walk(id, depth: 0, covered: "")
        }
        if lines.isEmpty { lines.append("The page shows nothing that can be read. It may still be loading: wait, then read again, or take a screenshot.") }
        return PageOutline(text: lines.joined(separator: "\n"), refs: refs)
    }
}
