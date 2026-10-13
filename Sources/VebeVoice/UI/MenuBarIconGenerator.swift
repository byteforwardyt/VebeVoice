import AppKit

/// Voice-to-cursor mark for the macOS menu bar.
/// Multi-res vector draw; idle is template-tinted, live states use brand neon.
enum MenuBarIconGenerator {
    private static let pointSize = NSSize(width: 18, height: 18)

    static func icon(for state: State) -> NSImage {
        Self.makeIcon(state: state)
    }

    enum State {
        case idle
        case recording
        case processing
    }

    private static func makeIcon(state: State) -> NSImage {
        let base = NSImage(size: Self.pointSize)
        base.isTemplate = (state == .idle)

        for scale in [1, 2, 3] {
            let px = NSSize(
                width: Self.pointSize.width * CGFloat(scale),
                height: Self.pointSize.height * CGFloat(scale)
            )
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(px.width),
                pixelsHigh: Int(px.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { continue }
            rep.size = Self.pointSize

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                ctx.imageInterpolation = .high
                ctx.shouldAntialias = true
                ctx.cgContext.setAllowsAntialiasing(true)
                ctx.cgContext.setShouldAntialias(true)

                let rect = NSRect(origin: .zero, size: Self.pointSize)
                NSColor.clear.setFill()
                rect.fill()
                Self.drawVoiceMark(in: rect, state: state, scale: CGFloat(scale))
            }
            NSGraphicsContext.restoreGraphicsState()
            base.addRepresentation(rep)
        }
        return base
    }

    /// The VebeVoice voice-to-cursor square: rounded square with three voice
    /// bars and a text cursor knocked out (matches the app icon). Template
    /// white when idle; brand pink while recording, brand purple while processing.
    private static func drawVoiceMark(in rect: NSRect, state: State, scale: CGFloat) {
        let inset: CGFloat = 1.5
        let b = rect.insetBy(dx: inset, dy: inset)

        let fill: NSColor
        switch state {
        case .idle:
            fill = .white
        case .recording:
            fill = NSColor(srgbRed: 1.0, green: 0.435, blue: 0.647, alpha: 1) // brand pink #FF6FA5
        case .processing:
            fill = NSColor(srgbRed: 0.545, green: 0.361, blue: 0.965, alpha: 1) // brand purple #8B5CF6
        }

        // Soft outer glow for live states
        if state != .idle, let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setShadow(offset: .zero, blur: 1.8 * scale, color: fill.withAlphaComponent(0.8).cgColor)
        }

        let cornerR = b.width * 0.29
        fill.setFill()
        NSBezierPath(roundedRect: b, xRadius: cornerR, yRadius: cornerR).fill()

        guard let context = NSGraphicsContext.current else { return }
        context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
        context.compositingOperation = .destinationOut
        Self.voiceToCursorGlyph(in: b).fill()
        context.compositingOperation = .sourceOver
    }

    /// 1024-unit geometry; keep in sync with `marketing/app-icon/layers/*.svg`.
    /// The glyph is vertically symmetric, so SVG's y-down origin needs no flip.
    private static func voiceToCursorGlyph(in plate: NSRect) -> NSBezierPath {
        let k = plate.width / 1024.0
        let rect = { (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) in
            NSRect(x: plate.minX + x * k, y: plate.minY + y * k, width: w * k, height: h * k)
        }
        let glyph = NSBezierPath()
        let bars: [NSRect] = [rect(176, 412, 100, 200), rect(320, 340, 100, 344), rect(464, 268, 100, 488)]
        for bar in bars {
            glyph.append(NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2))
        }
        let capRadius = 48 * k
        glyph.append(NSBezierPath(rect: rect(676, 240, 100, 544)))
        glyph.append(NSBezierPath(roundedRect: rect(612, 192, 228, 96), xRadius: capRadius, yRadius: capRadius))
        glyph.append(NSBezierPath(roundedRect: rect(612, 736, 228, 96), xRadius: capRadius, yRadius: capRadius))
        return glyph
    }
}
