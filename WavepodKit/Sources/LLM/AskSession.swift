import Foundation
import Library

/// Supplies the model for one answer. `AnswerModel` in the app, a fixed model in tests.
public protocol AnswerGenerating: Sendable {
    func withGenerator<T: Sendable>(_ choice: AnswerChoice,
                                    _ body: @Sendable (any TextGenerating, Int) async throws -> T) async throws -> T
}
extension AnswerModel: AnswerGenerating {}

/// One question about one episode, from the moment it is asked to the answer saved in the library (decision 0010).
///
/// - The question is saved first, so it shows at once and survives a quit.
/// - The whole transcript is read with the chosen model. Earlier messages give follow-ups their context.
/// - The answer is saved to the episode the question was asked on, also when the person has opened another one.
/// - A cancelled question saves "Stopped…", a failed one says why. Neither saves a partial answer.
public struct AskSession: Sendable {
    public static let stopped = "Stopped before completing the answer."
    public static let notFound = "I read the whole transcript and couldn’t find evidence to answer that question."

    let store: LibraryStore
    let answers: any AnswerGenerating

    public init(store: LibraryStore, answers: any AnswerGenerating) {
        self.store = store
        self.answers = answers
    }

    /// Asks `question` about the saved episode and returns the answer it saved, or nil when the episode is gone.
    /// - Parameter progress: reading and synthesis status, such as "Reading part 2 of 5…".
    @discardableResult
    public func ask(_ question: String, episodeID: String, choice: AnswerChoice,
                    progress: @escaping @Sendable (String) async -> Void = { _ in }) async -> ChatMessage? {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,
              let record = try? store.update(episodeID, { $0.chat.append(ChatMessage(role: .user, text: question, date: .now)) })
        else { return nil }
        let history = Array(record.chat.dropLast()), transcript = record.transcript
        let answer: ChatMessage
        do {
            let claims = try await answers.withGenerator(choice) { generator, limit in
                try await EpisodeAnswers(generator: generator, contextLimit: limit)
                    .answer(question: question, language: "Auto", history: history, transcript: transcript, progress: progress)
            }
            try Task.checkCancellation()
            answer = ChatMessage(role: .assistant, text: claims.isEmpty ? Self.notFound : claims.map(\.claim).joined(separator: "\n\n"),
                                 citations: claims.map(\.citation), date: .now, sections: EpisodeAnswers.sections(from: claims))
        } catch is CancellationError {
            answer = ChatMessage(role: .assistant, text: Self.stopped, date: .now)
        } catch {
            answer = ChatMessage(role: .assistant, text: Task.isCancelled ? Self.stopped : "I couldn’t complete this answer: \(error.localizedDescription)",
                                 date: .now)
        }
        guard (try? store.update(episodeID, { $0.chat.append(answer) })) != nil else { return nil }
        return answer
    }
}
