import SwiftUI
import AppKit
import ImageIO

@MainActor final class MusicModule: BuiltInModule {
    @Published private(set) var snapshot: PlaybackSnapshot?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var artworkColor = Color.mint
    @Published private(set) var status = "Проверяю проигрыватель…"
    @Published private(set) var commandBusy = false
    private let service = MediaService()
    private let preferences: PreferencesStore
    private var artworkTask: Task<Void, Never>?
    private var artworkKey = ""
    private var lastArtworkData: Data?
    private var pausedAt: Date?
    private var clock: Timer?
    private var demoUntil: Date?
    private var previouslyActive = false
    @Published private(set) var lyricLines: [MusicLyricLine] = []
    @Published private(set) var plainLyrics = ""
    @Published private(set) var lyricsStatus = "Текст ещё не загружен"
    @Published private(set) var lyricsLoading = false
    private var lyricsTask: Task<Void, Never>?
    private var lyricsKey = ""
    private var lyricsCache: [String: MusicLyricsDocument] = [:]
    private func resetLyrics() {
        lyricsTask?.cancel(); lyricsKey = ""; lyricLines = []; plainLyrics = ""; lyricsLoading = false
        lyricsStatus = "Текст ещё не загружен"
    }
    func loadLyrics(retry: Bool = false) {
        guard let value = snapshot, value.source != .demo else { lyricsStatus = "Текст доступен для реального трека"; return }
        let key = value.id + "|" + value.title + "|" + value.artist
        guard retry || lyricsKey != key else { return }
        lyricsTask?.cancel(); lyricsKey = key; lyricLines = []; plainLyrics = ""
        if let cached = lyricsCache[key] { applyLyrics(cached); return }
        lyricsLoading = true; lyricsStatus = "Ищу текст в LRCLIB…"
        lyricsTask = Task { [weak self] in
            do {
                let document = try await MusicLyricsDocument.fetch(value)
                guard let self, !Task.isCancelled, self.lyricsKey == key else { return }
                if self.lyricsCache.count >= 40 { self.lyricsCache.removeAll() }
                self.lyricsCache[key] = document; self.applyLyrics(document)
            } catch {
                guard let self, !Task.isCancelled, self.lyricsKey == key else { return }
                self.lyricsLoading = false
                self.lyricsStatus = (error as? MusicLyricsError) == .notFound ? "Для этой версии трека текст не найден" : "Не удалось загрузить текст. Проверь соединение и повтори."
            }
        }
    }
    private func applyLyrics(_ document: MusicLyricsDocument) {
        lyricLines = document.lines; plainLyrics = document.plain; lyricsLoading = false
        lyricsStatus = document.instrumental ? "Инструментальный трек" : (document.lines.isEmpty ? (document.plain.isEmpty ? "Текст не найден" : "Текст без синхронизации · LRCLIB") : "Синхронизированный текст · LRCLIB")
    }
    init(preferences: PreferencesStore) {
        self.preferences = preferences; super.init(id: .music)
        service.onSnapshot = { [weak self] in self?.receive($0) }
        service.onStatus = { [weak self] in self?.status = $0 }
    }
    override var accent: Color { preferences.value.artworkAccent ? artworkColor : .mint }
    override var activity: ModuleActivity? {
        guard let snapshot, snapshot.isPlaying || (pausedAt.map { Date().timeIntervalSince($0) < preferences.value.pauseTimeout } ?? false) else { return nil }
        return ModuleActivity(token: snapshot.id + (snapshot.isPlaying ? ":play" : ":pause"), title: snapshot.title, detail: snapshot.artist)
    }
    override func start() {
        guard clock == nil else { return }
        service.spotifyEnabled = preferences.value.spotifyEnabled; service.start()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    override func stop() { clock?.invalidate(); clock = nil; artworkTask?.cancel(); resetLyrics(); service.stop() }
    func applyPreferences() {
        service.spotifyEnabled = preferences.value.spotifyEnabled
        if let snapshot, snapshot.source != .demo, !SourcePolicy.permits(bundleID: snapshot.bundleID, exclusions: preferences.value.excludedBundleIDs) { receive(nil) }
        changed()
    }
    private func tick() {
        if let end = demoUntil, Date() >= end { demoUntil = nil; receive(nil); Task { await service.poll() } }
        let active = activity != nil
        if previouslyActive != active { previouslyActive = active; changed() }
    }
    private func receive(_ value: PlaybackSnapshot?) {
        guard demoUntil == nil else { return }
        guard let value, SourcePolicy.permits(bundleID: value.bundleID, exclusions: preferences.value.excludedBundleIDs) else {
            resetLyrics(); snapshot = nil; artwork = nil; pausedAt = nil; artworkKey = ""; artworkTask?.cancel(); changed(); return
        }
        if value.isPlaying { pausedAt = nil }
        else if pausedAt == nil { pausedAt = .now }
        if snapshot?.id != value.id { resetLyrics() }
        updateArtwork(value); snapshot = value; changed()
    }
    func connect() async { preferences.value.spotifyEnabled = true; service.spotifyEnabled = true; await service.reconnectSpotify() }
    func showDemo() {
        resetLyrics(); demoUntil = Date().addingTimeInterval(15); snapshot = .demo(now: .now); artwork = nil; pausedAt = nil; artworkTask?.cancel(); changed()
    }
    func endDemo() { demoUntil = nil; receive(nil); Task { await service.poll() } }
    override func pause() { if snapshot?.isPlaying == true { transport(.toggle) } }
    func transport(_ action: TransportAction) {
        guard !commandBusy, let snapshot, snapshot.source != .demo else { return }
        InteractionFeedback.tap(); commandBusy = true
        Task {
            if let error = await service.send(action, for: snapshot) { notify?(error) }
            commandBusy = false
            try? await Task.sleep(nanoseconds: 180_000_000); await service.poll()
        }
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        if region == .leading { return AnyView(AlbumArtwork(image: artwork, trackID: snapshot?.id ?? "", size: 24)) }
        return AnyView(Equalizer(playing: snapshot?.isPlaying == true, color: accent).frame(width: 20, height: 23))
    }
    override var expandedView: AnyView { AnyView(MusicPanel(module: self)) }
    override var minimalView: AnyView { AnyView(AlbumArtwork(image: artwork, trackID: snapshot?.id ?? "", size: 18)) }

    private func updateArtwork(_ value: PlaybackSnapshot) {
        let key = value.id + "|" + (value.artworkURL?.absoluteString ?? "embedded")
        if snapshot?.id != value.id { artwork = nil; artworkTask?.cancel(); artworkKey = "" }
        if let data = value.artworkData {
            if artworkKey != key || lastArtworkData != data { artworkKey = key; lastArtworkData = data; setImage(data) }
            return
        }
        guard let url = value.artworkURL, url.scheme == "https", artworkKey != key else { return }
        artworkKey = key; artworkTask?.cancel()
        artworkTask = Task { [weak self] in
            do {
                let data = try await Self.download(url)
                guard let self, self.artworkKey == key, !Task.isCancelled else { return }
                self.setImage(data)
            } catch { }
        }
    }
    private func setImage(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return }
        artwork = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
        artworkColor = Self.palette(cg); changed()
    }
    private nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 6
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.expectedContentLength <= 8_000_000 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation(); guard data.count < 8_000_000 else { throw URLError(.dataLengthExceedsMaximum) }; data.append(byte)
        }
        return data
    }
    private static func palette(_ image: CGImage) -> Color {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 8)); return true
        }
        guard success else { return .mint }
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[i]) / 255, green = Double(pixels[i + 1]) / 255, blue = Double(pixels[i + 2]) / 255
            let maximum = max(red, max(green, blue)); let minimum = min(red, min(green, blue))
            let w = max(0.05, maximum - minimum)
            if maximum > 0.18 { r += red * w; g += green * w; b += blue * w; weight += w }
        }
        guard weight > 0 else { return .mint }
        return Color(red: min(1, r / weight + 0.16), green: min(1, g / weight + 0.16), blue: min(1, b / weight + 0.16))
    }
}

