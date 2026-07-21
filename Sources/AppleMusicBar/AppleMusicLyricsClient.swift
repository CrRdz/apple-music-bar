import Foundation
import MusicKit

actor AppleMusicLyricsClient {
    private struct LyricsResponse: Decodable {
        struct Resource: Decodable {
            struct Attributes: Decodable {
                let ttml: String?
            }

            let attributes: Attributes?
        }

        let data: [Resource]
    }

    func lyrics(for track: TrackSnapshot) async -> LyricsTimeline? {
        guard await authorizationStatus() == .authorized else { return nil }

        do {
            guard let song = try await catalogSong(matching: track) else { return nil }
            let countryCode = try await MusicDataRequest.currentCountryCode.lowercased()
            guard let ttml = try await fetchTTML(
                songID: song.id.rawValue,
                countryCode: countryCode
            ) else { return nil }
            return AppleMusicTTMLParser.parse(ttml, duration: track.duration)
        } catch {
            return nil
        }
    }

    private func authorizationStatus() async -> MusicAuthorization.Status {
        switch MusicAuthorization.currentStatus {
        case .notDetermined:
            return await MusicAuthorization.request()
        case let status:
            return status
        }
    }

    private func catalogSong(matching track: TrackSnapshot) async throws -> Song? {
        let term = [track.title, track.artist]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        guard !term.isEmpty else { return nil }

        var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
        request.limit = 10
        let songs = try await request.response().songs.filter(\.hasLyrics)
        return songs
            .filter { isPlausibleMatch($0, for: track) }
            .max { matchScore($0, for: track) < matchScore($1, for: track) }
    }

    private func isPlausibleMatch(_ song: Song, for track: TrackSnapshot) -> Bool {
        guard TrackMetadataMatcher.equivalent(song.title, track.title) else { return false }

        let artistMatches = TrackMetadataMatcher.equivalent(song.artistName, track.artist)
        let albumMatches = TrackMetadataMatcher.equivalent(song.albumTitle, track.album)
        let durationMatches = song.duration.map { abs($0 - track.duration) <= 3 } ?? false
        return artistMatches || albumMatches || durationMatches
    }

    private func matchScore(_ song: Song, for track: TrackSnapshot) -> Int {
        var score = 0
        if TrackMetadataMatcher.equivalent(song.artistName, track.artist) { score += 40 }
        if TrackMetadataMatcher.equivalent(song.albumTitle, track.album) { score += 15 }
        if let duration = song.duration {
            let difference = abs(duration - track.duration)
            if difference <= 2 {
                score += 30
            } else if difference <= 5 {
                score += 10
            }
        }
        return score
    }

    private func fetchTTML(songID: String, countryCode: String) async throws -> String? {
        for host in ["amp-api.music.apple.com", "api.music.apple.com"] {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/v1/catalog/\(countryCode)/songs/\(songID)/lyrics"
            guard let url = components.url else { continue }

            var urlRequest = URLRequest(url: url)
            urlRequest.timeoutInterval = 10
            urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
            urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            urlRequest.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")

            do {
                let response = try await MusicDataRequest(urlRequest: urlRequest).response()
                guard (200..<300).contains(response.urlResponse.statusCode) else { continue }
                let decoded = try JSONDecoder().decode(LyricsResponse.self, from: response.data)
                if let ttml = decoded.data.lazy.compactMap(\.attributes?.ttml).first,
                   !ttml.isEmpty {
                    return ttml
                }
            } catch {
                continue
            }
        }
        return nil
    }
}
