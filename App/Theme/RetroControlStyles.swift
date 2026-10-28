import SwiftUI

extension EnvironmentValues {
    @Entry var retroTheme = false
}

struct RetroTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(RetroFont.font())
            .foregroundStyle(RetroPalette.shadow)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RetroPalette.bevelLight)
            .retroBevel(.sunken)
    }
}

struct RetroToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(configuration.isOn ? "X" : " ")
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
                    .frame(width: 16, height: 16)
                    .background(RetroPalette.bevelLight)
                    .retroBevel(.sunken)
                configuration.label
                    .font(RetroFont.font())
                    .foregroundStyle(isEnabled ? RetroPalette.shadow : RetroPalette.bevelDark)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func retroControls() -> some View {
        self
            .environment(\.retroTheme, true)
            .font(RetroFont.font())
            .foregroundStyle(RetroPalette.shadow)
            .buttonStyle(RetroButtonStyle())
            .toggleStyle(RetroToggleStyle())
            .textFieldStyle(RetroTextFieldStyle())
            .scrollContentBackground(.hidden)
            .background(RetroPalette.panel)
            .environment(\.colorScheme, .light)
    }
}
