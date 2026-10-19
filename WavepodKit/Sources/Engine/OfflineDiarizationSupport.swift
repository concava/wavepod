import Foundation

/// macOS 14's BNNS fallback can crash even with `.all` routing and a physical Neural Engine.
/// Keep this check outside Core ML so unsupported systems never load the offline diarizer.
public struct OfflineDiarizationSupport: Sendable {
    public static let current = Self(macOSVersion: ProcessInfo.processInfo.operatingSystemVersion)
    public let isAvailable: Bool

    public init(macOSVersion: OperatingSystemVersion) {
        isAvailable = macOSVersion.majorVersion >= 15
    }

    public var explanation: String? {
        isAvailable ? nil : "Speaker detection requires macOS 15 or later because an Apple system bug can crash it on macOS 14. Audio transcribed on this Mac uses a single speaker. Publisher transcripts keep their speaker labels."
    }

    public static func singleSpeaker(duration: Double, transcript: RawTranscript = RawTranscript(language: "", words: [])) -> RawTranscript {
        var result = transcript
        result.words = result.words.map {
            var token = $0
            token.speaker = "S1"
            token.word.overlap = false
            return token
        }
        result.turns = duration > 0 ? [SpeakerTurn(speaker: "S1", start: 0, end: duration)] : []
        result.embeddings = [:]
        return result
    }
}
