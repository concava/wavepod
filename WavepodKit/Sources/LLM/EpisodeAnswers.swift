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
                       progress: @Sendable (String) async -> Void = { _ in }) async throws -> [CitedClaim] {
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
        Use the conversation only to interpret follow-up questions; it is not transcript evidence.
        <conversation>\(conversation)</conversation>
        Current question: \(question)
        \(AnswerStyle.instruction)
        """
        var findings: [CitedClaim] = []
        for (offset, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await progress("Reading transcript \(offset + 1) of \(chunks.count)…")
            let instruction = chunks.count == 1 ? task : task + "\nThis is section \(offset + 1) of \(chunks.count). Extract all relevant facts here, including qualifications, examples, dates and changes of view. Other sections will be read separately. Do not infer that something is absent from the whole episode. Return [] only if this section has no evidence."
            findings += try await grounded.answer(instruction: instruction, context: chunk, transcript: transcript, index: index, report: report)
        }
        findings = Self.unique(findings)
        guard chunks.count > 1, findings.count > 1 else { return findings }
        await progress("Combining evidence from the whole episode…")
        // Hierarchical reduction keeps synthesis within the same context budget as extraction.
        while findings.count > 1 {
            try Task.checkCancellation()
            let groups = Self.groups(findings, limit: contextLimit)
            var reduced: [CitedClaim] = []
            for group in groups {
                let notes = group.map { "[\($0.start)]\($0.section.map { " (section: \($0))" } ?? "") Finding: \($0.claim)\nExact quote: \($0.quote)" }.joined(separator: "\n")
                let evidence = group.enumerated().map { offset, claim in
                    Segment(id: offset, speaker: SpeakerID("evidence"), words: [Word(text: claim.quote, start: claim.start, end: claim.start)])
                }
                let result = try await grounded.answer(instruction: task + "\nSynthesize the verified findings below into a clear, direct answer. Combine duplicates, compare different parts of the episode, preserve important qualifications and answer all parts of the question. Use original quotes, never quote a finding as though it were transcript text.\n<findings>\(notes)</findings>",
                                                       context: evidence, transcript: transcript, index: index, report: report)
                // A synthesis cannot turn verified evidence into a false “not found”.
                reduced += result.isEmpty ? group : result
            }
            reduced = Self.unique(reduced)
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

/// How answers are written: the structure of good episode notes, scaled to the question.
public enum AnswerStyle {
    public static let instruction = """
    Write each claim as one self-contained bullet of one to three sentences that begins with a short bold label
    naming its topic or speaker, e.g. "**Budget limits (host):** ...". Be specific: keep names, roles, figures,
    dates, chronology, examples, anecdotes and who said what. Attribute opinions and estimates to their speakers,
    and present news and anecdotes as claims made in the conversation.
    When the answer has distinct parts (for example who takes part, the main topic, anecdotes, news, audience
    questions), add a "section" field with a short heading in the answer's language, give claims that belong
    together the same heading, and put the most important part first. A heading may name its subject, e.g.
    "Main topic: personal agents (late 2025 to October 2026)". For a short factual question, answer with one or
    two bullets and no sections.
    """
}
