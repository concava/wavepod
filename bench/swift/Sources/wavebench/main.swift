// wavebench — runs one Swift-native engine over bench/data/manifest.json.
//
//   wavebench whisperkit <model> [ids...]   e.g. large-v3-v20240930_turbo
//   wavebench whisperkit-vad <model> [ids...]   same model, VAD windows decoded independently
//   wavebench parakeet [ids...]             FluidAudio Parakeet TDT v3 "ultra" (en/es only)
//   wavebench diarize [ids...]              FluidAudio offline pyannote pipeline
//
// Output matches the Python runners: results/raw/<engine>/<id>.json with {text, proc_s, load_s}, or
// {rttm, proc_s, load_s} for diarization. Peak memory is measured outside, with /usr/bin/time -l.
// parakeet and whisperkit-vad also write "words": [[start, end, word], …] (seconds from the file start).
// Run from the bench/ directory. podeval points it elsewhere with WB_MANIFEST and WB_RESULTS (absolute paths);
// audio paths in a manifest may be absolute or relative to bench/.

import FluidAudio
import Foundation
import WhisperKit

struct Sentence: Decodable {
    let start: Double
    let end: Double
}

struct Item: Decodable {
    let id: String
    let segments: [Sentence]?
    let lang: String
    let audio: String
    let duration_s: Double
    let kind: String
}

let bench = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let modelCache = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/wavepod-bench/models")

let environment = ProcessInfo.processInfo.environment
let manifestURL = environment["WB_MANIFEST"].map { URL(fileURLWithPath: $0) }
    ?? bench.appendingPathComponent("data/manifest.json")
let resultsURL = environment["WB_RESULTS"].map { URL(fileURLWithPath: $0) }
    ?? bench.appendingPathComponent("results/raw")

func audioURL(_ item: Item) -> URL {
    item.audio.hasPrefix("/") ? URL(fileURLWithPath: item.audio) : audioURL(item)
}

func items(kind: String, ids: [String]) throws -> [Item] {
    let data = try Data(contentsOf: manifestURL)
    return try JSONDecoder().decode([Item].self, from: data)
        .filter { $0.kind == kind && (ids.isEmpty || ids.contains($0.id)) }
}

func write(_ engine: String, _ item: Item, _ payload: [String: Any]) throws {
    let dir = resultsURL.appendingPathComponent(engine)
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
            audioPath: audioURL(item).path, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        print("  \(results.count) results, \(results.reduce(0) { $0 + $1.segments.count }) segments")
        try write(engine, item, ["text": text, "proc_s": seconds(since: t), "load_s": load])
    }
}

/// WhisperX-style long-form: Silero VAD finds speech, adjacent regions are merged into windows of at most
/// `maxWindow` seconds, and each window is decoded on its own (no text carried over between windows).
func runWhisperKitVAD(model: String, ids: [String]) async throws {
    let engine = "wk-vad-\(model)"
    let maxWindow = Double(ProcessInfo.processInfo.environment["WB_MAX_WINDOW"] ?? "") ?? 28.0
    let t0 = ContinuousClock.now
    let pipe = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: modelCache, verbose: false))
    let vadThreshold = Float(ProcessInfo.processInfo.environment["WB_VAD_THRESHOLD"] ?? "") ?? 0.85
    let vad = try await VadManager(config: VadConfig(defaultThreshold: vadThreshold))
    let load = seconds(since: t0)
    var segmentation = VadSegmentationConfig.default
    segmentation.minSilenceDuration = 0.3
    segmentation.maxSpeechDuration = maxWindow
    segmentation.speechPadding = 0.2
    for item in try items(kind: "asr", ids: ids) {
        let t = ContinuousClock.now
        let samples = try AudioConverter().resampleAudioFile(audioURL(item))
        // WB_AGC=1 levels the signal the VAD sees (not what Whisper sees), so quiet speakers are still detected.
        let vadInput = ProcessInfo.processInfo.environment["WB_AGC"] == "1" ? levelled(samples) : samples
        let regions = try await vad.segmentSpeech(vadInput, config: segmentation)
        var windows: [(Double, Double)] = []
        if ProcessInfo.processInfo.environment["WB_TILE"] == "1" {
            // Tile the whole file: cut only in the middle of silences between VAD regions, never drop audio.
            let total = Double(samples.count) / 16_000
            let cuts = zip(regions, regions.dropFirst()).map { ($0.endTime + $1.startTime) / 2 }
            var start = 0.0, lastCut = 0.0
            for cut in cuts + [total] {
                if cut - start > maxWindow, lastCut > start {
                    windows.append((start, lastCut))
                    start = lastCut
                }
                lastCut = cut
            }
            // Anything still longer than maxWindow (no silence found) is split hard.
            var s = start
            while total - s > maxWindow { windows.append((s, s + maxWindow)); s += maxWindow }
            windows.append((s, total))
        } else {
            for r in regions {
                if let last = windows.last, r.endTime - last.0 <= maxWindow {
                    windows[windows.count - 1].1 = r.endTime
                } else {
                    windows.append((r.startTime, r.endTime))
                }
            }
        }
        // WB_NO_TS=1 decodes each window without timestamp tokens, so the decoder cannot seek past a sentence.
        let options = DecodingOptions(language: item.lang, usePrefillPrompt: true, detectLanguage: false,
                                      withoutTimestamps: ProcessInfo.processInfo.environment["WB_NO_TS"] == "1",
                                      wordTimestamps: true)
        var texts: [String] = []
        var words: [[Any]] = []
        for (start, end) in windows {
            let a = max(0, Int(start * 16_000)), b = min(samples.count, Int(end * 16_000))
            guard b > a else { continue }
            let results = try await pipe.transcribe(audioArray: Array(samples[a..<b]), decodeOptions: options)
            let windowText = results.map(\.text).joined(separator: " ")
            for w in results.flatMap(\.allWords) {
                words.append([start + Double(w.start), start + Double(w.end), w.word.trimmingCharacters(in: .whitespaces)])
            }
            if ProcessInfo.processInfo.environment["WB_DEBUG"] == "1" {
                print(String(format: "  [%7.2f–%7.2f] ", start, end) + windowText)
            }
            texts.append(windowText)
        }
        print("  \(regions.count) speech regions, \(windows.count) windows")
        try write(engine, item, ["text": texts.joined(separator: " "), "words": words,
                                 "proc_s": seconds(since: t), "load_s": load])
    }
}

