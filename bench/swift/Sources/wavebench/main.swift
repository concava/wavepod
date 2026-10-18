// wavebench — runs one Swift-native engine over bench/data/manifest.json.
//
//   wavebench whisperkit <model> [ids...]   e.g. large-v3-v20240930_turbo
//   wavebench parakeet [ids...]             FluidAudio Parakeet TDT v3 "ultra" (en/es only)
//   wavebench diarize [ids...]              FluidAudio offline pyannote pipeline
//
// Output matches the Python runners: results/raw/<engine>/<id>.json with {text, proc_s, load_s}, or
// {rttm, proc_s, load_s} for diarization. Peak memory is measured outside, with /usr/bin/time -l.
// Run from the bench/ directory.

import FluidAudio
import Foundation
import WhisperKit

struct Item: Decodable {
    let id: String
    let lang: String
    let audio: String
    let duration_s: Double
    let kind: String
}

let bench = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelCache = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/wavepod-bench/models")

func items(kind: String, ids: [String]) throws -> [Item] {
    let data = try Data(contentsOf: bench.appendingPathComponent("data/manifest.json"))
    return try JSONDecoder().decode([Item].self, from: data)
        .filter { $0.kind == kind && (ids.isEmpty || ids.contains($0.id)) }
}

func write(_ engine: String, _ item: Item, _ payload: [String: Any]) throws {
    let dir = bench.appendingPathComponent("results/raw/\(engine)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try data.write(to: dir.appendingPathComponent("\(item.id).json"))
    let rtf = (payload["proc_s"] as! Double) / item.duration_s
    print("\(item.id): RTF \(String(format: "%.4f", rtf))")
}

func seconds(since start: ContinuousClock.Instant) -> Double {
    let d = ContinuousClock.now - start
    return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

func runWhisperKit(model: String, ids: [String]) async throws {
    let engine = "wk-\(model)"
    let t0 = ContinuousClock.now
    let pipe = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: modelCache, verbose: false))
    let load = seconds(since: t0)
    for item in try items(kind: "asr", ids: ids) {
        // WB_CHUNKING=none disables VAD chunking; WB_NO_THRESHOLDS=1 turns off the silence/quality skips.
        let env = ProcessInfo.processInfo.environment
        var options = DecodingOptions(
            language: item.lang,
            usePrefillPrompt: true,
            detectLanguage: false,
            chunkingStrategy: env["WB_CHUNKING"] == "none" ? ChunkingStrategy.none : .vad
        )
        if env["WB_NO_THRESHOLDS"] == "1" {
            options.noSpeechThreshold = nil
            options.logProbThreshold = nil
            options.compressionRatioThreshold = nil
        }
        let t = ContinuousClock.now
        let results = try await pipe.transcribe(
            audioPath: bench.appendingPathComponent(item.audio).path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        print("  \(results.count) results, \(results.reduce(0) { $0 + $1.segments.count }) segments")
        try write(engine, item, ["text": text, "proc_s": seconds(since: t), "load_s": load])
    }
}

func runParakeet(ids: [String]) async throws {
    let t0 = ContinuousClock.now
    let models = try await AsrModels.downloadAndLoad(to: modelCache.appendingPathComponent("parakeet-ultra"), version: .ultra)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    let load = seconds(since: t0)
    for item in try items(kind: "asr", ids: ids) where ["en", "es"].contains(item.lang) {
        var state = try TdtDecoderState()
        let t = ContinuousClock.now
        let result = try await asr.transcribe(bench.appendingPathComponent(item.audio), decoderState: &state)
        try write("fa-parakeet-ultra", item, ["text": result.text, "proc_s": seconds(since: t), "load_s": load])
    }
}

func runDiarize(ids: [String]) async throws {
    let t0 = ContinuousClock.now
    let manager = OfflineDiarizerManager()
    try await manager.prepareModels()
    let load = seconds(since: t0)
    for item in try items(kind: "diarization", ids: ids) {
        let t = ContinuousClock.now
        let result = try await manager.process(bench.appendingPathComponent(item.audio))
        let proc = seconds(since: t)
        let rttm = result.segments.map { s in
            String(format: "SPEAKER %@ 1 %.3f %.3f <NA> <NA> %@ <NA> <NA>",
                   item.id, s.startTimeSeconds, s.endTimeSeconds - s.startTimeSeconds, s.speakerId)
        }.joined(separator: "\n")
        try write("fa-offline", item, ["rttm": rttm, "proc_s": proc, "load_s": load])
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    print("usage: wavebench whisperkit <model> [ids...] | parakeet [ids...] | diarize [ids...]")
    exit(2)
}
let command = args.removeFirst()
switch command {
case "whisperkit":
    let model = args.removeFirst()
    try await runWhisperKit(model: model, ids: args)
case "parakeet":
    try await runParakeet(ids: args)
case "diarize":
    try await runDiarize(ids: args)
default:
    print("unknown command \(command)")
    exit(2)
}
