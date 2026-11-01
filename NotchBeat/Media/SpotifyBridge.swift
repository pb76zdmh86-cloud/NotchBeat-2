import AppKit
import Foundation

enum SpotifyReadResult {
    case snapshot(PlaybackSnapshot)
    case stopped
    case denied
    case failed(String)
}

private struct ScriptResponse: Sendable {
    var output: Data
    var error: String
    var code: Int32
}

/// A child process keeps Apple Events waits off the UI thread. All scripts are constants.
private enum LocalScript {
    static func run(_ source: String, timeoutSeconds: Double = 4) -> ScriptResponse {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", source]
        let stdout = Pipe(); let stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() }
        catch { return ScriptResponse(output: Data(), error: error.localizedDescription, code: -1) }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
        // The script truncates all strings, so output cannot fill the pipe buffers.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        return ScriptResponse(output: data, error: String(data: errorData, encoding: .utf8) ?? "", code: process.terminationStatus)
    }
}

@MainActor final class SpotifyBridge {
    private struct Payload: Decodable {
        var running: Bool
        var id: String?
        var title: String?
        var artist: String?
        var album: String?
        var artwork: String?
        var duration: Double?
        var position: Double?
        var playing: Bool?
    }

    private nonisolated static let readScript = """
    (function () {
      var app = Application('com.spotify.client');
      if (!app.running()) return JSON.stringify({running:false});
      var state = String(app.playerState());
      if (state === 'stopped') return JSON.stringify({running:false});
      var t = app.currentTrack();
      function str(v, limit) { return String(v || '').slice(0, limit); }
      var art = '';
      try { art = str(t.artworkUrl(), 2048); } catch (_) {}
      return JSON.stringify({running:true, id:str(t.id(),512), title:str(t.name(),512),
        artist:str(t.artist(),512), album:str(t.album(),512), artwork:art,
        duration:Number(t.duration()) / 1000, position:Number(app.playerPosition()),
        playing:state === 'playing'});
    })();
    """

    func read(requestingPermission: Bool = false) async -> SpotifyReadResult {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return .stopped }
        let result = await Task.detached(priority: .utility) { LocalScript.run(Self.readScript, timeoutSeconds: requestingPermission ? 45 : 4) }.value
        if result.error.contains("-1743") || result.error.localizedCaseInsensitiveContains("not authorized") { return .denied }
        guard result.code == 0 else { return .failed("Spotify не ответил. Проверь, что открыт настольный Spotify, и повтори подключение.") }
        guard let value = try? JSONDecoder().decode(Payload.self, from: result.output) else { return .failed("Spotify вернул неизвестный формат данных") }
        guard value.running, let title = value.title, !title.isEmpty else { return .stopped }
        let seconds = value.duration ?? 0
        let elapsed = value.position ?? 0
        let art = value.artwork.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil }
        return .snapshot(PlaybackSnapshot(id: "spotify:\(value.id ?? title)", title: title,
            artist: value.artist ?? "", album: value.album ?? "", bundleID: "com.spotify.client", source: .spotify,
            isPlaying: value.playing ?? false, duration: seconds.isFinite ? max(0, seconds) : 0,
            elapsed: elapsed.isFinite ? max(0, elapsed) : 0, sampledAt: .now, artworkURL: art))
    }

    func command(_ action: TransportAction) async -> String? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { return "Spotify закрыт" }
        let method: String
        switch action { case .toggle: method = "playpause"; case .next: method = "nextTrack"; case .previous: method = "previousTrack" }
        // method is a closed enum mapping, never user-controlled script text.
        let source = "var s = Application('com.spotify.client'); if (s.running()) { s.\(method)(); }"
        let result = await Task.detached(priority: .userInitiated) { LocalScript.run(source) }.value
        if result.code == 0 { return nil }
        if result.error.contains("-1743") { return "Разреши NotchBeat управлять Spotify в разделе «Автоматизация»" }
        return "Не удалось отправить команду Spotify"
    }
}
