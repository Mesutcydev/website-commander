import SwiftUI

/// A restrained empty-state treatment built from the Living Tab mark.
struct BrandIllustration: View {
    var size: CGFloat = 132

    var body: some View {
        LivingTabMark(size: size * 0.62, style: .gradient, animated: true)
            .frame(width: size, height: size)
            .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: size * 0.22))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .strokeBorder(Theme.borderSubtle)
            }
    }
}
