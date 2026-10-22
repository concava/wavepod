import SwiftUI

/// The sidebar: wordmark, sections, recent episodes and the setup checklist. Collapses to an icon rail.
struct SidebarView: View {
    @Bindable var model: AppModel
    /// The player bar's height while it shows. Settings then sits on the player's centre line.
    var footerHeight: CGFloat? = nil
    @Environment(\.typography) private var type

    private var collapsed: Bool { model.sidebarCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(compact: collapsed)
                .padding(.horizontal, collapsed ? 0 : 14)
                .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
                .padding(.top, 4)
                .padding(.bottom, 18)

            VStack(spacing: 2) {
                ForEach(AppModel.Section.sidebar) { section in
                    NavRow(title: section.title, symbol: section.symbol, collapsed: collapsed,
                           isSelected: model.section == section) {
                        model.section = section
                    }
                }
            }

            if !collapsed && !model.savedEpisodes.isEmpty {
                Text("PODCAST EPISODES")
                    .font(type.eyebrow).tracking(1.1)
                    .foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, 12)
                    .padding(.top, 22)
                    .padding(.bottom, 6)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(model.savedEpisodes.prefix(8)) { record in
                            RecentRow(title: record.episode.title, show: record.episode.showName,
                                      isSelected: model.section == .library && model.episode.id == record.id) {
                                model.open(record)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }

            Spacer(minLength: 12)

            if !collapsed && model.isPersistent && !model.hideSetup {
                SetupCard(model: model)
                    .padding(.bottom, 12)
            }

            // Next to the player bar the row lines up with the player instead, so no divider.
            if footerHeight == nil { Divider().overlay(Palette.rule).padding(.bottom, 8) }
            NavRow(title: "Settings", symbol: "gearshape", collapsed: collapsed, isSelected: false, badge: activeJobs) {
                model.openSettings(activeJobs == nil ? nil : .queue)
            }
            .frame(height: footerHeight, alignment: .center)
        }
        .padding(.horizontal, collapsed ? 8 : 12)
        .padding(.bottom, footerHeight == nil ? 12 : 8)
        .frame(width: collapsed ? 60 : 236)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Transcriptions waiting or running, shown on Settings because the queue lives there.
    private var activeJobs: String? {
        let active = model.jobs.filter { $0.state == .running || $0.state == .queued }.count
        return active > 0 ? String(active) : nil
    }
}

struct Wordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            WaveShape()
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 26, height: 20)
            if !compact {
                Text("Wavepod")
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Wavepod")
    }
}

struct NavRow: View {
    let title: String
    let symbol: String
    var collapsed = false
    var isSelected: Bool
    var badge: String?
    var muted = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.typography) private var type

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                    .overlay(alignment: .topTrailing) {
                        if collapsed, badge != nil {
                            Circle().fill(Palette.accent).frame(width: 7, height: 7).offset(x: 3, y: -2)
                        }
                    }
                if !collapsed {
                    Text(title).font(muted ? type.callout : type.nav).lineLimit(1)
                    Spacer(minLength: 0)
                    if let badge {
                        Text(badge)
                            .font(type.caption.weight(.semibold))
                            .foregroundStyle(Palette.onAccent)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Palette.accent, in: Capsule())
                    }
                }
            }
            .foregroundStyle(muted ? Palette.inkMuted : Palette.ink)
            .padding(.horizontal, collapsed ? 0 : 10)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .frame(height: collapsed ? 40 : 36)
            .background(isSelected ? Palette.selection : (hovering ? Palette.selection.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? title : "")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct RecentRow: View {
    let title: String
    let show: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.typography) private var type

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(type.callout).foregroundStyle(Palette.ink).lineLimit(1)
                Text(show).font(type.caption).foregroundStyle(Palette.inkMuted).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Palette.selection : (hovering ? Palette.selection.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// First-run checklist. Each step is done when the library shows it, so it needs no separate bookkeeping.
struct SetupCard: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    struct Step: Identifiable {
        let id: String
        let title: String
        let done: Bool
        let action: () -> Void
    }

    var steps: [Step] {
        [
            Step(id: "models", title: "Install transcription models", done: model.installedModels.contains("parakeet")) {
                model.openSettings(.transcription)
            },
            Step(id: "episode", title: "Transcribe a first episode", done: !model.savedEpisodes.isEmpty) {
                model.focusRequest = .command
            },
            Step(id: "speaker", title: "Name a speaker", done: model.hasNamedSpeaker || model.namedVoices > 0) {
                // Speaker names are edited from their labels in the transcript.
                if let first = model.savedEpisodes.first { model.open(first) }
                model.sidePane = .transcript
                model.showSidePane = true
            },
            Step(id: "show", title: "Follow a podcast", done: !model.subscriptions.isEmpty) {
                model.section = .shows
            },
            Step(id: "ask", title: "Set up answers", done: model.canWriteSummary) {
                model.openSettings(.ask)
            },
        ]
    }

    var body: some View {
        let steps = steps
        let done = steps.filter(\.done).count
        if done < steps.count {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Set up Wavepod").font(type.label).foregroundStyle(Palette.ink)
                    Spacer()
                    Button { model.hideSetup = true } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Palette.inkMuted)
                        .help("Hide the checklist")
                        .accessibilityLabel("Hide the setup checklist")
                }
                ProgressView(value: Double(done), total: Double(steps.count))
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
                    .accessibilityLabel("\(done) of \(steps.count) steps done")
                ForEach(steps) { step in
                    Button(action: step.action) {
                        HStack(spacing: 9) {
                            Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15))
                                .foregroundStyle(step.done ? Palette.accent : Palette.inkMuted)
                            Text(step.title)
                                .font(type.callout)
                                .strikethrough(step.done)
                                .foregroundStyle(step.done ? Palette.inkMuted : Palette.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(step.done)
                    .accessibilityValue(step.done ? "Done" : "Not done")
                }
            }
            .padding(14)
            .elevated(cornerRadius: 12)
        }
    }
}
