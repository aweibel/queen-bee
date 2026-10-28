import Testing
@testable import QueenBeeDesign

/// What a search picker lists for what has been typed.
@Suite struct SearchPickerTests {
    private static let items: [SearchPickerItem<String>] = [
        .init(id: "a", title: "feature/Login"),
        .init(id: "b", title: "main", isPinned: true),
        .init(id: "c", title: "fix/logout"),
        .init(id: "d", title: "develop", isPinned: true),
    ]

    private func ids(_ query: String) -> [String] {
        SearchPickerFilter.visible(Self.items, query: query).map(\.id)
    }

    @Test func emptyQueryListsEverythingWithPinnedFirst() {
        #expect(ids("") == ["b", "d", "a", "c"])
    }

    @Test func queryIgnoresCase() {
        #expect(ids("LOGIN") == ["a"])
        #expect(ids("lo") == ["d", "a", "c"])
    }

    @Test func pinnedKeepTheirOrderWhenTheyMatch() {
        #expect(ids("e") == ["d", "a"])
        #expect(ids("m") == ["b"])
    }

    @Test func spacesOnlyIsTheSameAsEmpty() {
        #expect(ids("   ") == ids(""))
    }

    @Test func noMatchIsEmpty() {
        #expect(ids("zzz").isEmpty)
    }
}
