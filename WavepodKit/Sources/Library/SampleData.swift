import Foundation

/// An invented episode used by previews, snapshot tests and the app's first-run demo.
/// The show, people and dialogue are fictional and written for this project.
public enum SampleData {
    public static let host = SpeakerID("S0")
    public static let guest = SpeakerID("S1")
    public static let producer = SpeakerID("S2")

    public static let speakers: [SpeakerID: Speaker] = [
        host: Speaker(id: host, name: "Marta Vidal", isConfirmed: true, colorIndex: 0),
        guest: Speaker(id: guest, name: "Jordi Serra", isConfirmed: false, suggestionConfidence: 0.86, colorIndex: 1),
        producer: Speaker(id: producer, name: "Speaker 3", isConfirmed: false, colorIndex: 2),
    ]

    /// (speaker, line, pause before the line in seconds)
    static let script: [(SpeakerID, String, Double)] = [
        (host, "This is Low Tide, the show about the places where the land runs out. I'm Marta Vidal.", 2.0),
        (host, "Today we climb a lighthouse that has not had a keeper living in it since 1988.", 0.4),
        (host, "My guest is the historian Jordi Serra, who spent three winters reading the keepers' logbooks.", 0.5),
        (guest, "Thanks for having me. And for the record, the stairs have one hundred and twelve steps. I counted them every day.", 0.8),
        (host, "Let's start with the logbooks. What did a keeper actually write down?", 0.6),
        (guest, "Everything that could go wrong. Wind direction, visibility, every ship that passed, and how much oil the lamp burned.", 0.7),
        (guest, "The oil mattered most. If the numbers didn't match, an inspector came on the next boat.", 0.4),
        (host, "So the logbook was really an audit.", 0.5),
        (guest, "Exactly. Poetry was not encouraged. But some keepers wrote it in the margins anyway.", 0.3),
        (producer, "Can I jump in? We found one of those margins in the archive in Palamós.", 1.2),
        (host, "This is our producer, who will now read us a poem from 1931.", 0.4),
        (producer, "It's short. The fog came in at four. I wound the horn and waited for the sea to answer.", 0.6),
        (guest, "That's Pere Bosch. He kept the light for thirty-one years and never once missed an entry.", 1.0),
        (host, "The fog horn. Tell me about the horn, because people forget lighthouses made noise.", 0.8),
        (guest, "In fog, light is useless. Sound carries. Each station had its own pattern, so a captain could tell where he was by ear.", 0.6),
        (guest, "Two long blasts every thirty seconds meant one cape. Three short meant another.", 0.4),
        (host, "Like a ringtone for a coastline.", 0.5),
        (guest, "That's a better description than anything in my book.", 0.3),
        (host, "What changed in 1988?", 1.4),
        (guest, "Automation. A sensor could measure the fog, and a timer could run the lamp. The last keeper handed over the keys in March.", 0.7),
        (guest, "He told me the hardest part was the silence. For the first time in decades, nobody needed him to stay awake.", 0.5),
        (host, "When we come back, we'll hear what the lighthouse sounds like now, from the inside.", 1.8),
    ]

    public static let transcript: Transcript = {
        var t: Seconds = 0
        var segments: [Segment] = []
        for (index, (speaker, line, pause)) in script.enumerated() {
            t += pause
            var words: [Word] = []
            for token in line.split(separator: " ") {
                // ~2.7 words per second, longer words take a little longer.
                let length = 0.22 + Double(token.count) * 0.035
                words.append(Word(text: String(token), start: t, end: t + length,
                                  confidence: token.count > 9 ? 0.82 : 0.97,
                                  overlap: index == 9 && words.count < 3))
                t += length + 0.05
            }
            segments.append(Segment(id: index, speaker: speaker, words: words))
        }
        return Transcript(language: "en", segments: segments)
    }()

