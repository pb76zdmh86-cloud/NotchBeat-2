import Foundation

@main enum CoreChecks {
    static func main() {
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
        assert(ActivitySelection.resolve(others + [reminder], showReminders: false) == ActivitySelection.resolve(others),
               "Hidden reminders must not occupy a primary/minimal slot or inflate overflow")
        assert(ActivitySelection.resolve([reminder, others[2]], showReminders: false).primary == [.downloads],
               "Other activities must remain visible when reminders are hidden")
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
