import SwiftUI

/// A vector illustration echoing the app icon: a dark "window" card with a title
/// bar and a faint grid, holding a metallic pipe. Used as the hero of empty
/// states so they read as *this app*, not a template. The contextual SF Symbol
/// for each state is composited as a small gradient chip by `EmptyStateView`.
struct BrandIllustration: View {
    var size: CGFloat = 132

    private var metallic: LinearGradient {
        LinearGradient(
            colors: [Color(white: 0.95), Color(white: 0.55), Color(white: 0.85), Color(white: 0.45)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            // Window body
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(Color(white: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .strokeBorder(LinearGradient(
                            colors: [Color(white: 0.7), Color(white: 0.35)],
                            startPoint: .top, endPoint: .bottom), lineWidth: size * 0.02)
                )
            // Title bar
            VStack(spacing: 0) {
                HStack(spacing: size * 0.04) {
                    Circle().fill(LinearGradient(colors: [.white, Color(white: 0.6)],
                                                 startPoint: .top, endPoint: .bottom))
                        .frame(width: size * 0.07, height: size * 0.07)
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.06, weight: .bold))
                        .foregroundStyle(Color(white: 0.7))
                    Spacer()
                }
                .padding(.horizontal, size * 0.1)
                .padding(.top, size * 0.09)
                Rectangle().fill(Color(white: 0.25)).frame(height: 1)
                    .padding(.top, size * 0.06)
                Spacer()
            }
            // Faint grid
            grid
                .padding(size * 0.08)
                .padding(.top, size * 0.16)
                .opacity(0.5)
            // The pipe
            pipe
                .frame(width: size * 0.5, height: size * 0.5)
                .rotationEffect(.degrees(-35))
                .offset(y: size * 0.04)
        }
        .frame(width: size, height: size * 0.82)
        .wcFloat()
    }

    private var grid: some View {
        GeometryReader { geo in
            let cols = 5, rows = 4
            Path { p in
                for i in 1..<cols {
                    let x = geo.size.width * CGFloat(i) / CGFloat(cols)
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                }
                for j in 1..<rows {
                    let y = geo.size.height * CGFloat(j) / CGFloat(rows)
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
        }
    }

    private var pipe: some View {
        ZStack {
            Capsule().fill(metallic)
            // end rings
            HStack {
                Capsule().fill(metallic).frame(width: 14)
                    .overlay(Capsule().stroke(Color(white: 0.3), lineWidth: 1))
                Spacer()
                Capsule().fill(metallic).frame(width: 14)
                    .overlay(Capsule().stroke(Color(white: 0.3), lineWidth: 1))
            }
            // bore on the lower-left end
            Circle().fill(Color(white: 0.18))
                .frame(width: 16, height: 16)
                .offset(x: -34)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}
