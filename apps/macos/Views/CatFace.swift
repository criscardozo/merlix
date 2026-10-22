import SwiftUI

/// Merlí's face from the app icon: the black head with yellow slit eyes,
/// outlined in white. Drawn from the icon's own shapes (a 1024-point canvas).
struct CatFace: View {
    var border: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            // The head spans about 232…792 by 210…856 of the icon's canvas.
            let box = CGRect(x: 232 - border, y: 210 - border, width: 560 + border * 2, height: 646 + border * 2)
            let scale = min(size.width / box.width, size.height / box.height)
            context.translateBy(
                x: (size.width - box.width * scale) / 2 - box.minX * scale,
                y: (size.height - box.height * scale) / 2 - box.minY * scale)
            context.scaleBy(x: scale, y: scale)

            let head = Path(Self.silhouette)
            context.stroke(head, with: .color(.white), style: StrokeStyle(lineWidth: border * 2, lineJoin: .round))
            context.fill(head, with: .color(Color(red: 0.08, green: 0.07, blue: 0.09)))

            for centre in [402.0, 622.0] {
                var eye = Path()
                eye.move(to: CGPoint(x: centre - 72, y: 580))
                eye.addQuadCurve(to: CGPoint(x: centre + 72, y: 580), control: CGPoint(x: centre, y: 506))
                eye.addQuadCurve(to: CGPoint(x: centre - 72, y: 580), control: CGPoint(x: centre, y: 654))
                context.fill(eye, with: .color(Color(red: 0.95, green: 0.79, blue: 0.30)))
                context.fill(
                    Path(ellipseIn: CGRect(x: centre - 11, y: 546, width: 22, height: 68)),
                    with: .color(Color(red: 0.08, green: 0.07, blue: 0.09)))
            }
        }
    }

    /// Ears and head as one shape, corners rounded as in the icon's SVG
    /// (a 36-point round-joined stroke of the same colour).
    private static let silhouette: CGPath = {
        let left = CGMutablePath()
        left.addLines(between: [CGPoint(x: 250, y: 520), CGPoint(x: 282, y: 228), CGPoint(x: 452, y: 368)])
        left.closeSubpath()
        let right = CGMutablePath()
        right.addLines(between: [CGPoint(x: 774, y: 520), CGPoint(x: 742, y: 228), CGPoint(x: 572, y: 368)])
        right.closeSubpath()
        let head = CGPath(ellipseIn: CGRect(x: 220, y: 342, width: 584, height: 496), transform: nil)
        let shape = head.union(left).union(right)
        let rounded = shape.copy(strokingWithWidth: 36, lineCap: .round, lineJoin: .round, miterLimit: 10)
        return shape.union(rounded)
    }()
}
