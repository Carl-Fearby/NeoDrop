import SwiftUI
import AppKit
import NeoDropCore

/// Two-way folders: the Dropbox-shaped mode. One local folder on this Mac, one vault on a share,
/// and every other Mac syncing the same vault.
struct VaultsTab: View {
    @ObservedObject var model: AppModel

    /// Edited locally and committed on submit, like the destination rows: binding straight to the
    /// model would write `machine.json` and announce a new name on every keystroke.
    @State private var machineNameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A two-way folder keeps one folder the same on every Mac. The share holds the shared copy — still ordinary files you can browse and open — and NeoDrop carries each change in both directions.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Text("This Mac is called")
                TextField("Name", text: $machineNameDraft, onCommit: { commitMachineName() })
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Save") { commitMachineName() }
                Text("— the name other Macs see on a conflicted copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.config.vaults.isEmpty {
                Text("No two-way folder yet. Point two or more Macs at the same folder on the share and each one keeps the whole tree.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                List {
                    ForEach(model.config.vaults) { link in
                        VaultRow(model: model, link: link)
                    }
                }
                .frame(minHeight: 220)
            }

            HStack {
                Button("Add Two-Way Folder…") { addVault() }
                Spacer()
                Button("Sync Now") { model.syncNow() }
                    .disabled(model.isBusy || !model.config.isConfigured)
            }

            Text("Every Mac that points at the same vault shares the tree. A Mac joining for the first time pulls the whole thing down on its first sync; if it already holds files, both versions are kept rather than one being thrown away.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { machineNameDraft = model.machineName }
    }

    private func commitMachineName() {
        model.setMachineName(machineNameDraft)
        machineNameDraft = model.machineName
    }

    /// Two folders, in the order that keeps the choices meaningful: the local working copy first,
    /// then the folder on the share. Both must already exist — an unmounted share and an empty
    /// folder are indistinguishable, and creating either one is how a sync tool fills a boot disk.
    private func addVault() {
        Panels.chooseDirectory(
            prompt: "Use as working copy",
            message: "Choose the folder on this Mac that should stay the same on every Mac. It has to exist already."
        ) { localPath in
            Panels.chooseDirectory(
                prompt: "Use as vault",
                message: "Choose the folder on the NAS that holds the shared copy. Mount the share first if it is not in the list."
            ) { vaultPath in
                model.addVault(localPath: localPath, vaultPath: vaultPath)
            }
        }
    }
}

private struct VaultRow: View {
    @ObservedObject var model: AppModel
    let link: VaultLink

    @State private var name: String = ""
    @State private var smbURL: String = ""

    var body: some View {
        let status = model.vaultStatuses[link.id] ?? VaultStatus(link: link)

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: link.enabled ? status.status.symbol : ReplicaStatus.disabled.symbol)
                Text(link.displayName).font(.headline)
                Spacer()
                Text(link.enabled ? status.statusLine : "stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("", isOn: Binding(
                    get: { link.enabled },
                    set: { _ in model.toggleVault(link) }
                ))
                .labelsHidden()
                Button {
                    model.removeVault(link)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop syncing this folder. Nothing is deleted from either side.")
            }

            Text("This Mac: \(link.localPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Vault: \(link.vaultPath)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text("\(status.detailLine) · \(status.lastSyncLine)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let error = status.summary?.errors.first {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }

            HStack {
                TextField("Name", text: $name, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                TextField("smb://nas.local/share (optional)", text: $smbURL, onCommit: commit)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { commit() }
                Button("Sync") { model.syncVaultNow(link) }
                    .disabled(model.isBusy || !link.enabled)
            }
        }
        .padding(.vertical, 6)
        .onAppear {
            name = link.name
            smbURL = link.smbURL ?? ""
        }
    }

    private func commit() {
        model.updateVault(link.id, name: name, smbURL: smbURL.isEmpty ? nil : smbURL)
    }
}
