import Library
import SwiftUI

struct EpisodePane: View {
    let model: AppModel
    @Environment(\.typography) private var type
    @Environment(\.openURL) private var openURL

    private var episode: Episode { model.episode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ArtworkView(hue: episode.artworkHue, cornerRadius: 12)
                    .frame(width: 148, height: 148)

                Label(episode.showName, systemImage: "headphones")
                    .font(type.label)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Palette.accentSoft, in: Capsule())
                    .accessibilityLabel("Show: \(episode.showName)")

                Text(episode.title)
                    .font(type.readingTitle)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { playButton; openButton }
                    VStack(alignment: .leading, spacing: 8) { playButton; openButton }
                }

                HStack(spacing: 14) {
                    Label(episode.pubDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    Label(Timecode.format(episode.duration), systemImage: "clock")
                        .accessibilityLabel("Duration \(Timecode.spoken(episode.duration))")
                    Button {
                        model.downloadAudio()
                    } label: {
                        Label("Download", systemImage: "arrow.down")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Download audio")
                }
                .font(type.callout)
                .foregroundStyle(Palette.inkMuted)
                .labelStyle(.titleAndIcon)

                Text(SafeHTML.render(episode.descriptionHTML))
                    .font(type.callout)
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityLabel("Episode description")
                    .accessibilityValue(String(SafeHTML.render(episode.descriptionHTML).characters))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pane()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Episode")
    }

    private var playButton: some View {
        Button {
            model.toggleEpisodePlayback()
        } label: {
            Label(model.isViewedEpisodePlaying ? "Pause" : "Play Episode",
                  systemImage: model.isViewedEpisodePlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(PrimaryButtonStyle())
    }

    private var openButton: some View {
        Button {
            if let url = episode.sourceURL { openURL(url) }
        } label: {
            Label("Open in \(episode.sourceName)", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(SecondaryButtonStyle())
        .disabled(episode.sourceURL == nil)
    }
}
