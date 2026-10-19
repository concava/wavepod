import XCTest
@testable import Resolver

final class ClassifierTests: XCTestCase {
    func testAppleShapes() {
        for host in ["podcasts.apple.com", "itunes.apple.com"] {
            for path in ["/us/podcast/made-up/id123", "/es/podcast/id123", "/podcast/id123", "/id123"] {
                for scheme in ["https", "http", "podcast"] {
                    XCTAssertEqual(LinkClassifier.classify("\(scheme)://\(host)\(path)?i=456&x=1"), .applePodcasts(showID: "123", episodeID: "456"))
                    XCTAssertEqual(LinkClassifier.classify("\(scheme)://\(host)\(path)"), .applePodcasts(showID: "123", episodeID: nil))
                }
            }
        }
    }

    func testSpotifyShapes() {
        let id = "0123456789abcdefghijkl"
        for kind in [SpotifyKind.episode, .show] {
            for prefix in ["", "/intl-es", "/intl-en"] {
                XCTAssertEqual(LinkClassifier.classify("https://open.spotify.com\(prefix)/\(kind.rawValue)/\(id)?si=abc"), .spotify(kind: kind, id: id))
            }
            XCTAssertEqual(LinkClassifier.classify("spotify:\(kind.rawValue):\(id)"), .spotify(kind: kind, id: id))
        }
        XCTAssertEqual(LinkClassifier.classify("spotify:episode:short"), .unknown)
    }

    func testYouTubeShapes() {
        let id = "abcdefghijk"
        for host in ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"] {
            for path in ["/watch?x=1&v=\(id)&t=2", "/shorts/\(id)?si=x", "/live/\(id)?x=1"] {
                XCTAssertEqual(LinkClassifier.classify("https://\(host)\(path)"), .youtube(videoID: id))
            }
        }
        XCTAssertEqual(LinkClassifier.classify("https://youtu.be/\(id)?t=10"), .youtube(videoID: id))
    }

    func testYouTubeEmbedShapes() {
        for host in ["youtube.com", "www.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"] {
            XCTAssertEqual(LinkClassifier.classify("https://\(host)/embed/abcdefghijk?start=30"), .youtube(videoID: "abcdefghijk"))
            XCTAssertEqual(LinkClassifier.classify("https://\(host)/embed/"), .unknown)
        }
    }

    func testFilesFeedsAndCleaning() {
        for ext in ["mp3", "m4a", "aac", "ogg", "opus", "wav", "flac", "mp4", "mov"] {
            let value = "https://example.org/audio.\(ext)?token=x"
            XCTAssertEqual(LinkClassifier.classify(" \n<\"\(value)\">\n"), .audioFile(url(value)))
        }
        for value in ["https://example.org/a.xml", "https://example.org/a.rss", "https://example.org/feed", "https://feeds.example.org/a", "https://example.org/mystery"] {
            XCTAssertEqual(LinkClassifier.classify(value), .rss(url(value)))
        }
        for value in ["hello", "file:///tmp/audio.mp3", "ftp://example.org/a", "https://youtube.com/", "https://podcasts.apple.com/no-id", "https://open.spotify.com/episode/short"] {
            XCTAssertEqual(LinkClassifier.classify(value), .unknown)
        }
    }
}
