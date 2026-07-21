import AppKit
import Foundation

enum MusicCommand: Sendable {
    case previousTrack
    case playPause
    case nextTrack
}

actor MusicAppClient {
    private let musicBundleIdentifier = "com.apple.Music"

    private static let nowPlayingMetadataSource = """
    tell application "Music"
        if player state is stopped then return {"stopped", "", "", "", "0", "0"}

        set currentItem to current track
        return {(player state as text), (name of currentItem), (artist of currentItem), (album of currentItem), (duration of currentItem as text), (player position as text)}
    end tell
    """

    private static let nowPlayingWithLyricsSource = """
    tell application "Music"
        if player state is stopped then return {"stopped", "", "", "", "0", "0", ""}

        set currentItem to current track
        set itemLyrics to ""
        try
            set itemLyrics to lyrics of currentItem
        end try

        return {(player state as text), (name of currentItem), (artist of currentItem), (album of currentItem), (duration of currentItem as text), (player position as text), itemLyrics}
    end tell
    """

    private static let currentPlaylistSource = """
    tell application "Music"
        if player state is stopped then return ""
        try
            return name of current playlist
        on error
            return ""
        end try
    end tell
    """

    private static let currentArtworkSource = """
    tell application "Music"
        if player state is stopped then return missing value
        try
            return raw data of artwork 1 of current track
        on error
            return missing value
        end try
    end tell
    """

    private lazy var nowPlayingMetadataScript = NSAppleScript(
        source: Self.nowPlayingMetadataSource
    )
    private lazy var nowPlayingWithLyricsScript = NSAppleScript(
        source: Self.nowPlayingWithLyricsSource
    )
    private lazy var currentPlaylistScript = NSAppleScript(
        source: Self.currentPlaylistSource
    )
    private lazy var currentArtworkScript = NSAppleScript(
        source: Self.currentArtworkSource
    )
    private var cachedTrackKey: TrackKey?
    private var cachedEmbeddedLyrics = ""

    func nowPlaying() -> MusicReadResult {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: musicBundleIdentifier
        ).isEmpty else {
            clearNowPlayingCache()
            return .notRunning
        }

        let metadataResult = readNowPlaying(
            using: nowPlayingMetadataScript,
            includesLyrics: false
        )
        guard case .track(let metadata) = metadataResult else {
            clearNowPlayingCache()
            return metadataResult
        }

        if metadata.key == cachedTrackKey {
            return .track(TrackSnapshot(
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                duration: metadata.duration,
                position: metadata.position,
                state: metadata.state,
                embeddedLyrics: cachedEmbeddedLyrics
            ))
        }

        // Reading complete lyrics through AppleScript is comparatively expensive.
        // Re-read the full snapshot only on a track transition so its metadata and
        // lyrics still come from the same Apple Music item.
        let detailedResult = readNowPlaying(
            using: nowPlayingWithLyricsScript,
            includesLyrics: true
        )
        if case .track(let track) = detailedResult {
            cachedTrackKey = track.key
            cachedEmbeddedLyrics = track.embeddedLyrics
        } else {
            clearNowPlayingCache()
        }
        return detailedResult
    }

    private func readNowPlaying(
        using script: NSAppleScript?,
        includesLyrics: Bool
    ) -> MusicReadResult {
        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                return .unauthorized
            }

            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "未知的 AppleScript 错误"
            return .failed(message)
        }

        let requiredItemCount = includesLyrics ? 7 : 6
        guard let result, result.numberOfItems >= requiredItemCount else {
            return .noTrack
        }

        let stateText = result.atIndex(1)?.stringValue ?? "stopped"
        if stateText == "stopped" {
            return .noTrack
        }

        let title = result.atIndex(2)?.stringValue ?? ""
        guard !title.isEmpty else {
            return .noTrack
        }

        return .track(TrackSnapshot(
            title: title,
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            duration: Double(result.atIndex(5)?.stringValue ?? "0") ?? 0,
            position: Double(result.atIndex(6)?.stringValue ?? "0") ?? 0,
            state: stateText == "playing" ? .playing : .paused,
            embeddedLyrics: includesLyrics
                ? result.atIndex(7)?.stringValue ?? ""
                : ""
        ))
    }

    private func clearNowPlayingCache() {
        cachedTrackKey = nil
        cachedEmbeddedLyrics = ""
    }

    func send(_ command: MusicCommand) {
        let statement: String
        switch command {
        case .previousTrack:
            statement = "back track"
        case .playPause:
            statement = "playpause"
        case .nextTrack:
            statement = "next track"
        }

        let source = """
        tell application "Music"
            \(statement)
        end tell
        """

        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
    }

    func seek(to position: TimeInterval) {
        let safePosition = max(0, position)
        let seconds = String(
            format: "%.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            safePosition
        )
        let source = """
        tell application "Music"
            set player position to \(seconds)
        end tell
        """

        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
    }

    func playlistPersistentID(
        named name: String,
        matching tracks: [LibraryTrackSnapshot]
    ) -> String? {
        let sampleTracks = Array(tracks.prefix(3))
        guard !sampleTracks.isEmpty else { return nil }

        let escapedName = escapedAppleScriptText(name)
        let titles = appleScriptList(sampleTracks.map(\.title))
        let artists = appleScriptList(sampleTracks.map(\.artist))
        let albums = appleScriptList(sampleTracks.map(\.album))
        let source = """
        tell application "Music"
            set candidatePlaylists to every playlist whose name is "\(escapedName)"
            if (count of candidatePlaylists) is 0 then return ""
            if (count of candidatePlaylists) is 1 then
                try
                    return persistent ID of item 1 of candidatePlaylists
                on error
                    return ""
                end try
            end if

            set targetTitles to \(titles)
            set targetArtists to \(artists)
            set targetAlbums to \(albums)
            set expectedTrackCount to \(tracks.count)
            set bestPlaylist to missing value
            set bestScore to -1
            set bestCountDelta to 2147483647

            repeat with candidatePlaylist in candidatePlaylists
                try
                    set candidateTrackCount to count of tracks of candidatePlaylist
                    set candidateScore to 0

                    repeat with targetIndex from 1 to count of targetTitles
                        set targetTitle to item targetIndex of targetTitles
                        set targetArtist to item targetIndex of targetArtists
                        set targetAlbum to item targetIndex of targetAlbums

                        set matchingTracks to search candidatePlaylist for targetTitle only names
                        repeat with candidateTrack in matchingTracks
                            set titleMatches to ((name of candidateTrack) is targetTitle)
                            set artistMatches to (targetArtist is "") or ((artist of candidateTrack) is targetArtist)
                            set albumMatches to (targetAlbum is "") or ((album of candidateTrack) is targetAlbum)
                            if titleMatches and artistMatches and albumMatches then
                                set candidateScore to candidateScore + 1
                                exit repeat
                            end if
                        end repeat
                    end repeat

                    set countDelta to candidateTrackCount - expectedTrackCount
                    if countDelta < 0 then set countDelta to -countDelta
                    if candidateScore > bestScore or (candidateScore is bestScore and countDelta < bestCountDelta) then
                        set bestPlaylist to candidatePlaylist
                        set bestScore to candidateScore
                        set bestCountDelta to countDelta
                    end if
                end try
            end repeat

            if bestPlaylist is missing value or bestScore is 0 then return ""
            try
                return persistent ID of bestPlaylist
            on error
                return ""
            end try
        end tell
        """

        var errorInfo: NSDictionary?
        let value = NSAppleScript(source: source)?
            .executeAndReturnError(&errorInfo)
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func playPlaylist(named name: String, persistentID: String? = nil) {
        let escapedName = escapedAppleScriptText(name)
        let playlistQuery = playlistQuery(named: escapedName, persistentID: persistentID)
        let source = """
        tell application "Music"
            set matchingPlaylists to \(playlistQuery)
            if (count of matchingPlaylists) > 0 then
                play item 1 of matchingPlaylists
            end if
        end tell
        """

        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
    }

    func playTrack(
        _ track: LibraryTrackSnapshot,
        fallbackIndex index: Int,
        inPlaylistNamed name: String,
        playlistPersistentID: String? = nil
    ) {
        guard index >= 0 else { return }
        let escapedName = escapedAppleScriptText(name)
        let escapedTitle = escapedAppleScriptText(track.title)
        let escapedArtist = escapedAppleScriptText(track.artist)
        let escapedAlbum = escapedAppleScriptText(track.album)
        let playlistQuery = playlistQuery(
            named: escapedName,
            persistentID: playlistPersistentID
        )
        let appleScriptIndex = index + 1
        let source = """
        tell application "Music"
            set matchingPlaylists to \(playlistQuery)
            if (count of matchingPlaylists) > 0 then
                set selectedPlaylist to item 1 of matchingPlaylists
                set targetTitle to "\(escapedTitle)"
                set targetArtist to "\(escapedArtist)"
                set targetAlbum to "\(escapedAlbum)"
                set selectedTrack to missing value
                set titleFallbackTrack to missing value
                set matchingTracks to search selectedPlaylist for targetTitle only names

                repeat with candidateTrack in matchingTracks
                    set titleMatches to false
                    set artistMatches to (targetArtist is "")
                    set albumMatches to (targetAlbum is "")
                    try
                        set titleMatches to ((name of candidateTrack) is targetTitle)
                        if targetArtist is not "" then
                            set artistMatches to ((artist of candidateTrack) is targetArtist)
                        end if
                        if targetAlbum is not "" then
                            set albumMatches to ((album of candidateTrack) is targetAlbum)
                        end if
                    end try

                    if titleMatches and titleFallbackTrack is missing value then
                        set titleFallbackTrack to candidateTrack
                    end if
                    if titleMatches and artistMatches and albumMatches then
                        set selectedTrack to candidateTrack
                        exit repeat
                    end if
                end repeat

                if selectedTrack is missing value then
                    set selectedTrack to titleFallbackTrack
                end if
                if selectedTrack is missing value and (count of tracks of selectedPlaylist) >= \(appleScriptIndex) then
                    set selectedTrack to track \(appleScriptIndex) of selectedPlaylist
                end if
                if selectedTrack is not missing value then
                    play selectedTrack
                end if
            end if
        end tell
        """

        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
    }

    private func escapedAppleScriptText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func appleScriptList(_ values: [String]) -> String {
        let items = values.map { "\"\(escapedAppleScriptText($0))\"" }
        return "{\(items.joined(separator: ", "))}"
    }

    private func playlistQuery(named escapedName: String, persistentID: String?) -> String {
        if let persistentID, !persistentID.isEmpty {
            let escapedID = escapedAppleScriptText(persistentID)
            return "every playlist whose persistent ID is \"\(escapedID)\""
        }
        return "every playlist whose name is \"\(escapedName)\""
    }

    func currentPlaylistName() -> String? {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: musicBundleIdentifier
        ).isEmpty else { return nil }

        var errorInfo: NSDictionary?
        let value = currentPlaylistScript?
            .executeAndReturnError(&errorInfo)
            .stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func currentArtworkData() -> Data? {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: musicBundleIdentifier
        ).isEmpty else { return nil }

        var errorInfo: NSDictionary?
        return currentArtworkScript?
            .executeAndReturnError(&errorInfo)
            .data
    }
}
