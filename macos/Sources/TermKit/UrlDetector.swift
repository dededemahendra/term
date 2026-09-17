import Foundation

/// Finds the URL under a column of a row's text, for cmd-click.
public enum UrlDetector {
    private static let stops: Set<Character> = [" ", "\t", "\"", "'", "<", ">", "`"]
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]

    public static func url(in line: String, at column: Int) -> String? {
        let chars = Array(line)
        guard column >= 0, column < chars.count, !stops.contains(chars[column]) else { return nil }
        var start = column
        while start > 0, !stops.contains(chars[start - 1]) { start -= 1 }
        var end = column
        while end + 1 < chars.count, !stops.contains(chars[end + 1]) { end += 1 }
        var run = String(chars[start...end])
        while run.first == "(" || run.first == "[" {
            run.removeFirst()
        }
        guard let schemeRange = run.range(of: "://") else { return nil }
        let scheme = run[..<schemeRange.lowerBound]
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }) else { return nil }
        while let last = run.last, trailing.contains(last) {
            if last == ")" && run.filter({ $0 == "(" }).count == run.filter({ $0 == ")" }).count { break }
            if last == "]" && run.filter({ $0 == "[" }).count == run.filter({ $0 == "]" }).count { break }
            run.removeLast()
        }
        return run.contains("://") ? run : nil
    }
}
