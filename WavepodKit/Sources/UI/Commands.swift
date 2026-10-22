import Player
import SwiftUI

/// Menu bar commands. Every action in the window is reachable from the keyboard; these are the shortcuts.
public struct WavepodCommands: Commands {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Welcome to Wavepod") { model.showSettings = false; model.showOnboarding = true }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Audio or Video…", action: model.chooseFile).keyboardShortcut("o")
        }
        CommandGroup(after: .textEditing) {
            Button("Search or Open Link…") { model.focusRequest = .command }
                .keyboardShortcut("k")
            Button("Ask This Episode") { model.focusRequest = .ask }
                .keyboardShortcut("j")
        }
        CommandGroup(after: .sidebar) {
            Button("Transcript") { model.section = .library; model.toggleSidePane(.transcript) }
                .keyboardShortcut("1")
            Button("About This Episode") { model.section = .library; model.toggleSidePane(.about) }
                .keyboardShortcut("2")
            Divider()
            Button("Bigger Text") { model.adjustTextSize(by: 1) }
                .keyboardShortcut("+")
            Button("Smaller Text") { model.adjustTextSize(by: -1) }
                .keyboardShortcut("-")
            Button("Actual Size") { model.textScale = 1 }
                .keyboardShortcut("0")
            Divider()
            Button("Toggle Appearance") { model.cycleAppearance() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }
        CommandMenu("Playback") {
            Button(model.player.isPlaying ? "Pause" : "Play") { model.player.togglePlayback() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Back 15 Seconds") { model.player.skip(by: -PlayerModel.skipInterval) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Forward 15 Seconds") { model.player.skip(by: PlayerModel.skipInterval) }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Divider()
            Button("Faster") { model.player.cycleRate() }
                .keyboardShortcut("]")
            Button("Normal Speed") { model.player.rate = 1 }
                .keyboardShortcut("\\")
            Divider()
            Button("Follow Playback") { model.followPlayback.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
    }
}
