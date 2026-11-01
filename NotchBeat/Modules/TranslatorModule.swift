import SwiftUI
import AppKit
import Translation

struct TranslatorLanguage: Identifiable {
    var language: Locale.Language
    var title: String
    var id: String { language.minimalIdentifier }
}
struct TranslatorWork: Identifiable {
    var id = UUID()
    var text: String
    var source: Locale.Language?
    var target: Locale.Language
}
@MainActor final class TranslatorModule: BuiltInModule {
    @Published var input = ""
    @Published private(set) var output = ""
    @Published var sourceID = UserDefaults.standard.string(forKey: "NotchBeat.translator.source") ?? "auto" {
        didSet { UserDefaults.standard.set(sourceID, forKey: "NotchBeat.translator.source") }
    }
    @Published var targetID = UserDefaults.standard.string(forKey: "NotchBeat.translator.target") ?? "ru" {
        didSet { UserDefaults.standard.set(targetID, forKey: "NotchBeat.translator.target") }
    }
    @Published private(set) var languages: [TranslatorLanguage] = []
    @Published private(set) var busy = false
    @Published private(set) var status = "Системный перевод · до 5000 символов"
    @Published private(set) var pending: TranslatorWork?
    private var pulseUntil = Date.distantPast
    override init(id: ModuleID = .translator) { super.init(id: id) }
    override var accent: Color { .cyan }
    override var activity: ModuleActivity? {
        guard busy || Date() < pulseUntil else { return nil }
        return ModuleActivity(token: pending?.id.uuidString ?? "ready", title: busy ? "Перевожу…" : "Перевод готов", detail: "Системный перевод macOS")
    }
    override func stop() { cancel() }
    override func pause() { cancel() }
    func loadLanguages() async {
        let available = await LanguageAvailability().supportedLanguages
        guard !Task.isCancelled else { return }
        let names = Locale(identifier: "ru")
        languages = available.map { language in
            TranslatorLanguage(language: language, title: names.localizedString(forIdentifier: language.minimalIdentifier) ?? language.minimalIdentifier)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !languages.contains(where: { $0.id == targetID }) {
            targetID = languages.first(where: { $0.language.languageCode?.identifier == "ru" })?.id
                ?? languages.first(where: { $0.language.languageCode?.identifier == "en" })?.id ?? languages.first?.id ?? ""
        }
        if sourceID != "auto" && !languages.contains(where: { $0.id == sourceID }) { sourceID = "auto" }
        if languages.isEmpty { status = "macOS не вернула доступные языки. Закрой и открой модуль снова." }
    }
    func begin() -> TranslatorWork? {
        guard !busy else { return nil }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { status = "Введи текст для перевода"; return nil }
        guard text.count <= 5000 else { status = "Сократи текст до 5000 символов"; return nil }
        guard let target = languages.first(where: { $0.id == targetID })?.language else { status = "Выбери язык перевода"; return nil }
        let source = sourceID == "auto" ? nil : languages.first(where: { $0.id == sourceID })?.language
        if let source, source.languageCode == target.languageCode { status = "Выбери разные языки"; return nil }
        let work = TranslatorWork(text: text, source: source, target: target)
        pending = work; output = ""; busy = true; pulseUntil = .distantPast
        status = "Проверяю языки…"; changed(); return work
    }
    func isCurrent(_ work: TranslatorWork) -> Bool { pending?.id == work.id && busy }
    func setPreparing(_ work: TranslatorWork, needsDownload: Bool) {
        guard isCurrent(work) else { return }
        status = needsDownload ? "Подтверди загрузку языков в системном окне" : "Перевожу…"
    }
    func finish(_ text: String, work: TranslatorWork) {
        guard isCurrent(work) else { return }
        output = text; busy = false; status = "Перевод готов"; pulseUntil = Date().addingTimeInterval(5); changed()
    }
    func fail(_ text: String, work: TranslatorWork) {
        guard isCurrent(work) else { return }
        busy = false; status = text; changed()
    }
    func cancel() {
        guard busy else { return }
        pending = nil; busy = false; status = "Перевод отменён"; changed()
    }
    func clear() { cancel(); input = ""; output = ""; pulseUntil = .distantPast; status = "Введи текст для перевода"; changed() }
    func clearResult() { if !busy { output = ""; pulseUntil = .distantPast; status = "Нажми «Перевести»"; changed() } }
    func paste() {
        guard !busy else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { status = "В буфере обмена нет текста"; return }
        input = String(text.prefix(5000)); clearResult()
        if text.count > 5000 { status = "Вставлены первые 5000 символов" }
    }
    func copyResult() {
        guard !output.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string)
        status = "Перевод скопирован"; InteractionFeedback.tap()
    }
    func swap() {
        guard !busy, sourceID != "auto" else { return }
        let oldSource = sourceID; let oldTarget = targetID; let translated = output
        sourceID = oldTarget; targetID = oldSource
        if !translated.isEmpty { input = translated }
        clearResult()
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        if region == .leading { return AnyView(Image(systemName: "character.bubble.fill").foregroundStyle(accent)) }
        return AnyView(Text(busy ? "…" : "Готово").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent))
    }
    override var expandedView: AnyView { AnyView(TranslatorPanel(module: self)) }
}
@MainActor private struct TranslatorPanel: View {
    @ObservedObject var module: TranslatorModule
    @State private var configuration: TranslationSession.Configuration?
    @State private var checking: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            languagePickers
            HStack {
                Text("Исходный текст").font(.caption).foregroundStyle(.secondary)
                Spacer(); Text("\(module.input.count)/5000").font(.caption2).foregroundStyle(module.input.count > 5000 ? Color.orange : Color.secondary)
                Button("Вставить") { module.paste() }.font(.caption).disabled(module.busy)
                Button { configuration = nil; module.clear() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).accessibilityLabel("Очистить текст")
            }
            TextEditor(text: $module.input).font(.system(size: 13)).scrollContentBackground(.hidden)
                .padding(7).frame(height: 68).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .disabled(module.busy)
            HStack {
                Text(module.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                Spacer()
                if module.busy { ProgressView().controlSize(.small) }
                Button(module.busy ? "Отмена" : "Перевести") {
                    if module.busy { checking?.cancel(); configuration = nil; module.cancel() }
                    else { startTranslation() }
                }.buttonStyle(.borderedProminent).tint(module.accent)
                    .disabled(!module.busy && (module.languages.isEmpty || module.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || module.input.count > 5000))
            }
            if !module.output.isEmpty {
                HStack { Text("Перевод").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Копировать") { module.copyResult() }.font(.caption) }
                Text(module.output).font(.system(size: 14)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(module.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            } else if !module.busy {
                Text("Без API-ключа. При первом переводе macOS может предложить скачать языки.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.task { await module.loadLanguages() }
            .onChange(of: module.sourceID) { _, _ in module.clearResult() }
            .onChange(of: module.targetID) { _, _ in module.clearResult() }
            .onChange(of: module.input) { _, _ in module.clearResult() }
            .translationTask(configuration) { session in
                guard let work = module.pending, module.isCurrent(work) else { return }
                do {
                    let result = try await session.translate(work.text)
                    guard !Task.isCancelled else { return }
                    module.finish(result.targetText, work: work)
                } catch {
                    guard !Task.isCancelled else { return }
                    module.fail("Не удалось перевести. Проверь загруженные языки и выбери исходный язык вручную. \(error.localizedDescription)", work: work)
                }
            }
            .onDisappear { checking?.cancel(); module.cancel() }
    }
    private var languagePickers: some View {
        HStack(spacing: 8) {
            Picker("С", selection: $module.sourceID) {
                Text("Определить язык").tag("auto")
                ForEach(module.languages) { language in Text(language.title).tag(language.id) }
            }
            Button { module.swap() } label: { Image(systemName: "arrow.left.arrow.right").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(module.busy || module.sourceID == "auto").accessibilityLabel("Поменять языки местами")
            Picker("На", selection: $module.targetID) {
                if module.languages.isEmpty { Text("Загрузка…").tag(module.targetID) }
                ForEach(module.languages) { language in Text(language.title).tag(language.id) }
            }
        }.labelsHidden().disabled(module.busy)
    }
    private func startTranslation() {
        guard let work = module.begin() else { return }
        InteractionFeedback.tap(); NSApp.activate(ignoringOtherApps: true)
        checking?.cancel()
        checking = Task { @MainActor in
            do {
                let availability = LanguageAvailability()
                let status: LanguageAvailability.Status
                if let source = work.source { status = await availability.status(from: source, to: work.target) }
                else { status = try await availability.status(for: work.text, to: work.target) }
                guard !Task.isCancelled, module.isCurrent(work) else { return }
                guard status != .unsupported else {
                    module.fail("Эта пара языков не поддерживается. Если текст короткий, выбери исходный язык вручную.", work: work); return
                }
                module.setPreparing(work, needsDownload: status == .supported)
                if configuration?.source == work.source && configuration?.target == work.target { configuration?.invalidate() }
                else { configuration = TranslationSession.Configuration(source: work.source, target: work.target) }
            } catch {
                guard !Task.isCancelled else { return }
                module.fail("Не удалось определить язык. Выбери исходный язык вручную. \(error.localizedDescription)", work: work)
            }
        }
    }
}
