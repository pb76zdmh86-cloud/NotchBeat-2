import AppKit
import SwiftUI
import Combine
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    let preferences: PreferencesStore
    let music: MusicModule
    let focus: TimerModule
    let calendar: CalendarModule
    let reminders: RemindersModule
    let battery: BatteryModule
    let downloads: DownloadsModule
    let airDrop: AirDropModule
    let recording: RecordingModule
    let modules: [BuiltInModule]
    @Published private(set) var mode: IslandMode = .collapsed
    @Published private(set) var selection = ActivitySelection(primary: [], minimal: nil, overflow: 0)
    @Published var selectedModule: ModuleID?
    @Published var showingHistory = false
    @Published private(set) var history: [ActivityHistoryEntry] = []
    @Published private(set) var displays: [DisplayChoice] = []
    @Published var canvasSize = CGSize(width: 740, height: 500)
    @Published var anchorX: CGFloat = 370
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var notice: String?
    @Published private(set) var revision = 0
    var onLayoutChange: (() -> Void)?
    var onGeometryChange: (([IslandHitRegion]) -> Void)?
    var onSettings: (() -> Void)?
    var onQuickMenu: (() -> Void)?
    private var hovered = false
    private var pinned = false
    private var lastInteraction = Date()
    private var autoRevealUntil = Date.distantPast
    private var log = ActivityHistory()
    private var servicesStarted = false
    private var clock: Timer?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    init() {
        let prefs = PreferencesStore()
        let music = MusicModule(preferences: prefs); let focus = TimerModule()
        let calendar = CalendarModule(preferences: prefs); let battery = BatteryModule()
        let reminders = RemindersModule(preferences: prefs)
        let downloads = DownloadsModule(); let airDrop = AirDropModule(); let recording = RecordingModule()
        self.preferences = prefs; self.music = music; self.focus = focus; self.calendar = calendar; self.battery = battery
        self.reminders = reminders
        self.downloads = downloads; self.airDrop = airDrop; self.recording = recording
        modules = [music, focus, calendar, reminders, battery, downloads, airDrop, recording]
        recording.selectedScreen = { [weak self] in self?.selectedScreen }
        calendar.onReminder = { [weak self] in self?.peek(.calendar) }
        focus.onFinished = { [weak self] in self?.peek(.timer) }
        focus.onPresetChange = { [weak self] focus, rest in
            guard let self else { return }
            self.preferences.value.focusMinutes = focus; self.preferences.value.breakMinutes = rest
        }
        for module in modules {
            module.activityDidChange = { [weak self] in self?.refresh() }
            module.notify = { [weak self] in self?.notice = $0 }
        }
        refreshDisplays(); applyPreferences()
        preferences.$value.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.applyPreferences() }
        }.store(in: &subscriptions)
    }
    var selectedScreen: NSScreen? { NSScreen.screens.first { $0.stableDisplayID == preferences.value.selectedDisplayID } }
    var notch: CGRect? { selectedScreen?.physicalNotch }
    var physical: Bool { notch != nil }
    var headerHeight: CGFloat { notch?.height ?? 0 }
    var enabledModules: [BuiltInModule] { modules.filter { $0.enabled || ($0.id == .recording && recording.capturing) } }
    var tint: Color { preferences.value.artworkAccent && music.snapshot != nil ? music.accent : module(selection.primary.first)?.accent ?? .mint }
    func module(_ id: ModuleID?) -> BuiltInModule? { modules.first { $0.id == id } }
    var desiredSize: CGSize {
        switch mode {
        case .collapsed: return CGSize(width: physical ? notch!.width : 94, height: physical ? headerHeight : 26)
        case .compact: return CGSize(
            width: physical ? notch!.width + (selection.primary.count > 1 ? 128 : 80) : preferences.value.emulatedWidth,
            height: physical ? headerHeight : preferences.value.emulatedHeight
        )
        case .expanded: return CGSize(width: 480, height: headerHeight + 404)
        }
    }
    func start() {
        servicesStarted = true
        modules.filter { $0.enabled }.forEach { $0.start() }; refreshLoginStatus()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        clock = timer; RunLoop.main.add(timer, forMode: .common)
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.calendar.refresh(); self?.reminders.refresh(); self?.refreshDisplays(); self?.refresh() }
        })
        refresh()
    }
    func stop() {
        servicesStarted = false; clock?.invalidate(); modules.forEach { $0.stop() }
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
    }
    private func applyPreferences() {
        for module in modules {
            let wasEnabled = module.enabled
            module.enabled = preferences.value.isEnabled(module.id)
            module.priority = preferences.value.priority(module.id)
            if servicesStarted && wasEnabled != module.enabled {
                if module.enabled { module.start() }
                else {
                    switch module.id {
                    case .music, .calendar, .reminders, .battery: module.stop()
                    case .timer: module.pause(); module.stop()
                    case .downloads: module.pause()
                    case .airDrop, .recording: break // System transfer / recording must finish explicitly.
                    }
                }
            }
        }
        InteractionFeedback.enabled = preferences.value.haptics
        focus.focusMinutes = preferences.value.focusMinutes; focus.breakMinutes = preferences.value.breakMinutes
        if !preferences.value.hoverExpands { hovered = false }
        music.applyPreferences(); calendar.refresh(); reminders.refresh()
        if let selectedModule, !enabledModules.contains(where: { $0.id == selectedModule }) { self.selectedModule = nil }
        refresh(); onLayoutChange?()
    }
    func refreshDisplays() {
        displays = NSScreen.screens.map { DisplayChoice(id: $0.stableDisplayID, name: $0.localizedName, hasNotch: $0.physicalNotch != nil, builtIn: CGDisplayIsBuiltin($0.displayNumber) != 0) }
        if preferences.value.selectedDisplayID.isEmpty { preferences.value.selectedDisplayID = displays.first(where: { $0.builtIn })?.id ?? displays.first?.id ?? "" }
        onLayoutChange?()
    }
    private func refresh() {
        revision &+= 1
        let candidates = enabledModules.compactMap { module -> ActivityCandidate? in
            guard let activity = module.activity else { log.observe(id: module.id, activity: nil, at: .now); return nil }
            log.observe(id: module.id, activity: activity, at: .now)
            return ActivityCandidate(id: module.id, priority: module.priority)
        }
        let next = ActivitySelection.resolve(candidates)
        if next != selection { selection = next }
        log.prune(at: .now)
        if history.map(\.id) != log.entries.map(\.id) { history = log.entries }
        if pinned && !hovered && Date().timeIntervalSince(lastInteraction) > preferences.value.inactivityTimeout { pinned = false }
        let nextMode: IslandMode = pinned || hovered || Date() < autoRevealUntil ? .expanded : (selection.primary.isEmpty ? .collapsed : .compact)
        if nextMode != mode { mode = nextMode; onLayoutChange?() }
    }
    func openCenter(_ id: ModuleID? = nil) { InteractionFeedback.tap(); selectedModule = id; showingHistory = false; pinned = true; lastInteraction = .now; refresh() }
    func toggleExpanded() { if mode == .expanded { collapse() } else { openCenter(selection.primary.first) } }
    func collapse() { pinned = false; hovered = false; showingHistory = false; autoRevealUntil = .distantPast; refresh() }
    private func peek(_ id: ModuleID) {
        guard !pinned && !hovered, module(id)?.enabled == true else { return }
        selectedModule = id; showingHistory = false; autoRevealUntil = Date().addingTimeInterval(6); refresh()
    }
    func hover(_ inside: Bool) {
        guard preferences.value.hoverExpands else { return }
        if inside && !hovered { selectedModule = selection.primary.first; showingHistory = false }
        hovered = inside
        if inside { lastInteraction = .now }
        refresh()
    }
    func select(_ id: ModuleID?) { InteractionFeedback.tap(); selectedModule = id; showingHistory = false; pinned = true; lastInteraction = .now; refresh() }
    func showHistory() { InteractionFeedback.tap(); showingHistory = true; pinned = true; lastInteraction = .now; refresh() }
    func pauseAll() { enabledModules.forEach { $0.pause() }; InteractionFeedback.tap(); lastInteraction = .now }
    func showDemo() { music.showDemo(); openCenter(.music) }
    func endDemo() { music.endDemo(); collapse() }
    func requestSettings() { onSettings?() }
    func noteInteraction() { lastInteraction = .now }
    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) {
        Task {
            do { if enabled { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() } }
            catch { notice = "Не удалось изменить автозапуск: \(error.localizedDescription)" }
            refreshLoginStatus()
        }
    }
    func openPrivacy(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") { NSWorkspace.shared.open(url) }
    }
}
