import AppKit

/// Opens an image in its own resizable, zoomable window.
///
/// A sheet cannot be wider than the window it is attached to, so the settings
/// window's 640pt would shrink the screenshot back to unreadable. This is a
/// separate window sized to the screen instead.
@MainActor
enum ImageViewer {
    private static var window: NSWindow?

    static func show(_ image: NSImage, title: String) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let imageView = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently

        let scrollView = NSScrollView()
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        // Pinch to zoom, and ⌘+/⌘- via the menu-less magnification API.
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.2
        scrollView.maxMagnification = 4

        // Show one source pixel per physical pixel. A screenshot taken on a
        // Retina display carries 2x DPI metadata, so NSImage reports half the
        // pixel dimensions in points; drawn at magnification 1 on a non-Retina
        // screen it comes out at 50% and the text is illegible.
        let screen = NSScreen.main
        let pixelsWide = CGFloat(image.representations.first?.pixelsWide ?? 0)
        let scale = pixelsWide > 0 ? pixelsWide / image.size.width : 1
        let magnification = max(1, scale / (screen?.backingScaleFactor ?? 1))
        scrollView.magnification = magnification
        scrollView.maxMagnification = max(4, magnification * 2)

        // Open as large as the screen sensibly allows; the point is to read
        // the text in the screenshot.
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(image.size.width * magnification, visible.width * 0.9)
        let height = min(image.size.height * magnification, visible.height * 0.9)

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false)
        newWindow.title = title
        newWindow.contentView = scrollView
        newWindow.isReleasedWhenClosed = false
        newWindow.center()

        // Start at the top-left, where the gesture fields are.
        imageView.scroll(NSPoint(x: 0, y: image.size.height))

        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }
}
