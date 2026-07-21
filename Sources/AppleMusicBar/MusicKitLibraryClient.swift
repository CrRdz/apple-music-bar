import Foundation
import MusicKit

struct LibraryPlaylistSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let artworkURL: URL?
    let isFolder: Bool

    init(id: String, name: String, artworkURL: URL?, isFolder: Bool = false) {
        self.id = id
        self.name = name
        self.artworkURL = artworkURL
        self.isFolder = isFolder
    }
}

struct LibraryTrackSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let album: String
    let artist: String
    let artworkURL: URL?
}

struct LibraryPlaylistContent: Equatable, Sendable {
    let tracks: [LibraryTrackSnapshot]
    let artworkURL: URL?
}

enum PlaylistDisplayFilter {
    static func visiblePlaylists(
        from playlists: [LibraryPlaylistSnapshot],
        hiddenIDs: Set<String>
    ) -> [LibraryPlaylistSnapshot] {
        playlists.filter { !$0.isFolder && !hiddenIDs.contains($0.id) }
    }

    static func validHiddenIDs(
        _ hiddenIDs: Set<String>,
        in playlists: [LibraryPlaylistSnapshot]
    ) -> Set<String> {
        hiddenIDs.intersection(playlists.filter { !$0.isFolder }.map(\.id))
    }
}

enum MusicKitLibraryError: LocalizedError, Equatable {
    case accessDenied
    case accessRestricted
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Apple Music library access was denied."
        case .accessRestricted:
            return "Apple Music library access is restricted."
        case .unavailable(let message):
            return message
        }
    }
}

actor MusicKitLibraryClient {
    private let artworkCache: NSCache<NSURL, NSData> = {
        let cache = NSCache<NSURL, NSData>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private var artworkRequests: [URL: Task<Data?, Never>] = [:]
    private var playlistsByID: [String: Playlist] = [:]
    private var contentCache: [String: LibraryPlaylistContent] = [:]

    func loadPlaylists() async throws -> [LibraryPlaylistSnapshot] {
        let status: MusicAuthorization.Status
        switch MusicAuthorization.currentStatus {
        case .notDetermined:
            status = await MusicAuthorization.request()
        case let current:
            status = current
        }

        switch status {
        case .authorized:
            break
        case .denied:
            throw MusicKitLibraryError.accessDenied
        case .restricted:
            throw MusicKitLibraryError.accessRestricted
        case .notDetermined:
            throw MusicKitLibraryError.unavailable("Apple Music authorization did not complete.")
        @unknown default:
            throw MusicKitLibraryError.unavailable("Unknown Apple Music authorization state.")
        }

        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 100
            var batch = try await request.response().items
            var playlists = Array(batch)

            while batch.hasNextBatch {
                guard let nextBatch = try await batch.nextBatch(limit: 100) else { break }
                playlists.append(contentsOf: nextBatch)
                batch = nextBatch
            }

            playlistsByID = Dictionary(
                uniqueKeysWithValues: playlists.map { ($0.id.rawValue, $0) }
            )
            contentCache.removeAll()

            return playlists
                .map {
                    LibraryPlaylistSnapshot(
                        id: $0.id.rawValue,
                        name: $0.name,
                        artworkURL: $0.artwork?.url(width: 180, height: 180),
                        isFolder: $0.playParameters == nil && $0.url == nil
                    )
                }
                .sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        } catch let error as MusicKitLibraryError {
            throw error
        } catch {
            throw MusicKitLibraryError.unavailable(error.localizedDescription)
        }
    }

    func loadContent(for playlistID: String) async throws -> LibraryPlaylistContent {
        if let cached = contentCache[playlistID] { return cached }
        guard let playlist = playlistsByID[playlistID] else {
            throw MusicKitLibraryError.unavailable("The selected playlist is no longer available.")
        }

        do {
            let detailedPlaylist = try await playlist.with(.tracks)
            playlistsByID[playlistID] = detailedPlaylist

            var tracks: [Track] = []
            if var batch = detailedPlaylist.tracks {
                tracks.append(contentsOf: batch)
                while batch.hasNextBatch {
                    guard let nextBatch = try await batch.nextBatch(limit: 100) else { break }
                    tracks.append(contentsOf: nextBatch)
                    batch = nextBatch
                }
            }

            let snapshots = tracks.enumerated().map { index, track in
                LibraryTrackSnapshot(
                    id: "\(track.id.rawValue)-\(index)",
                    title: track.title,
                    album: track.albumTitle ?? "",
                    artist: track.artistName,
                    artworkURL: track.artwork?.url(width: 96, height: 96)
                )
            }
            let artworkURL = detailedPlaylist.artwork?.url(width: 180, height: 180)
                ?? snapshots.lazy.compactMap(\.artworkURL).first
            let content = LibraryPlaylistContent(tracks: snapshots, artworkURL: artworkURL)
            contentCache[playlistID] = content
            return content
        } catch let error as MusicKitLibraryError {
            throw error
        } catch {
            throw MusicKitLibraryError.unavailable(error.localizedDescription)
        }
    }

    func artworkData(at url: URL) async -> Data? {
        if let cached = artworkCache.object(forKey: url as NSURL) {
            return cached as Data
        }
        if let request = artworkRequests[url] {
            return await request.value
        }

        let request = Task<Data?, Never> {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard
                    let response = response as? HTTPURLResponse,
                    (200..<300).contains(response.statusCode),
                    !data.isEmpty
                else { return nil }
                return data
            } catch {
                return nil
            }
        }
        artworkRequests[url] = request
        let data = await request.value
        artworkRequests.removeValue(forKey: url)
        if let data {
            artworkCache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        }
        return data
    }
}
