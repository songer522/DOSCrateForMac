import SwiftUI

enum RetroBevelStyle: Equatable, Sendable {
    case raised
    case sunken

    var topLeft: Color {
        switch self {
        case .raised: RetroPalette.bevelLight
        case .sunken: RetroPalette.bevelDark
        }
    }

    var bottomRight: Color {
        switch self {
        case .raised: RetroPalette.bevelDark
        case .sunken: RetroPalette.bevelLight
        }
    }
}

private struct RetroBevelModifier: ViewModifier {
    let style: RetroBevelStyle
    let width: CGFloat

    nonisolated init(style: RetroBevelStyle, width: CGFloat) {
        self.style = style
        self.width = width
    }

    func body(content: Content) -> some View {
        content
            .padding(width)
            .overlay {
                Canvas { context, size in
                    let w = width
                    var topLeftPath = Path()
                    // Top edge
                    topLeftPath.addRect(CGRect(x: 0, y: 0, width: size.width - w, height: w))
                    // Left edge
                    topLeftPath.addRect(CGRect(x: 0, y: w, width: w, height: size.height - w))
                    context.fill(topLeftPath, with: .color(style.topLeft))

                    var bottomRightPath = Path()
                    // Bottom edge
                    bottomRightPath.addRect(CGRect(x: w, y: size.height - w, width: size.width - w, height: w))
                    // Right edge
                    bottomRightPath.addRect(CGRect(x: size.width - w, y: 0, width: w, height: size.height - w))
                    context.fill(bottomRightPath, with: .color(style.bottomRight))
                }
                .allowsHitTesting(false)
            }
    }
}

extension View {
    nonisolated func retroBevel(_ style: RetroBevelStyle = .raised, width: CGFloat = 2) -> some View {
        modifier(RetroBevelModifier(style: style, width: width))
    }
}
