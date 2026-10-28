import SwiftUI

struct RetroPanel<Content: View>: View {
    let title: String?
    private let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(RetroFont.font())
                    .foregroundStyle(RetroPalette.highlightText)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RetroPalette.highlight)
            }
            content
        }
        .background(RetroPalette.panel)
        .retroBevel(.raised)
    }
}
