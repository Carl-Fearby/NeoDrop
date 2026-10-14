import SwiftUI
import AppKit
import NeoDropCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            SourcesTab(model: model)
                .tabItem { Label("Sources", systemImage: "folder") }
            ReplicasTab(model: model)
                .tabItem { Label("Destinations", systemImage: "externaldrive") }
            ActivityTab(model: model)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
        }
        .frame(minWidth: 640, idealWidth: 660, minHeight: 480, idealHeight: 500)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: model.statusSymbol)
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.statusTitle).font(.headline)
                        Text(model.redundancyLine).font(.subheadline).foregroundStyle(.secondary)
                        Text("\(model.stats.fileCount) files · \(model.stats.byteCount.byteDescription) across \(model.config.sources.count) source(s)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack {
                        Button("Sync Now") { model.syncNow() }
                            .disabled(model.isBusy || !model.config.isConfigured)
                        Button("Verify & Repair") { model.verifyNow(repair: true) }
                            .disabled(model.isBusy || !model.config.isConfigured)
                    }
                }
                if let line = model.progressLine {
                    ProgressView(value: model.progress.fraction) {
                        Text(line).font(.caption)
                    }
                }
            }

            Section("Automatic protection") {
                Toggle("Watch the source folders for changes", isOn: $model.config.watchForChanges)
                Toggle("Sync on a schedule", isOn: $model.config.scheduledSync)
                if model.config.scheduledSync {
                    Stepper("Every \(model.config.syncIntervalMinutes) minutes",
                            value: $model.config.syncIntervalMinutes, in: 1...1440)
                }
                Toggle("Verify replicas on a schedule", isOn: $model.config.scheduledVerify)
                if model.config.scheduledVerify {
                    Stepper("Every \(model.config.verifyIntervalHours) hours",
                            value: $model.config.verifyIntervalHours, in: 1...720)
                }
                Toggle("Re-read every copy after writing it", isOn: $model.config.verifyAfterCopy)
                Toggle("Remove files from replicas when deleted from the source",
                       isOn: $model.config.mirrorDeletions)
                if model.config.mirrorDeletions {
                    Toggle("Allow bulk deletions", isOn: $model.config.allowBulkDeletions)
                    Text("Off by default. NeoDrop refuses to remove more than a quarter of a replica in one run (or 25 files, whichever is larger), which is what stops a renamed or unplugged source folder from wiping the NAS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Ignored") {
                TextEditor(text: excludesBinding)
                    .frame(minHeight: 60)
                    .font(.system(.caption, design: .monospaced))
                Text("One glob per line. Patterns with a slash match the relative path, otherwise the file name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !model.issues.isEmpty {
                Section("Attention") {
                    ForEach(model.issues) { issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                            .font(.callout)
                    }
                }
            }

            Section {
                Toggle("Launch NeoDrop at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
    }

    private var excludesBinding: Binding<String> {
        Binding(
            get: { model.config.excludes.joined(separator: "\n") },
            set: { newValue in
                model.config.excludes = newValue
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }
}

// MARK: - Sources

private struct SourcesTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folders NeoDrop protects. Each one is mirrored in full to every destination.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.config.sources) { source in
                    HStack {
                        Image(systemName: "folder")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.displayName).font(.headline)
                            Text(source.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.removeSource(source)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop protecting this folder")
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 200)

            HStack {
                Button("Add Folder…") {
                    Panels.chooseDirectory(
                        prompt: "Protect",
                        message: "Choose the folder NeoDrop should mirror to your NAS drives."
                    ) { path in
                        model.addSource(path: path)
                    }
                }
                Spacer()
            }
        }
        .padding()
    }
}

// MARK: - Replicas

private struct ReplicasTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every destination holds a complete copy. Point them at mounted NAS shares such as /Volumes/NAS1/NeoDrop.")
                .font(.callout)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.snapshots.sorted { $0.replica.priority < $1.replica.priority }) { snapshot in
                    ReplicaRow(model: model, snapshot: snapshot)
                }
            }
            .frame(minHeight: 220)

            HStack {
                Button("Add Destination…") {
                    Panels.chooseDirectory(
                        prompt: "Use as replica",
                        message: "Choose the folder on the NAS that should hold a full copy. Create a NeoDrop folder inside the share if you like."
                    ) { path in
                        model.addReplica(path: path)
                    }
                }
                Button("Mount a Share…") {
                    Panels.askForShareURL { url in
                        guard let url, !url.isEmpty else { return }
                        _ = MountManager.requestMount(smbURL: url)
                        model.banner = "Asking Finder to mount \(url)…"
                    }
                }
                Spacer()
                Button("Check Availability") {
                    Task { await model.refresh() }
                }
            }
        }
        .padding()
    }
}

private struct ReplicaRow: View {
    @ObservedObject var model: AppModel
    let snapshot: ReplicaSnapshot

    @State private var name: String = ""
    @State private var smbURL: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: snapshot.status.symbol)
                Text(snapshot.displayName).font(.headline)
                Spacer()
                Text(snapshot.status.menuDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { snapshot.replica.enabled },
                    set: { _ in model.toggleReplica(snapshot.replica) }
                ))
                .labelsHidden()
                .help("Include this destination in every mirror")
                Button {
                    model.removeReplica(snapshot.replica)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }

            Text(snapshot.replica.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("\(snapshot.files) files · \(snapshot.bytes.byteDescription) · corrupt: \(snapshot.corrupt) · last sync \(Self.format(snapshot.lastSync)) · last verify \(Self.format(snapshot.lastVerify))")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let error = snapshot.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }

            HStack {
                TextField("Name", text: $name, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                TextField("smb://nas.local/share (optional)", text: $smbURL, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { commit() }
                Button("Verify") { model.verifyNow(repair: true, replicas: [snapshot.replica.id]) }
                    .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            name = snapshot.replica.name
            smbURL = snapshot.replica.smbURL ?? ""
        }
    }

    private func commit() {
        model.updateReplica(snapshot.replica.id, name: name, smbURL: smbURL.isEmpty ? nil : smbURL)
    }

    private static func format(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Activity

private struct ActivityTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Sync Now") { model.syncNow() }.disabled(model.isBusy)
                Button("Verify & Repair All") { model.verifyNow(repair: true) }.disabled(model.isBusy)
                Button("Refresh") { model.refreshActivity(); Task { await model.refresh() } }
                Spacer()
                Button("Reveal Log Folder") { model.openLog() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.activity) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.time.string(from: entry.date))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.level.rawValue)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.message)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding()
        .onAppear { model.refreshActivity() }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Panels

enum Panels {
    static func chooseDirectory(prompt: String, message: String, completion: @escaping (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    static func askForShareURL(completion: @escaping (String?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Mount a NAS share"
        alert.informativeText = "Enter the share address, for example smb://nas.local/backup. macOS will use the credentials already saved in your Keychain."
        alert.addButton(withTitle: "Mount")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "smb://nas.local/share"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
