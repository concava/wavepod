import Library
import SwiftUI

struct MessageView: View {
    let message: ChatMessage
    let onSeek: (Double) -> Void
    @Environment(\.typography) private var type

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(message.text)
                    .font(type.body)
                    .foregroundStyle(Palette.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You asked: \(message.text)")
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                Text(message.text)
                    .font(type.body)
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(message.citations, id: \.self) { citation in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TimestampPill(time: citation.start) { onSeek(citation.start) }
                        Text("“\(citation.quote)”")
                            .font(type.callout.italic())
                            .foregroundStyle(Palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }
}
