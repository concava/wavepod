// wavepod-ask — asks the local model questions about one transcript and reports how its citations fare.
// Evaluation tool for the Phase 5 rule "every cited timestamp must contain the supporting text".
//
//   wavepod-ask <transcript.json> <questions.txt> --models <ai root> [--language Spanish]
//
// transcript.json is wavepod-transcribe output; questions.txt has one question per line. The AI root holds
// language/ and embeddings/. Retrieval is the app's meaning search: the 12 segments closest to the question.
// Prints one JSON line per question: {question, claims: [{claim, quote, start}], attempts: [[returned, valid]]}.

import Foundation
import LLM
import Library

@MainActor func option(_ name: String, in arguments: inout [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(index...(index + 1)) }
    return arguments[index + 1]
}
var arguments = Array(CommandLine.arguments.dropFirst())
let models = option("--models", in: &arguments)
let language = option("--language", in: &arguments) ?? "the language of the question"
guard arguments.count == 2, let models else {
    FileHandle.standardError.write(Data("usage: wavepod-ask <transcript.json> <questions.txt> --models <ai root> [--language X]\n".utf8))
    exit(2)
}

// Rebuild segments the way WordAlignment renders them: a new segment on a speaker change or a 1.5 s pause.
struct Output: Decodable {
    let words: [[Value]]
    enum Value: Decodable {
        case number(Double), text(String)
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) { self = .number(number) } else { self = .text(try container.decode(String.self)) }
        }
        var number: Double { if case .number(let n) = self { n } else { 0 } }
        var text: String { if case .text(let t) = self { t } else { "" } }
    }
}
let output = try JSONDecoder().decode(Output.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
var segments: [Segment] = []
for item in output.words {
    let word = Word(text: item[2].text, start: item[0].number, end: item[1].number)
    let speaker = SpeakerID(item[3].text)
    if let last = segments.last, last.speaker == speaker, word.start - last.end < 1.5, last.words.count < 100 {
        segments[segments.count - 1].words.append(word)
    } else {
        segments.append(Segment(id: segments.count, speaker: speaker, words: [word]))
    }
}
let transcript = Transcript(language: "und", segments: segments)
let questions = try String(contentsOfFile: arguments[1], encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }

let root = URL(fileURLWithPath: models)
let embeddings = LocalEmbeddings(directory: root.appendingPathComponent("embeddings"))
let vectors = try await embeddings.encode(segments.map { $0.words.map(\.text).joined(separator: " ") })
let generator = LocalGenerator(directory: root.appendingPathComponent("language"))

final class Attempts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[Int]] = []
    func add(_ returned: Int, _ valid: Int) { lock.lock(); values.append([returned, valid]); lock.unlock() }
    func take() -> [[Int]] { lock.lock(); defer { values = []; lock.unlock() }; return values }
}
let attempts = Attempts()
for question in questions {
    let query = try await embeddings.encode([question], query: true)[0]
    let ranked = zip(segments, vectors).compactMap { segment, vector in VectorMath.cosine(query, vector).map { (segment, $0) } }
        .sorted { $0.1 > $1.1 }.prefix(12).map(\.0).sorted { $0.start < $1.start }
    let context = Array(ranked)
    let claims = try await generator.withSession { session in
        try await GroundedAnswers(generator: session).answer(
            instruction: "Answer this question in \(language): \(question)", context: context, transcript: transcript,
            report: { attempts.add($0, $1) })
    }
    let line: [String: Any] = [
        "question": question,
        "claims": claims.map { ["claim": $0.claim, "quote": $0.quote, "start": $0.start] },
        "attempts": attempts.take(),
    ]
    print(String(data: try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]), encoding: .utf8)!)
}
