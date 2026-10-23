import Foundation
import Library

/// Every section is read, including for questions with no keyword matches. No retrieval cutoff can silently
/// turn a missing search hit into “not in the episode”. Reduction retains original quotes and timestamps.
public struct EpisodeAnswers: Sendable {
    public let generator: any TextGenerating
    public var contextLimit: Int
    public init(generator: any TextGenerating, contextLimit: Int = 9000) {
        self.generator = generator
        self.contextLimit = max(2000, contextLimit)
    }

    public func answer(question: String, language: String, history: [ChatMessage] = [], transcript: Transcript,
                       report: (@Sendable (Int, Int) -> Void)? = nil,
                       progress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> [CitedClaim] {
        let chunks = ContextChunks.make(transcript, limit: contextLimit)
        guard !chunks.isEmpty else { return [] }
        let index = CitationValidator.Index(transcript)
        let grounded = GroundedAnswers(generator: generator)
        let conversation = history.suffix(6).map { message in
            let sources = message.citations.prefix(2).map { "[\($0.start)] \(String($0.quote.prefix(180)))" }.joined(separator: "\n")
            return "\(message.role.rawValue): \(String(message.text.prefix(800)))\n\(sources)"
        }.joined(separator: "\n")
        let task = """
        Answer the current question in \(language == "Auto" ? "the language of the question" : language).
        Use the conversation only to understand follow-up questions. The conversation is not transcript evidence.
        <conversation>\(conversation)</conversation>
        Current question: \(question)
        \(AnswerStyle.instruction)
        """
        let read = ReadCounter()
        await progress("Reading transcript 1 of \(chunks.count)…")
        var findings = try await generator.forEach(chunks) { offset, chunk in
            let instruction = chunks.count == 1 ? task : task + "\nThis is part \(offset + 1) of \(chunks.count) of the transcript. Give every relevant fact in this part. Include conditions, examples, dates and changes of opinion. Wavepod sends the other parts in separate requests. Do not conclude that the whole episode lacks a fact. Return [] only if this part has no evidence."
            let claims = try await grounded.answer(instruction: instruction, context: chunk, transcript: transcript, index: index, report: report)
            let done = await read.increment()
            if done < chunks.count { await progress("Reading transcript \(done + 1) of \(chunks.count)…") }
            return claims
        }.flatMap { $0 }
        findings = Self.unique(findings)
        guard chunks.count > 1, findings.count > 1 else { return findings }
        await progress("Combining evidence from the whole episode…")
        // Hierarchical reduction keeps synthesis within the same context budget as extraction.
        while findings.count > 1 {
            try Task.checkCancellation()
            let groups = Self.groups(findings, limit: contextLimit)
            let reduced = Self.unique(try await generator.forEach(groups) { _, group in
                let notes = group.map { "[\($0.start)]\($0.section.map { " (section: \($0))" } ?? "") Finding: \($0.claim)\nExact quote: \($0.quote)" }.joined(separator: "\n")
                let evidence = group.enumerated().map { offset, claim in
                    Segment(id: offset, speaker: SpeakerID("evidence"), words: [Word(text: claim.quote, start: claim.start, end: claim.start)])
                }
                let result = try await grounded.answer(instruction: task + "\nWrite one direct answer from the verified findings below. Merge findings that say the same thing. Compare what different parts of the episode say. Keep important conditions. Answer every part of the question. Quote only original transcript words. Never quote a finding as transcript text.\n<findings>\(notes)</findings>",
                                                       context: evidence, transcript: transcript, index: index, report: report)
                // A synthesis cannot turn verified evidence into a false “not found”.
                return result.isEmpty ? group : result
            }.flatMap { $0 })
            if groups.count == 1 { return reduced }
            let oldSize = findings.reduce(0) { $0 + $1.claim.count + $1.quote.count }
            let newSize = reduced.reduce(0) { $0 + $1.claim.count + $1.quote.count }
            if newSize >= oldSize { return reduced } // A model refusing to condense must not loop forever.
            findings = reduced
        }
        return findings
    }

    /// Organizes an answer's claims under their sections, in the order the model gave them. Answers without
    /// sections, or with a single unnamed one, stay plain.
    public static func sections(from claims: [CitedClaim]) -> [SummarySection]? {
        var sections: [SummarySection] = []
        for claim in claims {
            let title = claim.section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let point = SummaryPoint(text: claim.claim, citation: claim.citation)
            if let index = sections.firstIndex(where: { $0.title == title }) { sections[index].points.append(point) }
            else { sections.append(SummarySection(title: title, points: [point])) }
        }
        return sections.contains(where: { !$0.title.isEmpty }) ? sections : nil
    }

    private static func unique(_ claims: [CitedClaim]) -> [CitedClaim] {
        var seen = Set<String>()
        return claims.filter { seen.insert("\($0.start)|\(CitationValidator.normalize($0.claim).joined(separator: " "))").inserted }
    }
    private static func groups(_ claims: [CitedClaim], limit: Int) -> [[CitedClaim]] {
        var result: [[CitedClaim]] = [], current: [CitedClaim] = []
        var size = 0
        for claim in claims {
            let count = claim.claim.count + claim.quote.count * 2 + 120
            if size + count > limit, !current.isEmpty { result.append(current); current = []; size = 0 }
            current.append(claim); size += count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

private actor ReadCounter {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}

/// How answers are written: the structure of good episode notes, scaled to the question.
public enum AnswerStyle {
    public static let instruction = """
    Write each claim as one bullet of one to three sentences.
    Start each bullet with a short bold label for its topic or speaker, for example "**Budget limits (host):** ...".
    Be specific. Keep names, roles, numbers, dates, the order of events, examples, anecdotes and who said what.
    Give each opinion and estimate with the name of its speaker.
    Present news and anecdotes as statements made in the conversation.
    If the answer has different parts, give each claim a "section" field with a short heading.
    Write the heading in the language of the answer.
    Examples of parts: who takes part, the main topic, anecdotes, news, audience questions.
    Give the same heading to claims that belong together. Put the most important part first.
    A heading can name its subject, for example "Main topic: personal agents (late 2025 to October 2026)".
    For a short factual question, give one or two bullets and no "section" field.
    """
}
