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
        let conversation = history.suffix(6).map { "\($0.role.rawValue): \(String($0.text.prefix(1200)))" }.joined(separator: "\n")
        let task = """
        Answer the current question in \(language == "Auto" ? "the language of the question" : language).
        Use the conversation only to interpret follow-up questions; it is not transcript evidence.
        <conversation>\(conversation)</conversation>
        Current question: \(question)
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
                let notes = group.map { "[\($0.start)] Finding: \($0.claim)\nExact quote: \($0.quote)" }.joined(separator: "\n")
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
