import Foundation
import Testing
@testable import QueenBeeCore

@Suite struct PageOutlineTests {
    /// One node as `Accessibility.getFullAXTree` gives it.
    private func node(_ id: Int, _ role: String, _ name: String = "", children: [Int] = [], backend: Int? = nil,
                      ignored: Bool = false, value: String? = nil, properties: [String: JSONValue] = [:]) -> JSONValue {
        var fields: [String: JSONValue] = [
            "nodeId": .string(String(id)), "ignored": .bool(ignored), "role": ["type": "role", "value": .string(role)],
            "name": ["type": "computedString", "value": .string(name)],
            "childIds": .array(children.map { .string(String($0)) }),
            "backendDOMNodeId": .number(Double(backend ?? id + 100)),
            "properties": .array(properties.sorted { $0.key < $1.key }.map { ["name": .string($0.key), "value": ["value": $0.value]] }),
        ]
        if let value { fields["value"] = ["type": "string", "value": .string(value)] }
        return .object(fields)
    }

    @Test func aSimplePageReadsAsHeadingsTextAndNumberedLinks() {
        let outline = PageOutline.build(from: [
            node(1, "RootWebArea", "Example Domain", children: [2]),
            node(2, "generic", children: [3, 5, 7]),
            node(3, "heading", "Example Domain", children: [4], properties: ["level": 1]),
            node(4, "StaticText", "Example Domain"),
            node(5, "paragraph", children: [6]),
            node(6, "StaticText", "This domain is for use in examples."),
            node(7, "link", "Learn more", children: [8], backend: 42),
            node(8, "StaticText", "Learn more", children: [9]),
            node(9, "InlineTextBox", "Learn more"),
        ])
        #expect(outline.text == """
        heading 1 "Example Domain"
        text "This domain is for use in examples."
        [1] link "Learn more"
        """)
        #expect(outline.refs == [1: 42])
    }

    @Test func partsAreNumberedInReadingOrderWithTheirState() {
        let outline = PageOutline.build(from: [
            node(1, "RootWebArea", "Form", children: [2, 3, 4, 5, 6]),
            node(2, "textbox", "Email", backend: 10, value: "a@b.c"),
            node(3, "checkbox", "Remember me", backend: 11, properties: ["checked": "true"]),
            node(4, "checkbox", "Newsletter", backend: 12, properties: ["checked": "false"]),
            node(5, "button", "Sign in", backend: 13, properties: ["disabled": true]),
            node(6, "combobox", "Country", backend: 14, value: "Portugal", properties: ["expanded": true]),
        ])
        #expect(outline.text == """
        [1] textbox "Email" value "a@b.c"
        [2] checkbox "Remember me" (checked)
        [3] checkbox "Newsletter" (not checked)
        [4] button "Sign in" (disabled)
        [5] combobox "Country" value "Portugal" (expanded)
        """)
        #expect(outline.refs == [1: 10, 2: 11, 3: 12, 4: 13, 5: 14])
    }

    @Test func ignoredNodesAreSkippedButWhatIsInsideThemIsKept() {
        let outline = PageOutline.build(from: [
            node(1, "RootWebArea", "", children: [2]),
            node(2, "none", children: [3], ignored: true),
            node(3, "button", "Go", backend: 5),
        ])
        #expect(outline.text == #"[1] button "Go""#)
    }

    @Test func namedLandmarksShowAndIndentWhatTheyHold() {
        let outline = PageOutline.build(from: [
            node(1, "RootWebArea", "", children: [2, 4]),
            node(2, "navigation", "Main menu", children: [3]),
            node(3, "link", "Home", backend: 7),
            node(4, "navigation", "", children: [5]),
            node(5, "link", "Terms", backend: 8),
        ])
        #expect(outline.text == """
        navigation "Main menu"
          [1] link "Home"
        [2] link "Terms"
        """)
    }

    @Test func textAlreadySaidByItsParentIsNotRepeatedButExtraTextIs() {
        let outline = PageOutline.build(from: [
            node(1, "RootWebArea", "", children: [2]),
            node(2, "button", "Add to basket", children: [3, 4], backend: 9),
            node(3, "StaticText", "Add to basket"),
            node(4, "StaticText", "3 left"),
        ])
        #expect(outline.text == """
        [1] button "Add to basket"
          text "3 left"
        """)
    }

    @Test func imagesWithANameShowAndLongTextIsShortened() {
        let long = String(repeating: "word ", count: 200)
        let outline = PageOutline.build(from: [
            node(1, "RootWebArea", "", children: [2, 3, 4]),
            node(2, "image", "A chart of sales"),
            node(3, "image", ""),
            node(4, "StaticText", long + "\n  and   a new line"),
        ])
        let lines = outline.text.split(separator: "\n")
        #expect(lines[0] == #"image "A chart of sales""#)
        #expect(lines[1] == "image")
        #expect(lines[2].count < PageOutline.longestLabel + 12)
        #expect(lines[2].hasSuffix("…\""))
        #expect(!outline.text.contains("  and"))
    }

    @Test func aVeryLongPageIsCutAndSaysSo() {
        var nodes = [node(1, "RootWebArea", "", children: Array(2...3001))]
        for id in 2...3001 { nodes.append(node(id, "link", "Link number \(id) with a fairly long name to fill the page up", backend: id)) }
        let outline = PageOutline.build(from: nodes)
        #expect(outline.text.count <= PageOutline.longestText + 200)
        #expect(outline.text.hasSuffix("to see the rest."))
        // Every number in the outline can still be clicked.
        #expect(outline.refs.count == outline.text.split(separator: "\n").count - 1)
    }

    @Test func aNumberTooLargeToCountDoesNotCrashTheApp() {
        let slider: JSONValue = [
            "nodeId": "2", "ignored": false, "role": ["value": "slider"], "name": ["value": "Volume"],
            "value": ["type": "number", "value": .number(1e30)], "backendDOMNodeId": 7, "childIds": [],
        ]
        let huge: JSONValue = ["nodeId": "3", "ignored": false, "role": ["value": "button"], "name": ["value": "Go"],
                               "backendDOMNodeId": .number(1e30), "childIds": []]
        let outline = PageOutline.build(from: [node(1, "RootWebArea", "", children: [2, 3]), slider, huge])
        #expect(outline.text.contains("[1] slider \"Volume\" value \"1e+30\""))
        // A part whose node number makes no sense is shown but can't be acted on.
        #expect(outline.refs == [1: 7])
        #expect(JSONValue.number(.infinity).intValue == nil && JSONValue.number(2.9).intValue == 2)
    }

    @Test func anEmptyPageSaysThereIsNothingToRead() {
        #expect(PageOutline.build(from: []).text.contains("nothing that can be read"))
        #expect(PageOutline.build(from: [node(1, "RootWebArea", "Blank")]).refs.isEmpty)
    }
}