    public static let episode = Episode(
        id: "sample-low-tide-112",
        showName: "Low Tide",
        title: "One Hundred and Twelve Steps: The Last Lighthouse Keepers",
        pubDate: Date(timeIntervalSince1970: 1_791_878_400),  // 2026-10-13
        duration: transcript.duration + 2,
        descriptionHTML: """
            <p>Historian <b>Jordi Serra</b> spent three winters with the logbooks of the Costa Brava's last \
            lighthouse keepers. He tells <i>Marta Vidal</i> what they wrote down, what they left out, and \
            why the fog horn mattered more than the lamp.</p>
            <ul><li>The logbook as an audit</li><li>A poem from 1931</li><li>March 1988: the keys are handed over</li></ul>
            <p>Read more at <a href="https://example.org/low-tide/112">example.org</a>.</p>
            <script>alert('this never runs')</script>
            """,
        sourceName: "Website",
        sourceURL: URL(string: "https://example.org/low-tide/112"),
        enclosureURL: nil,
        artworkHue: 0.52
    )

    public static func start(ofSegment index: Int) -> Seconds { transcript.segments[index].start }

    public static let chapters: [Chapter] = [
        Chapter(title: "Cold open", start: 0, summary: "Marta introduces the show and the lighthouse."),
        Chapter(title: "The logbook as an audit", start: start(ofSegment: 4),
                summary: "What keepers recorded and why the oil numbers mattered."),
        Chapter(title: "A poem in the margin", start: start(ofSegment: 9),
                summary: "A 1931 entry by keeper Pere Bosch, read from the Palamós archive."),
        Chapter(title: "Sound in the fog", start: start(ofSegment: 13),
                summary: "Fog horn patterns let captains locate themselves by ear."),
        Chapter(title: "Automation, 1988", start: start(ofSegment: 18),
                summary: "Sensors and timers replace the last keeper."),
    ]

    public static let summary = EpisodeSummary(
        overview: "Historian Jordi Serra explains how lighthouse keepers on the Costa Brava worked until automation in 1988: their logbooks were audits rather than diaries, fog horns mattered more than lamps in bad weather, and the last keeper found the silence after automation the hardest part.",
        points: [
            SummaryPoint(text: "Logbooks tracked wind, visibility, passing ships and lamp oil; oil mismatches triggered an inspection.",
                         citation: Citation(start: start(ofSegment: 5), quote: "Wind direction, visibility, every ship that passed")),
            SummaryPoint(text: "Some keepers wrote poetry in the margins, such as Pere Bosch in 1931.",
                         citation: Citation(start: start(ofSegment: 11), quote: "The fog came in at four")),
            SummaryPoint(text: "Each station had its own fog-horn pattern so captains could navigate by ear.",
                         citation: Citation(start: start(ofSegment: 14), quote: "Each station had its own pattern")),
            SummaryPoint(text: "Automation in March 1988 ended live-in keeping at this lighthouse.",
                         citation: Citation(start: start(ofSegment: 19), quote: "The last keeper handed over the keys in March")),
        ],
        quotes: [
            Citation(start: start(ofSegment: 11), quote: "I wound the horn and waited for the sea to answer."),
            Citation(start: start(ofSegment: 20), quote: "For the first time in decades, nobody needed him to stay awake."),
        ]
    )

    public static let chat: [ChatMessage] = [
        ChatMessage(role: .user, text: "Why did the fog horn matter more than the light?",
                    date: Date(timeIntervalSince1970: 1_792_000_000)),
        ChatMessage(role: .assistant,
                    text: "In fog the light could not be seen, but sound still carried. Each station used its own pattern of blasts, so a captain could work out which cape he was near just by listening.",
                    citations: [
                        Citation(start: start(ofSegment: 14), quote: "In fog, light is useless. Sound carries."),
                        Citation(start: start(ofSegment: 15), quote: "Two long blasts every thirty seconds meant one cape."),
                    ],
                    date: Date(timeIntervalSince1970: 1_792_000_004)),
    ]
}
