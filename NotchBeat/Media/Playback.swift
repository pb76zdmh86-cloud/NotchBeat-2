import Foundation

enum PlaybackSource: String { case mediaRemote = "MediaRemote", spotify = "Spotify · локально", demo = "Демонстрация" }
enum TransportAction: String { case toggle, next, previous }

struct PlaybackSnapshot {
    var id: String
    var title: String
    var artist: String
    var album: String
    var bundleID: String?
    var source: PlaybackSource
    var isPlaying: Bool
    var duration: Double
    var elapsed: Double
    var sampledAt: Date
    var artworkData: Data? = nil
    var artworkURL: URL? = nil

    func position(at date: Date) -> Double {
        let advanced = elapsed + (isPlaying ? max(0, date.timeIntervalSince(sampledAt)) : 0)
        guard duration.isFinite && duration > 0 else { return 0 }
        return min(duration, max(0, advanced))
    }

    static func demo(now: Date) -> PlaybackSnapshot {
        PlaybackSnapshot(id: "demo", title: "Твой музыкальный остров", artist: "Демонстрация · это не реальный трек", album: "NotchBeat",
                         bundleID: nil, source: .demo, isPlaying: true, duration: 180, elapsed: 42, sampledAt: now)
    }
}
