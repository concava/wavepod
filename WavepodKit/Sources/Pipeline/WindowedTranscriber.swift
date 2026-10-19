import Engine
import Foundation

/// Long audio in 30-minute windows that overlap by 10 s. Each window is transcribed and diarized on its own,
/// both results are checkpointed in `folder`, and windows are stitched at the middle of their overlap.
/// Shared by the job queue and `wavepod-transcribe`, so the golden-set run scores the code the app ships.
public struct WindowedTranscriber: Sendable {
    public var engine: any Engine
    public var diarizer: any Diarizing
    /// Used only when `engine` returns segment-level text without word timings (some Scriberr models).
    public var aligner: (any Engine)?
    public var windowLength: Double = 1800
    public var overlap: Double = 10
    public var diarizationSupport: OfflineDiarizationSupport

    public init(engine: any Engine, diarizer: any Diarizing, aligner: (any Engine)? = nil,
                diarizationSupport: OfflineDiarizationSupport = .current) {
        self.engine = engine
        self.diarizer = diarizer
        self.aligner = aligner
        self.diarizationSupport = diarizationSupport
    }

    public func run(_ asset: AudioAsset, language: String?, folder: URL,
                    stage: @Sendable (String, Double) async throws -> Void) async throws -> RawTranscript {
        var combined = RawTranscript(language: language ?? "und", words: [])
        var start = 0.0
        var index = 0
        while start < asset.duration {
            try Task.checkCancellation()
            let end = min(asset.duration, start + windowLength)
            let windowURL = folder.appendingPathComponent("window-\(index).wav")
            let window: AudioAsset
            if FileManager.default.fileExists(atPath: windowURL.path) {
                window = AudioAsset(url: windowURL, duration: end - start)
            } else {
                window = try AudioDecoder.slice(asset, start: start, end: end, to: windowURL)
            }
            let rawURL = folder.appendingPathComponent("asr-\(index).json")
            var raw: RawTranscript
            if let cached = try? Data(contentsOf: rawURL) {
                raw = try JSONDecoder().decode(RawTranscript.self, from: cached)
            } else {
                try await stage("Transcribing window \(index + 1)", 0.15 + 0.75 * start / asset.duration)
                raw = try await engine.transcribe(window, options: TranscribeOptions(language: language), progress: { _ in })
                // Segment-level text gets real word timings rather than interpolated ones. The pipeline's own
                // "[No speech recognized]" markers are untimed on purpose and never trigger this.
                if let aligner, raw.words.contains(where: Self.lacksWordTiming) {
                    raw = try await aligner.transcribe(window, options: TranscribeOptions(language: language), progress: { _ in })
                }
                try JSONEncoder().encode(raw).write(to: rawURL, options: .atomic)
            }
            if diarizationSupport.isAvailable {
                let diarURL = folder.appendingPathComponent("diar-\(index).json")
                let diar: RawTranscript
                if let cached = try? Data(contentsOf: diarURL) {
                    diar = try JSONDecoder().decode(RawTranscript.self, from: cached)
                } else {
                    try await stage("Identifying speakers, window \(index + 1)", 0.15 + 0.75 * end / asset.duration)
                    diar = try await diarizer.diarize(window)
                    try JSONEncoder().encode(diar).write(to: diarURL, options: .atomic)
                }
                DiarizationAttachment.attach(diar, to: &raw)
            }
            combined.language = raw.language
            let half = overlap / 2
            WindowStitcher.append(raw, start: start, keepFrom: index == 0 ? 0 : start + half,
                                  keepUntil: end == asset.duration ? end + 1 : end - half, to: &combined)
            if end == asset.duration { break }
            start = end - overlap
            index += 1
        }
        // Normalize after stitching: without embeddings, window-local S1 labels otherwise become S1, S2, …
        // Do not checkpoint the fallback as diarization; resuming on macOS 15 must still detect speakers.
        return diarizationSupport.isAvailable ? combined :
            OfflineDiarizationSupport.singleSpeaker(duration: asset.duration, transcript: combined)
    }

    static func lacksWordTiming(_ token: RawWord) -> Bool {
        token.word.confidence == 0 && !token.word.text.hasPrefix("[") && token.word.text.split(separator: " ").count > 1
    }
}
