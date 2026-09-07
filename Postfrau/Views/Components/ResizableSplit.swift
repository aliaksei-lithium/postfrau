import AppKit
import SwiftUI

/// A two-pane split with a draggable divider whose position is bound — and therefore persisted.
///
/// `HSplitView` / `VSplitView` cannot report or restore their divider position, and §5 calls for a
/// persisted, user-toggleable layout, so this does the arithmetic itself.
struct ResizableSplit<First: View, Second: View>: View {
    private let axis: Axis
    @Binding private var fraction: Double
    private let minimumFraction: Double
    private let maximumFraction: Double
    private let first: First
    private let second: Second

    /// Thin line, generous grab area — the same feel as an AppKit split view.
    private let dividerThickness: Double = 1
    private let grabThickness: Double = 10
    private let space = "postfrau.split"

    init(
        axis: Axis,
        fraction: Binding<Double>,
        minimumFraction: Double = 0.15,
        maximumFraction: Double = 0.85,
        @ViewBuilder first: () -> First,
        @ViewBuilder second: () -> Second
    ) {
        self.axis = axis
        _fraction = fraction
        self.minimumFraction = minimumFraction
        self.maximumFraction = maximumFraction
        self.first = first()
        self.second = second()
    }

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .vertical ? proxy.size.height : proxy.size.width
            let firstLength = max(0, (total - dividerThickness) * clamped(fraction))

            Group {
                if axis == .vertical {
                    VStack(spacing: 0) {
                        first.frame(height: firstLength)
                        divider(total: total)
                        second.frame(maxHeight: .infinity)
                    }
                } else {
                    HStack(spacing: 0) {
                        first.frame(width: firstLength)
                        divider(total: total)
                        second.frame(maxWidth: .infinity)
                    }
                }
            }
            .coordinateSpace(.named(space))
        }
    }

    private func divider(total: Double) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(
                width: axis == .horizontal ? dividerThickness : nil,
                height: axis == .vertical ? dividerThickness : nil)
            .overlay {
                Color.clear
                    .frame(
                        width: axis == .horizontal ? grabThickness : nil,
                        height: axis == .vertical ? grabThickness : nil)
                    .contentShape(.rect)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active:
                            (axis == .vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
                        case .ended:
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                            .onChanged { value in
                                guard total > 0 else { return }
                                let position = axis == .vertical
                                    ? value.location.y : value.location.x
                                fraction = clamped(position / total)
                            })
            }
            .accessibilityLabel("Resize panes")
            .accessibilityHint("Drag to change how much space the request editor gets")
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, minimumFraction), maximumFraction)
    }
}
