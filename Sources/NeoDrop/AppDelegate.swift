import AppKit
import SwiftUI
import NeoDropCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var menuController: MenuController?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsWindowController(model: model)
        settingsWindow = settings
        menuController = MenuController(model: model)
        model.onOpenSettings = { [weak settings] in settings?.show() }
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// A plain AppKit window rather than a `Settings` scene, because NeoDrop has no Dock presence
/// and never installs a main menu.
@MainActor
final class SettingsWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "NeoDrop"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
