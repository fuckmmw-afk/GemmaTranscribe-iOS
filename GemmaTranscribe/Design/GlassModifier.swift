#if os(iOS)
// Reusable glass effect modifier supporting iOS 26 Liquid Glass with graceful fallback.
import SwiftUI

public struct DictusGlassModifier<S: Shape>: ViewModifier {
    public let shape: S

    public init(shape: S) {
        self.shape = shape
    }

    public func body(content: Content) -> some View {
        content
            .background(shape.fill(.regularMaterial))
    }
}

public struct GlassPressStyle: ButtonStyle {
    private let pressedScale: CGFloat

    public init(pressedScale: CGFloat = 0.92) {
        self.pressedScale = pressedScale
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

public extension View {
    func dictusGlass<S: Shape>(in shape: S = RoundedRectangle(cornerRadius: 16)) -> some View {
        modifier(DictusGlassModifier(shape: shape))
    }

    func dictusGlassBar() -> some View {
        modifier(DictusGlassModifier(shape: Capsule()))
    }
}
#endif
