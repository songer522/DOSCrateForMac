import LibraryKit

public enum ControllerMap {
    private static let directionalControls: [String: [LogicalControl]] = [
        "key_up": [.dpadUp, .stickUp],
        "key_down": [.dpadDown, .stickDown],
        "key_left": [.dpadLeft, .stickLeft],
        "key_right": [.dpadRight, .stickRight],
    ]

    private static let joystickButtonEvents: [ControllerButton: String] = [
        .a: "jbutton_0_0",
        .b: "jbutton_0_1",
        .x: "jbutton_0_2",
        .y: "jbutton_0_3",
        .leftTrigger: "jbutton_0_4",
        .rightTrigger: "jbutton_0_5",
    ]

    private static let joystickAxisControls: [String: [LogicalControl]] = [
        "jaxis_0_0-": [.stickLeft, .dpadLeft],
        "jaxis_0_0+": [.stickRight, .dpadRight],
        "jaxis_0_1-": [.stickUp, .dpadUp],
        "jaxis_0_1+": [.stickDown, .dpadDown],
    ]

    public static func render(
        _ layout: ControllerLayout,
        mode: ControllerMode = .keyboard,
        bindings: ControllerBindings = ControllerBindings()
    ) -> String {
        if mode.isJoystickEmulation {
            return renderJoystick(layout, bindings: bindings)
        }
        return renderKeyboard(layout, bindings: bindings)
    }

    private static func renderKeyboard(_ layout: ControllerLayout, bindings: ControllerBindings) -> String {
        var keyControls = directionalControls
        for button in ControllerButton.allCases {
            let resolvedKey = bindings[button] ?? button.defaultKeyboardKey
            if let key = resolvedKey, let event = key.mapperEvent {
                keyControls[event, default: []].append(LogicalControl(button: button))
            }
        }
        return ControllerTemplate.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let key = line.split(separator: " ").first,
                      let controls = keyControls[String(key)], !controls.isEmpty else {
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

    private static func renderJoystick(_ layout: ControllerLayout, bindings: ControllerBindings) -> String {
        var keyControls: [String: [LogicalControl]] = [:]
        var joyButtonControls: [String: LogicalControl] = [:]

        for button in ControllerButton.allCases {
            let control = LogicalControl(button: button)
            if let explicitKey = bindings[button] {
                if let event = explicitKey.mapperEvent {
                    keyControls[event, default: []].append(control)
                }
            } else if let joyEvent = joystickButtonEvents[button] {
                joyButtonControls[joyEvent] = control
            } else if let defaultKey = button.defaultKeyboardKey, let event = defaultKey.mapperEvent {
                keyControls[event, default: []].append(control)
            }
        }

        let managedJoyButtons = Set(joystickButtonEvents.values)

        return ControllerTemplate.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let eventSub = line.split(separator: " ").first else {
                    return String(line)
                }
                let event = String(eventSub)
                if let axisControls = joystickAxisControls[event] {
                    let bound = axisControls.map { "\"\(layout.binding($0))\"" }.joined(separator: " ")
                    return "\(event) \(bound) "
                }
                if managedJoyButtons.contains(event) {
                    if let control = joyButtonControls[event] {
                        return "\(event) \"\(layout.binding(control))\" "
                    }
                    return "\(event) "
                }
                if let controls = keyControls[event], !controls.isEmpty {
                    let extra = controls.map { " \"\(layout.binding($0))\"" }.joined()
                    if line.hasSuffix(" ") {
                        return line.dropLast() + extra + " "
                    }
                    return String(line) + extra
                }
                return String(line)
            }
            .joined(separator: "\n")
    }
}
