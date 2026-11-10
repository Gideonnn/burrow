import SwiftUI

/// Liquid glass from macOS 26, a material before.
public struct Glass<S: Shape>: ViewModifier {
    let shape: S

    public init(shape: S) { self.shape = shape }

    public func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
