import AppKit

/// The menu bar icon: the device silhouette with its ball, and the active
/// layer number at its left end.
///
/// Drawn rather than taken from SF Symbols because none of them read as a
/// trackball. It is a template image, so the menu bar tints it for light and
/// dark automatically. The number is drawn into the same image rather than
/// put in the button's title, because the title is already the battery level
/// on the right.
enum StatusIcon {
    private static let size = NSSize(width: 22, height: 14)
    private static let layerGap: CGFloat = 2
    /// The layer badge: a digit in a ring, like ①. Drawn rather than typed as
    /// the Unicode circled digits, which fall back to a CJK font whose ring
    /// weight and size do not match the line work of the icon.
    private static let badgeDiameter: CGFloat = 13
    private static let badgeFontSize: CGFloat = 9
    private static let housingHeight: CGFloat = 7
    private static let ballDiameter: CGFloat = 11
    private static let lineWidth: CGFloat = 1.0

    static func make(layer: Int? = nil) -> NSImage {
        let labelWidth = layer == nil ? 0 : badgeDiameter + layerGap
        let total = NSSize(width: labelWidth + size.width, height: size.height)

        let image = NSImage(size: total, flipped: false) { full in
            if let layer { drawBadge(layer, centeredAt: NSPoint(x: badgeDiameter / 2, y: full.midY)) }
            let rect = NSRect(x: labelWidth, y: 0, width: size.width, height: size.height)
            NSColor.black.setStroke()
            NSColor.black.setFill()

            // A flat housing, deliberately shorter than the ball. Square
            // corners, so the path is a plain rect rather than a rounded one.
            let body = NSRect(
                x: rect.minX + lineWidth / 2 + 0.5,
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

    private static func drawBadge(_ number: Int, centeredAt center: NSPoint) {
        let inset = lineWidth / 2
        let ring = NSBezierPath(ovalIn: NSRect(
            x: center.x - badgeDiameter / 2 + inset,
            y: center.y - badgeDiameter / 2 + inset,
            width: badgeDiameter - lineWidth,
            height: badgeDiameter - lineWidth))
        ring.lineWidth = lineWidth
        ring.stroke()

        let font = NSFont.monospacedDigitSystemFont(ofSize: badgeFontSize, weight: .semibold)
        let digit = NSAttributedString(string: "\(number)", attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
        ])
        // Centre on the digit's ink, not its line box: lining digits are cap
        // height tall and sit on the baseline, and draw(at:) places the bottom
        // of the descender.
        let baseline = center.y - font.capHeight / 2
        digit.draw(at: NSPoint(
            x: center.x - digit.size().width / 2,
            y: baseline + font.descender))
    }
}
