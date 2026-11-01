import SwiftUI
import AppKit

enum CompactRegion: Equatable { case leading, trailing }
@MainActor protocol IslandModule: AnyObject {
    var id: ModuleID { get }
    var priority: Int { get set }
    var enabled: Bool { get set }
    var activity: ModuleActivity? { get }
    var accent: Color { get }
    var activityDidChange: (() -> Void)? { get set }
    func compactView(in region: CompactRegion) -> AnyView
    var expandedView: AnyView { get }
    var minimalView: AnyView { get }
    func start()
    func stop()
    func pause()
}

@MainActor class BuiltInModule: NSObject, ObservableObject, IslandModule {
    let id: ModuleID
    var priority: Int
    var enabled = true
    var activityDidChange: (() -> Void)?
    var notify: ((String) -> Void)?
    init(id: ModuleID) { self.id = id; priority = id.defaultPriority; super.init() }
    var activity: ModuleActivity? { nil }
    var accent: Color { .mint }
    func compactView(in region: CompactRegion) -> AnyView { AnyView(Image(systemName: id.symbol).foregroundStyle(accent)) }
    var expandedView: AnyView { AnyView(Text(id.title)) }
    var minimalView: AnyView { AnyView(Image(systemName: id.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)) }
    func start() {}
    func stop() {}
    func pause() {}
    func changed() { activityDidChange?() }
}

@MainActor enum InteractionFeedback {
    static var enabled = true
    static func tap() {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

@MainActor struct ModuleButton: View {
    var title: String
    var symbol: String
    var tint: Color = .mint
    var action: () -> Void
    var body: some View {
        Button { InteractionFeedback.tap(); action() } label: {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 10)
                .frame(maxWidth: .infinity).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13)).foregroundStyle(tint)
        }.buttonStyle(.plain)
    }
}

enum DisplayTime {
    static func clock(_ seconds: Double) -> String { let s = Int(max(0, seconds.isFinite ? seconds : 0)); return String(format: "%02d:%02d", s / 60, s % 60) }
}
