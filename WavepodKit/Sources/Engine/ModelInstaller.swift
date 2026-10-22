import CryptoKit
import Foundation
import Networking

public struct ModelSpec: Sendable {
    public var repository: String
    public var folder: String
    public var prefix: String
    public init(repository: String, folder: String, prefix: String = "") {
        self.repository = repository; self.folder = folder; self.prefix = prefix
    }
    public static let native: [Self] = [
        Self(repository: "FluidInference/parakeet-ultra-coreml", folder: "parakeet"),
        Self(repository: "argmaxinc/whisperkit-coreml", folder: "whisper", prefix: "openai_whisper-large-v3-v20240930_turbo/"),
        Self(repository: "openai/whisper-large-v3-turbo", folder: "whisper", prefix: ""),
        Self(repository: "FluidInference/silero-vad-coreml", folder: "vad"),
        Self(repository: "FluidInference/speaker-diarization-coreml", folder: "diarizer"),
    ]
    public static let language = Self(repository: "mlx-community/Qwen3-4B-Instruct-2507-4bit", folder: "language")
    public static let embeddings = Self(repository: "intfloat/multilingual-e5-small", folder: "embeddings")
}

/// Downloads snapshots through the app transport, records immutable revisions, and verifies LFS hashes.
public struct ModelInstaller: Sendable {
    public let client: HTTPClient
    public let root: URL
    public init(client: HTTPClient, root: URL) { self.client = client; self.root = root }
    public func install(_ spec: ModelSpec, progress: @Sendable @escaping (String) -> Void) async throws {
        struct Info: Decodable {
            struct File: Decodable {
                struct LFS: Decodable { var sha256: String; var size: Int64 }
                var rfilename: String; var blobId: String?; var lfs: LFS?
            }
            var sha: String; var siblings: [File]
        }
        let url = URL(string: "https://huggingface.co/api/models/\(spec.repository)?blobs=true")!
        let (data, response) = try await client.data(URLRequest(url: url), purpose: "model")
        guard response.statusCode == 200 else { throw NetworkError.status(response.statusCode) }
        let info = try JSONDecoder().decode(Info.self, from: data)
        let marker = root.appendingPathComponent(spec.folder).appendingPathComponent("revision-\(spec.repository.replacingOccurrences(of: "/", with: "-"))")
        let sameRevision = (try? String(contentsOf: marker, encoding: .utf8)) == info.sha
        let files = info.siblings.filter { file in
            let path = file.rfilename
            guard path.hasPrefix(spec.prefix), !path.contains(".."), !path.hasPrefix("/"), !path.contains("\\") else { return false }
            if ["LICENSE", "NOTICE", "NOTICE.md", "README.md", "PROVENANCE.md"].contains(path) { return true }
            if spec.repository == "openai/whisper-large-v3-turbo" {
                return ["tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt", "special_tokens_map.json", "added_tokens.json", "normalizer.json"].contains(path)
            }
            if spec.folder == "diarizer" {
                return ["Segmentation.mlmodelc/", "Embedding.mlmodelc/", "FBank.mlmodelc/", "PldaRho.mlmodelc/"].contains(where: path.hasPrefix) || path == "plda-parameters.json"
            }
            if spec.folder == "parakeet" {
                return ["Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecisionv3.mlmodelc/"].contains(where: path.hasPrefix) || path == "parakeet_vocab.json"
            }
            if spec.folder == "vad" { return path.hasPrefix("silero-vad-unified-256ms-v6.2.1.mlmodelc/") }
            if spec.folder == "embeddings", path == "1_Pooling/config.json" { return true }
            if path.contains(".mlmodelc/") { return true }
            return !path.contains("/") && ["safetensors", "json", "txt", "model", "jinja"].contains(URL(fileURLWithPath: path).pathExtension)
        }
        guard !files.isEmpty else { throw EngineError.unavailable("Wavepod found no compatible files for \(spec.repository).") }
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let relative = String(file.rfilename.dropFirst(spec.prefix.count))
            let destination = root.appendingPathComponent(spec.folder).appendingPathComponent(relative)
            progress("\(spec.folder): \(index + 1)/\(files.count) · \(relative)")
            if FileManager.default.fileExists(atPath: destination.path) {
                if let hash = file.lfs?.sha256, try digest(destination) == hash { continue }
                if file.lfs == nil, sameRevision { continue }
                try FileManager.default.removeItem(at: destination)
            }
            let remote = URL(string: "https://huggingface.co/\(spec.repository)/resolve/\(info.sha)/\(file.rfilename)")!
            try await client.download(remote, to: destination, purpose: "model")
            if let hash = file.lfs?.sha256, try digest(destination) != hash {
                try FileManager.default.removeItem(at: destination)
                throw EngineError.unavailable("Model checksum failed for \(relative). Retry the download.")
            }
        }
        try info.sha.write(to: marker, atomically: true, encoding: .utf8)
    }
    private func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
