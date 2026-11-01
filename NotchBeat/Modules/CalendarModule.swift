import SwiftUI
import EventKit
import AppKit
import UserNotifications

struct CalendarChoice: Identifiable { var id: String; var title: String; var source: String }
struct CalendarItem: Identifiable {
    var id: String; var title: String; var start: Date; var end: Date; var location: String
    var calendarTitle: String; var notes: String; var allDay: Bool
}

@MainActor final class CalendarModule: BuiltInModule {
    private let store = EKEventStore()
    private let preferences: PreferencesStore
    private var clock: Timer?
    private var observer: NSObjectProtocol?
    private var notificationIDs: [String] = []
    private var scheduleGeneration = 0
    private var reminded: Set<String> = []
    var onReminder: (() -> Void)?
    @Published private(set) var calendars: [CalendarChoice] = []
    @Published private(set) var events: [CalendarItem] = []
    @Published private(set) var status = "Выбери календари в настройках"
    @Published private(set) var granted = false
    init(preferences: PreferencesStore) { self.preferences = preferences; super.init(id: .calendar) }
    override var accent: Color { .red }
    var nextTimedEvent: CalendarItem? { events.first { !$0.allDay } }
    override var activity: ModuleActivity? {
        guard let event = nextTimedEvent, event.start.timeIntervalSinceNow <= Double(max(preferences.value.calendarLookaheadMinutes, preferences.value.calendarReminderMinutes) * 60), event.end > .now else { return nil }
        let imminent = event.start.timeIntervalSinceNow <= Double(preferences.value.calendarReminderMinutes * 60)
        return ModuleActivity(token: event.id + (imminent ? ":reminder" : ""), title: event.title, detail: event.start.formatted(date: .omitted, time: .shortened))
    }
    override func start() {
        guard clock == nil else { return }
        refresh()
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh(reschedule: false) } }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    override func stop() { clock?.invalidate(); clock = nil; if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil; replaceReminders([]) }
    func requestAccess() async {
        do {
            granted = try await store.requestFullAccessToEvents()
            if granted { await LocalNotifications.requestPermission(); refresh() }
            else { status = "Доступ к календарю отклонён. Его можно разрешить в системных настройках." }
        } catch { status = "Не удалось подключить календарь: \(error.localizedDescription)" }
        changed()
    }
    func refresh(reschedule: Bool = true) {
        granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        guard granted else { events = []; calendars = []; if reschedule { replaceReminders([]) }; changed(); return }
        let available = store.calendars(for: .event)
        calendars = available.map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
        let selected = available.filter { preferences.value.selectedCalendarIDs.contains($0.calendarIdentifier) }
        guard enabled, !selected.isEmpty else {
            events = []; status = enabled ? "Отметь нужные календари в настройках" : "Модуль отключён"
            if reschedule { replaceReminders([]) }; changed(); return
        }
        let start = Date(); let end = start.addingTimeInterval(7 * 86400)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: selected)
        events = store.events(matching: predicate).filter { $0.endDate > start }.sorted { $0.startDate < $1.startDate }
            .map { CalendarItem(id: ($0.eventIdentifier ?? $0.calendarItemIdentifier) + ":\($0.startDate.timeIntervalSince1970)",
                title: $0.title ?? "Событие", start: $0.startDate, end: $0.endDate, location: $0.location ?? "", calendarTitle: $0.calendar.title, notes: $0.notes ?? "", allDay: $0.isAllDay) }
        status = events.isEmpty ? "Нет ближайших событий" : "Подключено календарей: \(selected.count)"
        if let first = nextTimedEvent, first.start > .now,
           first.start.timeIntervalSinceNow <= Double(preferences.value.calendarReminderMinutes * 60), !reminded.contains(first.id) {
            reminded.insert(first.id); onReminder?()
        }
        if reschedule { replaceReminders(events) }
        changed()
    }
    private func replaceReminders(_ items: [CalendarItem]) {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        let minutes = preferences.value.calendarReminderMinutes
        UNUserNotificationCenter.current().getPendingNotificationRequests { [weak self] pending in
            let ids = pending.map(\.identifier).filter { $0.hasPrefix("NotchBeat.calendar.") }
            Task { @MainActor in
                guard let self, self.scheduleGeneration == generation else { return }
                LocalNotifications.cancel(ids); self.notificationIDs = []
                for event in items.filter({ !$0.allDay }).prefix(20) {
                    let time = event.start.addingTimeInterval(-Double(minutes * 60)); guard time > .now else { continue }
                    let id = "NotchBeat.calendar.\(event.id)"; self.notificationIDs.append(id)
                    LocalNotifications.schedule(id: id, title: event.title, body: "Через \(minutes) мин · \(event.location)", at: time)
                }
            }
        }
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        if region == .leading { return AnyView(Image(systemName: "calendar").font(.system(size: 17, weight: .semibold)).foregroundStyle(accent)) }
        return AnyView(TimelineView(.periodic(from: .now, by: 1)) { _ in
            let mins = max(0, Int(ceil((self.nextTimedEvent?.start.timeIntervalSinceNow ?? 0) / 60)))
            Text(mins == 0 ? "Сейчас" : "\(mins) мин").font(.system(size: 11, weight: .semibold)).foregroundStyle(self.accent)
        })
    }
    override var expandedView: AnyView { AnyView(CalendarPanel(module: self)) }
}

@MainActor private struct CalendarPanel: View {
    @ObservedObject var module: CalendarModule
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !module.granted {
                Text("Выбери личные и учебные календари, подключённые на Mac.").font(.callout).foregroundStyle(.secondary)
                ModuleButton(title: "Разрешить доступ к календарю", symbol: "calendar", tint: .red) { Task { await module.requestAccess() } }
            } else if module.events.isEmpty { Text(module.status).foregroundStyle(.secondary) }
            else {
                ForEach(module.events) { event in CalendarEventRow(event: event) }
            }
            Button("Открыть Календарь") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
                }
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.red)
        }
    }
}

@MainActor struct CalendarEventRow: View {
    var event: CalendarItem
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                Text(event.allDay ? "Весь день" : "\(event.start.formatted(date: .abbreviated, time: .shortened)) — \(event.end.formatted(date: .abbreviated, time: .shortened))")
                Text(event.calendarTitle).foregroundStyle(.secondary)
                if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse") }
                if !event.notes.isEmpty { Text(event.notes).textSelection(.enabled) }
            }.font(.caption).padding(.vertical, 6)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 2) {
                    Text(event.start.formatted(.dateTime.day())).font(.system(size: 23, weight: .light))
                    Text(event.start.formatted(.dateTime.month(.abbreviated))).font(.caption2)
                }.frame(width: 43, height: 49).background(Color.red.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(event.allDay ? "Весь день · \(event.start.formatted(date: .abbreviated, time: .omitted))" : event.start.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
