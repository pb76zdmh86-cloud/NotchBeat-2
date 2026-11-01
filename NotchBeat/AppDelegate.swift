import AppKit
import SwiftUI
import Combine
import UserNotifications

@main enum NotchBeatMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel()
    private var island: IslandWindowController?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMainMenu()
        createStatusItem()
        island = IslandWindowController(model: model)
        model.onSettings = { [weak self] in self?.showSettings() }
        UNUserNotificationCenter.current().delegate = self
        model.start()
        island?.updateLayout()
        if !model.preferences.value.onboardingCompleted { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) { island?.stop(); model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { model.openCenter(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.recording.capturing else { return .terminateNow }
        Task {
            await model.recording.finish()
            for _ in 0..<50 where model.recording.state == .finishing { try? await Task.sleep(nanoseconds: 100_000_000) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 700),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "NotchBeat"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        model.refreshLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showDemo() { model.showDemo() }
    @objc private func openCenter() { model.openCenter() }
    @objc private func endDemo() { model.endDemo() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self
        return item
    }

    private func createStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = NSImage(systemSymbolName: "waveform", accessibilityDescription: "NotchBeat")
        icon?.isTemplate = true
        status.button?.image = icon
        status.button?.toolTip = "NotchBeat — центр активностей"
        let menu = NSMenu()
        menu.addItem(item("Открыть центр", #selector(openCenter)))
        menu.addItem(item("Настройки…", #selector(showSettings), key: ","))
        menu.addItem(item("Проверить остров (15 секунд)", #selector(showDemo)))
        menu.addItem(item("Завершить демонстрацию", #selector(endDemo)))
        menu.addItem(.separator())
        menu.addItem(item("Завершить NotchBeat", #selector(quit), key: "q"))
        status.menu = menu; statusItem = status
    }

    private func createMainMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: "NotchBeat")
        appMenu.addItem(item("Открыть центр", #selector(openCenter), key: "1"))
        appMenu.addItem(item("Настройки…", #selector(showSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Завершить NotchBeat", #selector(quit), key: "q"))
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "Правка")
        for (title, selector, key) in [("Вырезать", "cut:", "x"), ("Копировать", "copy:", "c"), ("Вставить", "paste:", "v"), ("Выделить всё", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
}
