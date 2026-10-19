import SwiftUI
import UI

@main
struct WavepodApp: App {
    @State private var model = AppModel(persistent: true)

    var body: some Scene {
        Window("wavepod", id: "main") {
            RootView(model: model)
                .frame(minWidth: 1080, minHeight: 640)
                .onOpenURL { url in
                    if url.isFileURL { model.importFile(url) }
                    else { model.commandText = url.absoluteString; model.submitCommand() }
                }
        }
        .defaultSize(width: 1440, height: 880)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { WavepodCommands(model: model) }
    }
}
