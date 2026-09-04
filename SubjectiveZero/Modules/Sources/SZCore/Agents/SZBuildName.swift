// SPDX-License-Identifier: AGPL-3.0-only
// The short name the UI gives a build, derived from the ask by one fixed rule so the strip,
// transcript header, RUNS list and scheduled rows all say the same words. No model turn is
// spent on a title.
import Foundation

public enum SZBuildName {
    /// The name for an ask: its first line, imperative lead dropped ("Make a warm orange gradient"
    /// → "Warm orange gradient"), capped at `maxWords`, sentence-cased. The lead stays when what
    /// follows cannot stand alone ("Make it grayscale").
    public static func short(_ ask: String, maxWords: Int = 6, maxCharacters: Int = 48) -> String {
        let line = ask.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return "" }
        words = dropLead(words)
        var clipped = false
        if words.count > maxWords {
            words = Array(words.prefix(maxWords))
            clipped = true
            // The ellipsis follows a content word, not "and" or "the".
            while words.count > 1, trailing.contains(key(words[words.count - 1])) { words.removeLast() }
        }
        var name = words.joined(separator: " ")
        if name.count > maxCharacters {
            name = String(name.prefix(maxCharacters - 1))
            clipped = true
        }
        while let last = name.last, last.isWhitespace || ".,;:!?".contains(last) { name.removeLast() }
        // Punctuation-only asks keep their own text rather than vanishing.
        if name.isEmpty { name = String(line.prefix(maxCharacters)) }
        let first = words.first?.trimmingCharacters(in: .punctuationCharacters) ?? ""
        if !first.isEmpty, first.allSatisfy(\.isLowercase) {
            name = name.prefix(1).uppercased() + name.dropFirst()
        }
        return clipped ? name + "…" : name
    }

    /// Leads people put before what they want, longest first so "give me" wins over "give".
    private static let leads: [[String]] = [
        ["i", "would", "like", "to"], ["i'd", "like", "to"], ["i", "want", "to"], ["i", "need", "to"],
        ["we", "need", "to"], ["i", "would", "like"], ["i'd", "like"], ["i", "want"], ["i", "need"],
        ["we", "need"], ["can", "you"], ["could", "you"], ["would", "you"], ["let's"], ["lets"],
        ["please"], ["make", "me"], ["give", "me"], ["show", "me"], ["make"], ["create"], ["add"],
        ["build"], ["generate"], ["write"], ["produce"], ["render"], ["show"],
    ]
    private static let articles: Set<String> = ["a", "an", "the", "some", "another", "new", "me"]
    /// A word that only makes sense after the verb it followed.
    private static let dependents: Set<String> = [
        "it", "this", "that", "these", "those", "them", "everything", "all", "sure", "up", "to",
    ]
    /// Words a clipped name must not end on.
    private static let trailing: Set<String> = articles.union(["and", "or", "of", "in", "with", "to", "for", "then"])

    /// A word as the tables know it: lower-case, straight apostrophe, no surrounding punctuation.
    private static func key(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func dropLead(_ words: [String]) -> [String] {
        var rest = words
        var dropped = false
        outer: while true {
            let keys = rest.map(key)
            for lead in leads where keys.starts(with: lead) && rest.count > lead.count {
                rest.removeFirst(lead.count)
                dropped = true
                continue outer
            }
            if let first = keys.first, articles.contains(first), rest.count > 1 {
                rest.removeFirst()
                dropped = true
                continue
            }
            break
        }
        guard dropped, let first = rest.first.map(key), !dependents.contains(first) else { return words }
        return rest
    }
}
