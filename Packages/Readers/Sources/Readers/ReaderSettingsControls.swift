import SwiftUI

/// A setting with its value and round − / + buttons (the reader settings sheets).
struct RoundStepperRow<Value: Strideable & Comparable>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride
    let format: (Value) -> String

    init(_ title: String, value: Binding<Value>, in range: ClosedRange<Value>, step: Value.Stride, format: @escaping (Value) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack {
            Text(title) + Text(" ") + Text(format(value)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 10) {
                button("minus", label: "Less") { value = max(range.lowerBound, value.advanced(by: -step)) }
                    .disabled(value <= range.lowerBound)
                button("plus", label: "More") { value = min(range.upperBound, value.advanced(by: step)) }
                    .disabled(value >= range.upperBound)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value.advanced(by: step))
            case .decrement: value = max(range.lowerBound, value.advanced(by: -step))
            @unknown default: break
            }
        }
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold)).frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

/// A row of preview tiles ("あ" on the page colour); the selected one has an accent ring.
struct ThemeTiles<Theme: Hashable>: View {
    struct Tile {
        var theme: Theme
        var title: String
        var page: Color
        var ink: Color
        /// System: half light, half dark.
        var split = false
    }

    let tiles: [Tile]
    @Binding var selection: Theme

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tiles, id: \.theme) { tile in
                Button {
                    selection = tile.theme
                } label: {
                    VStack(spacing: 2) {
                        Text("あ").font(.title2)
                        Text(tile.title).font(.caption)
                    }
                    .foregroundStyle(tile.split ? Color.white : tile.ink)
                    // On the split tile, a dark capsule sized to the text keeps it readable on both halves.
                    .padding(.horizontal, tile.split ? 10 : 0).padding(.vertical, tile.split ? 4 : 0)
                    .background { if tile.split { Capsule().fill(.black.opacity(0.55)) } }
                    .frame(maxWidth: .infinity, minHeight: 68)
                    .background {
                        if tile.split {
                            HStack(spacing: 0) { Color.white; Color.black }
                        } else {
                            tile.page
                        }
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(selection == tile.theme ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                          lineWidth: selection == tile.theme ? 3 : 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tile.title)
                .accessibilityAddTraits(selection == tile.theme ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}
