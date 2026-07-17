import AppKit

enum AppVisualStyle {
    private static let phi: CGFloat = (1 + sqrt(5)) / 2

    static let emphasisColor = NSColor.systemRed

    static func goldenCornerRadius(for side: CGFloat) -> CGFloat {
        guard side > 0 else { return 0 }
        return (side / pow(phi, 4)).rounded(.toNearestOrAwayFromZero)
    }
}
