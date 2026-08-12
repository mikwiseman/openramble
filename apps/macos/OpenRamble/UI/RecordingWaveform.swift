import SwiftUI

enum RecordingWaveformLayout {
    static func barHeight(sample: Float, maximum: CGFloat) -> CGFloat {
        let normalized = CGFloat(min(1, max(0, sample)))
        return 1 + (maximum - 1) * sqrt(normalized)
    }

    /// Oldest bars fade, the newest is fully opaque: the ramp gives the
    /// rolling signal a direction without animating anything of its own.
    static func barOpacity(index: Int, count: Int) -> Double {
        guard count > 1 else { return 1 }
        return 0.35 + 0.65 * Double(index + 1) / Double(count)
    }
}

/// A rolling view of the microphone signal. Samples are drawn directly: there is
/// no decorative loop or interpolation that could imply sound the microphone did
/// not receive.
struct RecordingWaveform: View {
    let samples: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty, size.width > 0, size.height > 0 else { return }

            let spacing: CGFloat = 2
            let availableWidth = max(0, size.width - spacing * CGFloat(samples.count - 1))
            let barWidth = max(1, availableWidth / CGFloat(samples.count))
            let step = barWidth + spacing

            for (index, sample) in samples.enumerated() {
                let height = RecordingWaveformLayout.barHeight(
                    sample: sample,
                    maximum: size.height
                )
                let rect = CGRect(
                    x: CGFloat(index) * step,
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(barWidth, height) / 2),
                    with: .color(color.opacity(
                        RecordingWaveformLayout.barOpacity(index: index, count: samples.count)
                    ))
                )
            }
        }
        .frame(height: 32)
        .accessibilityHidden(true)
    }
}
