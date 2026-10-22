import Engine
import Foundation
import Library
import LLM
import Networking

/// Everything that works on one Wavepod folder, wired the same way in every process: the library, the network
/// client, the transcription engine, the answer model and the job queue. The app and the background feed checker
/// both open it here, so a new dependency of the queue can't be forgotten in one of them.
public struct Workspace: Sendable {
    public let root: URL
    public let store: LibraryStore
    public let client: HTTPClient
    public let chatGPT: ChatGPTPlan
    public let claude: ClaudePlan
    public let answers: AnswerModel
    public let queue: JobQueue
    public let subscriptions: SubscriptionMonitor

    /// The transcription engine choice in Settings → Transcription.
    public enum EngineSetting {
        public static let choice = "engine", scriberrURL = "scriberrURL"
        /// Scriberr when it is chosen and its address reads as a URL, otherwise Wavepod's own engine.
        public static func engine(settings: any SettingsStore, client: HTTPClient) throws -> any Engine {
            if settings.string(forKey: choice) == "scriberr",
               let value = settings.string(forKey: scriberrURL), let url = URL(string: value) {
                return try ScriberrEngine(base: url, client: client)
            }
            return IsolatedEngine()
        }
    }

    /// - Parameter interactive: false in processes without a window, such as the feed checker. See
    ///   `AnswerModel.interactive`.
    public init(root: URL = WavepodFolder.default, settings: any SettingsStore = UserDefaults.standard, interactive: Bool = true) throws {
        self.root = root
        store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
        client = HTTPClient(logURL: root.appendingPathComponent("network.json"))
        chatGPT = ChatGPTPlan(client: client)
        claude = ClaudePlan(root: root.appendingPathComponent("claude"), client: client)
        answers = AnswerModel(settings: settings, local: LocalGenerator(directory: root.appendingPathComponent("models/language")),
                              chatGPT: chatGPT, claude: claude, interactive: interactive)
        queue = try JobQueue(store: store, directory: root.appendingPathComponent("jobs"), client: client,
                             engine: try EngineSetting.engine(settings: settings, client: client), notesGenerator: answers)
        subscriptions = SubscriptionMonitor(store: store, client: client, queue: queue)
    }
}
