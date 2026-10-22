import Foundation
import Library

/// Where answers and summaries run.
public enum AnswerProvider: String, CaseIterable, Identifiable, Sendable {
    case local, chatgpt, claude
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .local: "On this Mac"
        case .chatgpt: "My ChatGPT plan"
        case .claude: "My Claude plan"
        }
    }
    public var shortTitle: String {
        switch self {
        case .local: "On this Mac"
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        }
    }
}

/// The answer model as chosen in Settings → Ask. The ChatGPT model is kept per account and its effort per model,
/// so switching back restores what was chosen before.
public struct AnswerChoice: Equatable, Sendable {
    public var provider: AnswerProvider = .local
    public var chatGPTAccount = ""
    public var chatGPTModel = ""
    /// Empty: the model's default effort.
    public var chatGPTEffort = ""
    public var claudeExecutable = ""
    public var claudeModel = "sonnet"
    /// One of `ClaudePlan.efforts(for: claudeModel)`, or empty for Claude Code's default.
    public var claudeEffort = ""

    public init(provider: AnswerProvider = .local, chatGPTAccount: String = "", chatGPTModel: String = "", chatGPTEffort: String = "",
                claudeExecutable: String = "", claudeModel: String = "sonnet", claudeEffort: String = "") {
        self.provider = provider
        self.chatGPTAccount = chatGPTAccount
        self.chatGPTModel = chatGPTModel
        self.chatGPTEffort = chatGPTEffort
        self.claudeExecutable = claudeExecutable
        self.claudeModel = claudeModel
        self.claudeEffort = claudeEffort
    }

    enum Key {
        static let provider = "askProvider", account = "chatGPTProfile", claudeExecutable = "claudeExecutable"
        static let claudeModel = "claudeModel", claudeEffort = "claudeEffort"
        static func chatGPTModel(_ account: String) -> String { "chatGPTModel.\(account)" }
        static func chatGPTEffort(_ model: String) -> String { "chatGPTEffort.\(model)" }
    }

    /// The saved choice. A saved Claude Code that no longer runs is replaced by the one Wavepod finds.
    public static func load(from settings: any SettingsStore, detectClaude: () -> String = { ClaudePlan.detectedExecutable }) -> AnswerChoice {
        let account = settings.string(forKey: Key.account) ?? ""
        let model = settings.string(forKey: Key.chatGPTModel(account)) ?? ""
        let claudeModel = settings.string(forKey: Key.claudeModel) ?? "sonnet"
        let claudeEffort = settings.string(forKey: Key.claudeEffort) ?? ""
        return AnswerChoice(
            provider: AnswerProvider(rawValue: settings.string(forKey: Key.provider) ?? "") ?? .local,
            chatGPTAccount: account,
            chatGPTModel: model,
            chatGPTEffort: settings.string(forKey: Key.chatGPTEffort(model)) ?? "",
            claudeExecutable: settings.string(forKey: Key.claudeExecutable).flatMap { ClaudePlan.isExecutable($0) ? $0 : nil } ?? detectClaude(),
            claudeModel: claudeModel,
            claudeEffort: ClaudePlan.efforts(for: claudeModel).contains(claudeEffort) ? claudeEffort : "")
    }

    public func save(to settings: any SettingsStore) {
        settings.set(provider.rawValue, forKey: Key.provider)
        settings.set(chatGPTAccount, forKey: Key.account)
        settings.set(chatGPTModel, forKey: Key.chatGPTModel(chatGPTAccount))
        if !chatGPTModel.isEmpty { settings.set(chatGPTEffort, forKey: Key.chatGPTEffort(chatGPTModel)) }
        settings.set(claudeExecutable, forKey: Key.claudeExecutable)
        settings.set(claudeModel, forKey: Key.claudeModel)
        settings.set(claudeEffort, forKey: Key.claudeEffort)
    }

    /// Chooses another ChatGPT account and restores the model and effort last chosen for it.
    public mutating func selectChatGPTAccount(_ account: String, settings: any SettingsStore) {
        chatGPTAccount = account
        chatGPTModel = settings.string(forKey: Key.chatGPTModel(account)) ?? ""
        chatGPTEffort = settings.string(forKey: Key.chatGPTEffort(chatGPTModel)) ?? ""
    }

    /// Chooses another ChatGPT model and restores the effort last chosen for it.
    public mutating func selectChatGPTModel(_ model: String, settings: any SettingsStore) {
        chatGPTModel = model
        chatGPTEffort = settings.string(forKey: Key.chatGPTEffort(model)) ?? ""
    }

