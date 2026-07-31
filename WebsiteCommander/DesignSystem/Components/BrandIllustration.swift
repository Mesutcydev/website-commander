import SwiftUI

/// The empty-state hero: an elevated white tile with a neutral hairline, so the
/// only colour in it is the small brand mark at its centre.
struct BrandIllustration: View {
    var size: CGFloat = 132

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
    }

    var body: some View {
        LivingTabMark(size: size * 0.58, style: .gradient, animated: true)
            .frame(width: size, height: size)
            .background(Theme.elevatedSurface, in: shape)
            .overlay { shape.strokeBorder(Theme.borderSubtle, lineWidth: 1) }
            .cardElevation()
    }
}
