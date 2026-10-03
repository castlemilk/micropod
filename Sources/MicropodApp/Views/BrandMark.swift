import SwiftUI

/// The pod/terminal identity, drawn directly at its display scale.
struct MicropodGlyph: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 96, geometry.size.height / 64)
            let x = (geometry.size.width - 96 * scale) / 2
            let y = (geometry.size.height - 64 * scale) / 2
            PodShape()
                .stroke(style: StrokeStyle(lineWidth: 7 * scale, lineCap: .square, lineJoin: .round))
                .frame(width: 96 * scale, height: 64 * scale)
                .offset(x: x, y: y)
        }
        .accessibilityHidden(true)
    }

    private struct PodShape: Shape {
        func path(in rect: CGRect) -> Path {
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * rect.width / 96, y: y * rect.height / 64)
            }
            var path = Path()
            path.move(to: point(10, 10))
            for point in [point(65, 10), point(86, 32), point(65, 54), point(10, 54)] {
                path.addLine(to: point)
            }
            path.closeSubpath()
            for x in [CGFloat(24), 37, 50] {
                path.move(to: point(x, 22))
                path.addLine(to: point(x, 42))
            }
            path.move(to: point(63, 22))
            path.addLine(to: point(72, 32))
            path.addLine(to: point(63, 42))
            return path
        }
    }
}

struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        MicropodGlyph()
            .foregroundStyle(.white)
            .frame(width: size * 0.78, height: size * 0.52)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.145, green: 0.647, blue: 1),
                                Tokens.Palette.action,
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .accessibilityHidden(true)
    }
}
