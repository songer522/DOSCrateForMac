public enum ControllerMap {
    private static let keyControls: [String: [LogicalControl]] = [
        "key_lctrl": [.a],
        "key_lalt": [.b],
        "key_space": [.x],
        "key_enter": [.y],
        "key_esc": [.start],
        "key_up": [.dpadUp, .stickUp],
        "key_down": [.dpadDown, .stickDown],
        "key_left": [.dpadLeft, .stickLeft],
        "key_right": [.dpadRight, .stickRight],
    ]

    public static func render(_ layout: ControllerLayout) -> String {
        ControllerTemplate.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let key = line.split(separator: " ").first,
                      let controls = keyControls[String(key)] else {
                    return String(line)
                }
                let extra = controls.map { " \"\(layout.binding($0))\"" }.joined()
                if line.hasSuffix(" ") {
                    return line.dropLast() + extra + " "
                }
                return String(line) + extra
            }
            .joined(separator: "\n")
    }
}
