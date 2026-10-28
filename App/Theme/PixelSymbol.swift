import AppKit
import SwiftUI

struct PixelSymbol: View {
    let systemName: String
    let color: Color
    let pointSize: CGFloat
    let scale: Int

    init(_ systemName: String, color: Color, pointSize: CGFloat = 16, scale: Int = 2) {
        self.systemName = systemName
        self.color = color
        self.pointSize = pointSize
        self.scale = scale
    }

    var body: some View {
        let displaySize = pointSize * CGFloat(max(scale, 1))
        if let nsImage = Self.render(systemName, color: NSColor(color), pointSize: pointSize) {
            Image(nsImage: nsImage)
                .interpolation(.none)
                .resizable()
                .frame(width: displaySize, height: displaySize)
        }
    }

    static func render(_ systemName: String, color: NSColor, pointSize: CGFloat) -> NSImage? {
        guard let base = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize * 0.75, weight: .bold)
        let symbol = base.withSymbolConfiguration(config) ?? base
        let side = max(1, Int(pointSize.rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = NSSize(width: CGFloat(side), height: CGFloat(side))
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .none
            let srcSize = symbol.size
            let scaleFactor = min(CGFloat(side) / max(srcSize.width, 1), CGFloat(side) / max(srcSize.height, 1))
            let drawW = srcSize.width * scaleFactor
            let drawH = srcSize.height * scaleFactor
            let rect = NSRect(
                x: (CGFloat(side) - drawW) / 2,
                y: (CGFloat(side) - drawH) / 2,
                width: drawW,
                height: drawH
            )
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            color.set()
            rect.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: NSSize(width: CGFloat(side), height: CGFloat(side)))
        out.addRepresentation(rep)
        return out
    }
}
