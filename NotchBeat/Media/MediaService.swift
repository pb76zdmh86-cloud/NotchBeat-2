import AppKit
import Foundation

@MainActor final class MediaService {
    private let remote = NBMediaRemoteBridge()
    private let spotify = SpotifyBridge()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var busy = false
    private var generation = 0
    private var failures = 0
    private var lastProbe = Date.distantPast
    private var lastGood = Date.distantPast
    private var permissionAttempt = false
    private(set) var automationDenied = false
    var spotifyEnabled = false
    var onSnapshot: ((PlaybackSnapshot?) -> Void)?
    var onStatus: ((String) -> Void)?

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification", "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"] {
            observers.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.poll() }
            })
        }
        Task { await poll() }
    }

    func stop() {
        timer?.invalidate(); timer = nil; generation += 1
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
    }

    func reconnectSpotify() async {
        automationDenied = false
        permissionAttempt = true
        lastProbe = .distantPast; failures = 0
        while busy && !Task.isCancelled { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard !Task.isCancelled else { return }
        await poll()
    }

    private func readRemote() async -> PlaybackSnapshot? {
        await withCheckedContinuation { continuation in
            remote.read { raw in
                guard let raw, let title = raw["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else {
                    continuation.resume(returning: nil); return
                }
                let duration = (raw["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? 0
                var elapsed = (raw["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? 0
                let rate = (raw["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
                let playing = (raw["NBIsPlaying"] as? NSNumber)?.boolValue ?? (rate > 0)
                if playing, let timestamp = raw["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
                    elapsed += max(0, Date().timeIntervalSince(timestamp)) * (rate > 0 ? rate : 1)
                }
                let artist = raw["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
                let album = raw["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
                let bundleID = raw["NBBundleID"] as? String
                let identity = raw["kMRMediaRemoteNowPlayingInfoUniqueIdentifier"] as? String ?? "\(title)|\(artist)|\(album)"
                let artwork = raw["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                continuation.resume(returning: PlaybackSnapshot(id: "mr:\(bundleID ?? "unknown"):\(identity)",
                    title: title, artist: artist, album: album, bundleID: bundleID, source: .mediaRemote,
                    isPlaying: playing, duration: duration.isFinite ? max(0, duration) : 0,
                    elapsed: elapsed.isFinite ? max(0, elapsed) : 0, sampledAt: .now,
                    artworkData: (artwork?.count ?? 0) <= 8_000_000 ? artwork : nil))
            }
        }
    }

    func poll() async {
        guard !busy else { return }
        busy = true
        let currentGeneration = generation
        defer { busy = false }
        if remote.available && (failures < 3 || Date().timeIntervalSince(lastProbe) >= 30) {
            lastProbe = .now
            let snapshot = await readRemote()
            guard currentGeneration == generation else { return }
            if let snapshot {
                failures = 0; lastGood = .now
                onStatus?("MediaRemote · системный источник")
                onSnapshot?(snapshot)
                return
            }
            failures += 1
        }
        guard spotifyEnabled else {
            onStatus?("MediaRemote не дал данных. Для Spotify нажми «Подключить Spotify».")
            if Date().timeIntervalSince(lastGood) > 3 { onSnapshot?(nil) }
            return
        }
        if automationDenied {
            onStatus?("Нет разрешения «Автоматизация» для Spotify")
            onSnapshot?(nil)
            return
        }
        let permission = permissionAttempt; permissionAttempt = false
        let response = await spotify.read(requestingPermission: permission)
        guard currentGeneration == generation else { return }
        switch response {
        case .snapshot(let snapshot):
            lastGood = .now
            onStatus?("Spotify · локальный резервный источник")
            onSnapshot?(snapshot)
        case .stopped:
            onStatus?("Открой Spotify и включи трек")
            if Date().timeIntervalSince(lastGood) > 3 { onSnapshot?(nil) }
        case .denied:
            automationDenied = true
            onStatus?("Доступ к Spotify запрещён. Включи его в «Автоматизация» и нажми «Подключить Spotify».")
            onSnapshot?(nil)
        case .failed(let message):
            onStatus?(message)
            if Date().timeIntervalSince(lastGood) > 3 { onSnapshot?(nil) }
        }
    }

    func send(_ action: TransportAction, for snapshot: PlaybackSnapshot) async -> String? {
        if snapshot.source == .spotify { return await spotify.command(action) }
        guard snapshot.source == .mediaRemote else { return nil }
        // Do not send a global command to a different app that became active since rendering.
        guard let current = await readRemote(), current.bundleID == snapshot.bundleID, current.id == snapshot.id else {
            await poll(); return "Проигрыватель сменился. Попробуй ещё раз."
        }
        let command: Int
        switch action { case .toggle: command = 2; case .next: command = 4; case .previous: command = 5 }
        guard remote.sendCommand(command) else { return "macOS не приняла команду MediaRemote" }
        return nil
    }
}
