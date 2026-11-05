import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

private enum SettingsPage: String, CaseIterable, Identifiable {
    case modules = "Модули", music = "Музыка", calendar = "Календари", reminders = "Напоминания", island = "Остров", system = "Система"
    var id: String { rawValue }
    var symbol: String { switch self { case .modules: return "square.grid.2x2"; case .music: return "music.note"; case .calendar: return "calendar"; case .reminders: return "checklist"; case .island: return "capsule"; case .system: return "gearshape" } }
}
@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: PreferencesStore
    @State private var page: SettingsPage = .modules
    init(model: AppModel) { self.model = model; preferences = model.preferences }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 55, height: 55)
                    Text("NotchBeat").font(.system(size: 19, weight: .bold))
                    Text("Центр активностей").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
                VStack(spacing: 5) {
                    ForEach(SettingsPage.allCases) { item in
                        Button { page = item } label: {
                            Label(item.rawValue, systemImage: item.symbol).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(page == item ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Button("Открыть центр") { model.openCenter() }.buttonStyle(.borderedProminent)
                Text("Версия 0.3 · macOS 15+").font(.caption2).foregroundStyle(.secondary)
            }.padding(19).frame(width: 155).background(.ultraThinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack { Text(page.rawValue).font(.system(size: 25, weight: .bold)); Spacer(); Button("Проверить дизайн") { model.showDemo() } }.padding(24)
                if !preferences.value.onboardingCompleted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Добро пожаловать в центр NotchBeat").font(.headline)
                        Text(model.physical ? "Остров работает у камеры выбранного экрана. Клик открывает центр, долгое нажатие — быстрые действия." : "На выбранном экране нет чёлки: остров — отдельное окно у верхней границы, его размер и положение можно менять.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Понятно") { preferences.value.onboardingCompleted = true }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 24)
                }
                Group {
                    switch page {
                    case .modules: modulesPage
                    case .music: MusicSettings(model: model, module: model.music, preferences: preferences)
                    case .calendar: CalendarSettings(model: model, module: model.calendar, preferences: preferences)
                    case .reminders: RemindersSettings(model: model, module: model.reminders, preferences: preferences)
                    case .island: islandPage
                    case .system: systemPage
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 820, height: 700)
        .onAppear { model.refreshDisplays(); model.refreshLoginStatus() }
        .alert("NotchBeat", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) { Button("Понятно") { model.notice = nil } } message: { Text(model.notice ?? "") }
    }
    private var modulesPage: some View {
        Form {
            Section("Встроенные модули") {
                ForEach(ModuleID.allCases) { id in
                    HStack {
                        Image(systemName: id.symbol).font(.system(size: 18)).foregroundStyle(model.module(id)?.accent ?? .mint).frame(width: 29)
                        Toggle(id.title, isOn: Binding(get: { preferences.value.isEnabled(id) }, set: { enabled in
                            if enabled { if !preferences.value.enabledModules.contains(id.rawValue) { preferences.value.enabledModules.append(id.rawValue) } }
                            else { preferences.value.enabledModules.removeAll { $0 == id.rawValue } }
                        }))
                        Stepper("\(preferences.value.priority(id))", value: Binding(get: { preferences.value.priority(id) }, set: { preferences.value.priorities[id.rawValue] = $0 }), in: 0...100, step: 5)
                            .frame(width: 110).help("Чем больше число, тем выше приоритет")
                    }.padding(.vertical, 4)
                }
                Text("Две активности с наибольшим приоритетом занимают края острова. Следующая — боковой индикатор. Работающая запись остаётся видна до сохранения, даже если модуль выключен.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Помодоро") {
                Stepper("Фокус: \(preferences.value.focusMinutes) мин", value: $preferences.value.focusMinutes, in: 1...240)
                Stepper("Перерыв: \(preferences.value.breakMinutes) мин", value: $preferences.value.breakMinutes, in: 1...60)
                Text("После завершения фокуса перерыв ждёт твоего подтверждения.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private var islandPage: some View {
        Form {
            Section("Экран") {
                Picker("Показывать на", selection: $preferences.value.selectedDisplayID) {
                    ForEach(model.displays) { display in Text("\(display.name) · \(display.hasNotch ? "чёлка" : "эмуляция")").tag(display.id) }
                    if !model.displays.contains(where: { $0.id == preferences.value.selectedDisplayID }) { Text("Отключённый монитор").tag(preferences.value.selectedDisplayID) }
                }
                if model.selectedScreen == nil { Text("Остров скрыт: выбранный монитор отключён").foregroundStyle(.orange) }
                else if !model.physical {
                    slider("Ширина", $preferences.value.emulatedWidth, 170...360, "pt")
                    slider("Высота", $preferences.value.emulatedHeight, 28...60, "pt")
                    Slider(value: $preferences.value.horizontalPosition, in: 0...1) { Text("Горизонтальная позиция") }
                    slider("Отступ сверху", $preferences.value.topOffset, 0...120, "pt")
                    Text("На этом экране остров эмулируется окном.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Взаимодействие") {
                Toggle("Раскрывать при наведении", isOn: $preferences.value.hoverExpands)
                slider("Зона чувствительности наведения", $preferences.value.hoverPadding, 0...24, "pt")
                slider("Задержка раскрытия", $preferences.value.hoverDelay, 0...300, "мс")
                Toggle("Отклик трекпада", isOn: $preferences.value.haptics)
                Toggle("Акцент из обложки", isOn: $preferences.value.artworkAccent)
                slider("Музыка скрывается после паузы", $preferences.value.pauseTimeout, 1...60, "сек")
                slider("Закрывать центр без взаимодействия", $preferences.value.inactivityTimeout, 2...60, "сек")
                Text("В спокойном состоянии остаётся небольшой вход в центр. Историю можно открыть свайпом вниз по верхней панели или кнопкой часов. «Уменьшение движения» учитывается автоматически.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    private func slider(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { HStack { Text(title); Spacer(); Text("\(Int(binding.wrappedValue)) \(unit)").foregroundStyle(.secondary).monospacedDigit() }; Slider(value: binding, in: range, step: 1) }
    }
    private var systemPage: some View {
        Form {
            Section("Автозапуск") {
                Toggle("Запускать при входе в систему", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                if model.loginNeedsApproval { Button("Подтвердить в Объектах входа") { SMAppService.openSystemSettingsLoginItems() } }
                Text("Для постоянного запуска помести собранный NotchBeat.app в «Программы».").font(.caption).foregroundStyle(.secondary)
            }
            Section("Разрешения") {
                Button("Автоматизация → Spotify") { model.openPrivacy("Privacy_Automation") }
                Button("Календари") { model.openPrivacy("Privacy_Calendars") }
                Button("Напоминания") { model.openPrivacy("Privacy_Reminders") }
                Button("Запись экрана и системного аудио") { model.openPrivacy("Privacy_ScreenCapture") }
                Button("Микрофон") { model.openPrivacy("Privacy_Microphone") }
                Text("Разрешения запрашиваются, когда ты подключаешь календарь или начинаешь запись. Для Spotify: «Автоматизация → NotchBeat → Spotify». Accessibility не нужен. AirDrop использует системный выбор получателя и файла.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Область работы") {
                Text("Загрузки и записи запускаются из центра NotchBeat. Прогресс произвольных операций Finder и чужих записей здесь не показывается. Входящий AirDrop обрабатывает macOS.").font(.caption).foregroundStyle(.secondary)
                Text("MediaRemote — приватный системный источник, который macOS может ограничить. Spotify имеет отдельный локальный путь без OAuth.").font(.caption).foregroundStyle(.secondary)
                Text("История хранится только в памяти за последний час. Внешние плагины не подключаются.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
@MainActor private struct MusicSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var module: MusicModule
    @ObservedObject var preferences: PreferencesStore
    @State private var exclusion = ""
    @State private var connecting = false
    var body: some View {
        Form {
            Section("Проигрыватель") {
                Text(module.status).font(.callout)
                if let value = module.snapshot { LabeledContent("Сейчас", value: value.title); LabeledContent("Источник", value: value.source.rawValue) }
                Toggle("Локальный резервный источник Spotify", isOn: $preferences.value.spotifyEnabled)
                Button(connecting ? "Подключаю…" : "Подключить Spotify") { connecting = true; Task { await module.connect(); connecting = false } }.disabled(connecting)
                Button("Открыть Spotify") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in } }
                    else { model.notice = "Настольный Spotify не найден" }
                }
            }
            Section("Исключённые приложения") {
                ForEach(preferences.value.excludedBundleIDs, id: \.self) { id in HStack { Text(id).font(.caption); Spacer(); Button { preferences.value.excludedBundleIDs.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless) } }
                HStack { TextField("Bundle ID", text: $exclusion); Button("Добавить") { let text = exclusion.trimmingCharacters(in: .whitespacesAndNewlines); if !text.isEmpty && !preferences.value.excludedBundleIDs.contains(text) { preferences.value.excludedBundleIDs.append(text) }; exclusion = "" } }
                Button("Выбрать приложение…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.begin { result in guard result == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }; Task { @MainActor in if !preferences.value.excludedBundleIDs.contains(id) { preferences.value.excludedBundleIDs.append(id) } } }
                }
            }
        }.formStyle(.grouped)
    }
}
@MainActor private struct CalendarSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var module: CalendarModule
    @ObservedObject var preferences: PreferencesStore
    var body: some View {
        Form {
            Section("Доступ") {
                Text(module.status).font(.callout)
                Button("Подключить календарь") { Task { await module.requestAccess() } }
                Text("NotchBeat читает только выбранные источники. События не изменяются.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Выбери источники") {
                if module.calendars.isEmpty { Text("Список появится после разрешения доступа").foregroundStyle(.secondary) }
                ForEach(module.calendars) { calendar in
                    Toggle("\(calendar.title) · \(calendar.source)", isOn: Binding(get: { preferences.value.selectedCalendarIDs.contains(calendar.id) }, set: { selected in
                        if selected { preferences.value.selectedCalendarIDs.append(calendar.id) }
                        else { preferences.value.selectedCalendarIDs.removeAll { $0 == calendar.id } }
                    }))
                }
            }
            Section("События на ближайшие 7 дней") {
                if module.events.isEmpty { Text(module.status).foregroundStyle(.secondary) }
                ForEach(module.events) { event in CalendarEventRow(event: event) }
                Button("Обновить события") { module.refresh() }
            }
            Section("Напоминания о событиях") {
                Stepper("За \(preferences.value.calendarReminderMinutes) мин", value: $preferences.value.calendarReminderMinutes, in: 1...120)
                Stepper("Показывать события за \(preferences.value.calendarLookaheadMinutes) мин", value: $preferences.value.calendarLookaheadMinutes, in: 5...240, step: 5)
            }
        }.formStyle(.grouped)
    }
}

@MainActor private struct RemindersSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var module: RemindersModule
    @ObservedObject var preferences: PreferencesStore
    var body: some View {
        Form {
            Section("Островок") {
                Toggle("Показывать счётчик задач в островке", isOn: $preferences.value.showRemindersInIsland)
                Text("Показывает значок и количество оставшихся задач сверху. При выключении напоминания остаются подключёнными: список задач, добавление, отметки выполнения и системные оповещения продолжают работать.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Подключение") {
                Button(module.connectionActionTitle) { Task { await module.requestAccess() } }
                    .disabled(module.requestingAccess)
                if !module.granted { Text(module.status).font(.caption).foregroundStyle(.secondary) }
                Text("При первом подключении выбраны все списки. Отметка выполнения и добавление изменяют системные Напоминания и синхронизируются через твой аккаунт.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Выбранные списки") {
                ForEach(module.lists) { list in
                    Toggle(list.title, isOn: Binding(get: { preferences.value.selectedReminderListIDs.contains(list.id) }, set: { selected in
                        if selected { if !preferences.value.selectedReminderListIDs.contains(list.id) { preferences.value.selectedReminderListIDs.append(list.id) } }
                        else { preferences.value.selectedReminderListIDs.removeAll { $0 == list.id } }
                    }))
                }
            }
            Section("Задачи") { RemindersPanel(module: module) }
        }.formStyle(.grouped)
    }
}
