import SwiftUI

struct LargeReaderSlider: View {
    let title: String
    let accessibilityTitle: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    @Environment(\.readerInterfaceScale) private var scale

    var body: some View {
        HStack(spacing: 8 * scale) {
            Text(title).fixedSize()
            track.frame(width: (title == "字号" ? 84 : 120) * scale, height: 36 * scale)
            valueLabel
        }
        .font(.system(size: 15 * scale, weight: .semibold))
        .foregroundStyle(ReaderPalette.ink)
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: setValue(value - step)
            case .right, .up: setValue(value + step)
            @unknown default: break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(accessibilityTitle)
                .accessibilityValue(valueText)
        }
    }

    private var valueLabel: some View {
        Text(valueText)
            .monospacedDigit()
            .frame(minWidth: (title == "字号" ? 21 : 36) * scale, alignment: .trailing)
    }

    private var track: some View {
        GeometryReader { geometry in
            let knob = 20 * scale
            let width = max(1, geometry.size.width - knob)
            let progress = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            let offset = width * progress
            ZStack(alignment: .leading) {
                Capsule().fill(ReaderPalette.rule).frame(width: width, height: 5 * scale).offset(x: knob / 2)
                Capsule().fill(ReaderPalette.accent).frame(width: offset, height: 5 * scale).offset(x: knob / 2)
                Circle().fill(ReaderPalette.card)
                    .overlay(Circle().strokeBorder(ReaderPalette.accent, lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                    .frame(width: knob, height: knob).offset(x: offset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let ratio = min(1, max(0, (drag.location.x - knob / 2) / width))
                setValue(range.lowerBound + ratio * (range.upperBound - range.lowerBound))
            })
        }
    }

    private func setValue(_ next: Double) {
        let snapped = range.lowerBound + ((next - range.lowerBound) / step).rounded() * step
        value = min(range.upperBound, max(range.lowerBound, snapped))
    }
}
