import Foundation

enum PlaybackState: String, Sendable {
    case playing
    case paused
    case stopped
}

struct TrackSnapshot: Sendable, Equatable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let position: TimeInterval
    let state: PlaybackState
    let embeddedLyrics: String

    var key: TrackKey {
        TrackKey(
            title: title.normalizedTrackComponent,
            artist: artist.normalizedTrackComponent,
            album: album.normalizedTrackComponent,
            duration: Int(duration.rounded())
        )
    }

    var displayName: String {
        artist.isEmpty ? title : "\(title) — \(artist)"
    }
}

struct TrackKey: Hashable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: Int
}

enum MusicReadResult: Sendable {
    case notRunning
    case noTrack
    case unauthorized
    case failed(String)
    case track(TrackSnapshot)
}

private extension String {
    var normalizedTrackComponent: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
