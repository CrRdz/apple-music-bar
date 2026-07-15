import Foundation

struct LyricLine: Equatable, Sendable {
    let time: TimeInterval
    let text: String
}

enum LyricsSource: String, Sendable {
    case embeddedSynced = "曲目内嵌同步歌词"
    case lrclibSynced = "LRCLIB 同步歌词"
    case embeddedEstimated = "曲目内嵌歌词（估算进度）"
    case lrclibEstimated = "LRCLIB 歌词（估算进度）"
}

struct LyricsTimeline: Sendable {
    let lines: [LyricLine]
    let source: LyricsSource

    func line(at position: TimeInterval) -> LyricLine? {
        guard !lines.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = lines.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lines[middle].time <= position {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        guard lowerBound > 0 else { return nil }
        return lines[lowerBound - 1]
    }
}

enum LRCParser {
    private static let timestampExpression = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{2})(?:[\.:](\d{1,3}))?\]"#
    )
    private static let offsetExpression = try! NSRegularExpression(
        pattern: #"\[offset:([+-]?\d+)\]"#,
        options: [.caseInsensitive]
    )
    private static let enhancedTimestampExpression = try! NSRegularExpression(
        pattern: #"<\d{1,3}:\d{2}(?:[\.:]\d{1,3})?>"#
    )

    static func parse(_ text: String, source: LyricsSource) -> LyricsTimeline? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let offsetMilliseconds = offsetExpression.firstMatch(in: text, range: fullRange)
            .flatMap { match -> Int? in
                guard let range = Range(match.range(at: 1), in: text) else { return nil }
                return Int(text[range])
            } ?? 0

        var parsedLines: [LyricLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let range = NSRange(rawLine.startIndex..<rawLine.endIndex, in: rawLine)
            let matches = timestampExpression.matches(in: rawLine, range: range)
            guard !matches.isEmpty else { continue }

            var lyric = timestampExpression.stringByReplacingMatches(
                in: rawLine,
                range: range,
                withTemplate: ""
            )
            let lyricRange = NSRange(lyric.startIndex..<lyric.endIndex, in: lyric)
            lyric = enhancedTimestampExpression.stringByReplacingMatches(
                in: lyric,
                range: lyricRange,
                withTemplate: ""
            )
            lyric = lyric.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lyric.isEmpty else { continue }

            for match in matches {
                guard
                    let minutesRange = Range(match.range(at: 1), in: rawLine),
                    let secondsRange = Range(match.range(at: 2), in: rawLine),
                    let minutes = Double(rawLine[minutesRange]),
                    let seconds = Double(rawLine[secondsRange])
                else { continue }

                var fractionalSeconds = 0.0
                if match.range(at: 3).location != NSNotFound,
                   let fractionRange = Range(match.range(at: 3), in: rawLine) {
                    let fractionText = String(rawLine[fractionRange])
                    if let fraction = Double(fractionText) {
                        fractionalSeconds = fraction / pow(10, Double(fractionText.count))
                    }
                }

                let timestamp = max(
                    0,
                    minutes * 60 + seconds + fractionalSeconds
                        + Double(offsetMilliseconds) / 1_000
                )
                parsedLines.append(LyricLine(time: timestamp, text: lyric))
            }
        }

        guard !parsedLines.isEmpty else { return nil }
        parsedLines.sort { left, right in
            if left.time == right.time { return left.text < right.text }
            return left.time < right.time
        }
        return LyricsTimeline(lines: parsedLines, source: source)
    }

    static func estimate(
        _ text: String,
        duration: TimeInterval,
        source: LyricsSource
    ) -> LyricsTimeline? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[") }

        guard !lines.isEmpty else { return nil }
        let usableDuration = duration > 0 ? duration : Double(lines.count) * 5
        let interval = usableDuration / Double(lines.count)
        let estimatedLines = lines.enumerated().map { index, text in
            LyricLine(time: Double(index) * interval, text: text)
        }
        return LyricsTimeline(lines: estimatedLines, source: source)
    }
}
