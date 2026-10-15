import AppKit
import SwiftUI
import WebKit
import NeoDropCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var menuController: MenuController?
    private var settingsWindow: SettingsWindowController?
    private var deletedFilesWindow: DeletedFilesWindowController?
    private var setupWindow: SetupWindowController?
    private var fileStatusWindow: FileStatusWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsWindowController(model: model)
        settingsWindow = settings
        let deletedFiles = DeletedFilesWindowController(model: model)
        deletedFilesWindow = deletedFiles
        let setup = SetupWindowController(model: model)
        setupWindow = setup
        let fileStatus = FileStatusWindowController(model: model)
        fileStatusWindow = fileStatus
        menuController = MenuController(model: model)
        model.onOpenSettings = { [weak settings] in settings?.show() }
        model.onOpenDeletedFiles = { [weak deletedFiles] in deletedFiles?.show() }
        model.onOpenSetup = { [weak setup] in setup?.show() }
        model.onOpenFileStatus = { [weak fileStatus] path in fileStatus?.show(path: path) }
        model.start()
    }

    /// Finder → right-click → Services → “Show NeoDrop Status”.
    ///
    /// The name Finder shows comes from `NSServices` in the bundle's Info.plist, which is also what
    /// routes the selection to this selector — so the two have to agree, and `scripts/verify.sh`
    /// checks that they do.
    @objc func showFileStatus(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let path = Self.selectedFilePaths(on: pasteboard).first else {
            error.pointee = "Select a file or folder in Finder first." as NSString
            return
        }
        model.onOpenFileStatus?(path)
    }

    /// What Finder put on the pasteboard. `NSSendFileTypes` promises file URLs, but a service can
    /// also be invoked by an app that offers something else, so both representations are read and
    /// anything that is not a file is ignored rather than guessed at.
    static func selectedFilePaths(on pasteboard: NSPasteboard) -> [String] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        let filenames = pasteboard.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] ?? []
        return filenames
    }

    /// `neodrop://status?path=…`, which is how the Finder extension opens this app's own window for
    /// the file the user right-clicked. The extension has no engine and no window: it asks, and the
    /// app (which is the only thing that can answer honestly) shows the report.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "neodrop" {
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "path" }?.value
            model.onOpenFileStatus?(path)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// The file-status window: a web view onto the loopback page `FileStatusQuery` fills in.
///
/// Same shape as the deleted-files window, and for the same reason: the report is a document, it is
/// rendered by code that needs no AppKit, and the window is one `load` away from it.
@MainActor
final class FileStatusWindowController: NSObject, WKNavigationDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var webView: WKWebView?

    init(model: AppModel) {
        self.model = model
    }

    /// `show(path: nil)` asks the user which file, which is what the menu item does; Finder passes
    /// the selected path directly.
    func show(path: String?) {
        guard let path else {
            Panels.chooseFileForStatus { [weak self] chosen in
                guard let chosen else { return }
                self?.present(chosen)
            }
            return
        }
        present(path)
    }

    private func present(_ path: String) {
        if window == nil {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "File Status"
            window.contentView = webView
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            self.webView = webView
        }
        window?.title = "File Status — \(URL(fileURLWithPath: path).lastPathComponent)"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        guard let url = model.statusPageURL(for: path) else {
            webView?.loadHTMLString(Self.unavailablePage, baseURL: nil)
            return
        }
        webView?.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let isLocalServer = url.host == "127.0.0.1" || url.host == "localhost"
        if isLocalServer {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.cancel)
        }
    }

    private static let unavailablePage = """
        <html><head><meta charset="utf-8"><style>
        body { font: 13px -apple-system, sans-serif; padding: 40px; text-align: center; color: #6e6e73; }
        h1 { font-size: 16px; color: #1d1d1f; }
        </style></head><body>
        <h1>File status is not available</h1>
        <p>The local page could not be started. NeoDrop is still mirroring your folders — check the
        activity log from the menu for the reason.</p>
        </body></html>
        """
}

/// The deleted-files view: a web view onto the loopback page the engine's retention records
/// feed.
///
/// A web view rather than SwiftUI because this is the first screen of a UI that is meant to grow
/// (history, per-file versions, a folder picker), and the page needs no AppKit or Swift knowledge
/// to extend. Navigation is locked down: the only thing it may load is NeoDrop's own page, so a
/// stray link cannot turn the window into a browser.
@MainActor
final class DeletedFilesWindowController: NSObject, WKNavigationDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var webView: WKWebView?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let configuration = WKWebViewConfiguration()
            // No persistent storage, no cookies: the page is stateless and has nothing to keep.
            configuration.websiteDataStore = .nonPersistent()
            let webView = WKWebView(frame: .zero, configuration: configuration)
            webView.navigationDelegate = self

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Deleted Files"
            window.contentView = webView
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            self.webView = webView
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        load()
    }

    /// Reload on every open: the list changes with every sync, and the page is cheap.
    private func load() {
        guard let url = model.deletedFilesURL else {
            webView?.loadHTMLString(Self.unavailablePage, baseURL: nil)
            return
        }
        webView?.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Anything that is not NeoDrop's own loopback page is opened where it belongs (the user's
        // browser) instead of inside this window.
        let isLocalServer = url.host == "127.0.0.1" || url.host == "localhost"
        if isLocalServer {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.cancel)
        }
    }

    /// Shown when the server could not start, instead of an empty window.
    private static let unavailablePage = """
        <html><head><meta charset="utf-8"><style>
        body { font: 13px -apple-system, sans-serif; padding: 40px; text-align: center; color: #6e6e73; }
        h1 { font-size: 16px; color: #1d1d1f; }
        </style></head><body>
        <h1>Deleted files is not available</h1>
        <p>The local page could not be started. NeoDrop is still mirroring your folders — check the
        activity log from the menu for the reason.</p>
        </body></html>
        """
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
