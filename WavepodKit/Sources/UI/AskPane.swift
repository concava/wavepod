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
            if let sections = message.sections {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            if !section.title.isEmpty { SectionHeading(section.title) }
                            ForEach(section.points) { point in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    TimestampPill(time: point.citation.start) { onSeek(point.citation.start) }
                                        .help("“\(point.citation.quote)”")
                                    Text(.init(point.text))
                                        .font(type.reading)
                                        .foregroundStyle(Palette.ink)
                                        .lineSpacing(5)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
            } else {
                plain
            }
        }
    }

    private var plain: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(.init(message.text))
                .font(type.reading)
                .foregroundStyle(Palette.ink)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(message.citations, id: \.self) { citation in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TimestampPill(time: citation.start) { onSeek(citation.start) }
                    Text("“\(citation.quote)”")
                        .font(type.reading.italic())
                        .foregroundStyle(Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
