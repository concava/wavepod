import Foundation

public enum SpotifyKind: String, Sendable, Hashable, Codable { case episode, show }

public enum ClassifiedLink: Sendable, Equatable {
    case rss(URL), applePodcasts(showID: String, episodeID: String?)
    case spotify(kind: SpotifyKind, id: String), youtube(videoID: String), audioFile(URL), unknown
}

public enum LinkClassifier {
    static func cleaned(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'")))
    }

    public static func classify(_ input: String) -> ClassifiedLink {
        var text = cleaned(input)
        if text.hasPrefix("spotify:") {
            let parts = text.split(separator: ":")
            if parts.count == 3, let kind = SpotifyKind(rawValue: String(parts[1])), validSpotify(String(parts[2])) {
                return .spotify(kind: kind, id: String(parts[2]))
            }
            return .unknown
        }
        if text.hasPrefix("podcast://") { text = "https://" + text.dropFirst(10) }
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return .unknown }
        let path = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if ["podcasts.apple.com", "itunes.apple.com"].contains(host) {
            if let id = path.first(where: { $0.hasPrefix("id") && !$0.dropFirst(2).isEmpty && $0.dropFirst(2).allSatisfy(\.isNumber) }) {
                let episode = query.first { $0.name == "i" }?.value
                return .applePodcasts(showID: String(id.dropFirst(2)), episodeID: episode)
            }
            return .unknown
        }
        if host == "open.spotify.com" {
            let parts = path.first?.hasPrefix("intl-") == true ? Array(path.dropFirst()) : path
            if parts.count >= 2, let kind = SpotifyKind(rawValue: parts[0]), validSpotify(parts[1]) {
                return .spotify(kind: kind, id: parts[1])
            }
            return .unknown
        }
        if ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be",
            "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(host) {
            let id: String?
            if host.hasSuffix("youtu.be") { id = path.first }
            else if host.hasSuffix("youtube-nocookie.com") { id = path.first == "embed" ? path.dropFirst().first : nil }
            else if path.first == "watch" { id = query.first { $0.name == "v" }?.value }
            else if ["shorts", "live", "embed"].contains(path.first ?? "") { id = path.dropFirst().first }
            else { id = nil }
            if let id, !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                return .youtube(videoID: id)
            }
            return .unknown
        }
        if ["mp3", "m4a", "aac", "ogg", "opus", "wav", "flac", "mp4", "mov"].contains(url.pathExtension.lowercased()) {
            return .audioFile(url)
        }
        // Unknown web hosts are feed candidates; the parser checks the root before accepting them.
        return .rss(url)
    }

    static func validSpotify(_ id: String) -> Bool { id.count == 22 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
}
