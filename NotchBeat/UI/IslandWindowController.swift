import AppKit
import SwiftUI

struct IslandHitRegion: Equatable {
    var id: String
    var frame: CGRect
    var physical: Bool
}
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
private final class IslandHost: NSHostingView<IslandView> {
    override var needsPanelToBecomeKey: Bool { true }
}
@MainActor final class IslandWindowController: NSObject {
    private let model: AppModel
    private let panel: IslandPanel
    private var regions: [IslandHitRegion] = []
    private var pointerTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hoverTask: Task<Void, Never>?
    private var pointerWasInside = false
    private var scrollTotal: CGFloat = 0
    private var lastSwipe = Date.distantPast
    init(model: AppModel) {
        self.model = model
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.isMovable = false
        panel.becomesKeyOnlyIfNeeded = true; panel.acceptsMouseMovedEvents = true; panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true; panel.title = "NotchBeat Center"
        let host = IslandHost(rootView: IslandView(model: model)); host.sizingOptions = []; panel.contentView = host
        model.onLayoutChange = { [weak self] in self?.updateLayout() }
        model.onGeometryChange = { [weak self] in self?.regions = $0; self?.updatePointer() }
        model.onQuickMenu = { [weak self] in self?.quickMenu() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel, .keyDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updatePointer()
                if let self, event.windowNumber == self.panel.windowNumber {
                    if event.type != .mouseMoved { self.model.noteInteraction() }
                    if event.type == .scrollWheel { self.scroll(event) }
                }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in MainActor.assumeIsolated { self?.updatePointer() } }
    }
    func updateLayout() {
        guard let screen = model.selectedScreen else { panel.orderOut(nil); return }
        if model.mode == .collapsed && !model.preferences.value.showRemindersInIsland {
            hoverTask?.cancel()
            pointerWasInside = false
            panel.orderOut(nil)
            return
        }
        let size = CGSize(width: min(740, screen.frame.width), height: min(500, screen.frame.height))
        let center = screen.physicalNotch?.midX ?? screen.frame.minX + screen.frame.width * model.preferences.value.horizontalPosition
        let offset = screen.physicalNotch == nil ? model.preferences.value.topOffset : 0
        let originX = min(max(screen.frame.minX, center - size.width / 2), screen.frame.maxX - size.width)
        model.canvasSize = size; model.anchorX = center - originX
        // Window geometry stays fixed during all SwiftUI springs: no 60 Hz setFrame loop.
        let frame = CGRect(x: originX, y: screen.frame.maxY - offset - size.height, width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        if pointerTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updatePointer() } }
            pointerTimer = timer; RunLoop.main.add(timer, forMode: .common)
        }
        updatePointer()
    }
    private func updatePointer() {
        guard panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x - panel.frame.minX, y: panel.frame.maxY - mouse.y)
        let visualInside = regions.contains { region in
            let local = CGPoint(x: point.x - region.frame.minX, y: point.y - region.frame.minY)
            return region.frame.contains(point) && IslandContour.cgPath(in: CGRect(origin: .zero, size: region.frame.size), physical: region.physical).contains(local)
        } && !(model.notch?.contains(mouse) ?? false)
        panel.ignoresMouseEvents = !visualInside
        // Larger hover target only; clicks still pass through outside the visible shape.
        let padding = CGFloat(model.preferences.value.hoverPadding)
        let inside = regions.contains { $0.frame.insetBy(dx: -padding, dy: -padding).contains(point) }
        guard pointerWasInside != inside else { return }
        pointerWasInside = inside; hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: inside ? UInt64(self?.model.preferences.value.hoverDelay ?? 30) * 1_000_000 : 220_000_000)
            guard !Task.isCancelled else { return }
            self?.model.hover(inside)
        }
    }
    private func scroll(_ event: NSEvent) {
        guard pointerWasInside, model.mode == .expanded, let primary = regions.first(where: { $0.id == "primary" }) else { return }
        let localY = panel.frame.maxY - NSEvent.mouseLocation.y - primary.frame.minY
        guard localY < model.headerHeight + 57 else { return }
        if event.phase == .began { scrollTotal = 0 }
        scrollTotal += event.scrollingDeltaY
        if scrollTotal > 40 && Date().timeIntervalSince(lastSwipe) > 1 { lastSwipe = .now; scrollTotal = 0; model.showHistory() }
        if event.phase == .ended || event.phase == .cancelled { scrollTotal = 0 }
    }
    private func quickMenu() {
        let menu = NSMenu()
        let pause = NSMenuItem(title: "Пауза активностей", action: #selector(pauseActivities), keyEquivalent: ""); pause.target = self
        let settings = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ""); settings.target = self
        menu.addItem(pause); menu.addItem(settings)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    @objc private func pauseActivities() { model.pauseAll() }
    @objc private func openSettings() { model.requestSettings() }
    func stop() {
        pointerTimer?.invalidate(); hoverTask?.cancel(); panel.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        model.onLayoutChange = nil; model.onGeometryChange = nil; model.onQuickMenu = nil
    }
}