/// Short-term gain toward -20 dBFS over 0.4 s blocks, at most +24 dB, never boosting blocks below -60 dBFS
/// (true silence). Gains are smoothed between blocks to avoid steps.
func levelled(_ x: [Float]) -> [Float] {
    let block = 6_400
    var gains: [Float] = []
    var i = 0
    while i < x.count {
        let chunk = x[i..<min(x.count, i + block)]
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let db = 20 * log10(max(rms, 1e-9))
        gains.append(db < -60 ? 1 : pow(10, min(24, max(0, -20 - db)) / 20))
        i += block
    }
    var out = x
    for (b, g) in gains.enumerated() {
        let next = b + 1 < gains.count ? gains[b + 1] : g
        let start = b * block
        for j in start..<min(x.count, start + block) {
            let t = Float(j - start) / Float(block)
            out[j] = x[j] * (g + (next - g) * t)
        }
    }
    return out
}

/// Short-form: decode each FLEURS sentence on its own, using the known boundaries.
func runShort(engine: String, ids: [String], languages: Set<String>? = nil,
              decode: ([Float], Item) async throws -> String) async throws {
    for item in try items(kind: "asr", ids: ids) where languages?.contains(item.lang) ?? true {
        let samples = try AudioConverter().resampleAudioFile(audioURL(item))
        let t = ContinuousClock.now
        var texts: [String] = []
        for s in item.segments ?? [] {
            let a = max(0, Int(s.start * 16_000)), b = min(samples.count, Int(s.end * 16_000))
            texts.append(try await decode(Array(samples[a..<b]), item))
        }
        try write(engine, item, ["text": texts.joined(separator: " "), "proc_s": seconds(since: t), "load_s": 0.0])
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
        let result = try await asr.transcribe(audioURL(item), decoderState: &state)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map { [$0.startTime, $0.endTime, $0.word] as [Any] }
        try write("fa-parakeet-ultra", item, ["text": result.text, "words": words,
                                              "proc_s": seconds(since: t), "load_s": load])
    }
}

func runDiarize(ids: [String]) async throws {
    let t0 = ContinuousClock.now
    let manager = OfflineDiarizerManager()
    try await manager.prepareModels()
    let load = seconds(since: t0)
    for item in try items(kind: "diarization", ids: ids) {
        let t = ContinuousClock.now
        let result = try await manager.process(audioURL(item))
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
case "whisperkit-vad":
    let model = args.removeFirst()
    try await runWhisperKitVAD(model: model, ids: args)
case "parakeet":
    try await runParakeet(ids: args)
case "whisperkit-short":
    let model = args.removeFirst()
    let pipe = try await WhisperKit(WhisperKitConfig(model: model, downloadBase: modelCache, verbose: false))
    try await runShort(engine: "wk-\(model)-short", ids: args) { audio, item in
        let options = DecodingOptions(language: item.lang, usePrefillPrompt: true, detectLanguage: false)
        return try await pipe.transcribe(audioArray: audio, decodeOptions: options).map(\.text).joined(separator: " ")
    }
case "parakeet-short":
    let models = try await AsrModels.downloadAndLoad(to: modelCache.appendingPathComponent("parakeet-ultra"), version: .ultra)
    let asr = AsrManager(config: .default)
    try await asr.loadModels(models)
    try await runShort(engine: "fa-parakeet-ultra-short", ids: args, languages: ["en", "es"]) { audio, _ in
        var state = try TdtDecoderState()
        return try await asr.transcribe(audio, decoderState: &state).text
    }
case "diarize":
    try await runDiarize(ids: args)
default:
    print("unknown command \(command)")
    exit(2)
}
