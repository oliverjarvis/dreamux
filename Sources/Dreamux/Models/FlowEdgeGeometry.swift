// Sources/Dreamux/Models/FlowEdgeGeometry.swift
import SwiftUI

/// Pure edge-drawing geometry shared by any renderer of a `FlowLayout`
/// (currently `FlowDetailView`'s `Canvas`). Extracted so a new graph
/// renderer can reuse the same smoothed-spline and arrowhead math.
enum FlowEdgeGeometry {
    /// A smooth path through routed waypoints: quadratic curves round each
    /// interior corner while the path still passes through the endpoints.
    static func smoothedPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        guard pts.count >= 3 else {
            path.move(to: first)
            for point in pts.dropFirst() { path.addLine(to: point) }
            return path
        }
        path.move(to: first)
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2,
                              y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// A small filled triangle on the target node's border, pointing inward
    /// along the edge's approach direction.
    static func arrowheadPath(into target: CGPoint, along pts: [CGPoint]) -> Path? {
        guard pts.count >= 2 else { return nil }
        let approach = pts[pts.count - 2]
        let dir = CGVector(dx: target.x - approach.x, dy: target.y - approach.y)
        let len = max(hypot(dir.dx, dir.dy), 0.001)
        let ux = dir.dx / len, uy = dir.dy / len
        // Border crossing on the approach side of the node center.
        let halfW = FlowLayoutEngine.nodeSize.width / 2
        let halfH = FlowLayoutEngine.nodeSize.height / 2
        let tX = ux == 0 ? CGFloat.greatestFiniteMagnitude : halfW / abs(ux)
        let tY = uy == 0 ? CGFloat.greatestFiniteMagnitude : halfH / abs(uy)
        let t = min(tX, tY)
        let tip = CGPoint(x: target.x - ux * t, y: target.y - uy * t)
        let size: CGFloat = 7
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        let px = -uy, py = ux
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: base.x + px * size * 0.5, y: base.y + py * size * 0.5))
        path.addLine(to: CGPoint(x: base.x - px * size * 0.5, y: base.y - py * size * 0.5))
        path.closeSubpath()
        return path
    }
}
