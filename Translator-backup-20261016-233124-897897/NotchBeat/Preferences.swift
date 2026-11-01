import Foundation
import Combine
struct UserPreferences: Codable, Equatable {
    var selectedDisplayID = ""
    var pauseTimeout: Double = 5
    var inactivityTimeout: Double = 8
    var hoverExpands = true
    var hoverPadding: Double = 12
    var hoverDelay: Double = 30
    var schemaRevision = 3
    var selectedReminderListIDs: [String] = []
    var spotifyEnabled = false
    var emulatedWidth: Double = 230
    var emulatedHeight: Double = 36
    var horizontalPosition: Double = 0.5
    var topOffset: Double = 0
    var excludedBundleIDs: [String] = []
    var onboardingCompleted = false
    var enabledModules = ModuleID.allCases.map(\.rawValue)
    var priorities: [String: Int] = [:]
    var selectedCalendarIDs: [String] = []
    var calendarReminderMinutes = 10
    var calendarLookaheadMinutes = 60
    var haptics = true
    var artworkAccent = true
    var focusMinutes = 25
    var breakMinutes = 5
    func isEnabled(_ id: ModuleID) -> Bool { enabledModules.contains(id.rawValue) }
    func priority(_ id: ModuleID) -> Int { priorities[id.rawValue] ?? id.defaultPriority }
    mutating func validate() {
        hoverPadding = min(24, max(0, hoverPadding.isFinite ? hoverPadding : 12))
        hoverDelay = min(300, max(0, hoverDelay.isFinite ? hoverDelay : 30))
        pauseTimeout = min(60, max(1, pauseTimeout.isFinite ? pauseTimeout : 5))
        inactivityTimeout = min(60, max(2, inactivityTimeout.isFinite ? inactivityTimeout : 8))
        emulatedWidth = min(360, max(170, emulatedWidth.isFinite ? emulatedWidth : 230))
        emulatedHeight = min(60, max(28, emulatedHeight.isFinite ? emulatedHeight : 36))
        horizontalPosition = min(1, max(0, horizontalPosition.isFinite ? horizontalPosition : 0.5))
        topOffset = min(120, max(0, topOffset.isFinite ? topOffset : 0))
        excludedBundleIDs = Array(Set(excludedBundleIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        enabledModules = enabledModules.filter { ModuleID(rawValue: $0) != nil }
        calendarReminderMinutes = min(120, max(1, calendarReminderMinutes))
        calendarLookaheadMinutes = min(240, max(calendarReminderMinutes, calendarLookaheadMinutes))
        focusMinutes = min(240, max(1, focusMinutes)); breakMinutes = min(60, max(1, breakMinutes))
    }
}
@MainActor final class PreferencesStore: ObservableObject {
    private let defaults: UserDefaults
    @Published var value: UserPreferences { didSet { if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "NotchBeat.preferences.v2") } } }
    private static func decodeMigrating(_ data: Data) -> UserPreferences? {
        guard var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(UserPreferences()),
              var defaults = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any] else { return nil }
        if stored["schemaRevision"] == nil {
            var enabled = stored["enabledModules"] as? [String] ?? ModuleID.allCases.map(\.rawValue)
            if !enabled.contains(ModuleID.reminders.rawValue) { enabled.append(ModuleID.reminders.rawValue) }
            stored["enabledModules"] = enabled
        }
        stored["schemaRevision"] = 3
        defaults.merge(stored) { _, saved in saved }
        guard let merged = try? JSONSerialization.data(withJSONObject: defaults) else { return nil }
        return try? JSONDecoder().decode(UserPreferences.self, from: merged)
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "NotchBeat.preferences.v2"), var decoded = Self.decodeMigrating(data) {
            decoded.validate(); value = decoded
        } else {
            var initial = UserPreferences()
            if let bytes = defaults.data(forKey: "NotchBeat.preferences.v1"),
               let old = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] {
                initial.selectedDisplayID = old["selectedDisplayID"] as? String ?? ""
                initial.spotifyEnabled = old["spotifyEnabled"] as? Bool ?? false
                initial.pauseTimeout = old["pauseTimeout"] as? Double ?? 5
                initial.hoverExpands = old["hoverExpands"] as? Bool ?? true
                initial.excludedBundleIDs = old["excludedBundleIDs"] as? [String] ?? []
                initial.horizontalPosition = old["horizontalPosition"] as? Double ?? 0.5
                initial.topOffset = old["topOffset"] as? Double ?? 0
            }
            initial.validate(); value = initial
        }
    }
}