@MainActor private struct MusicPanel: View {
    @ObservedObject var module: MusicModule
    @State private var showingLyrics = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 12) {
            if let value = module.snapshot {
                header(value)
                if showingLyrics {
                    lyrics(value)
                } else {
                    progress(value)
                }
                HStack(spacing: 28) {
                    MusicTransportButton(icon: "backward.end.fill", label: "Предыдущий трек", accent: module.accent, main: false) { module.transport(.previous) }
                    MusicTransportButton(icon: value.isPlaying ? "pause.fill" : "play.fill", label: value.isPlaying ? "Пауза" : "Воспроизвести", accent: module.accent, main: true) { module.transport(.toggle) }
                    MusicTransportButton(icon: "forward.end.fill", label: "Следующий трек", accent: module.accent, main: false) { module.transport(.next) }
                }.disabled(module.commandBusy || value.source == .demo).opacity(module.commandBusy ? 0.55 : 1)
                if !showingLyrics {
                    Text("Текст через LRCLIB: название, исполнитель и альбом будут отправлены сервису.")
                        .font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
                }
            } else {
                Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(module.accent)
                Text(module.status).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                ModuleButton(title: "Подключить Spotify", symbol: "link") { Task { await module.connect() } }
            }
        }.task(id: module.snapshot?.id) { if showingLyrics { module.loadLyrics() } }
    }
    private func header(_ value: PlaybackSnapshot) -> some View {
        HStack(spacing: 16) {
            AlbumArtwork(image: module.artwork, trackID: value.id, size: showingLyrics ? 44 : 80)
                .overlay(RoundedRectangle(cornerRadius: showingLyrics ? 8 : 14).stroke(.white.opacity(0.18), lineWidth: 0.7))
                .shadow(color: module.accent.opacity(0.22), radius: 14, y: 5)
            VStack(alignment: .leading, spacing: 5) {
                Text(value.title).font(.system(size: showingLyrics ? 15 : 19, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                Text(value.artist).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.64)).lineLimit(1)
                if !showingLyrics {
                    HStack(spacing: 5) {
                        Circle().fill(value.isPlaying ? module.accent : .white.opacity(0.4)).frame(width: 4, height: 4)
                        Text(value.source == .demo ? "Демонстрация" : value.isPlaying ? "Сейчас играет" : "На паузе").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.44))
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                InteractionFeedback.tap(); showingLyrics.toggle()
                if showingLyrics { module.loadLyrics() }
            } label: {
                Image(systemName: showingLyrics ? "music.note" : "quote.bubble.fill").font(.system(size: 14, weight: .medium))
                    .frame(width: 36, height: 36).foregroundStyle(showingLyrics ? module.accent : .white.opacity(0.7))
                    .background(.white.opacity(showingLyrics ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 12)).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(showingLyrics ? "Вернуться к проигрывателю" : "Загрузить текст песни через LRCLIB")
        }
    }
    private func progress(_ value: PlaybackSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = value.position(at: context.date)
            let fraction = value.duration > 0 ? min(1, max(0, position / value.duration)) : 0
            VStack(spacing: 7) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(LinearGradient(colors: [module.accent.opacity(0.65), module.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(0, geometry.size.width * fraction))
                    }
                }.frame(height: 4).accessibilityLabel("Прогресс воспроизведения")
                HStack {
                    Text(DisplayTime.clock(position)); Spacer()
                    Text(value.duration > 0 ? "−" + DisplayTime.clock(max(0, value.duration - position)) : "Прямой эфир")
                }.font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.44))
            }
        }
    }
    @ViewBuilder private func lyrics(_ value: PlaybackSnapshot) -> some View {
        if module.lyricsLoading {
            VStack(spacing: 8) { ProgressView().controlSize(.small); Text(module.lyricsStatus).font(.caption).foregroundStyle(.secondary) }.frame(height: 116)
        } else if !module.lyricLines.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let position = value.position(at: context.date)
                let activeID = module.lyricLines.last(where: { $0.time <= position })?.id
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(module.lyricLines) { line in
                                Text(line.text.isEmpty ? "♪" : line.text).font(.system(size: 19, weight: .bold))
                                    .foregroundStyle(activeID == line.id ? Color.white : Color.white.opacity(0.34))
                                    .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                            }
                        }.padding(.vertical, 35).padding(.horizontal, 2)
                    }.scrollIndicators(.hidden).frame(height: 116)
                        .onChange(of: activeID, initial: true) { _, id in
                            guard let id else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) { reader.scrollTo(id, anchor: .center) }
                        }
                }
            }
        } else if !module.plainLyrics.isEmpty {
            ScrollView { Text(module.plainLyrics).font(.system(size: 17, weight: .semibold)).lineSpacing(9).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 116)
        } else {
            VStack(spacing: 9) {
                Text(module.lyricsStatus).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Повторить поиск") { module.loadLyrics(retry: true) }.font(.caption)
            }.frame(height: 116)
        }
    }
}
@MainActor private struct MusicTransportButton: View {
    var icon: String; var label: String; var accent: Color; var main: Bool; var action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: main ? 23 : 19, weight: .semibold))
                .foregroundStyle(main ? Color.black : Color.white.opacity(0.9))
                .frame(width: main ? 54 : 44, height: main ? 54 : 44)
                .background(main ? accent : Color.white.opacity(hovered ? 0.13 : 0.05), in: Circle())
                .overlay(Circle().stroke(.white.opacity(main ? 0.2 : 0.06), lineWidth: 0.6))
                .scaleEffect(hovered ? 1.06 : 1).contentShape(Circle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.8), value: hovered)
            .accessibilityLabel(label)
    }
}

