import AppKit
import Security
import ServiceManagement
import SwiftUI

/// Everything Wavepod keeps, and how to remove it. Used by Settings › Data and Privacy › Danger zone.
enum DataEraser {
    /// The text the person types to confirm, as GitHub asks for a repository's name before it deletes it.
    static let confirmation = "erase wavepod"
    /// Keychain services that hold sign-ins: ChatGPT accounts and Scriberr keys.
    static let keychainServices = ["app.wavepod.chatgpt", "app.wavepod.scriberr"]

    /// Deletes every item in `root` except the names in `keeping`. The folder itself stays.
    static func removeContents(of root: URL, keeping: Set<String> = []) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !keeping.contains(item.lastPathComponent) {
            try fm.removeItem(at: item)
        }
    }

    static func removeKeychainItems() {
        for service in keychainServices {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
    }

    /// Size of a folder on disk, for "Keep the downloaded models (3.1 GB)".
    static func size(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

extension AppModel {
    /// Erases the library, transcripts, answers, voices, followed podcasts, downloads, sign-ins and settings, then
    /// opens Wavepod again as on the first day. With `keepModels`, the downloaded models stay.
    func eraseAllData(keepModels: Bool) async {
        player.pause()
        show("Erasing all data…")
        if let services {
            await services.queue.shutdown()
            // Best effort, at most 15 seconds: remove Wavepod's access on OpenAI's and Anthropic's side too.
            // Erasing goes on when a provider can't be reached, because the local tokens are deleted anyway.
            let claudeExecutable = claudeExecutable
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for profile in (try? await services.chatGPT.profiles()) ?? [] where profile.connected {
                        try? await services.chatGPT.disconnect(profile.id)
                    }
                    if !claudeExecutable.isEmpty { try? await services.claude.disconnect(executable: claudeExecutable) }
                }
                group.addTask { try? await Task.sleep(for: .seconds(15)) }
                await group.next()
                group.cancelAll()
            }
        }
        try? await SMAppService.agent(plistName: "app.wavepod.feeds.plist").unregister()
        DataEraser.removeKeychainItems()
        do {
            try DataEraser.removeContents(of: WorkspaceServices.defaultRoot, keeping: keepModels ? ["models"] : [])
        } catch {
            show("Wavepod could not erase all files: \(error.localizedDescription)")
            return
        }
        if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
        Self.relaunch()
    }

    /// Opens a new copy of the app one second after this one quits.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// The last group in Settings › Data and Privacy. Its one button opens the confirmation.
struct DangerZone: View {
    let model: AppModel
    @State private var confirming = false
    @Environment(\.typography) private var type

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Danger zone").font(type.paneTitle).foregroundStyle(Palette.danger)
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Erase all data").font(type.body.weight(.medium)).foregroundStyle(Palette.ink)
                    Text("Deletes everything Wavepod keeps on this Mac and starts again from the welcome. You can't undo this.")
                        .font(type.callout).foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button("Erase All Data…") { confirming = true }
                    .buttonStyle(DangerButtonStyle(filled: false))
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.danger.opacity(0.5)))
        }
        .sheet(isPresented: $confirming) { EraseConfirmation(model: model) }
    }
}

/// What gets erased, the option to keep the models, and a typed confirmation before the button works.
struct EraseConfirmation: View {
    let model: AppModel
    /// Measured for "Keep the downloaded models (3.1 GB)". Tests pass a folder of their own.
    var modelsFolder = WorkspaceServices.defaultRoot.appendingPathComponent("models")
    @State private var typed = ""
    @State private var keepModels = false
    @State private var modelsSize: Int64 = 0
    @State private var erasing = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.typography) private var type

    private var confirmed: Bool { typed.trimmingCharacters(in: .whitespaces).lowercased() == DataEraser.confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Erase all Wavepod data?", systemImage: "exclamationmark.triangle.fill")
                .font(type.readingTitle).foregroundStyle(Palette.danger)
            Text("Wavepod deletes these items from this Mac and then opens again as on the first day:")
                .font(type.body).foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(["Your library: episodes, transcripts, summaries and answers",
                         "Named voices and followed podcasts",
                         "Downloaded audio and artwork",
                         "Your ChatGPT and Claude connections in Wavepod, and your Scriberr key",
                         "All settings, and the background check for new episodes"], id: \.self) {
                    Label($0, systemImage: "minus.circle").font(type.callout).foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: $keepModels) {
                Text(modelsSize > 0 ? "Keep the downloaded models (\(ByteCountFormatter.string(fromByteCount: modelsSize, countStyle: .file)))"
                                    : "Keep the downloaded models")
                    .font(type.body)
            }
            .toggleStyle(.checkbox)
            .help("Starting again then needs no model download.")
            VStack(alignment: .leading, spacing: 6) {
                Text("To confirm, type \"\(DataEraser.confirmation)\".").font(type.callout).foregroundStyle(Palette.ink)
                TextField(DataEraser.confirmation, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { if confirmed { erase() } }
                    .accessibilityLabel("Type \(DataEraser.confirmation) to confirm")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    erase()
                } label: {
                    if erasing { ProgressView().controlSize(.small) } else { Text("Erase and Restart") }
                }
                .buttonStyle(DangerButtonStyle(filled: true))
                .disabled(!confirmed || erasing)
            }
        }
        .padding(24)
        .frame(width: 480)
        .disabled(erasing)
        .task { modelsSize = DataEraser.size(of: modelsFolder) }
    }

    private func erase() {
        guard confirmed, !erasing else { return }
        erasing = true
        Task { await model.eraseAllData(keepModels: keepModels) }
    }
}

/// Red for actions that destroy data: outlined where it opens a confirmation, filled for the final step.
struct DangerButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.typography) private var type
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(type.label)
            .foregroundStyle(filled ? Palette.onDanger : Palette.danger)
            .padding(.horizontal, 14)
            .frame(minHeight: 30)
            .background(filled ? Palette.danger.opacity(configuration.isPressed ? 0.85 : 1) : (configuration.isPressed ? Palette.danger.opacity(0.08) : Palette.surface),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.danger.opacity(filled ? 0 : 0.6)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .pressScale(configuration.isPressed && isEnabled)
    }
}
