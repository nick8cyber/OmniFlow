import AppKit

// OmniFlow app icon generator — macOS Big Sur style: 1024 canvas, 824 squircle,
// diagonal gradient, soft shadow, "speech bars → text lines" motif.

func makeIcon(top: NSColor, bottom: NSColor, out: String) {
    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size, flipped: true) { _ in
        let squircle = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                                    xRadius: 185, yRadius: 185)

        // Drop shadow painted from the squircle silhouette.
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
        shadow.shadowOffset = NSSize(width: 0, height: 14)
        shadow.shadowBlurRadius = 42
        shadow.set()
        NSColor.white.setFill()
        squircle.fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        // Diagonal gradient fill.
        NSGraphicsContext.current?.saveGraphicsState()
        squircle.addClip()
        NSGradient(colors: [top, bottom])?.draw(in: NSRect(x: 100, y: 100, width: 824, height: 824),
                                                angle: -55)
        // Top gloss.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0.0)])?
            .draw(in: NSRect(x: 100, y: 100, width: 824, height: 400), angle: 90)
        // Inner hairline.
        NSColor.white.withAlphaComponent(0.20).setStroke()
        squircle.lineWidth = 3
        squircle.stroke()

        // Motif: speech bars, then text lines.
        func bar(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat, _ cy: CGFloat, _ alpha: CGFloat) {
            let r = NSBezierPath(roundedRect: NSRect(x: x, y: cy - h / 2, width: w, height: h),
                                 xRadius: w / 2, yRadius: w / 2)
            NSColor.white.withAlphaComponent(alpha).setFill()
            r.fill()
        }
        let barW: CGFloat = 46
        let gap: CGFloat = 30
        let heights: [CGFloat] = [170, 280, 380, 280, 170]
        let barsAlpha: [CGFloat] = [0.95, 0.95, 1.0, 0.95, 0.95]
        let totalBars = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
        let cx0 = (1024 - totalBars) / 2
        let barCy: CGFloat = 425
        for (i, h) in heights.enumerated() {
            let x = cx0 + CGFloat(i) * (barW + gap)
            bar(x, barW, h, barCy, barsAlpha[i])
        }
        // Text lines below the bars: rectangular, softly rounded — reads as text.
        func line(_ x: CGFloat, _ w: CGFloat, _ cy: CGFloat, _ alpha: CGFloat) {
            let r = NSBezierPath(roundedRect: NSRect(x: x, y: cy - 18, width: w, height: 36),
                                 xRadius: 14, yRadius: 14)
            NSColor.white.withAlphaComponent(alpha).setFill()
            r.fill()
        }
        line(316, 392, 642, 0.95)
        line(316, 262, 718, 0.55)
        NSGraphicsContext.current?.restoreGraphicsState()
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("encode failed")
    }
    try! png.write(to: URL(fileURLWithPath: out))
    print("wrote \(out)")
}

makeIcon(top: NSColor(red: 0.345, green: 0.655, blue: 1.0, alpha: 1),
         bottom: NSColor(red: 0.42, green: 0.28, blue: 1.0, alpha: 1),
         out: "/Users/surja/Projects/OmniFlow/Resources/AppIcon-Source.png")
makeIcon(top: NSColor(red: 1.0, green: 0.78, blue: 0.24, alpha: 1),
         bottom: NSColor(red: 1.0, green: 0.42, blue: 0.24, alpha: 1),
         out: "/Users/surja/Projects/OmniFlow/Resources/AppIcon-Dev-Source.png")
