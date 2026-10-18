import Library
import Player
import SwiftUI

/// The single window: collapsible sidebar, top bar with the command field, three resizable panes and the player bar.
public struct RootView: View {
    @Bindable var model: AppModel
    @FocusState private var focus: AppModel.FocusTarget?

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let notice = model.notice {
                    NoticeBar(text: notice)
                }
                Group {
                    if model.section == .library {
                        Workspace(model: model, focus: $focus)
                    } else {
                        SectionPlaceholder(section: model.section)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                PlayerBar(model: model, player: model.player)
            }
            .background(Palette.paper)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    CommandField(model: model, focus: $focus)
                }
                ToolbarItem(placement: .primaryAction) {
                    AppearanceButton(model: model)
                }
            }
        }
        .environment(\.typography, Typography(scale: model.textScale))
        .preferredColorScheme(model.appearance == .system ? nil : (model.appearance == .dark ? .dark : .light))
        .tint(Palette.accent)
        .onChange(of: model.focusRequest) { _, request in
            guard let request else { return }
            if request != .transcript { model.section = .library }
            focus = request
            model.focusRequest = nil
        }
    }
}

struct Workspace: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding

    var body: some View {
        HSplitView {
            EpisodePane(model: model)
                .padding(6)
                .frame(minWidth: 230, idealWidth: 290, maxWidth: 380)
            CenterPane(model: model, focus: focus)
                .padding(6)
                .frame(minWidth: 380, idealWidth: 560)
            AskPane(model: model, focus: focus)
                .padding(6)
                .frame(minWidth: 250, idealWidth: 310, maxWidth: 440)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

struct CommandField: View {
    @Bindable var model: AppModel
    var focus: FocusState<AppModel.FocusTarget?>.Binding
    @Environment(\.typography) private var type

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Palette.inkMuted)
                .accessibilityHidden(true)
            TextField("Search or paste a podcast, Spotify or YouTube link", text: $model.commandText)
                .textFieldStyle(.plain)
                .font(type.body)
                .focused(focus, equals: .command)
                .onSubmit { model.submitCommand() }
                .accessibilityLabel("Search or open a link")
            Text("⌘K")
                .font(type.caption)
                .foregroundStyle(Palette.inkMuted)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(width: 440, height: 28)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.rule))
    }
}

struct AppearanceButton: View {
    let model: AppModel

    var body: some View {
        Button {
            model.cycleAppearance()
        } label: {
            Image(systemName: symbol)
        }
        .help("Appearance: \(model.appearance.rawValue.capitalized)")
        .accessibilityLabel("Appearance")
        .accessibilityValue(model.appearance.rawValue.capitalized)
    }

    var symbol: String {
        switch model.appearance {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

struct NoticeBar: View {
    let text: String
    @Environment(\.typography) private var type

    var body: some View {
        Text(text)
            .font(type.callout)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Palette.accentSoft)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

struct SectionPlaceholder: View {
    let section: AppModel.Section

    var body: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.symbol)
        } description: {
            Text(description)
        }
    }

    var description: String {
        switch section {
        case .library: ""
        case .shows: "Subscriptions with automatic transcription arrive in Phase 5."
        case .queue: "The transcription queue with progress, pause and resume arrives in Phase 3."
        case .search: "Keyword and meaning search across every episode arrives in Phase 5."
        case .settings: "Engines, models, storage and the network log arrive with the pipeline."
        }
    }
}
