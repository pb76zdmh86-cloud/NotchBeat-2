import SwiftUI
import AppKit
import ScreenCaptureKit
import AVFoundation
import UniformTypeIdentifiers

enum CaptureState: Equatable { case idle, starting, screen, microphone, pausedMicrophone, finishing, saved, failed }

@MainActor final class RecordingModule: BuiltInModule, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput, AVAudioRecorderDelegate {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var status = "Запись из NotchBeat"
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastSavedURL: URL?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var audio: AVAudioRecorder?
    private var destination: URL?
    private var staged: URL?
    private var token = UUID()
    private var pulseUntil = Date.distantPast
    var selectedScreen: (() -> NSScreen?)?
    override init(id: ModuleID = .recording) { super.init(id: id) }
    var capturing: Bool { state == .screen || state == .microphone || state == .pausedMicrophone || state == .starting || state == .finishing }
    override var accent: Color { .red }
    override var activity: ModuleActivity? {
        guard capturing || Date() < pulseUntil else { return nil }
        return ModuleActivity(token: "\(token):\(String(describing: state))", title: status, detail: destination?.lastPathComponent ?? "")
    }
    func choose(screen: Bool) {
        guard !capturing else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [screen ? .mpeg4Movie : .mpeg4Audio]
        panel.nameFieldStringValue = "NotchBeat-\(Int(Date().timeIntervalSince1970)).\(screen ? "mp4" : "m4a")"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if screen { await self?.beginScreen(destination: url) }
                else { await self?.beginMicrophone(destination: url) }
            }
        }
    }
    private func prepare(_ destination: URL, ext: String) {
        self.destination = destination; token = UUID(); state = .starting; lastSavedURL = nil
        staged = FileManager.default.temporaryDirectory.appendingPathComponent("NotchBeat-\(token).\(ext)")
        status = "Подготовка записи…"; changed()
    }
    private func beginScreen(destination: URL) async {
        guard let screen = selectedScreen?() else { notify?("Подключи выбранный монитор перед записью"); return }
        prepare(destination, ext: "mp4")
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == screen.displayNumber }), let staged else { throw URLError(.cannotCreateFile) }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = min(1, 1920.0 / Double(display.width))
            config.width = max(2, Int(Double(display.width) * scale) / 2 * 2)
            config.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 5; config.capturesAudio = true; config.excludesCurrentProcessAudio = true
            config.captureMicrophone = false; config.showsCursor = true
            let recording = SCRecordingOutputConfiguration(); recording.outputURL = staged
            recording.outputFileType = .mp4; recording.videoCodecType = .h264
            let sink = SCRecordingOutput(configuration: recording, delegate: self)
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            let samples = DispatchQueue(label: "NotchBeat.capture.samples")
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: samples)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: samples)
            try capture.addRecordingOutput(sink)
            stream = capture; output = sink
            try await capture.startCapture()
            state = .screen; startedAt = .now; status = "Идёт запись экрана"; changed()
        } catch { fail("Запись экрана недоступна. Разреши её в «Конфиденциальность и безопасность → Запись экрана и системного аудио», затем повтори. \(error.localizedDescription)") }
    }
    private func beginMicrophone(destination: URL) async {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { notify?("Разреши NotchBeat доступ к микрофону в системных настройках"); return }
        prepare(destination, ext: "m4a")
        do {
            guard let staged else { throw URLError(.cannotCreateFile) }
            let recorder = try AVAudioRecorder(url: staged, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
            recorder.delegate = self
            guard recorder.record() else { throw URLError(.cannotCreateFile) }
            audio = recorder; state = .microphone; startedAt = .now; status = "Идёт запись микрофона"; changed()
        } catch { fail("Не удалось начать запись: \(error.localizedDescription)") }
    }
    override func pause() {
        if state == .microphone { audio?.pause(); state = .pausedMicrophone; status = "Микрофон на паузе"; changed() }
        else if state == .screen { notify?("Запись экрана продолжается: её можно завершить кнопкой «Стоп»") }
    }
    func resumeAudio() {
        guard state == .pausedMicrophone, audio?.record() == true else { return }
        state = .microphone; status = "Идёт запись микрофона"; changed()
    }
    func finish() async {
        if let audio {
            audio.stop(); self.audio = nil; completeSaving(); return
        }
        guard let stream, state == .screen else { return }
        state = .finishing; status = "Сохраняю запись…"; changed()
        do { try await stream.stopCapture() }
        catch { fail("Не удалось завершить запись: \(error.localizedDescription)") }
    }
    override func stop() { audio?.stop(); if stream != nil { Task { await finish() } } }
    private func completeSaving() {
        guard let staged, let destination else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
            else { try FileManager.default.moveItem(at: staged, to: destination) }
            lastSavedURL = destination; status = "Запись сохранена"; state = .saved; pulseUntil = Date().addingTimeInterval(8)
            self.staged = nil; stream = nil; output = nil; audio = nil; changed()
        } catch { fail("Запись осталась во временном файле: \(staged.path). Ошибка сохранения: \(error.localizedDescription)") }
    }
    private func fail(_ message: String) {
        if state == .failed && stream == nil && audio == nil { return }
        if let capture = stream { Task { try? await capture.stopCapture() } }
        audio?.stop(); audio = nil
        state = .failed; status = message; stream = nil; output = nil; notify?(message); changed()
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {}
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let identity = ObjectIdentifier(recordingOutput)
        Task { @MainActor [weak self] in
            guard let self, self.output.map({ ObjectIdentifier($0) }) == identity else { return }
            self.completeSaving()
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let message = error.localizedDescription; let identity = ObjectIdentifier(recordingOutput)
        Task { @MainActor [weak self] in
            guard let self, self.output.map({ ObjectIdentifier($0) }) == identity else { return }
            self.fail("Запись не удалась: \(message)")
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription; let identity = ObjectIdentifier(stream)
        Task { @MainActor [weak self] in
            guard let self, self.stream.map({ ObjectIdentifier($0) }) == identity else { return }
            self.fail("Запись прервана: \(message)")
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.audio.map({ ObjectIdentifier($0) }) == identity else { return }
            if flag { self.completeSaving() } else { self.fail("Запись микрофона прервана") }
        }
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        if region == .leading { return AnyView(Image(systemName: "record.circle.fill").foregroundStyle(accent)) }
        return AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(DisplayTime.clock(self.startedAt.map { context.date.timeIntervalSince($0) } ?? 0)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.red)
        })
    }
    override var expandedView: AnyView { AnyView(RecordingPanel(module: self)) }
}

@MainActor private struct RecordingPanel: View {
    @ObservedObject var module: RecordingModule
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle.fill").font(.system(size: 34)).foregroundStyle(.red)
            Text(module.status).font(.callout).multilineTextAlignment(.center).lineLimit(4)
            if module.capturing {
                if module.state == .microphone { ModuleButton(title: "Пауза", symbol: "pause.fill", tint: .red) { module.pause() } }
                if module.state == .pausedMicrophone { ModuleButton(title: "Продолжить", symbol: "play.fill", tint: .red) { module.resumeAudio() } }
                ModuleButton(title: "Завершить и сохранить", symbol: "stop.fill", tint: .red) { Task { await module.finish() } }
                    .disabled(module.state == .starting || module.state == .finishing)
            } else {
                HStack {
                    ModuleButton(title: "Экран + звук", symbol: "display", tint: .red) { module.choose(screen: true) }
                    ModuleButton(title: "Микрофон", symbol: "mic", tint: .red) { module.choose(screen: false) }
                }
                if let file = module.lastSavedURL { Button("Показать запись в Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }.buttonStyle(.plain).font(.caption) }
            }
            Text("Индикатор относится к записям, запущенным из NotchBeat.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
