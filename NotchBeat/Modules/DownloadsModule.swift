import SwiftUI
import AppKit

enum TransferPhase: String { case running, paused, complete, failed, cancelled }
struct DownloadItem: Identifiable {
    var id = UUID()
    var source: URL
    var destination: URL
    var phase: TransferPhase = .running
    var received: Int64 = 0
    var expected: Int64 = -1
    var error = ""
    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
}

@MainActor final class DownloadsModule: BuiltInModule, URLSessionDownloadDelegate {
    @Published private(set) var items: [DownloadItem] = []
    private var session: URLSession?
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var identifiers: [Int: UUID] = [:]
    private var lastUpdate: [Int: Date] = [:]
    private var pulseUntil = Date.distantPast
    override init(id: ModuleID = .downloads) { super.init(id: id) }
    override var accent: Color { .cyan }
    var active: [DownloadItem] { items.filter { $0.phase == .running || $0.phase == .paused } }
    override var activity: ModuleActivity? {
        guard !active.isEmpty || Date() < pulseUntil, let first = active.first ?? items.first else { return nil }
        let token = items.map { "\($0.id):\($0.phase.rawValue)" }.joined(separator: "|")
        return ModuleActivity(token: token, title: active.isEmpty ? "Файл сохранён" : "Загрузки: \(active.count)", detail: first.destination.lastPathComponent)
    }
    override func start() {
        guard session == nil else { return }
        let configuration = URLSessionConfiguration.default; configuration.timeoutIntervalForRequest = 45
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    override func stop() { session?.invalidateAndCancel(); session = nil }
    func begin(_ address: String) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), ["https", "http"].contains(url.scheme ?? ""), url.host != nil else {
            notify?("Вставь HTTP или HTTPS-ссылку на файл"); return
        }
        let panel = NSSavePanel(); panel.nameFieldStringValue = url.lastPathComponent.isEmpty ? "Download" : url.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in self?.enqueue(url, destination: destination) }
        }
    }
    private func enqueue(_ url: URL, destination: URL) {
        start(); guard let task = session?.downloadTask(with: url) else { return }
        let item = DownloadItem(source: url, destination: destination)
        items.insert(item, at: 0); tasks[item.id] = task; identifiers[task.taskIdentifier] = item.id
        task.resume(); changed()
    }
    override func pause() { for item in active where item.phase == .running { toggle(item.id) } }
    func toggle(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), let task = tasks[id] else { return }
        if items[index].phase == .running { task.suspend(); items[index].phase = .paused }
        else if items[index].phase == .paused { task.resume(); items[index].phase = .running }
        changed()
    }
    func cancel(_ id: UUID) {
        tasks[id]?.cancel(); tasks[id] = nil
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].phase = .cancelled }
        changed()
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let identifier = downloadTask.taskIdentifier
        Task { @MainActor [weak self] in
            guard let self, Date().timeIntervalSince(self.lastUpdate[identifier] ?? .distantPast) > 0.1,
                  let id = self.identifiers[identifier], let index = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.lastUpdate[identifier] = .now
            self.items[index].received = totalBytesWritten; self.items[index].expected = totalBytesExpectedToWrite
        }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let identifier = downloadTask.taskIdentifier
        guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            Task { @MainActor [weak self] in self?.fail(identifier, message: "Сервер не вернул файл") }; return
        }
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("NotchBeat-download-" + UUID().uuidString)
        do {
            // The system removes location as soon as this callback returns.
            try FileManager.default.copyItem(at: location, to: staged)
            Task { @MainActor [weak self] in self?.finish(identifier, staged: staged) }
        } catch {
            let message = error.localizedDescription
            Task { @MainActor [weak self] in self?.fail(identifier, message: message) }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let identifier = task.taskIdentifier; let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.fail(identifier, message: message) }
    }
    private func finish(_ identifier: Int, staged: URL) {
        defer { try? FileManager.default.removeItem(at: staged) }
        guard let id = identifiers[identifier], let index = items.firstIndex(where: { $0.id == id }), items[index].phase != .cancelled else { return }
        do {
            let destination = items[index].destination
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
            else { try FileManager.default.moveItem(at: staged, to: destination) }
            items[index].phase = .complete; pulseUntil = Date().addingTimeInterval(8); tasks[id] = nil
            changed()
        } catch { fail(identifier, message: error.localizedDescription) }
    }
    private func fail(_ identifier: Int, message: String) {
        guard let id = identifiers[identifier], let index = items.firstIndex(where: { $0.id == id }), items[index].phase != .cancelled else { return }
        items[index].phase = .failed; items[index].error = message; tasks[id] = nil; notify?("Не удалось сохранить загрузку: \(message)"); changed()
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        if region == .leading { return AnyView(Image(systemName: "arrow.down").foregroundStyle(accent).font(.system(size: 17, weight: .semibold))) }
        let text = active.count == 1 ? active[0].fraction.map { "\(Int($0 * 100))%" } ?? "…" : "\(active.count)"
        return AnyView(Text(text).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(accent))
    }
    override var expandedView: AnyView { AnyView(DownloadsPanel(module: self)) }
}

@MainActor private struct DownloadsPanel: View {
    @ObservedObject var module: DownloadsModule
    @State private var address = ""
    var body: some View {
        VStack(spacing: 13) {
            HStack {
                TextField("Ссылка на файл", text: $address).textFieldStyle(.roundedBorder)
                Button { module.begin(address) } label: { Image(systemName: "arrow.down.circle.fill").font(.system(size: 23)).foregroundStyle(.cyan) }
                    .buttonStyle(.plain).disabled(address.isEmpty).accessibilityLabel("Скачать файл")
            }
            if module.items.isEmpty { Text("Сохраняй файлы прямо из центра. Здесь показываются загрузки, запущенные в NotchBeat.").font(.caption).foregroundStyle(.secondary) }
            ForEach(module.items.prefix(3)) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.destination.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer()
                        if item.phase == .running || item.phase == .paused {
                            Button { module.toggle(item.id) } label: { Image(systemName: item.phase == .running ? "pause.fill" : "play.fill") }.buttonStyle(.plain)
                            Button { module.cancel(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        } else if item.phase == .complete {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([item.destination]) } label: { Image(systemName: "folder") }.buttonStyle(.plain)
                        }
                    }
                    if let fraction = item.fraction { ProgressView(value: fraction).tint(.cyan) }
                    else if item.phase == .running { ProgressView().controlSize(.mini) }
                    Text(item.phase == .failed ? item.error : item.phase == .complete ? "Сохранён" : ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }.padding(11).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}
