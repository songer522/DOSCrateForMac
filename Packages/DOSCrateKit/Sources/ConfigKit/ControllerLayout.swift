public enum ControllerLayout: String, Sendable, CaseIterable {
    case standard
    case steam
    case xboxUSB

    public func binding(_ c: LogicalControl) -> String {
        switch (self, c) {
        case (.standard, .a), (.xboxUSB, .a): "stick_0 button 0"
        case (.standard, .b), (.xboxUSB, .b): "stick_0 button 1"
        case (.standard, .x): "stick_0 button 2"
        case (.standard, .y): "stick_0 button 3"
        case (.standard, .start): "stick_0 button 6"
        case (.standard, .dpadUp), (.xboxUSB, .dpadUp): "stick_0 button 11"
        case (.standard, .dpadDown): "stick_0 button 12"
        case (.standard, .dpadLeft): "stick_0 button 13"
        case (.standard, .dpadRight): "stick_0 button 14"
        case (.steam, .a): "stick_0 button 4"
        case (.steam, .b): "stick_0 button 5"
        case (.steam, .x): "stick_0 button 9"
        case (.steam, .y): "stick_0 button 10"
        case (.steam, .start): "stick_0 button 7"
        case (.steam, .dpadUp): "stick_0 button 14"
        case (.steam, .dpadDown): "stick_0 button 11"
        case (.steam, .dpadLeft): "stick_0 button 12"
        case (.steam, .dpadRight): "stick_0 button 13"
        case (.xboxUSB, .x): "stick_0 button 6"
        case (.xboxUSB, .y): "stick_0 button 7"
        case (.xboxUSB, .start): "stick_0 button 3"
        case (.xboxUSB, .dpadDown): "stick_0 button 8"
        case (.xboxUSB, .dpadLeft): "stick_0 button 9"
        case (.xboxUSB, .dpadRight): "stick_0 button 10"
        case (_, .stickLeft): "stick_0 axis 0 0"
        case (_, .stickRight): "stick_0 axis 0 1"
        case (.standard, .stickUp): "stick_0 axis 1 0"
        case (.standard, .stickDown): "stick_0 axis 1 1"
        case (.steam, .stickUp), (.xboxUSB, .stickUp): "stick_0 axis 1 1"
        case (.steam, .stickDown), (.xboxUSB, .stickDown): "stick_0 axis 1 0"
        }
    }
}

public enum LogicalControl: Sendable, CaseIterable {
    case a, b, x, y, start
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case stickUp, stickDown, stickLeft, stickRight
}
