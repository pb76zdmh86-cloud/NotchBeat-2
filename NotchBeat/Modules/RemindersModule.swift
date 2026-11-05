import SwiftUI
import EventKit
import AppKit

struct ReminderListChoice: Identifiable { var id: String; var title: String; var writable: Bool }
struct ReminderItem: Identifiable {
    var id: String; var title: String; var listTitle: String; var due: Date?; var dueHasTime: Bool; var completed: Bool; var notes: String
}
@MainActor final class RemindersModule: BuiltInModule {
    private let store = EKEventStore()
    private let preferences: PreferencesStore
    private var observer: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var clock: Timer?
    private var generation = 0
    private var accessError: String?
    private var accessSession = ReminderAccessSession()
    @Published private(set) var lists: [ReminderListChoice] = []
    @Published private(set) var items: [ReminderItem] = []
    @Published private(set) var granted = false
    @Published private(set) var loading = false
    @Published private(set) var requestingAccess = false
    @Published private(set) var status = "Подключи системные Напоминания"
    var connectionActionTitle: String {
        if requestingAccess { return "Ожидание разрешения…" }
        if granted { return "Обновить подключение" }
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .denied: return "Разрешить доступ в системных настройках"
        case .fullAccess: return "Обновить подключение"
        default: return "Подключить системные Напоминания"
        }
    }
    init(preferences: PreferencesStore) { self.preferences = preferences; super.init(id: .reminders) }
    override var accent: Color { .blue }
    var dueToday: [ReminderItem] {
        items.filter { item in
            guard !item.completed, let due = item.due else { return false }
            let start = Calendar.current.startOfDay(for: .now)
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
            return due < tomorrow
        }
    }
    override var activity: ModuleActivity? {
        guard !dueToday.isEmpty else { return nil }
        return ModuleActivity(token: dueToday.map(\.id).joined(separator: "|"), title: "Напоминания: \(dueToday.count)", detail: dueToday.first?.title ?? "")
    }
    override func start() {
        guard clock == nil else { return }; refresh()
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.requestingAccess else { return }
                self.store.reset()
                self.refresh()
            }
        }
    }
    override func stop() {
        clock?.invalidate(); clock = nil; generation += 1; loading = false
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }; activationObserver = nil
    }
    func requestAccess() async {
        guard !requestingAccess else { return }
        let authorization = EKEventStore.authorizationStatus(for: .reminder)
        if authorization == .denied {
            refresh()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(url) }
            return
        }
        if authorization == .restricted || authorization == .fullAccess { store.reset(); refresh(); return }
        requestingAccess = true
        accessError = nil
        defer { requestingAccess = false; changed() }
        do {
            let allowed = try await store.requestFullAccessToReminders()
            accessSession.completeRequest(granted: allowed)
            if allowed {
                store.reset()
                refresh()
            } else { refresh() }
        } catch {
            let message = "Не удалось подключить Напоминания: \(error.localizedDescription)"
            accessError = message
            status = message
        }
        changed()
    }
    func refresh() {
        generation += 1; let current = generation
        let authorization = EKEventStore.authorizationStatus(for: .reminder)
        switch authorization {
        case .fullAccess: accessSession.update(.fullAccess)
        case .notDetermined: accessSession.update(.notDetermined)
        case .denied: accessSession.update(.denied)
        case .restricted: accessSession.update(.restricted)
        default: accessSession.update(.unavailable)
        }
        // A successful request is authoritative while EventKit's status cache catches up.
        granted = accessSession.granted
        guard granted else {
            items = []; lists = []; loading = false
            switch authorization {
            case .denied: status = "Доступ к Напоминаниям выключен в macOS. Разреши NotchBeat доступ в Системных настройках → Конфиденциальность и безопасность → Напоминания."
            case .restricted: status = "Доступ к Напоминаниям ограничен системой или администратором."
            default: status = accessError ?? (requestingAccess ? "Разреши доступ в системном диалоге macOS." : "Подключи системные Напоминания")
            }
            changed(); return
        }
        accessError = nil
        let available = store.calendars(for: .reminder)
        lists = available.map { ReminderListChoice(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications) }
        if !preferences.value.reminderListsInitialized, !available.isEmpty {
            preferences.value.initializeReminderListsIfNeeded(available.map(\.calendarIdentifier))
        }
        let selected = available.filter { preferences.value.selectedReminderListIDs.contains($0.calendarIdentifier) }
        guard enabled, !selected.isEmpty else {
            items = []; loading = false
            status = !enabled ? "Модуль отключён" : (available.isEmpty ? "Списки пока недоступны. Открой системные Напоминания и повтори обновление." : "Выбери списки в настройках")
            changed(); return
        }
        loading = true
        store.fetchReminders(matching: store.predicateForReminders(in: selected)) { [weak self] reminders in
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.loading = false
                guard let reminders else {
                    self.items = []
                    self.accessSession.invalidateRequestGrant()
                    self.status = "Не удалось прочитать списки. Повтори обновление."
                    self.changed(); return
                }
                self.items = reminders.map { reminder in
                    var due: Date?
                    if let components = reminder.dueDateComponents {
                        let calendar = components.calendar ?? Calendar.current
                        due = calendar.date(from: components)
                    }
                    return ReminderItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Напоминание", listTitle: reminder.calendar.title,
                        due: due, dueHasTime: reminder.dueDateComponents?.hour != nil, completed: reminder.isCompleted, notes: reminder.notes ?? "")
                }.sorted {
                    if $0.completed != $1.completed { return !$0.completed }
                    if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                self.status = "Невыполненных: \(self.items.filter { !$0.completed }.count)"
                self.changed()
            }
        }
    }
    func setCompleted(_ item: ReminderItem) {
        guard granted, let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder, reminder.calendar.allowsContentModifications else {
            notify?("Этот список недоступен для изменения"); return
        }
        let original = reminder.isCompleted; reminder.isCompleted = !item.completed
        do {
            try store.save(reminder, commit: true)
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].completed = reminder.isCompleted }
            InteractionFeedback.tap(); changed(); refresh()
        }
        catch { reminder.isCompleted = original; notify?("Не удалось сохранить отметку: \(error.localizedDescription)") }
    }
    @discardableResult func add(title: String, listID: String, due: Date?) -> Bool {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard granted, !text.isEmpty, let calendar = store.calendar(withIdentifier: listID), calendar.allowsContentModifications else {
            notify?("Введи название и выбери доступный для записи список"); return false
        }
        let reminder = EKReminder(eventStore: store); reminder.title = text; reminder.calendar = calendar
        if let due {
            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            components.timeZone = TimeZone.current; reminder.dueDateComponents = components
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
            if !preferences.value.selectedReminderListIDs.contains(listID) { preferences.value.selectedReminderListIDs.append(listID) }
            refresh(); return true
        }
        catch { notify?("Не удалось добавить напоминание: \(error.localizedDescription)"); return false }
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        if region == .leading { return AnyView(Image(systemName: "checklist").foregroundStyle(accent)) }
        return AnyView(Text("\(dueToday.count)").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent))
    }
    override var expandedView: AnyView { AnyView(RemindersPanel(module: self)) }
}
@MainActor struct RemindersPanel: View {
    @ObservedObject var module: RemindersModule
    @State private var title = ""
    @State private var listID = ""
    @State private var hasDue = false
    @State private var due = Date().addingTimeInterval(3600)
    @State private var showCompleted = false
    private var writableLists: [ReminderListChoice] { module.lists.filter(\.writable) }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !module.granted {
                Text(module.status).font(.caption).foregroundStyle(.secondary)
                ModuleButton(title: module.connectionActionTitle, symbol: "checklist", tint: .blue) { Task { await module.requestAccess() } }
                    .disabled(module.requestingAccess)
            } else {
                HStack { Text(module.status).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Обновить") { module.refresh() } }
                TextField("Новое напоминание", text: $title).textFieldStyle(.roundedBorder)
                Picker("Список", selection: $listID) {
                    Text("Выбери список").tag("")
                    ForEach(writableLists) { list in Text(list.title).tag(list.id) }
                }
                Toggle("Дата и время", isOn: $hasDue)
                if hasDue { DatePicker("Когда", selection: $due, displayedComponents: [.date, .hourAndMinute]) }
                ModuleButton(title: "Добавить", symbol: "plus", tint: .blue) {
                    if module.add(title: title, listID: listID, due: hasDue ? due : nil) { title = "" }
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || listID.isEmpty)
                Toggle("Показать выполненные", isOn: $showCompleted).font(.caption)
                if module.loading { ProgressView().controlSize(.small) }
                ForEach(module.items.filter { showCompleted || !$0.completed }) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Button { module.setCompleted(item) } label: {
                            Image(systemName: item.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 20)).foregroundStyle(.blue)
                        }.buttonStyle(.plain).accessibilityLabel(item.completed ? "Вернуть задачу" : "Отметить выполненной")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).strikethrough(item.completed).font(.system(size: 13, weight: .medium))
                            Text(item.listTitle).font(.caption2).foregroundStyle(.secondary)
                            if let due = item.due {
                                Text(due.formatted(date: .abbreviated, time: item.dueHasTime ? .shortened : .omitted)).font(.caption2)
                                    .foregroundStyle(due < .now && !item.completed ? Color.orange : Color.secondary)
                            }
                            if !item.notes.isEmpty { Text(item.notes).font(.caption2).foregroundStyle(.secondary) }
                        }; Spacer(minLength: 0)
                    }.padding(.vertical, 4)
                }
            }
        }.onChange(of: module.lists.map(\.id), initial: true) { _, _ in
            if !writableLists.contains(where: { $0.id == listID }) { listID = writableLists.first?.id ?? "" }
        }
    }
}
