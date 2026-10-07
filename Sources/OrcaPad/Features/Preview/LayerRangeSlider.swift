import SwiftUI

/// Desktop-style vertical layer range slider: layer 0 at the bottom, the top
/// layer at the top, two thumbs bounding the visible range. Updates stream
/// live while dragging (the renderer only moves index windows).
struct LayerRangeSlider: View {
    let lower: Int
    let upper: Int
    let maximum: Int
    let label: (Int) -> String
    let onChange: (_ lower: Int, _ upper: Int) -> Void

    private let thumbSize: CGFloat = 26

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height - thumbSize, 1)
            ZStack(alignment: .top) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 6)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, thumbSize / 2)

                Capsule()
                    .fill(Color.accentColor.opacity(0.8))
                    .frame(width: 6, height: max(y(lower, height) - y(upper, height), 2))
                    .offset(y: y(upper, height) + thumbSize / 2)

                thumb(value: upper, height: height, isUpper: true)
                thumb(value: lower, height: height, isUpper: false)
            }
            .frame(maxWidth: .infinity)
            .coordinateSpace(name: "layer-track")
        }
    }

    private func y(_ value: Int, _ height: CGFloat) -> CGFloat {
        guard maximum > 0 else { return height }
        return height * (1 - CGFloat(value) / CGFloat(maximum))
    }

    private func value(at location: CGFloat, height: CGFloat) -> Int {
        guard maximum > 0 else { return 0 }
        let fraction = 1 - min(max((location - thumbSize / 2) / height, 0), 1)
        return Int((fraction * CGFloat(maximum)).rounded())
    }

    private func thumb(value current: Int, height: CGFloat, isUpper: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isUpper ? Color.accentColor : Color.secondary)
                .frame(width: thumbSize, height: thumbSize)
                .shadow(radius: 2)
            Text(label(current))
                .font(.caption2.monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
                .offset(x: -thumbSize - 28)
        }
        .offset(y: y(current, height))
        .gesture(
            DragGesture(coordinateSpace: .named("layer-track"))
                .onChanged { drag in
                    let target = value(at: drag.location.y, height: height)
                    if isUpper {
                        onChange(min(lower, target), max(target, lower))
                    } else {
                        onChange(min(target, upper), upper)
                    }
                }
        )
    }
}
