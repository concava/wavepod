import AppKit
import Engine
import Foundation
import LLM
import SwiftUI

extension AppModel {
    public func refreshChatGPTProfiles() async {
        guard let services else { return }
        do {
            chatGPTProfiles = try await services.chatGPT.profiles()
            if chatGPTProfileID.isEmpty { chatGPTProfileID = chatGPTProfiles.first?.id ?? "" }
            if chatGPTProfiles.first(where: { $0.id == chatGPTProfileID })?.connected == true { await loadChatGPTModels() }
        } catch { chatGPTStatus = error.localizedDescription }
    }
    public func loadChatGPTModels() async {
        guard let services, !chatGPTProfileID.isEmpty else { return }
        let id = chatGPTProfileID
        chatGPTModels = []
        do {
            let models = try await services.chatGPT.models(account: id)
            guard chatGPTProfileID == id else { return }
            chatGPTModels = models
            let saved = UserDefaults.standard.string(forKey: "chatGPTModel.\(id)") ?? ""
            chatGPTModelID = models.contains(where: { $0.id == saved }) ? saved : models.first?.id ?? ""
            chatGPTStatus = models.isEmpty ? "No eligible models were returned for this account." : "ChatGPT plan connected. Model access is verified when you ask a question."
        } catch { if chatGPTProfileID == id { chatGPTStatus = error.localizedDescription } }
    }
    public func connectChatGPT(newAccount: Bool = false) {
        guard let services, !isConnectingChatGPT else { return }
        isConnectingChatGPT = true
        chatGPTStatus = "Finish connecting in your browser…"
        let id = newAccount || chatGPTProfileID.isEmpty ? nil : chatGPTProfileID
        chatGPTConnectionTask = Task {
            defer { isConnectingChatGPT = false; chatGPTConnectionTask = nil }
            do {
                let profile = try await services.chatGPT.signIn(reusing: id) { url in
                    let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                    guard opened else { throw EngineError.unavailable("The sign-in browser could not be opened.") }
                }
                chatGPTProfileID = profile.id
                await refreshChatGPTProfiles()
                let key = "chatGPTUsageNotice.\(profile.id)"
                if !UserDefaults.standard.bool(forKey: key) { showChatGPTPlanNotice = true; UserDefaults.standard.set(true, forKey: key) }
            } catch is CancellationError { chatGPTStatus = "Connection cancelled. Local inference is still available." }
            catch { chatGPTStatus = error.localizedDescription }
        }
    }
    public func disconnectChatGPT() {
        guard let services, !isConnectingChatGPT else { return }
        let id = chatGPTProfileID
        isConnectingChatGPT = true
        Task {
            defer { isConnectingChatGPT = false }
            askProvider = "local"
            chatGPTModels = []
            do { try await services.chatGPT.disconnect(id); chatGPTStatus = "Disconnected from ChatGPT." }
            catch { chatGPTStatus = error.localizedDescription }
            chatGPTProfiles = (try? await services.chatGPT.profiles()) ?? []
        }
    }
}

struct AskSettings: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Answer model") {
                SettingRow(title: "Answers and summaries", detail: model.isAnswering ? "Applies from your next question; the current answer keeps its model."
                           : "On this Mac is private and free. Your ChatGPT or Claude plan is faster and better on long episodes.", last: true) {
                    Picker("Answer model", selection: $model.askProvider) {
                        ForEach(AppModel.AskProvider.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().fixedSize()
                }
            }
            // Only the connection controls wait for a running answer; the choice of model never does.
            Group {
                switch AppModel.AskProvider(rawValue: model.askProvider) ?? .local {
                case .local: localSettings
                case .chatgpt: chatGPTSettings
                case .claude: ClaudeSettings(model: model)
                }
            }
            .disabled(model.isAnswering)
            SettingsGroup(title: "Search") {
                ModelRow(model: model, title: "Search by meaning", detail: "Finds passages that say the same thing in other words or languages.",
                         kind: "embeddings", folder: "embeddings")
                SettingRow(title: "Search index", detail: model.isIndexing ? model.modelStatus : "Rebuild if search misses episodes you know are there.", last: true) {
                    Button(model.isIndexing ? "Indexing…" : "Rebuild", action: model.indexLibrary)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(model.isIndexing)
                }
            }
        }
        .task { await model.refreshChatGPTProfiles() }
        .alert("You’re using your ChatGPT plan", isPresented: $model.showChatGPTPlanNotice) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("Eligible requests use your ChatGPT plan. You can manage app access and usage in ChatGPT Settings. Local inference remains available in wavepod.")
        }
    }

    private var localSettings: some View {
        SettingsGroup(title: "On this Mac") {
            ModelRow(model: model, title: "Language model", detail: "About 2.3 GB, 3.6 GB of memory while answering. Every transcript section is read before answering, so long episodes take a while.",
                     kind: "language", folder: "language", last: true)
        }
    }

    private var isChatGPTConnected: Bool {
        model.chatGPTProfiles.contains { $0.id == model.chatGPTProfileID && $0.connected }
    }

    @ViewBuilder private var chatGPTSettings: some View {
        SettingsGroup(title: "ChatGPT") {
            SettingRow(title: "Account", detail: model.chatGPTStatus) {
                if model.isConnectingChatGPT {
                    HStack { ProgressView().controlSize(.small); Button("Cancel") { model.chatGPTConnectionTask?.cancel() } }
                } else {
                    HStack(spacing: 8) {
                        if model.chatGPTProfiles.count > 1 {
                            Picker("ChatGPT account", selection: $model.chatGPTProfileID) {
                                ForEach(model.chatGPTProfiles) { profile in Text(profile.label + (profile.connected ? "" : " (disconnected)")).tag(profile.id) }
                            }
                            .labelsHidden().fixedSize()
                            .onChange(of: model.chatGPTProfileID) { _, _ in Task { await model.loadChatGPTModels() } }
                        }
                        if !isChatGPTConnected {
                            Button("Continue with ChatGPT") { model.connectChatGPT() }.buttonStyle(PrimaryButtonStyle())
                        }
                        Menu {
                            Button("Add Another Account") { model.connectChatGPT(newAccount: true) }
                            Button("Refresh Models") { Task { await model.loadChatGPTModels() } }
                            if isChatGPTConnected { Divider(); Button("Disconnect", role: .destructive, action: model.disconnectChatGPT) }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("More account actions")
                    }
                }
            }
            SettingRow(title: "Model", detail: "Models your plan includes.", last: true) {
                if model.chatGPTModels.isEmpty {
                    Text("Connect first").font(type.callout).foregroundStyle(Palette.inkMuted)
                } else {
                    Picker("ChatGPT model", selection: $model.chatGPTModelID) {
                        ForEach(model.chatGPTModels) { Text($0.display_name).tag($0.id) }
                    }.labelsHidden().fixedSize()
                }
            }
        }
        PlanFootnote(text: "Questions, recent conversation and transcript text go to OpenAI when you ask or a summary is written. Audio is not sent, and your ChatGPT conversations are not read. Plan limits apply.",
                     link: ("Manage usage", URL(string: "https://chatgpt.com/#settings/Usage")!))
    }
}

/// The privacy note and usage link under a plan's settings.
struct PlanFootnote: View {
    let text: String
    let link: (title: String, url: URL)
    @Environment(\.typography) private var type

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(type.callout).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
            Link(link.title, destination: link.url).font(type.callout)
        }
        .padding(.top, -8)
    }
}
