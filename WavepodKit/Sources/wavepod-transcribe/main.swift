// wavepod-transcribe — runs the app's transcription pipeline (decode, windowed ASR, diarization, word alignment)
// in-process on one file, without the XPC helper or the library. Used by eval/podeval to score what ships.
//
//   wavepod-transcribe <audio> <output.json> --models <root> [--language es] [--work <checkpoint dir>]
//
// The model root has the layout Settings installs: parakeet/, whisper/, vad/, diarizer/.
// Output: {"words": [[start, end, word, speaker], …], "rttm": "…", "text": "…", "proc_s": …, "language": "…",
//          "embeddings": {speaker: [Float]}}.

import Engine
import Foundation
import Library
import NativeEngine
import Pipeline

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(index...(index + 1)) }
    return arguments[index + 1]
}
let models = option("--models")
let language = option("--language")
let work = option("--work")
guard arguments.count == 2, let models else {
    FileHandle.standardError.write(Data("usage: wavepod-transcribe <audio> <output.json> --models <root> [--language xx] [--work dir]\n".utf8))
    exit(2)
}
let input = URL(fileURLWithPath: arguments[0])
let output = URL(fileURLWithPath: arguments[1])
let folder = work.map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.temporaryDirectory.appendingPathComponent("wavepod-transcribe-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

let started = ContinuousClock.now
let decodedURL = folder.appendingPathComponent("decoded.wav")
let asset = FileManager.default.fileExists(atPath: decodedURL.path)
    ? AudioAsset(url: decodedURL, duration: 0)
    : try AudioDecoder.decode(input, to: decodedURL)
let duration = asset.duration > 0 ? asset.duration : try AudioDecoder.decode(input, to: decodedURL).duration
let engine = NativeEngine(models: URL(fileURLWithPath: models))
let transcriber = WindowedTranscriber(engine: engine, diarizer: engine)
let raw = try await transcriber.run(AudioAsset(url: decodedURL, duration: duration), language: language, folder: folder) { step, fraction in
    FileHandle.standardError.write(Data(String(format: "%3.0f%%  %@\n", fraction * 100, step.title).utf8))
}
let transcript = try WordAlignment.render(raw)
let elapsed = ContinuousClock.now - started
let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

var words: [[Any]] = []
for segment in transcript.segments {
    for word in segment.words where !word.text.hasPrefix("[") {
        words.append([word.start, word.end, word.text, segment.speaker.rawValue])
    }
}
let rttm = raw.turns.map { turn in
    String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>",
           input.deletingPathExtension().lastPathComponent, turn.start, turn.end - turn.start, turn.speaker)
}.joined(separator: "\n")
let payload: [String: Any] = [
    "words": words,
    "rttm": rttm,
    "text": words.map { $0[2] as! String }.joined(separator: " "),
    "language": raw.language,
    "proc_s": seconds,
    "load_s": 0.0,
    // One voice embedding per speaker label, for cross-episode identity checks (Phase 4).
    "embeddings": raw.embeddings.mapValues { $0.map(Double.init) },
    "markers": transcript.segments.flatMap(\.words).filter { $0.text.hasPrefix("[") }.map { [$0.start, $0.end] },
]
try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: output)
FileHandle.standardError.write(Data(String(format: "done: %.1f min audio in %.1f s (RTF %.4f)\n", duration / 60, seconds, seconds / duration).utf8))
