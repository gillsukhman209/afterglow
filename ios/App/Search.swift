import Foundation
import UIKit

enum YouTubeSearch {
    static func target(for query: String) throws -> String {
        let terms = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        unreserved.insert(charactersIn: "-._~")
        guard !terms.isEmpty, let escaped = terms.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            throw RemoteError("Say or type something to search for.")
        }
        return "q=" + escaped
    }
}

// Match a named destination in the command before considering its subject.
enum SearchRouting {
    static let providers: [(Shortcut, String)] = [
        (.prime, #"amazon(?: prime(?: video)?| video)?|prime(?: video)?"#),
        (.netflix, "netflix"), (.sling, "sling(?: tv)?"), (.youtube, "you ?tube"),
        (.home, "afterglow")
    ]
    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let match = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func destination(in text: String) -> Shortcut? {
        let matches = providers.filter { _, alias in
            capture(#"\b(?:on|in|using|through|open|launch|search)\s+(?:"# + alias + #")\b"#, text) != nil
        }
        return matches.count == 1 ? matches[0].0 : nil
    }
    static func action(for text: String) -> Action? {
        let start = #"^(?:please\s+)?(?:search(?:\s+for)?|find|look\s+(?:up|for)|watch|play)\s+"#
        for (app, alias) in providers {
            let provider = "(?:" + alias + ")"
            if capture(#"^(?:(?:open|launch|start|go to)\s+)?"# + provider + "$", text) != nil { return .open(app) }
            guard app != .home else { continue }
            let patterns = [
                start + #"(.+?)\s+(?:on|in|using|through)\s+"# + provider + #"(?:\s+please)?$"#,
                #"^(?:please\s+)?(?:open|launch)\s+"# + provider + #"\s+(?:and\s+)?(?:search(?:\s+for)?|find|look up|play)\s+(.+)$"#,
                #"^(?:please\s+)?(?:search|look)\s+(?:on\s+)?"# + provider + #"\s+for\s+(.+)$"#,
                #"^(?:on|in)\s+"# + provider + #",?\s+(?:search(?: for)?|find|play)\s+(.+)$"#
            ]
            for pattern in patterns {
                if let title = capture(pattern, text) { return .search(app, title) }
            }
        }
        if let query = capture(start + "(.+)$", text),
           destination(in: text) == nil { return .search(nil, query) }
        return nil
    }
}

enum TitleMatching {
    static func terms(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:the movie|the show|the series|the film)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    static func key(_ input: String, relaxed: Bool = false) -> String {
        let decoded = input.replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        var words = decoded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if relaxed {
            if words.count > 1 && ["a", "an", "the"].contains(words[0]) { words.removeFirst() }
            let numbers = ["two": "2", "three": "3", "four": "4", "five": "5", "ii": "2", "iii": "3", "iv": "4"]
            words = words.map { numbers[$0] ?? $0 }
        }
        return words.joined(separator: " ")
    }

    static func match(_ query: String, in cards: [(id: String, name: String)]) -> String? {
        for relaxed in [false, true] {
            let key = key(query, relaxed: relaxed)
            let matches = cards.filter { Self.key($0.name, relaxed: relaxed) == key }
            let ids = Set(matches.map(\.id))
            if ids.count == 1 { return ids.first }
            if !ids.isEmpty { return nil }
        }
        return nil
    }
}

enum NetflixSearch {
    static let cards: [(id: String, name: String)] = {
        guard let data = NSDataAsset(name: "NetflixTitles")?.data,
              let index = try? JSONDecoder().decode([String: String].self, from: data) else { return [] }
        return index.map { (id: $0.key, name: $0.value) }
    }()

    static func target(for query: String) -> String? {
        guard let id = TitleMatching.match(TitleMatching.terms(query), in: cards) else { return nil }
        return "m=http%3A%2F%2Fapi.netflix.com%2Fcatalog%2Ftitles%2Fmovies%2F" + id + "&source_type=4"
    }
}

// The installed Prime Video app accepts a catalog ID for a title page.
enum PrimeSearch {
    static func titleID(for query: String) async throws -> String? {
        let terms = TitleMatching.terms(query)
        var components = URLComponents(string: "https://www.primevideo.com/search/")!
        components.queryItems = [URLQueryItem(name: "phrase", value: terms)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard !terms.isEmpty, let url = components.url else {
            throw RemoteError("Say or type a title to search for.")
        }
        let results = try await html(at: url)
        let card = #"<a\b[^>]*\bhref="/detail/([A-Z0-9]+)(?:\?[^"]*)?"[^>]*>([^<>]+)</a>"#
        let regex = try NSRegularExpression(pattern: card)
        let source = results as NSString
        let cards = regex.matches(in: results, range: NSRange(location: 0, length: source.length)).map {
            (id: source.substring(with: $0.range(at: 1)), name: source.substring(with: $0.range(at: 2)))
        }
        guard !cards.isEmpty else { throw RemoteError("Prime’s catalog didn’t return readable titles. Try again or use Search in Prime.") }
        // Prime lists the same named movie under multiple offers. Keep their catalog ordering.
        var seen = Set<String>()
        let ranked = cards.filter { seen.insert(TitleMatching.key($0.name)).inserted }
        guard let match = TitleMatching.match(terms, in: ranked) else { return nil }
        let detailURL = URL(string: "https://www.primevideo.com/detail/")!.appendingPathComponent(match)
        let detail = try await html(at: detailURL)
        let identifier = #""pageTitleId"\s*:\s*"(amzn1\.dv\.gti\.[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})""#
        guard let id = firstMatch(identifier, in: detail)?.first else {
            throw RemoteError("Prime found the title but didn’t provide a TV link.")
        }
        return id
    }

    private static func html(at url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw RemoteError("Prime Video lookup unavailable.")
        }
        return text
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { (text as NSString).substring(with: match.range(at: $0)) }
    }

}
