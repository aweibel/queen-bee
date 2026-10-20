import Foundation

/// How the command palette matches what is typed against its commands, like "Link Writer to Reviewer".
public enum PaletteSearch {
    /// How well `title` matches `query`, higher for better, or nil when it doesn't. Every word typed has to be
    /// found in the title, in any order. A word that starts a word of the title counts for more than one found
    /// inside a word, and a title that starts with what was typed counts most. An empty query matches everything.
    public static func score(_ query: String, in title: String) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return 0 }
        let lowered = title.lowercased()
        let titleWords = lowered.split { !$0.isLetter && !$0.isNumber }
        var score = 0
        for word in words {
            if titleWords.contains(where: { $0.hasPrefix(word) }) {
                score += 3
            } else if lowered.contains(word) {
                score += 1
            } else {
                return nil
            }
        }
        if lowered.hasPrefix(query.lowercased().trimmingCharacters(in: .whitespaces)) { score += 5 }
        return score
    }

    /// The titles that match `query`, best first, keeping the given order among equals.
    public static func rank<T>(_ items: [T], by query: String, title: (T) -> String) -> [T] {
        items.enumerated()
            .compactMap { index, item in score(query, in: title(item)).map { (index, item, $0) } }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map(\.1)
    }
}
