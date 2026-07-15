import Foundation

enum TrackMetadataMatcher {
    private static let traditionalToSimplified = StringTransform("Hant-Hans")
    private static let simplifiedToTraditional = StringTransform("Hans-Hant")

    static func canonical(_ value: String?) -> String {
        let source = value ?? ""
        let simplified = source.applyingTransform(
            traditionalToSimplified,
            reverse: false
        ) ?? source
        let folded = simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()

        let scalars = folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    static func equivalent(_ left: String?, _ right: String?) -> Bool {
        let normalizedLeft = canonical(left)
        let normalizedRight = canonical(right)
        return !normalizedLeft.isEmpty && normalizedLeft == normalizedRight
    }

    static func titleSearchVariants(_ title: String) -> [String] {
        let candidates = [
            title,
            title.applyingTransform(simplifiedToTraditional, reverse: false),
            title.applyingTransform(traditionalToSimplified, reverse: false)
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return candidates.filter { candidate in
            seen.insert(candidate.lowercased()).inserted
        }
    }

    static func preferredTitleSearchTerm(_ title: String) -> String {
        let traditional = title.applyingTransform(
            simplifiedToTraditional,
            reverse: false
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let traditional, !traditional.isEmpty {
            return traditional
        }
        return title
    }
}
