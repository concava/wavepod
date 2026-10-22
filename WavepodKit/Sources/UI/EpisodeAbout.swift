import Library
import SwiftUI

/// The About side pane: show, date, length, download and the feed's description.
struct EpisodeAbout: View {
    let model: AppModel
    @Environment(\.typography) private var type

    private var episode: Episode { model.episode }
    private var description: AttributedString { SafeHTML.renderDescription(episode.descriptionHTML) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(episode.showName, systemImage: "headphones")
                    .font(type.label)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Palette.accentSoft, in: Capsule())
                    .accessibilityLabel("Podcast: \(episode.showName)")

                // In a narrow pane the Download button moves under the date and length instead of wrapping its label.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        facts
                        downloadButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 14) { facts }
                        downloadButton
                    }
                }

                Text(description)
                    .font(type.reading)
                    .foregroundStyle(Palette.ink)
                    .tint(Palette.accent)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Episode description")
                    .accessibilityValue(String(description.characters))
                    // Timestamps in the notes play the episode from that point. Other links open in the browser.
                    .environment(\.openURL, OpenURLAction { url in
                        guard let seconds = SafeHTML.seconds(in: url) else { return .systemAction }
                        model.play(from: episode.duration > 0 ? min(Double(seconds), episode.duration - 1) : Double(seconds))
                        return .handled
                    })
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("About this episode")
    }

    private var facts: some View {
        Group {
            Label(episode.pubDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            Label(Timecode.format(episode.duration), systemImage: "clock")
                .accessibilityLabel("Duration \(Timecode.spoken(episode.duration))")
        }
        .font(type.callout)
        .foregroundStyle(Palette.inkMuted)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .fixedSize()
    }

    private var downloadButton: some View {
        Button(action: model.downloadAudio) {
            Label("Download", systemImage: "arrow.down")
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(SecondaryButtonStyle())
        .accessibilityLabel("Download audio")
    }
}
