import SwiftUI

struct RetroButtonStyle: ButtonStyle {
    enum Kind: Sendable {
        case icon
        case text
    }

    var kind: Kind = .text
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let sunken = (configuration.isPressed && isEnabled) || isSelected
        let fg: Color = if !isEnabled {
            RetroPalette.bevelDark
        } else if isSelected {
            RetroPalette.highlightText
        } else {
            RetroPalette.shadow
        }
        return configuration.label
            .font(RetroFont.font())
            .foregroundStyle(fg)
            .padding(.horizontal, kind == .icon ? 10 : 8)
            .padding(.vertical, kind == .icon ? 6 : 4)
            .background(isSelected ? RetroPalette.highlight : RetroPalette.panel)
            .retroBevel(sunken ? .sunken : .raised)
    }
}
