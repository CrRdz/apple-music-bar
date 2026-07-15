import Foundation

actor LyricsRepository {
    private enum CacheEntry {
        case found(LyricsTimeline)
        case missing
    }

    private struct LRCLIBLyrics: Decodable {
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
        if let exact = try? await exactMatch(for: track),
           let timeline = makeTimeline(from: exact, track: track) {
            return timeline
        }

        guard let candidates = try? await search(for: track) else { return nil }
        let bestCandidate = candidates.max { left, right in
            score(left, for: track) < score(right, for: track)
        }
        guard let bestCandidate, score(bestCandidate, for: track) >= 40 else { return nil }
        return makeTimeline(from: bestCandidate, track: track)
    }

    private func exactMatch(for track: TrackSnapshot) async throws -> LRCLIBLyrics? {
        var components = baseComponents(path: "/api/get")
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))
        ]

        guard let url = components.url else { return nil }
        let (data, response) = try await URLSession.shared.data(for: request(for: url))
        guard let httpResponse = response as? HTTPURLResponse else { return nil }
        if httpResponse.statusCode == 404 { return nil }
        guard (200..<300).contains(httpResponse.statusCode) else { return nil }
        return try JSONDecoder().decode(LRCLIBLyrics.self, from: data)
    }

    private func search(for track: TrackSnapshot) async throws -> [LRCLIBLyrics] {
        var components = baseComponents(path: "/api/search")
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album)
        ]

        guard let url = components.url else { return [] }
        let (data, response) = try await URLSession.shared.data(for: request(for: url))
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else { return [] }
        return try JSONDecoder().decode([LRCLIBLyrics].self, from: data)
    }

    private func baseComponents(path: String) -> URLComponents {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        return components
    }

    private func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("AppleMusicBar/0.1.0", forHTTPHeaderField: "User-Agent")
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
        if normalized(result.trackName) == normalized(track.title) { value += 50 }
        if normalized(result.artistName) == normalized(track.artist) { value += 30 }
        if normalized(result.albumName) == normalized(track.album) { value += 10 }
        if let duration = result.duration,
           abs(duration - track.duration) <= 3 { value += 10 }
        if result.syncedLyrics?.isEmpty == false { value += 5 }
        return value
    }

    private func normalized(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
