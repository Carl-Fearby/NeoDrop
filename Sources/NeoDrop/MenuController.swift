import AppKit
import Combine
import NeoDropCore

/// The title bar icon and everything behind it.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellable: AnyCancellable?

    /// How the status item image was produced — the bundled artwork or a system symbol standing in
    /// for it. Recorded in the log line that scripts/e2e.sh asserts on, because "the app launched"
    /// and "the app is showing the icon it was packaged with" are different claims.
    private var installedIconSource = "none"

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.behavior = .removalAllowed

        updateStatusItem()
        // Recorded so that "the app is running" can be distinguished from "the title bar icon is
        // actually installed" — scripts/e2e.sh asserts on this line.
        NeoDropLog.shared.write("Menu bar status item installed (icon: \(installedIconSource))", level: .success)

        // @Published fires before the value changes, so read the model on the next runloop turn.
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let description = model.isBusy ? "NeoDrop: working" : "NeoDrop: \(model.statusTitle)"

        // The supplied artwork, loaded by base name so AppKit picks up the @2x and @3x files sitting
        // beside it in the bundle. It is a template image: macOS tints it to match the menu bar,
        // which is why a single monochrome asset works in light mode, dark mode, and with reduced
        // transparency.
        if let artwork = NSImage(named: "MenuBarIcon") {
            artwork.isTemplate = true
            artwork.size = NSSize(width: 18, height: 18)
            artwork.accessibilityDescription = description
            button.image = artwork
            button.imageScaling = .scaleProportionallyDown
            // Report how many representations AppKit actually assembled. Loading the file is not the
            // claim that matters — the three files are what make the icon sharp on a Retina display,
            // and if only the 1x were picked up it would be upscaled and merely look soft, which is
            // indistinguishable from a badly drawn icon after the fact.
            let representations = artwork.representations
                .map { "\($0.pixelsWide)x\($0.pixelsHigh)" }
                .joined(separator: " ")
            installedIconSource = "bundled artwork, \(representations.isEmpty ? "no" : representations) px"
        } else {
            // A bundle without the artwork — `swift run`, or a packaging slip — still gets a usable
            // icon rather than an empty menu bar slot, and says so in the log.
            let symbol = model.isBusy ? "arrow.triangle.2.circlepath" : model.statusSymbol
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
                ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "NeoDrop")
            image?.isTemplate = true
            button.image = image
            installedIconSource = "fallback symbol \(symbol)"
        }

        // State is deliberately not drawn into the icon. The artwork is a flat single-colour mask, so
        // the only ink available for a badge is the same ink the chassis body is already painted in —
        // a badge composited over the body disappears into it, and running the earlier symbol-style
        // badge would need a knocked-out transparent gap around an 8-point badge on an 18-point
        // canvas. The tooltip carries the state instead, along with the menu, whose first line is the
        // status and which lists any issues.
        button.toolTip = "NeoDrop — \(model.statusTitle)\n\(model.redundancyLine)"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        addDisabled("NeoDrop — \(model.statusTitle)")
        if let progressLine = model.progressLine {
            addDisabled(progressLine)
        }
        addDisabled(model.redundancyLine)
        if model.stats.fileCount > 0 {
            addDisabled("\(model.stats.fileCount) files · \(model.stats.byteCount.byteDescription) protected")
        }

        let errors = model.issues.filter { $0.severity == .error }
        let warnings = model.issues.filter { $0.severity == .warning }
        if !errors.isEmpty || !warnings.isEmpty {
            menu.addItem(.separator())
            for issue in errors.prefix(3) {
                addDisabled("⛔️ \(issue.message)")
            }
            for issue in warnings.prefix(3) {
                addDisabled("⚠️ \(issue.message)")
            }
        }

        menu.addItem(.separator())
        add("Sync Now", #selector(syncNow), key: "s", enabled: !model.isBusy && model.config.isConfigured)
        add("Verify & Repair All", #selector(verifyAll), key: "r", enabled: !model.isBusy && model.config.isConfigured)

        menu.addItem(.separator())
        menu.addItem(replicasMenu())
        menu.addItem(activityMenu())

        menu.addItem(.separator())
        add("Settings…", #selector(openSettings), key: ",", enabled: true)
        if Bundle.main.bundleIdentifier != nil {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            login.target = self
            login.state = model.launchAtLogin ? .on : .off
            login.isEnabled = true
            menu.addItem(login)
        }

        menu.addItem(.separator())
        add("Quit NeoDrop", #selector(quit), key: "q", enabled: true)
    }

    private func replicasMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Replicas", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        root.submenu = submenu

        if model.config.replicas.isEmpty {
            let item = NSMenuItem(title: "No destinations yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return root
        }

        for snapshot in model.snapshots.sorted(by: { $0.replica.priority < $1.replica.priority }) {
            let replica = snapshot.replica
            let item = NSMenuItem(
                title: "\(replica.displayName) — \(snapshot.status.menuDescription)",
                action: nil,
                keyEquivalent: ""
            )
            item.submenu = replicaDetailMenu(snapshot: snapshot)
            item.image = symbolImage(for: snapshot.status)
            submenu.addItem(item)
        }
        return root
    }

    private func replicaDetailMenu(snapshot: ReplicaSnapshot) -> NSMenu {
        let replica = snapshot.replica
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let lines = [
            replica.path,
            "\(snapshot.files) files · \(snapshot.bytes.byteDescription)",
            "Last sync: \(Self.format(snapshot.lastSync))",
            "Last verify: \(Self.format(snapshot.lastVerify))",
        ]
        for line in lines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }

        if snapshot.corrupt > 0 {
            let item = NSMenuItem(title: "\(snapshot.corrupt) file(s) failed verification", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        if let error = snapshot.lastError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }

        submenu.addItem(.separator())
        let verify = NSMenuItem(title: "Verify & Repair This Replica", action: #selector(verifyReplica(_:)), keyEquivalent: "")
        verify.target = self
        verify.representedObject = replica.id
        verify.isEnabled = !model.isBusy && replica.enabled
        submenu.addItem(verify)

        if let smbURL = replica.smbURL, !smbURL.isEmpty {
            let mount = NSMenuItem(title: "Mount \(smbURL)…", action: #selector(mountReplica(_:)), keyEquivalent: "")
            mount.target = self
            mount.representedObject = replica.id
            submenu.addItem(mount)
        }

        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealReplica(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = replica.id
        submenu.addItem(reveal)

        let toggle = NSMenuItem(title: replica.enabled ? "Disable" : "Enable", action: #selector(toggleReplica(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = replica.id
        submenu.addItem(toggle)

        let remove = NSMenuItem(title: "Remove Destination", action: #selector(removeReplica(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = replica.id
        submenu.addItem(remove)

        return submenu
    }

    private func activityMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "Activity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        for entry in model.activity.prefix(12) {
            let item = NSMenuItem(title: "\(Self.time(entry.date))  \(entry.message)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        if model.activity.isEmpty {
            let item = NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let open = NSMenuItem(title: "Open Log Folder", action: #selector(openLogFolder), keyEquivalent: "")
        open.target = self
        submenu.addItem(open)
        root.submenu = submenu
        return root
    }

    // MARK: - Item helpers

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func add(_ title: String, _ selector: Selector, key: String, enabled: Bool) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    private func symbolImage(for status: ReplicaStatus) -> NSImage? {
        let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Actions

    @objc private func syncNow() { model.syncNow() }
    @objc private func verifyAll() { model.verifyNow(repair: true) }
    @objc private func openSettings() { model.onOpenSettings?() }
    @objc private func toggleLaunchAtLogin() { model.setLaunchAtLogin(!model.launchAtLogin) }
    @objc private func openLogFolder() { model.openLog() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func verifyReplica(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.verifyNow(repair: true, replicas: [id])
    }

    @objc private func mountReplica(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let replica = model.config.replica(id: id) else { return }
        model.mount(replica)
    }

    @objc private func revealReplica(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let replica = model.config.replica(id: id) else { return }
        model.reveal(replica)
    }

    @objc private func toggleReplica(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let replica = model.config.replica(id: id) else { return }
        model.toggleReplica(replica)
    }

    @objc private func removeReplica(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let replica = model.config.replica(id: id) else { return }
        model.removeReplica(replica)
    }
}
