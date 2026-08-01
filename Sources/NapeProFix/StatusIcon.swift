import AppKit

/// The menu bar icon: the device silhouette with its ball.
///
/// Drawn rather than taken from SF Symbols because none of them read as a
/// trackball. It is a template image, so the menu bar tints it for light and
/// dark automatically.
enum StatusIcon {
    private static let size = NSSize(width: 22, height: 14)
    private static let housingHeight: CGFloat = 7
    private static let ballDiameter: CGFloat = 11
    private static let lineWidth: CGFloat = 1.0

    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // A flat housing, deliberately shorter than the ball. Square
            // corners, so the path is a plain rect rather than a rounded one.
            let body = NSRect(
                x: lineWidth / 2 + 0.5,
                y: rect.midY - housingHeight / 2,
                width: rect.width - lineWidth - 1,
                height: housingHeight)
            let housing = NSBezierPath(rect: body)
            housing.lineWidth = lineWidth
            housing.stroke()

            // Filled last, so it covers the outline it crosses and reads as
            // sitting proud of the housing rather than behind it.
            let ball = NSRect(
                x: rect.midX - ballDiameter / 2,
                y: rect.midY - ballDiameter / 2,
                width: ballDiameter,
                height: ballDiameter)
            NSBezierPath(ovalIn: ball).fill()

            return true
        }
        image.isTemplate = true
        return image
    }
}
