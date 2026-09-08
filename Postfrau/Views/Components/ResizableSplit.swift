import AppKit
import SwiftUI

/// A two-pane split with a draggable divider whose position is bound — and therefore persisted.
///
/// `HSplitView` / `VSplitView` cannot report or restore their divider position, and §5 calls for a
/// persisted, user-toggleable layout, so this does the arithmetic itself.
///
/// The arithmetic lives in a `Layout` rather than a `GeometryReader`, which publishes its size
/// *into* its own content and so re-proposes the whole subtree. Measured on its own that change
/// was a wash — it was not the cause of the tab-switch lag, and the profile that suggested it was
/// misread. It is kept because this split is now nested inside another one in `HeadersTab`, and a
/// `Layout` gets the container's bounds directly in `placeSubviews` instead of round-tripping a
/// size through the view tree twice. See `docs/decisions.md` D46.
struct ResizableSplit<First: View, Second: View>: View {
    private let axis: Axis
    @Binding private var fraction: Double
    private let minimumFraction: Double
    private let maximumFraction: Double
    private let first: First
    private let second: Second

    /// The container's length along `axis`, needed only to turn a drag into a fraction.
    @State private var containerLength: Double = 0

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
        // Read into a local: `onGeometryChange`'s transform is `@Sendable`, and touching `self`
        // inside it would capture this view's generic parameters, which are not `Sendable`.
        let axis = axis
        return SplitLayout(
            axis: axis, fraction: clamped(fraction), dividerThickness: dividerThickness
        ) {
            first
            divider
            second
        }
        .coordinateSpace(.named(space))
        // `onGeometryChange` reports the size after layout instead of feeding it back in, which is
        // the whole point of moving off `GeometryReader`. The value is only ever read by the drag.
        .onGeometryChange(for: Double.self) { proxy in
            axis == .vertical ? proxy.size.height : proxy.size.width
        } action: { containerLength = $0 }
    }

    private var divider: some View {
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
                                guard containerLength > 0 else { return }
                                let position = axis == .vertical
                                    ? value.location.y : value.location.x
                                fraction = clamped(position / containerLength)
                            })
            }
            .accessibilityLabel("Resize panes")
            .accessibilityHint("Drag to change how much space the request editor gets")
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, minimumFraction), maximumFraction)
    }
}

/// Places first pane, divider and second pane along one axis at an exact fraction.
private struct SplitLayout: Layout {
    let axis: Axis
    let fraction: Double
    let dividerThickness: Double

    /// The split fills whatever it is given; it never asks its children how big they want to be.
    /// That is what keeps a change inside one pane from re-measuring the other.
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
    ) {
        guard subviews.count == 3 else { return }
        let total = axis == .vertical ? bounds.height : bounds.width
        let firstLength = max(0, (total - dividerThickness) * fraction)
        let secondLength = max(0, total - dividerThickness - firstLength)

        var offset = axis == .vertical ? bounds.minY : bounds.minX
        for (subview, length) in zip(subviews, [firstLength, dividerThickness, secondLength]) {
            let size = axis == .vertical
                ? CGSize(width: bounds.width, height: length)
                : CGSize(width: length, height: bounds.height)
            let origin = axis == .vertical
                ? CGPoint(x: bounds.minX, y: offset)
                : CGPoint(x: offset, y: bounds.minY)
            subview.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(size))
            offset += length
        }
    }
}
