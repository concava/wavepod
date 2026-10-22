import Library
import Player
import SwiftUI

struct PlayerBar: View {
    @Bindable var player: PlayerModel
    @State private var showVolume = false
    @Environment(\.typography) private var type

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                HStack(spacing: 10) {
                    ArtworkView(hue: player.episode?.artworkHue ?? 0.15, url: player.episode?.artworkURL, cornerRadius: 6)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.episode?.showName ?? "wavepod")
                            .font(type.caption)
                            .foregroundStyle(Palette.inkMuted)
                        Text(player.episode?.title ?? "Choose an episode to play")
                            .font(type.callout.weight(.medium))
                            .foregroundStyle(Palette.ink)
                    }
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)

                HStack(spacing: 14) {
                    Button { player.skip(by: -PlayerModel.skipInterval) } label: {
                        Image(systemName: "gobackward.15").font(.system(size: 17))
                    }
                    .accessibilityLabel("Back 15 seconds")
                    Button { player.togglePlayback() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .contentTransition(.symbolEffect(.replace))
                            // The triangle's visual mass sits left of its box; nudge it toward the point.
                            .offset(x: player.isPlaying ? 0 : 1.5)
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 36, height: 36)
                            .background(Palette.ink, in: Circle())
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.skip(by: PlayerModel.skipInterval) } label: {
                        Image(systemName: "goforward.15").font(.system(size: 17))
                    }
                    .accessibilityLabel("Forward 15 seconds")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.ink)

                HStack(spacing: 12) {
                    Button { player.cycleRate() } label: {
                        Text(rateLabel)
                            .font(type.label.monospacedDigit())
                            .frame(minWidth: 38)
                    }
                    .buttonStyle(.plain)
                    .help("Playback speed")
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(rateLabel)
                    Button { showVolume.toggle() } label: {
                        Image(systemName: volumeSymbol).font(.system(size: 14))
                            .frame(width: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Volume")
                    .popover(isPresented: $showVolume, arrowEdge: .top) {
                        Slider(value: $player.volume, in: 0...1)
                            .frame(width: 140)
                            .padding(12)
                            .accessibilityLabel("Volume")
                    }
                }
                .foregroundStyle(Palette.ink)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Text(Timecode.format(player.currentTime))
                    .accessibilityHidden(true)
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 1))
                    .controlSize(.mini)
                    .accessibilityLabel("Position")
                    .accessibilityValue("\(Timecode.spoken(player.currentTime)) of \(Timecode.spoken(player.duration))")
                Text("-" + Timecode.format(player.duration - player.currentTime))
                    .accessibilityHidden(true)
            }
            .font(type.timestamp)
            .monospacedDigit()
            .foregroundStyle(Palette.inkMuted)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Palette.surface)
        .overlay(alignment: .top) { Divider().overlay(Palette.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player")
    }

    private var rateLabel: String {
        player.rate == player.rate.rounded() ? "\(Int(player.rate))×" : "\(player.rate.formatted())×"
    }

    private var volumeSymbol: String {
        switch player.volume {
        case 0: "speaker.slash"
        case ..<0.34: "speaker.wave.1"
        case ..<0.67: "speaker.wave.2"
        default: "speaker.wave.3"
        }
    }
}
