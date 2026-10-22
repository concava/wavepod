import Library
import Pipeline
import SwiftUI

/// The start page: a greeting, the quick ways in, what is being transcribed, and the library by date.
struct HomeView: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
    }

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 26) {
                    greeting
                    StartCard(model: model)
                    activity
                    library
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                StatsCard(model: model)
                    .frame(width: 270)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
    }

    private var greeting: some View {
        HStack(spacing: 8) {
            Text(firstName.isEmpty ? "Paste a podcast link with" : "Hey \(firstName), paste a podcast link with")
                .font(type.display)
                .foregroundStyle(Palette.ink)
            Text("⌘K")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Palette.key, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Palette.keyEdge, lineWidth: 1.5))
                .accessibilityLabel("Command K")
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var activity: some View {
        let active = model.jobs.filter { $0.state != .completed && $0.state != .cancelled }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("IN PROGRESS")
                VStack(spacing: 0) {
                    ForEach(active) { job in
                        FeedRow(leading: job.state == .running ? "\(Int(job.fraction * 100)) %" : job.state.rawValue.capitalized,
                                title: job.episode.title,
                                detail: job.batteryPaused ? "Paused to save battery" : job.stage,
                                progress: job.state == .running ? job.fraction : nil,
                                isLast: job.id == active.last?.id) {
                            model.openSettings(.queue)
                        }
                    }
                }
                .feedCard()
            }
        }
    }

    @ViewBuilder private var library: some View {
        if model.savedEpisodes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("YOUR LIBRARY")
                VStack(spacing: 6) {
                    Image(systemName: "text.quote").font(.system(size: 22)).foregroundStyle(Palette.inkMuted)
                    Text("Transcripts appear here").font(type.body.weight(.medium)).foregroundStyle(Palette.ink)
                    Text("Paste a Spotify, Apple Podcasts, YouTube or RSS link, or drop an audio file on the window.")
                        .font(type.callout).foregroundStyle(Palette.inkMuted)
                }
                .padding(28)
                .frame(maxWidth: .infinity)
                .feedCard()
            }
        } else {
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(group.day.formatted(.dateTime.month(.wide).day().year()).uppercased())
                    VStack(spacing: 0) {
                        ForEach(group.items) { item in
                            FeedRow(leading: Timecode.format(item.episode.duration), title: item.episode.title,
                                    detail: [item.episode.showName, model.episodeStatus(item.id)].filter { !$0.isEmpty }.joined(separator: " · "), isLast: item.id == group.items.last?.id) {
                                model.open(item)
                            }
                        }
                    }
                    .feedCard()
                }
            }
        }
    }

    private var groups: [(day: Date, items: [EpisodeListing])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.savedEpisodes) { calendar.startOfDay(for: $0.episode.pubDate) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0]!) }
    }
}

/// The two ways to start, as one wide card.
struct StartCard: View {
    let model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Every episode, searchable and quotable")
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .foregroundStyle(.white)
                Text("Wavepod transcribes on this Mac and names the speakers. Ask questions and go to the moment that answers them.")
                    .font(type.body)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { model.focusRequest = .command } label: { Label("Paste a Link", systemImage: "link") }
                        .buttonStyle(LightButtonStyle())
                    Button(action: model.chooseFile) { Label("Add Audio File", systemImage: "waveform") }
                        .buttonStyle(LightButtonStyle(subtle: true))
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
            WaveShape()
                .stroke(.white.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 180, height: 90)
                .accessibilityHidden(true)
        }
        .padding(28)
        .background(
            LinearGradient(colors: [Color(hex: 0x0F5E63), Color(hex: 0x123B47), Color(hex: 0x3A2A1E)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StatsCard: View {
    let model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        let hours = model.savedEpisodes.reduce(0) { $0 + $1.episode.duration } / 3600
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                stat(String(model.savedEpisodes.count), "episodes")
                if hours < 1 {
                    stat(String(Int((hours * 60).rounded())), "minutes transcribed")
                } else {
                    stat(hours < 10 ? String(format: "%.1f", hours) : String(Int(hours)), "hours transcribed")
                }
                stat(String(model.namedVoices), model.namedVoices == 1 ? "voice named" : "voices named")
                stat(String(model.subscriptions.count), model.subscriptions.count == 1 ? "podcast followed" : "podcasts followed")
            }
            .padding(22)
            Divider().overlay(Palette.rule)
            VStack(alignment: .leading, spacing: 6) {
                Label("Privacy", systemImage: "lock").font(type.body.weight(.medium)).foregroundStyle(Palette.ink)
                Text(model.askProvider == "local" ? "Audio, transcripts and answers stay on this Mac."
                     : "Audio stays on this Mac. Questions and transcript text go to your \((AppModel.AskProvider(rawValue: model.askProvider) ?? .local).shortTitle) plan when you ask or a summary is written.")
                    .font(type.callout).foregroundStyle(Palette.inkMuted).fixedSize(horizontal: false, vertical: true)
                Button("See the network log") { model.openSettings(.privacy) }
                    .buttonStyle(.link).font(type.callout)
            }
            .padding(22)
        }
        .feedCard()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(type.stat).foregroundStyle(Palette.ink)
            Text(label).font(type.body).foregroundStyle(Palette.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

struct FeedRow: View {
    let leading: String
    let title: String
    let detail: String
    var progress: Double?
    var isLast = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.typography) private var type

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 20) {
                    Text(leading)
                        .font(type.callout).monospacedDigit()
                        .foregroundStyle(Palette.inkMuted)
                        .frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(type.body.weight(.medium)).foregroundStyle(Palette.ink).lineLimit(1)
                        Text(detail).font(type.callout).foregroundStyle(Palette.inkMuted).lineLimit(1)
                        if let progress {
                            ProgressView(value: progress).tint(Palette.accent).padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.inkMuted).opacity(hovering ? 1 : 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                if !isLast { Divider().overlay(Palette.rule) }
            }
            .background(hovering ? Palette.sunken : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    @Environment(\.typography) private var type
    var body: some View {
        Text(text).font(type.eyebrow).tracking(1.3).foregroundStyle(Palette.inkMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

struct LightButtonStyle: ButtonStyle {
    var subtle = false
    @Environment(\.typography) private var type
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(type.label)
            .foregroundStyle(subtle ? .white : Color(hex: 0x1C1B19))
            .padding(.horizontal, 16)
            .frame(minHeight: 34)
            .background(subtle ? .white.opacity(configuration.isPressed ? 0.25 : 0.15) : Color(hex: 0xF7F4EE).opacity(configuration.isPressed ? 0.85 : 1),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
            .pressScale(configuration.isPressed)
    }
}

extension View {
    /// The rounded, bordered card the home feed and stats sit in.
    func feedCard() -> some View {
        elevated(cornerRadius: 14)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}
