import AppKit
import SwiftUI

enum RetroPalette {
    static let desktop = rgb(0x00, 0x00, 0xAA)
    static let panel = rgb(0xC0, 0xC0, 0xC0)
    static let bevelLight = rgb(0xFF, 0xFF, 0xFF)
    static let bevelDark = rgb(0x80, 0x80, 0x80)
    static let secondaryText = rgb(0x40, 0x40, 0x40)
    static let shadow = rgb(0x00, 0x00, 0x00)
    static let highlight = rgb(0x00, 0x00, 0xAA)
    static let highlightText = rgb(0xFF, 0xFF, 0xFF)
    static let green = rgb(0x00, 0xAA, 0x00)
    static let red = rgb(0xAA, 0x00, 0x00)
    static let yellow = rgb(0xFF, 0xFF, 0x55)
    static let cyan = rgb(0x55, 0xFF, 0xFF)

    private static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Color {
        Color(.sRGB, red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0, opacity: 1.0)
    }

    static func hex(_ color: Color) -> String {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((srgb.redComponent * 255.0).rounded())
        let g = Int((srgb.greenComponent * 255.0).rounded())
        let b = Int((srgb.blueComponent * 255.0).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
