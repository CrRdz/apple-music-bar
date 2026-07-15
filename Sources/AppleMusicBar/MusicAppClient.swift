import AppKit
import Foundation

enum MusicCommand: Sendable {
    case previousTrack
    case playPause
    case nextTrack
}

actor MusicAppClient {
    private let musicBundleIdentifier = "com.apple.Music"

    func nowPlaying() -> MusicReadResult {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: musicBundleIdentifier
        ).isEmpty else {
            return .notRunning
        }

        let source = """
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

        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                return .unauthorized
            }

            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "未知的 AppleScript 错误"
            return .failed(message)
        }

        guard let result, result.numberOfItems >= 7 else {
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

        let state: PlaybackState = stateText == "playing" ? .playing : .paused
        let snapshot = TrackSnapshot(
            title: title,
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            duration: Double(result.atIndex(5)?.stringValue ?? "0") ?? 0,
            position: Double(result.atIndex(6)?.stringValue ?? "0") ?? 0,
            state: state,
            embeddedLyrics: result.atIndex(7)?.stringValue ?? ""
        )

        return .track(snapshot)
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

    func currentArtworkData() -> Data? {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: musicBundleIdentifier
        ).isEmpty else { return nil }

        let source = """
        tell application "Music"
            if player state is stopped then return missing value
            try
                return raw data of artwork 1 of current track
            on error
                return missing value
            end try
        end tell
        """

        var errorInfo: NSDictionary?
        return NSAppleScript(source: source)?
            .executeAndReturnError(&errorInfo)
            .data
    }
}
