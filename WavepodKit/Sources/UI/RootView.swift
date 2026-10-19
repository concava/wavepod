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
                        LibrarySection(model: model)
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
                    if model.isPersistent {
                        Button("Open Audio…", systemImage: "plus", action: model.chooseFile)
                            .help("Open an audio or video file")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    AppearanceButton(model: model)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            for file in files { model.importFile(file) }
            return !files.isEmpty
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
