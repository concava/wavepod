import SwiftUI

/// One choice in a `PreviewSelector`.
struct SelectorOption<ID: Hashable>: Identifiable {
    let id: ID
    var symbol: String?
    let title: String
    var subtitle: String?
    var isEnabled = true
}

/// A selector in a floating panel, like the model picker in Claude: each choice with an icon, a name and one line
/// about it, a check on the current one, and a preview of the choice under the pointer beside the list.
/// The arrow keys move through the choices, Return chooses and Escape closes.
struct PreviewSelector<ID: Hashable, Label: View, Preview: View>: View {
    let title: String
    let options: [SelectorOption<ID>]
    let selection: ID?
    let onSelect: (ID) -> Void
    var footer: [(title: String, action: () -> Void)] = []
    @ViewBuilder let label: () -> Label
    @ViewBuilder let preview: (ID) -> Preview

    @State private var isOpen = false
    @State private var highlighted: ID?
    @FocusState private var listFocused: Bool
    @Environment(\.typography) private var type

    var body: some View {
        Button { isOpen.toggle() } label: { label() }
            .buttonStyle(.plain)
            .popover(isPresented: $isOpen, arrowEdge: .bottom) { panel }
            .onChange(of: isOpen) { _, open in if open { highlighted = selection ?? options.first?.id } }
    }

    private var panel: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(type.eyebrow).tracking(1.1)
                    .foregroundStyle(Palette.inkMuted)
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 6)
                ForEach(options) { option in row(option) }
                if !footer.isEmpty {
                    Divider().overlay(Palette.rule).padding(.vertical, 6)
                    ForEach(footer.indices, id: \.self) { index in
                        Button {
                            isOpen = false
                            footer[index].action()
                        } label: {
                            Text(footer[index].title)
                                .font(type.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SelectorRowStyle())
                    }
                }
            }
            .padding(8)
            .frame(width: 260)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(.return) {
                if let highlighted { choose(highlighted) }
                return .handled
            }
            .onKeyPress(.escape) { isOpen = false; return .handled }

            Rectangle().fill(Palette.rule).frame(width: 1)

            Group {
                if let shown = highlighted ?? selection { preview(shown) }
            }
            .frame(width: 280, alignment: .topLeading)
            .padding(16)
        }
        .background(Palette.surface)
        .onAppear { listFocused = true }
    }

    private func row(_ option: SelectorOption<ID>) -> some View {
        let isSelected = option.id == selection
        let isHighlighted = option.id == highlighted
        return Button { choose(option.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .frame(width: 16)
                        .foregroundStyle(isSelected ? Palette.accent : Palette.inkMuted)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(type.body.weight(.medium)).foregroundStyle(Palette.ink)
                    if let subtitle = option.subtitle {
                        Text(subtitle).font(type.caption).foregroundStyle(Palette.inkMuted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.accent)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .opacity(option.isEnabled ? 1 : 0.45)
        .onHover { if $0 { highlighted = option.id } }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func move(_ step: Int) {
        let enabled = options.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        let current = enabled.firstIndex { $0.id == highlighted } ?? -1
        highlighted = enabled[(current + step + enabled.count) % enabled.count].id
    }

    private func choose(_ id: ID) {
        isOpen = false
        onSelect(id)
    }
}

/// A footer row in a selector: plain text with the hover fill of the choices.
private struct SelectorRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.ink)
            .background(hovering || configuration.isPressed ? Palette.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering = $0 }
    }
}
