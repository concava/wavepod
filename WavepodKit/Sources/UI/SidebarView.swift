import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.typography) private var type

    var body: some View {
        List(selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) {
            ForEach(AppModel.Section.allCases) { section in
                Label(section.title, systemImage: section.symbol)
                    .font(type.body)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                WaveShape()
                    .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 26, height: 18)
                Text("wavepod")
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("wavepod")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Label("On this Mac only", systemImage: "lock")
                .font(type.caption)
                .foregroundStyle(Palette.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .help("Transcription, search and answers run on this Mac. The network log lists every request.")
        }
    }
}
