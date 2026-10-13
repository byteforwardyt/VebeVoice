import SwiftUI

// MARK: - Brand Waveform Color

/// Crown-gradient colors for the bottom-overlay audio visualizer.
/// (The visualizer itself is drawn by `BottomOverlayView`'s GPU Canvas; this
/// only supplies the per-bar brand color.)
enum VibeWaveformStyle {
    /// TheVibeFather crown gradient stops (118deg on the site):
    /// #8B5CF6 at 0%, #FF6FA5 at 52%, #66B3FA at 100%.
    private static let crownStops: [(CGFloat, (Double, Double, Double))] = [
        (0.00, (0x8B / 255.0, 0x5C / 255.0, 0xF6 / 255.0)),
        (0.52, (0xFF / 255.0, 0x6F / 255.0, 0xA5 / 255.0)),
        (1.00, (0x66 / 255.0, 0xB3 / 255.0, 0xFA / 255.0)),
    ]

    /// Color along the crown gradient, t in 0...1 (left -> right across the bars).
    static func crownColor(_ t: CGFloat) -> Color {
        let clamped = min(max(t, 0), 1)
        for i in 0..<(self.crownStops.count - 1) {
            let (t0, c0) = self.crownStops[i]
            let (t1, c1) = self.crownStops[i + 1]
            if clamped <= t1 {
                let f = Double((clamped - t0) / max(t1 - t0, 0.0001))
                return Color(
                    red: c0.0 + (c1.0 - c0.0) * f,
                    green: c0.1 + (c1.1 - c0.1) * f,
                    blue: c0.2 + (c1.2 - c0.2) * f
                )
            }
        }
        let last = self.crownStops[self.crownStops.count - 1].1
        return Color(red: last.0, green: last.1, blue: last.2)
    }
}