    /// Chooses another Claude model. An effort that model does not take goes back to the default.
    public mutating func selectClaudeModel(_ model: String) {
        claudeModel = model
        if !ClaudePlan.efforts(for: model).contains(claudeEffort) { claudeEffort = "" }
    }
}

/// Whether the chosen answer model can run now, and if not, what to do.
public enum AnswerReadiness: Equatable, Sendable {
    case ready
    case needsSetup(String)
    public var isReady: Bool { self == .ready }
}

/// The one place that knows which model writes answers and summaries: on this Mac, or on the person's ChatGPT or
/// Claude plan. Ask, the summaries the app writes, the job queue and the background feed checker all use it, so
/// they always agree on the model, its context size and whether it is ready.
public struct AnswerModel: NotesGenerating {
    /// Plans read the transcript in larger parts than the local model, so a long episode takes a few requests.
    public static let planContextLimit = 40_000
    /// The local model's part size, the same as `EpisodeAnswers`'s default.
    public static let localContextLimit = 9000

    public let settings: any SettingsStore
    public let local: LocalGenerator
    public let chatGPT: ChatGPTPlan
    public let claude: ClaudePlan
    /// False in the feed checker, which runs without a window. The ChatGPT sign-in is in the Keychain, and macOS
    /// would ask for a password there with nothing to explain it. Those summaries stay pending, and the app writes
    /// them on the person's plan the next time it runs.
    public let interactive: Bool

    public init(settings: any SettingsStore = UserDefaults.standard, local: LocalGenerator, chatGPT: ChatGPTPlan, claude: ClaudePlan,
                interactive: Bool = true) {
        self.settings = settings
        self.local = local
        self.chatGPT = chatGPT
        self.claude = claude
        self.interactive = interactive
    }

    /// The saved choice, read each time, so a change in Settings applies to the next answer or summary.
    public var choice: AnswerChoice { AnswerChoice.load(from: settings) }

    /// - Parameter connectedChatGPTAccounts: the accounts with a working sign-in, when the caller knows them. Nil
    ///   checks only that an account is chosen; the sign-in is then checked when the model runs.
    public func readiness(_ choice: AnswerChoice, connectedChatGPTAccounts: Set<String>? = nil) -> AnswerReadiness {
        switch choice.provider {
        case .local:
            return local.isInstalled ? .ready : .needsSetup("Download the Ask model in Settings → Ask.")
        case .chatgpt:
            guard interactive else { return .needsSetup("Wavepod writes this summary on your ChatGPT plan when you open it.") }
            guard !choice.chatGPTAccount.isEmpty,
                  connectedChatGPTAccounts.map({ $0.contains(choice.chatGPTAccount) }) ?? true
            else { return .needsSetup("Connect your ChatGPT account in Settings → Ask.") }
            return choice.chatGPTModel.isEmpty ? .needsSetup("Choose a ChatGPT model in Settings → Ask.") : .ready
        case .claude:
            return ClaudePlan.isExecutable(choice.claudeExecutable) ? .ready : .needsSetup("Choose Claude Code in Settings → Ask.")
        }
    }

    /// Runs `body` with the chosen model and the transcript part size that suits it. The local model stays loaded
    /// for the whole call, so an answer and its retries load the weights once.
    public func withGenerator<T: Sendable>(_ choice: AnswerChoice,
                                           _ body: @Sendable (any TextGenerating, Int) async throws -> T) async throws -> T {
        switch choice.provider {
        case .local:
            return try await local.withSession { try await body($0, Self.localContextLimit) }
        case .chatgpt:
            return try await body(ChatGPTGenerator(plan: chatGPT, account: choice.chatGPTAccount, model: choice.chatGPTModel,
                                                   effort: choice.chatGPTEffort), Self.planContextLimit)
        case .claude:
            return try await body(ClaudeGenerator(plan: claude, executable: choice.claudeExecutable, model: choice.claudeModel,
                                                  effort: choice.claudeEffort), Self.planContextLimit)
        }
    }

    // MARK: NotesGenerating

    public var isAvailable: Bool { readiness(choice).isReady }

    public func notes(_ transcript: Transcript) async throws -> [CitedClaim] {
        let choice = choice
        if choice.provider == .local { return try await local.notes(transcript) }
        return try await withGenerator(choice) { generator, limit in
            try await EpisodeSummaryStyle.notes(transcript, generator: generator, contextLimit: limit)
        }
    }
}
