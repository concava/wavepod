import Library
import SwiftUI

/// The About side pane: show, date, length, download, source link and the feed's description.
struct EpisodeAbout: View {
    let model: AppModel
    @Environment(\.typography) private var type
    @Environment(\.openURL) private var openURL

    private var episode: Episode { model.episode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(episode.showName, systemImage: "headphones")
                    .font(type.label)
                    .foregroundStyle(Palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Palette.accentSoft, in: Capsule())
                    .accessibilityLabel("Show: \(episode.showName)")

                HStack(spacing: 14) {
                    Label(episode.pubDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    Label(Timecode.format(episode.duration), systemImage: "clock")
                        .accessibilityLabel("Duration \(Timecode.spoken(episode.duration))")
                }
                .font(type.callout)
                .foregroundStyle(Palette.inkMuted)
                .labelStyle(.titleAndIcon)

                HStack(spacing: 8) {
                    Button {
                        if let url = episode.sourceURL { openURL(url) }
                    } label: {
                        Label("Open in \(episode.sourceName)", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(episode.sourceURL == nil)
                    Button(action: model.downloadAudio) {
                        Label("Download", systemImage: "arrow.down")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel("Download audio")
                }

                Text(SafeHTML.render(episode.descriptionHTML))
                    .font(type.callout)
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Episode description")
                    .accessibilityValue(String(SafeHTML.render(episode.descriptionHTML).characters))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("About this episode")
    }
}
