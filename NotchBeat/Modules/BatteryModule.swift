import SwiftUI
import IOKit.ps

@MainActor final class BatteryModule: BuiltInModule {
    @Published private(set) var percentage = 0
    @Published private(set) var plugged = false
    @Published private(set) var charging = false
    @Published private(set) var available = false
    private var clock: Timer?
    private var pulseUntil = Date.distantPast
    private var firstRead = true
    private var changeID = UUID()
    override init(id: ModuleID = .battery) { super.init(id: id) }
    override var accent: Color { plugged ? .green : .yellow }
    override var activity: ModuleActivity? {
        guard available, Date() < pulseUntil else { return nil }
        return ModuleActivity(token: changeID.uuidString, title: plugged ? "Питание подключено" : "Питание отключено", detail: "Заряд \(percentage)%")
    }
    override func start() {
        guard clock == nil else { return }
        read()
        clock = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.read() } }
    }
    override func stop() { clock?.invalidate(); clock = nil }
    private func read() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { available = false; return }
        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = (values[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
            let maximum = max(1, (values[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100)
            let ac = values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            if !firstRead && ac != plugged { pulseUntil = Date().addingTimeInterval(8); changeID = UUID() }
            plugged = ac; percentage = min(100, max(0, Int(current / maximum * 100)))
            charging = (values[kIOPSIsChargingKey] as? NSNumber)?.boolValue ?? false
            available = true; firstRead = false; changed(); return
        }
        available = false; changed()
    }
    override func compactView(in region: CompactRegion) -> AnyView {
        if region == .leading { return AnyView(Image(systemName: plugged ? "bolt.fill" : "battery.50").foregroundStyle(accent)) }
        return AnyView(Text("\(percentage)%").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(accent))
    }
    override var expandedView: AnyView { AnyView(BatteryPanel(module: self)) }
}
@MainActor private struct BatteryPanel: View {
    @ObservedObject var module: BatteryModule
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: module.plugged ? "battery.100.bolt" : "battery.75").font(.system(size: 42)).foregroundStyle(module.accent)
            Text(module.available ? "\(module.percentage)%" : "Нет встроенной батареи").font(.system(size: 43, weight: .light, design: .rounded))
            Text(module.charging ? "Заряжается" : module.plugged ? "Питание от сети" : "Питание от батареи").font(.callout).foregroundStyle(.secondary)
            ProgressView(value: Double(module.percentage) / 100).tint(module.accent)
        }
    }
}
