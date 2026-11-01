import SwiftUI

@MainActor final class TimerModule: BuiltInModule {
    @Published private(set) var session = FocusSession()
    @Published var focusMinutes = 25
    @Published var breakMinutes = 5
    private var clock: Timer?
    private let notificationID = "NotchBeat.focus"
    var onFinished: (() -> Void)?
    var onPresetChange: ((Int, Int) -> Void)?
    func savePreset() { onPresetChange?(focusMinutes, breakMinutes) }
    override init(id: ModuleID = .timer) {
        super.init(id: id)
        if let data = UserDefaults.standard.data(forKey: "NotchBeat.focus.session"), let saved = try? JSONDecoder().decode(FocusSession.self, from: data) {
            session = saved; session.tick(now: .now)
        }
    }
    override var accent: Color { .orange }
    override var activity: ModuleActivity? {
        guard session.isActive else { return nil }
        return ModuleActivity(token: "\(session.cycleID):\(session.phase.rawValue)", title: phaseTitle, detail: "\(Int(session.focusSeconds / 60))/\(Int(session.breakSeconds / 60)) мин")
    }
    var phaseTitle: String {
        switch session.phase {
        case .idle: return "Оставшиеся время"; case .focus: return "Время фокуса"; case .pausedFocus, .pausedRest: return "Таймер на паузе"
        case .awaitingBreak: return "Фокус завершён · начни перерыв"; case .rest: return "Перерыв"; case .finished: return "Перерыв завершён"
        }
    }
    override func start() {
        guard clock == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
    }
    override func stop() { clock?.invalidate(); clock = nil }
    private func tick() {
        let old = session.phase; session.tick(now: .now)
        if old != session.phase { save(); changed(); onFinished?() }
    }
    func begin(focus: Int, rest: Int) {
        session.start(focus: Double(focus * 60), rest: Double(rest * 60), now: .now); save(); changed()
        Task { await LocalNotifications.requestPermission(); scheduleNotification() }
    }
    override func pause() {
        guard session.running else { return }
        session.pause(now: .now); LocalNotifications.cancel([notificationID]); save(); changed()
    }
    func resume() { session.resume(now: .now); save(); scheduleNotification(); changed() }
    func beginBreak() { session.confirmBreak(now: .now); save(); scheduleNotification(); changed() }
    func reset() { session.reset(); LocalNotifications.cancel([notificationID]); save(); changed() }
    private func save() { if let data = try? JSONEncoder().encode(session) { UserDefaults.standard.set(data, forKey: "NotchBeat.focus.session") } }
    private func scheduleNotification() {
        guard let end = session.deadline else { return }
        LocalNotifications.schedule(id: notificationID, title: session.phase == .focus ? "Фокус завершён" : "Перерыв завершён",
            body: session.phase == .focus ? "Открой NotchBeat и подтверди начало перерыва" : "Можно начать следующий цикл", at: end)
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        if region == .leading { return AnyView(Image(systemName: session.phase == .awaitingBreak ? "checkmark.circle.fill" : "timer").foregroundStyle(accent).font(.system(size: 17, weight: .semibold))) }
        return AnyView(TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(self.session.phase == .awaitingBreak ? "Готово" : DisplayTime.clock(self.session.remaining(at: context.date)))
                .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(self.accent)
        })
    }
    override var expandedView: AnyView { AnyView(TimerPanel(module: self)) }
}

@MainActor private struct TimerPanel: View {
    @ObservedObject var module: TimerModule
    var body: some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 6) {
                    Text(module.phaseTitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text(module.session.phase == .awaitingBreak ? "Пора отдохнуть" : DisplayTime.clock(module.session.isActive ? module.session.remaining(at: context.date) : Double(module.focusMinutes * 60)))
                        .font(.system(size: module.session.phase == .awaitingBreak ? 26 : 49, weight: .light, design: .rounded)).monospacedDigit()
                }.frame(height: 82)
            }
            if module.session.phase == .awaitingBreak {
                ModuleButton(title: "Начать перерыв \(Int(module.session.breakSeconds / 60)) мин", symbol: "cup.and.saucer.fill", tint: .orange) { module.beginBreak() }
            } else if module.session.running {
                ModuleButton(title: "Пауза", symbol: "pause.fill", tint: .orange) { module.pause() }
            } else if module.session.phase == .pausedFocus || module.session.phase == .pausedRest {
                ModuleButton(title: "Продолжить", symbol: "play.fill", tint: .orange) { module.resume() }
            } else {
                HStack {
                    ModuleButton(title: "25 / 5", symbol: "play.fill", tint: .orange) { module.begin(focus: 25, rest: 5) }
                    ModuleButton(title: "50 / 10", symbol: "play.fill", tint: .orange) { module.begin(focus: 50, rest: 10) }
                }
                HStack {
                    Stepper("\(module.focusMinutes) мин", value: $module.focusMinutes, in: 1...240).font(.caption)
                    Stepper("Пауза \(module.breakMinutes)", value: $module.breakMinutes, in: 1...60).font(.caption)
                }
                ModuleButton(title: "Свой интервал", symbol: "timer", tint: .orange) { module.begin(focus: module.focusMinutes, rest: module.breakMinutes) }
            }
            if module.session.isActive { Button("Сбросить таймер") { module.reset() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: module.focusMinutes) { _, _ in module.savePreset() }
        .onChange(of: module.breakMinutes) { _, _ in module.savePreset() }
    }
}
