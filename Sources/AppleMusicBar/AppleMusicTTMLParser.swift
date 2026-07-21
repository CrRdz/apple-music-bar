import Foundation

enum AppleMusicTTMLParser {
    static func parse(_ text: String, duration: TimeInterval) -> LyricsTimeline? {
        guard let data = text.data(using: .utf8) else { return nil }

        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        guard parser.parse(), !delegate.lines.isEmpty else { return nil }

        if delegate.lines.allSatisfy({ $0.time != nil }) {
            let lines = delegate.lines.compactMap { line -> LyricLine? in
                guard let time = line.time else { return nil }
                return LyricLine(time: max(0, time), text: line.text)
            }.sorted { left, right in
                if left.time == right.time { return left.text < right.text }
                return left.time < right.time
            }
            guard !lines.isEmpty else { return nil }
            return LyricsTimeline(lines: lines, source: .appleMusicSynced)
        }

        return LRCParser.estimate(
            delegate.lines.map(\.text).joined(separator: "\n"),
            duration: duration,
            source: .appleMusicEstimated
        )
    }

    static func parseTime(_ value: String) -> TimeInterval? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix("ms"), let milliseconds = Double(text.dropLast(2)) {
            return milliseconds / 1_000
        }
        if text.hasSuffix("s"), let seconds = Double(text.dropLast()) {
            return seconds
        }

        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == text.split(separator: ":").count else {
            return nil
        }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

private extension AppleMusicTTMLParser {
    final class ParserDelegate: NSObject, XMLParserDelegate {
        struct ParsedLine {
            let time: TimeInterval?
            let text: String
        }

        private(set) var lines: [ParsedLine] = []
        private var currentTime: TimeInterval?
        private var currentText = ""
        private var isInsideLine = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "p":
                isInsideLine = true
                currentText = ""
                currentTime = attributeDict["begin"].flatMap(AppleMusicTTMLParser.parseTime)
            case "br" where isInsideLine:
                currentText.append("\n")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard isInsideLine else { return }
            currentText.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard elementName == "p", isInsideLine else { return }
            let text = normalized(currentText)
            if !text.isEmpty {
                lines.append(ParsedLine(time: currentTime, text: text))
            }
            isInsideLine = false
            currentTime = nil
            currentText = ""
        }

        private func normalized(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\u{00a0}", with: " ")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
    }
}
