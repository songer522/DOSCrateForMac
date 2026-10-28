import SwiftUI

struct RetroButtonStyle: ButtonStyle {
    enum Kind: Sendable {
        case icon
        case text
    }

    var kind: Kind = .text
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RetroFont.font())
            .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
            .padding(.horizontal, kind == .icon ? 10 : 8)
            .padding(.vertical, kind == .icon ? 6 : 4)
            .background(RetroPalette.panel)
            .retroBevel(configuration.isPressed && isEnabled ? .sunken : .raised)
    }
}
