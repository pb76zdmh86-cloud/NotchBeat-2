import SwiftUI
import AppKit

@MainActor final class AirDropModule: BuiltInModule, NSSharingServiceDelegate {
    @Published private(set) var status = "Выбери файл и получателя"
    @Published private(set) var sending = false
    private var sharing: NSSharingService?
    private var file: URL?
    private var token = UUID()
    override init(id: ModuleID = .airDrop) { super.init(id: id) }
    override var accent: Color { .blue }
    override var activity: ModuleActivity? {
        guard sending else { return nil }
        return ModuleActivity(token: token.uuidString, title: "AirDrop", detail: file?.lastPathComponent ?? "Отправка файла")
    }
    func chooseFile() {
        guard !sending else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let file = panel.url else { return }
            Task { @MainActor in self?.share(file) }
        }
    }
    private func share(_ file: URL) {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [file]) else {
            notify?("AirDrop недоступен для выбранного файла"); return
        }
        self.file = file; token = UUID(); sending = true; status = "Выбери получателя в системном окне"; changed()
        sharing = service; service.delegate = self; service.perform(withItems: [file])
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor [weak self] in self?.sending = false; self?.status = "Передача завершена"; self?.sharing = nil; self?.changed() }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in self?.sending = false; self?.status = "Передача отменена или не удалась: \(message)"; self?.sharing = nil; self?.changed() }
    }
    func openFinder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"))
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        AnyView(Image(systemName: region == .leading ? "airplayaudio" : "arrow.up").foregroundStyle(accent))
    }
    override var expandedView: AnyView { AnyView(AirDropPanel(module: self)) }
}
@MainActor private struct AirDropPanel: View {
    @ObservedObject var module: AirDropModule
    var body: some View {
        VStack(spacing: 17) {
            Image(systemName: "airplayaudio").font(.system(size: 35)).foregroundStyle(.blue)
            Text(module.status).font(.callout).multilineTextAlignment(.center)
            if module.sending { ProgressView().controlSize(.small) }
            ModuleButton(title: "Отправить файл", symbol: "arrow.up.doc", tint: .blue) { module.chooseFile() }.disabled(module.sending)
            Button("Открыть AirDrop в Finder") { module.openFinder() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            Text("Получатель выбирается в системном окне. Входящие файлы принимает macOS.").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}
