import SwiftUI
import AppKit
import NeoDropCore

/// What the wizard is setting up: the two modes, in the order they should be considered.
enum SetupMode: String, CaseIterable, Identifiable {
    case twoWay
    case mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .twoWay: return "The same folder on every Mac (two-way)"
        case .mirror: return "A copy on a NAS (one-way mirror)"
        }
    }

    var detail: String {
        switch self {
        case .twoWay:
            return "Every Mac pointed at the same vault on the share keeps the whole tree: change a file on any of them and it appears on the others. Deleting is a 30-day undo, and a Mac joining later pulls everything down."
        case .mirror:
            return "This Mac is the only writer. The folder is copied in full to the NAS, verified by checksum and repaired from the good copy. Edits made on another Mac are not brought back — for that, use a two-way folder."
        }
    }
}

/// The first-run wizard, and the same flow when asked for again from the menu.
///
/// It exists because the alternative is what a fresh install used to do: nothing, with an empty
/// Settings window whose tabs each assume you already know what a source, a destination and a vault
/// are. One folder is the question a person can actually answer, so it is the first question.
@MainActor
final class SetupWindowController {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupWizard(model: model, onFinish: { [weak self] in
                self?.window?.close()
            }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Set Up NeoDrop"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SetupWizard: View {
    @ObservedObject var model: AppModel
    let onFinish: () -> Void

    @State private var step = 0
    @State private var mainFolder = ""
    @State private var mode: SetupMode = .twoWay
    @State private var vaultFolder = ""
    @State private var destinationFolder = ""
    @State private var machineName = ""
    @State private var problem: String?

    private let steps = ["Your folder", "How it works", "Where it goes", "Finish"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Group {
                switch step {
                case 0: folderStep
                case 1: modeStep
                case 2: destinationStep
                default: finishStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            Divider()
            HStack {
                Button("Back") { step -= 1 }
                    .disabled(step == 0)
                Spacer()
                if step < steps.count - 1 {
                    Button("Continue") { step += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                } else {
                    Button("Finish") { finish() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 420, alignment: .topLeading)
        .onAppear { machineName = model.machineName }
    }

    // MARK: - Steps

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Set up NeoDrop").font(.title2).bold()
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    Text(steps[index])
                        .font(.caption)
                        .foregroundStyle(index == step ? Color.primary : Color.secondary)
                    if index < steps.count - 1 {
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which folder matters most?")
                .font(.headline)
            Text("NeoDrop starts with one folder, because that is the choice that makes the rest make sense. You can add more later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Choose Folder…") {
                    Panels.chooseDirectory(
                        prompt: "Use this folder",
                        message: "Choose the folder NeoDrop should keep safe. It has to exist already."
                    ) { path in
                        mainFolder = path
                    }
                }
                Text(mainFolder.isEmpty ? "No folder chosen yet" : mainFolder)
                    .font(.callout)
                    .foregroundStyle(mainFolder.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Text("NeoDrop never creates this folder and never deletes it: an unmounted disk looks exactly like an empty folder, and guessing wrong there is how a sync tool fills a boot disk.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How should it be protected?").font(.headline)
            ForEach(SetupMode.allCases) { choice in
                Button {
                    mode = choice
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: mode == choice ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(mode == choice ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.title).font(.callout).bold()
                            Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var destinationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if mode == .twoWay {
                Text("Where should the shared copy live?").font(.headline)
                Text("This is the vault: one folder on the mounted share that every Mac points at. The first Mac to arrive creates it; the others read it and add their own changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                chooseRow(title: "Vault folder on the share", value: vaultFolder) {
                    Panels.chooseDirectory(
                        prompt: "Use as vault",
                        message: "Choose the folder on the NAS that holds the shared copy. Create it inside the share first if you like; mount the share if it is not in the list."
                    ) { vaultFolder = $0 }
                }
                HStack {
                    Text("This Mac is called")
                    TextField("Name", text: $machineName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Text("— what other Macs see on a conflicted copy.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Where should the copy go?").font(.headline)
                Text("A folder on the mounted NAS. Create a NeoDrop folder inside the share first if you like; you can add a second NAS afterwards in Settings, which is what makes the copy safe rather than merely convenient.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                chooseRow(title: "Destination on the NAS", value: destinationFolder) {
                    Panels.chooseDirectory(
                        prompt: "Use as destination",
                        message: "Choose the folder on the NAS that should hold a full copy."
                    ) { destinationFolder = $0 }
                }
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ready").font(.headline)
            Text(summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text(mode == .twoWay
                 ? "Finishing syncs this folder with the vault now. The first sync carries every file across, in whichever direction it is needed."
                 : "Finishing mirrors this folder to the NAS now, and verifies what it wrote.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button("Choose Folder…", action: action)
            Text(value.isEmpty ? title : value)
                .font(.callout)
                .foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Decisions

    private var canContinue: Bool {
        switch step {
        case 0: return !mainFolder.isEmpty
        case 2: return mode == .twoWay ? !vaultFolder.isEmpty : !destinationFolder.isEmpty
        default: return true
        }
    }

    private var summary: String {
        var lines = ["Folder: \(mainFolder)"]
        if mode == .twoWay {
            lines.append("Two-way folder with the vault at \(vaultFolder)")
            if !machineName.isEmpty { lines.append("This Mac will be called “\(machineName)” to your others") }
        } else {
            lines.append("One-way mirror to \(destinationFolder)")
        }
        return lines.joined(separator: "\n")
    }

    /// Applies the choices through the same model calls the Settings tabs use, so the wizard cannot
    /// configure something the rest of the app would refuse.
    private func finish() {
        problem = nil
        if !machineName.isEmpty, machineName != model.machineName {
            model.setMachineName(machineName)
        }

        switch mode {
        case .twoWay:
            model.addVault(localPath: mainFolder, vaultPath: vaultFolder)
        case .mirror:
            model.addSource(path: mainFolder)
            model.addReplica(path: destinationFolder)
        }

        // The model refuses an unusable configuration and says why through `banner`; the wizard has
        // to show that rather than close on a setup that did not happen.
        guard model.config.isConfigured else {
            problem = model.banner ?? "That combination could not be set up."
            step = mode == .twoWay ? 2 : 2
            return
        }
        model.syncNow(reason: "after setup")
        onFinish()
    }
}
