@preconcurrency import AVFoundation
@preconcurrency import CoreML
import ArgmaxCore
import Engine
import FluidAudio
import Foundation
import Library
import WhisperKit

public struct NativeEngine: Engine, Diarizing {
    public let id = "native"
    public let models: URL
    public init(models: URL) { self.models = models }
    public func capabilities() async throws -> EngineCapabilities {
        EngineCapabilities(wordTimestamps: true, diarization: true, embeddings: true)
    }
    private func required(_ path: String) throws -> URL {
        let url = models.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineError.unavailable("Install the transcription models in Settings → Transcription. Missing: \(path).")
        }
        return url
    }
    private func whisper() async throws -> WhisperKit {
        let folder = try required("whisper")
        _ = try required("whisper/tokenizer.json")
        _ = try await AutoTokenizerWrapper.from(modelFolder: folder)
        return try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: folder,
                                                    verbose: false, download: false))
    }
    public func transcribe(_ audio: AudioAsset, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> RawTranscript {
        var detectedLanguage = options.language?.lowercased().split(separator: "-").first.map(String.init)
        if detectedLanguage == nil || detectedLanguage == "auto" {
            let detector = try await whisper()
            detectedLanguage = try await detector.detectLanguage(audioPath: audio.url.path).language
            await detector.unloadModels()
        }
        let language = detectedLanguage ?? "en"
        let parakeetLanguages: Set<String> = ["en", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "uk", "bg", "hr", "cs", "da", "et", "fi", "el", "hu", "lv", "lt", "mt", "ro", "sk", "sl", "sv"]
        let asr: AsrManager?
        let whisper: WhisperKit?
        if parakeetLanguages.contains(language) {
            let folder = try required("parakeet")
            let manager = AsrManager(config: .default)
            try await manager.loadModels(AsrModels.loadLocal(from: folder, version: .ultra))
            asr = manager; whisper = nil
        } else { asr = nil; whisper = try await self.whisper() }
        let vadModel = try MLModel(contentsOf: required("vad/silero-vad-unified-256ms-v6.2.1.mlmodelc"))
        let vad = VadManager(config: VadConfig(defaultThreshold: 0.5), vadModel: vadModel)
        let file = try AVAudioFile(forReading: audio.url)
        let checkpoint = audio.url.appendingPathExtension("asr.json")
        struct Partial: Codable { var nextSample: Int64; var result: RawTranscript }
        var partial = (try? JSONDecoder().decode(Partial.self, from: Data(contentsOf: checkpoint))) ??
            Partial(nextSample: 0, result: RawTranscript(language: language, words: []))
        file.framePosition = partial.nextSample
        if let asr, partial.nextSample == 0 {
            // Parakeet's own long-form decoding (overlapping chunks, merged tokens) over the whole window. Cutting
            // it into independent 14 s pieces lost words at every cut: on two golden-set windows WER rose from
            // 11.91 to 14.06 % and 5.30 to 6.66 %, deletions doubling. It decodes every sample, so no audio is
            // dropped; the window is the checkpoint unit.
            var state = try TdtDecoderState()
            let decoded = try await asr.transcribe(audio.url, decoderState: &state)
            partial.result.words = buildWordTimings(from: decoded.tokenTimings ?? []).map {
                RawWord(Word(text: $0.word, start: $0.startTime, end: min($0.endTime, audio.duration)))
            }
            if partial.result.words.isEmpty {
                partial.result.words = [RawWord(Word(text: "[No speech recognized]", start: 0, end: audio.duration, confidence: 0))]
            }
            partial.nextSample = file.length
            try JSONEncoder().encode(partial).write(to: checkpoint, options: .atomic)
            progress(1)
            return partial.result
        }
        let maximumWindow = 28
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let startFrame = file.framePosition
            let count = AVAudioFrameCount(min(Int64(maximumWindow * 16000), file.length - startFrame))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw EngineError.invalidResult }
            try file.read(into: buffer, frameCount: count)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { throw EngineError.invalidResult }
            var values = Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            // VAD selects a silence boundary, but every sample, including quiet speakers, is decoded.
            var segmentation = VadSegmentationConfig.default
            segmentation.minSilenceDuration = 0.2
            segmentation.speechPadding = 0
            let regions = try await vad.segmentSpeech(values, config: segmentation)
            if count == maximumWindow * 16000,
               let cut = zip(regions, regions.dropFirst()).map({ ($0.endTime + $1.startTime) / 2 })
                .filter({ $0 >= Double(maximumWindow) / 2 && $0 <= Double(maximumWindow) }).last {
                let length = Int(cut * 16000)
                values = Array(values.prefix(length))
                file.framePosition = startFrame + Int64(length)
            }
            let offset = Double(startFrame) / 16000
            let tokens: [RawWord]
            if let asr {
                var state = try TdtDecoderState()
                // Parakeet needs at least 300 ms, including the last fractional tail of a file.
                let input = values.count < 4800 ? values + Array(repeating: Float(0), count: 4800 - values.count) : values
                let decoded = try await asr.transcribe(input, decoderState: &state)
                tokens = buildWordTimings(from: decoded.tokenTimings ?? []).filter { $0.startTime < Double(values.count) / 16000 }.map {
                    RawWord(Word(text: $0.word, start: offset + $0.startTime, end: offset + min($0.endTime, Double(values.count) / 16000)))
                }
            } else if let whisper {
                let options = DecodingOptions(language: language, detectLanguage: false, wordTimestamps: true, chunkingStrategy: ChunkingStrategy.none)
                tokens = try await whisper.transcribe(audioArray: values, decodeOptions: options).flatMap(\.allWords).map {
                    RawWord(Word(text: $0.word.trimmingCharacters(in: .whitespaces), start: offset + Double($0.start), end: offset + Double($0.end), confidence: $0.probability))
                }
            } else { throw EngineError.invalidResult }
            if tokens.isEmpty {
                // Silence/undecodable audio remains visible instead of silently disappearing.
                partial.result.words.append(RawWord(Word(text: "[No speech recognized]", start: offset,
                                                         end: Double(file.framePosition) / 16000, confidence: 0)))
            } else { partial.result.words.append(contentsOf: tokens) }
            partial.nextSample = file.framePosition
            try JSONEncoder().encode(partial).write(to: checkpoint, options: .atomic)
            progress(Double(file.framePosition) / Double(file.length))
        }
        await whisper?.unloadModels()
        return partial.result
    }

    public func diarize(_ audio: AudioAsset) async throws -> RawTranscript {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        func model(_ name: String) throws -> MLModel {
            try MLModel(contentsOf: required("diarizer/\(name).mlmodelc"), configuration: configuration)
        }
        // Load only local files: a missing/corrupt model must never trigger an SDK's hidden network fallback.
        let parameters = try JSONSerialization.jsonObject(with: Data(contentsOf: required("diarizer/plda-parameters.json"))) as? [String: Any]
        guard let tensors = parameters?["tensors"] as? [String: Any], let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String, let bytes = Data(base64Encoded: encoded), bytes.count % 4 == 0 else { throw EngineError.invalidResult }
        var floats = [Float](repeating: 0, count: bytes.count / 4)
        _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        let models = try OfflineDiarizerModels(segmentationModel: model("Segmentation"), fbankModel: model("FBank"),
                                              embeddingModel: model("Embedding"), pldaRhoModel: model("PldaRho"),
                                              pldaPsi: floats.map(Double.init), compilationDuration: 0)
        let manager = OfflineDiarizerManager()
        manager.initialize(models: models)
        let result = try await manager.process(audio.url)
        return RawTranscript(language: "", words: [], turns: result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }, embeddings: result.speakerDatabase ?? [:])
    }
}
