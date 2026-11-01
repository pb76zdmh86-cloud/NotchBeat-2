import Foundation

@main enum PreferencesChecks {
    @MainActor static func main() throws {
        let domain = "NotchBeat.migration.check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var connecting = UserPreferences()
        connecting.initializeReminderListsIfNeeded([])
        assert(!connecting.reminderListsInitialized, "An empty EventKit response must not finalize list selection")
        connecting.initializeReminderListsIfNeeded(["first-list", "second-list"])
        assert(connecting.selectedReminderListIDs == ["first-list", "second-list"])
        connecting.selectedReminderListIDs = []
        connecting.initializeReminderListsIfNeeded(["first-list", "second-list"])
        assert(connecting.selectedReminderListIDs.isEmpty, "Manually deselected lists must stay deselected")
        var previous = UserPreferences()
        previous.selectedDisplayID = "saved-display"
        previous.selectedCalendarIDs = ["saved-calendar"]
        previous.enabledModules = ["music", "calendar"]
        previous.spotifyEnabled = true
        previous.pauseTimeout = 17
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous)) as! [String: Any]
        for key in ["schemaRevision", "hoverPadding", "hoverDelay", "selectedReminderListIDs", "showRemindersInIsland"] { json.removeValue(forKey: key) }
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "NotchBeat.preferences.v2")
        let migrated = PreferencesStore(defaults: defaults)
        assert(migrated.value.selectedDisplayID == "saved-display")
        assert(migrated.value.selectedCalendarIDs == ["saved-calendar"])
        assert(migrated.value.spotifyEnabled && migrated.value.pauseTimeout == 17)
        assert(!migrated.value.isEnabled(.battery), "Previously disabled modules must remain disabled")
        assert(migrated.value.isEnabled(.reminders), "The new module must be available after upgrade")
        assert(migrated.value.hoverDelay == 30 && migrated.value.hoverPadding == 12)
        assert(migrated.value.showRemindersInIsland, "Existing users must keep seeing reminders by default")
        migrated.value.showRemindersInIsland = false
        migrated.value.enabledModules.removeAll { $0 == "reminders" }
        let restored = PreferencesStore(defaults: defaults)
        assert(!restored.value.showRemindersInIsland, "Reminder visibility must survive a restart")
        restored.value.showRemindersInIsland = true
        assert(PreferencesStore(defaults: defaults).value.showRemindersInIsland)
        assert(!restored.value.isEnabled(.reminders), "An explicitly disabled new module must not be re-enabled")
        print("PASS: upgrade preserves screen, calendars, module switches and Spotify; missing new fields use defaults")
    }
}