private enum MusicLyricsError: Error, Equatable { case notFound }
struct MusicLyricLine: Identifiable { var id: Int; var time: Double; var text: String }
private struct MusicLyricsDocument {
    var lines: [MusicLyricLine]; var plain: String; var instrumental: Bool
    private struct Response: Decodable { var plainLyrics: String?; var syncedLyrics: String?; var instrumental: Bool? }
    static func fetch(_ value: PlaybackSnapshot) async throws -> MusicLyricsDocument {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var query = [URLQueryItem(name: "track_name", value: value.title), URLQueryItem(name: "artist_name", value: value.artist)]
        if !value.album.isEmpty { query.append(URLQueryItem(name: "album_name", value: value.album)) }
        if value.duration.isFinite && value.duration > 0 { query.append(URLQueryItem(name: "duration", value: String(Int(value.duration.rounded())))) }
        components.queryItems = query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 10; request.setValue("NotchBeat/0.3", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 { throw MusicLyricsError.notFound }
        guard http.statusCode == 200, response.expectedContentLength <= 512_000 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes { try Task.checkCancellation(); guard data.count < 512_000 else { throw URLError(.dataLengthExceedsMaximum) }; data.append(byte) }
        let result = try JSONDecoder().decode(Response.self, from: data)
        return MusicLyricsDocument(lines: parse(result.syncedLyrics ?? ""), plain: String((result.plainLyrics ?? "").prefix(150_000)), instrumental: result.instrumental ?? false)
    }
    static func parse(_ text: String) -> [MusicLyricLine] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]"#) else { return [] }
        var rows: [(Double, String)] = []
        var offset = 0.0
        if let expression = try? NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text) {
            offset = (Double(text[range]) ?? 0) / 1000
        }
        for raw in text.components(separatedBy: .newlines).prefix(2000) {
            let matches = regex.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            guard let last = matches.last, let end = Range(last.range, in: raw)?.upperBound else { continue }
            let content = String(raw[end...]).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard let minuteRange = Range(match.range(at: 1), in: raw), let secondRange = Range(match.range(at: 2), in: raw),
                      let minute = Double(raw[minuteRange]), let second = Double(raw[secondRange]), second < 60 else { continue }
                var fraction = 0.0
                if let range = Range(match.range(at: 3), in: raw) { fraction = (Double(raw[range]) ?? 0) / pow(10, Double(raw[range].count)) }
                rows.append((max(0, minute * 60 + second + fraction + offset), content))
            }
        }
        return rows.sorted { $0.0 < $1.0 }.enumerated().map { MusicLyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
