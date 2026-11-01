import Foundation

enum ModuleID: String, Codable, CaseIterable, Identifiable {
    case music, timer, calendar, reminders, battery, downloads, airDrop, recording
    var id: String { rawValue }
    var title: String {
        switch self { case .music: return "Музыка"; case .timer: return "Фокус"; case .calendar: return "Календарь"
        case .reminders: return "Напоминания"; case .battery: return "Батарея"; case .downloads: return "Загрузки"; case .airDrop: return "AirDrop"; case .recording: return "Запись" }
    }
    var symbol: String {
        switch self { case .music: return "music.note"; case .timer: return "timer"; case .calendar: return "calendar"
        case .reminders: return "checklist"; case .battery: return "battery.100"; case .downloads: return "arrow.down.circle"; case .airDrop: return "airplayaudio"; case .recording: return "record.circle" }
    }
    var defaultPriority: Int {
        switch self { case .recording: return 90; case .timer: return 80; case .music: return 70; case .calendar: return 60
        case .reminders: return 55; case .downloads: return 40; case .airDrop: return 30; case .battery: return 20 }
    }
}
enum IslandMode: String { case collapsed, compact, expanded }
struct ModuleActivity: Equatable { var token: String; var title: String; var detail: String }
struct ActivityCandidate: Equatable { var id: ModuleID; var priority: Int }
struct ActivitySelection: Equatable {
    var primary: [ModuleID]; var minimal: ModuleID?; var overflow: Int
    static func resolve(_ candidates: [ActivityCandidate]) -> ActivitySelection {
        let sorted = candidates.sorted { $0.priority == $1.priority ? $0.id.rawValue < $1.id.rawValue : $0.priority > $1.priority }
        var unique: [ActivityCandidate] = []
        for candidate in sorted where !unique.contains(where: { $0.id == candidate.id }) { unique.append(candidate) }
        return ActivitySelection(primary: Array(unique.prefix(2).map(\.id)), minimal: unique.dropFirst(2).first?.id, overflow: max(0, unique.count - 3))
    }
}
enum FocusPhase: String, Codable { case idle, focus, pausedFocus, awaitingBreak, rest, pausedRest, finished }
struct FocusSession: Codable, Equatable {
    var phase: FocusPhase = .idle
    var cycleID = UUID()
    var focusSeconds: Double = 25 * 60
    var breakSeconds: Double = 5 * 60
    var deadline: Date?
    var pausedRemaining: Double = 0
    var isActive: Bool { phase != .idle && phase != .finished }
    var running: Bool { phase == .focus || phase == .rest }
    func remaining(at now: Date) -> Double {
        if let deadline, running { return max(0, deadline.timeIntervalSince(now)) }
        return max(0, pausedRemaining)
    }
    mutating func start(focus: Double, rest: Double, now: Date) {
        focusSeconds = min(4 * 3600, max(60, focus)); breakSeconds = min(3600, max(60, rest))
        cycleID = UUID(); phase = .focus; deadline = now.addingTimeInterval(focusSeconds); pausedRemaining = 0
    }
    mutating func pause(now: Date) {
        guard running else { return }
        pausedRemaining = remaining(at: now); deadline = nil
        phase = phase == .focus ? .pausedFocus : .pausedRest
    }
    mutating func resume(now: Date) {
        guard phase == .pausedFocus || phase == .pausedRest else { return }
        phase = phase == .pausedFocus ? .focus : .rest
        deadline = now.addingTimeInterval(pausedRemaining); pausedRemaining = 0
    }
    mutating func tick(now: Date) {
        guard running, let deadline, now >= deadline else { return }
        phase = phase == .focus ? .awaitingBreak : .finished
        self.deadline = nil; pausedRemaining = 0
    }
    mutating func confirmBreak(now: Date) {
        guard phase == .awaitingBreak else { return }
        phase = .rest; deadline = now.addingTimeInterval(breakSeconds)
    }
    mutating func reset() { phase = .idle; deadline = nil; pausedRemaining = 0 }
}
struct ActivityHistoryEntry: Identifiable {
    let id = UUID(); var module: ModuleID; var title: String; var detail: String; var date: Date
}
struct ActivityHistory {
    private(set) var entries: [ActivityHistoryEntry] = []
    private var tokens: [ModuleID: String] = [:]
    mutating func observe(id: ModuleID, activity: ModuleActivity?, at now: Date) {
        prune(at: now)
        guard let activity else { tokens[id] = nil; return }
        guard tokens[id] != activity.token else { return }
        tokens[id] = activity.token
        entries.insert(ActivityHistoryEntry(module: id, title: activity.title, detail: activity.detail, date: now), at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
    }
    mutating func prune(at now: Date) { entries.removeAll { now.timeIntervalSince($0.date) > 3600 } }
}
enum SourcePolicy {
    static func permits(bundleID: String?, exclusions: [String]) -> Bool {
        let cleaned = exclusions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return true }
        guard let bundleID, !bundleID.isEmpty else { return false }
        return !cleaned.contains(bundleID.lowercased())
    }
}
