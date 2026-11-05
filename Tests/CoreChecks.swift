import Foundation

@main enum CoreChecks {
    static func main() {
        var reminderAccess = ReminderAccessSession()
        assert(!reminderAccess.granted)
        reminderAccess.completeRequest(granted: true)
        reminderAccess.update(.notDetermined)
        assert(reminderAccess.granted, "A stale undecided status must not discard a successful permission request")
        reminderAccess.update(.fullAccess)
        assert(reminderAccess.granted)
        reminderAccess.update(.denied)
        assert(!reminderAccess.granted, "Revoking permission must take effect")
        reminderAccess.update(.notDetermined)
        assert(!reminderAccess.granted, "A previous request must not survive revoked permission")
        reminderAccess.completeRequest(granted: false)
        assert(!reminderAccess.granted)
        reminderAccess.completeRequest(granted: true)
        reminderAccess.invalidateRequestGrant()
        assert(!reminderAccess.granted, "A failed fetch must invalidate the transient request grant")
        reminderAccess.completeRequest(granted: true)
        reminderAccess.update(.restricted)
        assert(!reminderAccess.granted)
        let base = Date(timeIntervalSince1970: 1000)
        var focus = FocusSession()
        focus.start(focus: 25 * 60, rest: 5 * 60, now: base)
        focus.tick(now: base.addingTimeInterval(1500))
        assert(focus.phase == .awaitingBreak)
        focus.tick(now: base.addingTimeInterval(10_000))
        assert(focus.phase == .awaitingBreak && focus.deadline == nil, "Break must never start without confirmation")
        focus.confirmBreak(now: base.addingTimeInterval(10_000))
        assert(focus.phase == .rest && focus.remaining(at: base.addingTimeInterval(10_100)) == 200)
        focus.tick(now: base.addingTimeInterval(10_300))
        assert(focus.phase == .finished)
        focus.start(focus: 120, rest: 60, now: base)
        focus.pause(now: base.addingTimeInterval(30))
        assert(focus.remaining(at: base.addingTimeInterval(9000)) == 90, "Sleep while paused must not consume time")
        focus.resume(now: base.addingTimeInterval(9000))
        assert(focus.remaining(at: base.addingTimeInterval(9045)) == 45)
        focus.tick(now: base.addingTimeInterval(50_000))
        assert(focus.phase == .awaitingBreak, "A missed timer after sleep is resolved by deadline, not tick count")
        focus.reset(); assert(focus.phase == .idle && focus.deadline == nil)
        let selection = ActivitySelection.resolve([ActivityCandidate(id: .music, priority: 70), ActivityCandidate(id: .timer, priority: 80), ActivityCandidate(id: .calendar, priority: 60), ActivityCandidate(id: .battery, priority: 20)])
        assert(selection.primary == [.timer, .music] && selection.minimal == .calendar && selection.overflow == 1)
        let urgent = ActivitySelection.resolve([ActivityCandidate(id: .music, priority: 70), ActivityCandidate(id: .timer, priority: 80), ActivityCandidate(id: .recording, priority: 90)])
        assert(urgent.primary == [.recording, .timer] && urgent.minimal == .music)
        let duplicate = ActivitySelection.resolve([ActivityCandidate(id: .timer, priority: 80), ActivityCandidate(id: .timer, priority: 80)])
        assert(duplicate.primary == [.timer] && duplicate.minimal == nil)
        let reminder = ActivityCandidate(id: .reminders, priority: 55)
        let hiddenOnly = ActivitySelection.resolve([reminder], showReminders: false)
        assert(hiddenOnly.primary.isEmpty && hiddenOnly.minimal == nil && hiddenOnly.overflow == 0,
               "Hidden reminders must not keep an empty compact island open")
        assert(ActivitySelection.resolve([reminder], showReminders: true).primary == [.reminders],
               "Showing reminders again must restore their activity")
        let others = [ActivityCandidate(id: .timer, priority: 80), ActivityCandidate(id: .music, priority: 70),
                      ActivityCandidate(id: .downloads, priority: 40), ActivityCandidate(id: .battery, priority: 20)]
        let mixed = ActivitySelection.resolve(others + [reminder], showReminders: false)
        assert(mixed.primary == [.timer, .music] && mixed.minimal == .reminders && mixed.overflow == 2,
               "Hiding a minimal reminder must not move other activities into its slot")
        for priority in [10, 55, 100] {
            let candidates = others + [ActivityCandidate(id: .reminders, priority: priority)]
            let before = ActivitySelection.resolve(candidates)
            let after = ActivitySelection.resolve(candidates, showReminders: false)
            assert(after.primary == before.primary, "Primary positions and island width must stay unchanged")
            assert(after.minimal == before.minimal, "Other activity counters must keep their side slot")
            assert(after.overflow == before.overflow - (priority == 10 ? 1 : 0))
        }
        assert(ActivitySelection.resolve([reminder, others[2]], showReminders: false).primary == [.reminders, .downloads],
               "The download must stay in its trailing slot while the reminder slot is hidden")
        var history = ActivityHistory()
        let activity = ModuleActivity(token: "track1", title: "Song", detail: "Artist")
        for offset in 0..<100 { history.observe(id: .music, activity: activity, at: base.addingTimeInterval(Double(offset))) }
        assert(history.entries.count == 1, "Polling must not fill the history with duplicates")
        history.observe(id: .music, activity: nil, at: base.addingTimeInterval(100))
        history.observe(id: .music, activity: activity, at: base.addingTimeInterval(101))
        assert(history.entries.count == 2)
        history.prune(at: base.addingTimeInterval(4000)); assert(history.entries.isEmpty)
        assert(!SourcePolicy.permits(bundleID: "COM.SPOTIFY.CLIENT", exclusions: ["com.spotify.client"]))
        assert(!SourcePolicy.permits(bundleID: nil, exclusions: ["com.spotify.client"]))
        assert(SourcePolicy.permits(bundleID: nil, exclusions: []))
        print("PASS: confirmation-only breaks, pause/resume, sleep, ranking, minimal/overflow, deduplicated history and source exclusions")
    }
}
