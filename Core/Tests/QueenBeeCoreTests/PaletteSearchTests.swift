import Testing
@testable import QueenBeeCore

@Suite struct PaletteSearchTests {
    @Test func everyWordTypedHasToBeThere() {
        #expect(PaletteSearch.score("link rev", in: "Link Writer to Reviewer") != nil)
        #expect(PaletteSearch.score("rev link", in: "Link Writer to Reviewer") != nil)
        #expect(PaletteSearch.score("link editor", in: "Link Writer to Reviewer") == nil)
        #expect(PaletteSearch.score("", in: "Anything") == 0)
    }

    @Test func theStartOfAWordCountsForMore() {
        let titles = ["Go to Driver", "Add River Card", "Run from River"]
        #expect(PaletteSearch.rank(titles, by: "riv") { $0 } == ["Add River Card", "Run from River", "Go to Driver"])
        // A title that starts with what was typed comes first.
        #expect(PaletteSearch.rank(["Add Agent Card", "Agent card settings"], by: "agent") { $0 }.first == "Agent card settings")
    }
}
