import Foundation

actor LyricsRepository {
    private enum CacheEntry {
        case found(LyricsTimeline)
        case missing
    }

    private struct LRCLIBLyrics: Decodable {
        let id: Int?
        let trackName: String?
        let artistName: String?
        let albumName: String?
        let duration: Double?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    private var cache: [TrackKey: CacheEntry] = [:]

    func lyrics(for track: TrackSnapshot) async -> LyricsTimeline? {
        if let cached = cache[track.key] {
            switch cached {
            case .found(let timeline): return timeline
            case .missing: return nil
            }
        }

        if let embedded = LRCParser.parse(
            track.embeddedLyrics,
            source: .embeddedSynced
        ) {
            cache[track.key] = .found(embedded)
            return embedded
        }

        if let online = await fetchFromLRCLIB(track: track) {
            cache[track.key] = .found(online)
            return online
        }

        if let embedded = LRCParser.estimate(
            track.embeddedLyrics,
            duration: track.duration,
            source: .embeddedEstimated
        ) {
            cache[track.key] = .found(embedded)
            return embedded
        }

        cache[track.key] = .missing
        return nil
    }

    func invalidate(_ key: TrackKey) {
        cache.removeValue(forKey: key)
    }

    private func fetchFromLRCLIB(track: TrackSnapshot) async -> LyricsTimeline? {
        let primaryCandidates = await primarySearchCandidates(for: track)
        if let timeline = bestTimeline(in: primaryCandidates, for: track) {
            return timeline
        }

        let preferredTerm = TrackMetadataMatcher.preferredTitleSearchTerm(track.title)
        let remainingVariants = TrackMetadataMatcher.titleSearchVariants(track.title)
            .filter { $0.caseInsensitiveCompare(preferredTerm) != .orderedSame }
        for variant in remainingVariants {
            let candidates = (try? await Self.search(queryItems: [
                URLQueryItem(name: "q", value: variant)
            ])) ?? []
            if let timeline = bestTimeline(in: candidates, for: track) {
                return timeline
            }
        }
        return nil
    }

    private static func search(
        queryItems: [URLQueryItem]
    ) async throws -> [LRCLIBLyrics] {
        var components = baseComponents(path: "/api/search")
        components.queryItems = queryItems

        guard let url = components.url else { return [] }
        let (data, response) = try await URLSession.shared.data(for: request(for: url))
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else { return [] }
        return try JSONDecoder().decode([LRCLIBLyrics].self, from: data)
    }

    private func primarySearchCandidates(for track: TrackSnapshot) async -> [LRCLIBLyrics] {
        let preferredTerm = TrackMetadataMatcher.preferredTitleSearchTerm(track.title)
        let queryGroups = [[
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album)
        ], [
            URLQueryItem(name: "q", value: preferredTerm)
        ]]

        let results = await withTaskGroup(of: [LRCLIBLyrics].self) { group in
            for queryItems in queryGroups {
                group.addTask {
                    (try? await Self.search(queryItems: queryItems)) ?? []
                }
            }

            var collected: [LRCLIBLyrics] = []
            for await candidates in group {
                collected.append(contentsOf: candidates)
            }
            return collected
        }

        var seen = Set<String>()
        return results.filter { result in
            let identity = result.id.map(String.init)
                ?? [result.trackName, result.artistName, result.albumName]
                    .compactMap { $0 }
                    .joined(separator: "|")
            return seen.insert(identity).inserted
        }
    }

    private static func baseComponents(path: String) -> URLComponents {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        return components
    }

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("AppleMusicBar/0.2.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func makeTimeline(
        from result: LRCLIBLyrics,
        track: TrackSnapshot
    ) -> LyricsTimeline? {
        if let syncedLyrics = result.syncedLyrics,
           let timeline = LRCParser.parse(syncedLyrics, source: .lrclibSynced) {
            return timeline
        }

        if let plainLyrics = result.plainLyrics {
            return LRCParser.estimate(
                plainLyrics,
                duration: track.duration,
                source: .lrclibEstimated
            )
        }
        return nil
    }

    private func score(_ result: LRCLIBLyrics, for track: TrackSnapshot) -> Int {
        var value = 0
        if TrackMetadataMatcher.equivalent(result.trackName, track.title) { value += 50 }
        if TrackMetadataMatcher.equivalent(result.artistName, track.artist) { value += 30 }
        if TrackMetadataMatcher.equivalent(result.albumName, track.album) { value += 10 }
        if let duration = result.duration,
           abs(duration - track.duration) <= 3 { value += 10 }
        if result.syncedLyrics?.isEmpty == false { value += 5 }
        return value
    }

    private func bestTimeline(
        in candidates: [LRCLIBLyrics],
        for track: TrackSnapshot
    ) -> LyricsTimeline? {
        let rankedCandidates = candidates.sorted {
            score($0, for: track) > score($1, for: track)
        }
        for candidate in rankedCandidates where score(candidate, for: track) >= 40 {
            if let timeline = makeTimeline(from: candidate, track: track) {
                return timeline
            }
        }
        return nil
    }
}
