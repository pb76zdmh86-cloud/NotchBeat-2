import SwiftUI
import AppKit

private struct RegionPreference: PreferenceKey {
    static let defaultValue: [IslandHitRegion] = []
    static func reduce(value: inout [IslandHitRegion], nextValue: () -> [IslandHitRegion]) { value.append(contentsOf: nextValue()) }
}
private struct BlurLayer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView(); view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active; return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
@MainActor struct IslandView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemTheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var size = CGSize(width: 220, height: 38)
    private var spring: Animation { .spring(response: 0.46, dampingFraction: 0.84, blendDuration: 0.12) }
    private var x: CGFloat { min(max(size.width / 2 + 24, model.anchorX), model.canvasSize.width - size.width / 2 - 24) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            primary
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(report("primary", physical: model.physical))
                .position(x: x, y: size.height / 2)
            if model.mode == .compact, let minimal = model.module(model.selection.minimal) {
                Button { model.openCenter(minimal.id) } label: {
                    HStack(spacing: 2) {
                        MinimalSlot(module: minimal).frame(width: 20, height: 20)
                        if model.selection.overflow > 0 { Text("+\(model.selection.overflow)").font(.system(size: 8, weight: .bold)) }
                    }.padding(7).background(.black, in: Capsule())
                }.buttonStyle(.plain)
                    .opacity(hideReminders(minimal) ? 0 : 1)
                    .allowsHitTesting(!hideReminders(minimal))
                    .accessibilityHidden(hideReminders(minimal))
                    .background(report("minimal", physical: false))
                    .position(x: x + (x + size.width / 2 + 46 > model.canvasSize.width ? -1 : 1) * (size.width / 2 + 25), y: min(size.height / 2, 22))
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .frame(width: model.canvasSize.width, height: model.canvasSize.height, alignment: .topLeading)
        .coordinateSpace(name: "islandCanvas")
        .onPreferenceChange(RegionPreference.self) { model.onGeometryChange?($0) }
        .onAppear { size = model.desiredSize }
        .onChange(of: model.desiredSize) { _, value in withAnimation(reduceMotion ? nil : spring) { size = value } }
        .animation(reduceMotion ? nil : spring, value: model.selection)
        .onExitCommand { model.collapse() }
    }
    private var primary: some View {
        ZStack(alignment: .top) {
            if model.mode == .expanded {
                expandedSurface.allowsHitTesting(false)
                // The physical camera remains opaque while the surrounding panel is glass.
                if let notch = model.notch {
                    Rectangle().fill(.black).frame(width: notch.width, height: model.headerHeight)
                        .allowsHitTesting(false)
                }
                expanded.transition(.opacity)
            } else if model.mode == .compact {
                IslandShape(physical: model.physical).fill(.black)
                compact.transition(.opacity)
            } else {
                IslandShape(physical: model.physical).fill(.black)
                Button { model.openCenter() } label: {
                    VStack { Spacer(); Capsule().fill(.white.opacity(0.23)).frame(width: 16, height: 2).padding(.bottom, 3) }
                        .frame(width: model.desiredSize.width, height: model.desiredSize.height).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Открыть NotchBeat")
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(IslandShape(physical: model.physical))
         .overlay {
            IslandShape(physical: model.physical).stroke(
                LinearGradient(colors: [.white.opacity(model.mode == .expanded ? 0.48 : 0.035), .white.opacity(0.06), .white.opacity(model.mode == .expanded ? 0.2 : 0.035)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8
            ).allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(model.mode == .expanded ? 0.34 : 0.1), radius: model.mode == .expanded ? 18 : 3, y: model.mode == .expanded ? 10 : 2)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in InteractionFeedback.tap(); model.onQuickMenu?() })
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : spring, value: model.mode)
    }
    @ViewBuilder private var expandedSurface: some View {
        if reduceTransparency {
            IslandShape(physical: model.physical).fill(Color(white: 0.12))
        } else {
            // Swift 6.2 / Xcode 26 supplies the macOS 26 Liquid Glass SDK.
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                Color.clear.frame(width: size.width, height: size.height)
                    .glassEffect(.regular.tint(model.tint.opacity(0.12)), in: IslandShape(physical: model.physical))
            } else {
                legacyGlassSurface
            }
            #else
            legacyGlassSurface
            #endif
        }
    }
    private var legacyGlassSurface: some View {
        ZStack {
            BlurLayer()
            Color.black.opacity(0.22)
            LinearGradient(colors: [.white.opacity(0.14), .clear, model.tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }.frame(width: size.width, height: size.height)
    }
    private func report(_ id: String, physical: Bool) -> some View {
        GeometryReader { geometry in Color.clear.preference(key: RegionPreference.self,
            value: [IslandHitRegion(id: id, frame: geometry.frame(in: .named("islandCanvas")), physical: physical)]) }
    }
    private var compact: some View {
        let leading = model.module(model.selection.primary.first)
        let trailing = model.module(model.selection.primary.count > 1 ? model.selection.primary.last : model.selection.primary.first)
        return HStack(spacing: 0) {
            Button { model.openCenter(leading?.id) } label: {
                HStack(spacing: 5) {
                    if let leading { CompactSlot(module: leading, region: .leading) }
                    if model.selection.primary.count > 1, let leading, leading.id == .timer { CompactSlot(module: leading, region: .trailing) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .opacity(hideReminders(leading) ? 0 : 1)
                .allowsHitTesting(!hideReminders(leading))
                .accessibilityHidden(hideReminders(leading))
            Color.clear.frame(width: model.notch?.width ?? 20)
            Button { model.openCenter(trailing?.id) } label: {
                HStack(spacing: 5) {
                    if model.selection.primary.count > 1, let trailing,
                       (trailing.id == .music || trailing.id == .reminders) { CompactSlot(module: trailing, region: .leading) }
                    if let trailing { CompactSlot(module: trailing, region: .trailing) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .opacity(hideReminders(trailing) ? 0 : 1)
                .allowsHitTesting(!hideReminders(trailing))
                .accessibilityHidden(hideReminders(trailing))
        }.padding(.horizontal, 12).frame(width: model.desiredSize.width, height: model.desiredSize.height)
    }
    private func hideReminders(_ module: BuiltInModule?) -> Bool {
        module?.id == .reminders && !model.preferences.value.showRemindersInIsland
    }
    private var expanded: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.headerHeight + 10)
            HStack(spacing: 10) {
                Button { model.select(nil) } label: { Image(systemName: "square.grid.2x2.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.58)).frame(width: 36, height: 36).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Все модули")
                Text(model.showingHistory ? "Последний час" : model.selectedModule?.title ?? "NotchBeat").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { model.showHistory() } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 36, height: 36).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("История активностей")
                Button { model.requestSettings() } label: { Image(systemName: "slider.horizontal.3").frame(width: 36, height: 36).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Настройки")
                Button { model.collapse() } label: { Image(systemName: "chevron.up").frame(width: 36, height: 36).contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("Свернуть")
            }.foregroundStyle(.white.opacity(0.7)).padding(.horizontal, 18)
                .simultaneousGesture(DragGesture(minimumDistance: 12).onEnded { value in if value.translation.height > 30 { model.showHistory() } })
            HStack(spacing: 6) {
                ForEach(model.enabledModules, id: \.id) { module in
                    Button { model.select(module.id) } label: {
                        Image(systemName: module.id.symbol).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 40).contentShape(Rectangle())
                            .foregroundStyle(model.selectedModule == module.id ? module.accent : .white.opacity(0.38))
                            .background(model.selectedModule == module.id ? module.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel(module.id.title)
                }
            }.padding(.horizontal, 19).padding(.top, 10)
            ScrollView {
                VStack(spacing: 12) {
                    if model.showingHistory { history }
                    else if let module = model.module(model.selectedModule) { module.expandedView }
                    else { home }
                    if let notice = model.notice {
                        HStack(alignment: .top) {
                            Text(notice).font(.caption2).foregroundStyle(.orange)
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.frame(maxWidth: .infinity).padding(19)
            }.scrollIndicators(.hidden).frame(height: 274)
        }.frame(width: 480).foregroundStyle(.white)
    }
    private var home: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Твои активности в одном месте").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(model.enabledModules, id: \.id) { module in
                    Button { model.select(module.id) } label: {
                        VStack(alignment: .leading, spacing: 9) {
                            HStack { Image(systemName: module.id.symbol).font(.system(size: 19)).foregroundStyle(module.accent); Spacer(); if module.activity != nil { Circle().fill(module.accent).frame(width: 5, height: 5) } }
                            Text(module.id.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 17))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.history.isEmpty { Text("Активности за последний час появятся здесь").font(.callout).foregroundStyle(.secondary) }
            ForEach(model.history) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.module.symbol).foregroundStyle(model.module(entry.module)?.accent ?? .mint).frame(width: 20)
                    VStack(alignment: .leading, spacing: 4) { Text(entry.title).font(.system(size: 12, weight: .medium)); Text(entry.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Text(entry.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }
    }
}
