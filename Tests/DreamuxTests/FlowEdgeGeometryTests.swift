// Tests/DreamuxTests/FlowEdgeGeometryTests.swift
import XCTest
import SwiftUI
@testable import Dreamux

final class FlowEdgeGeometryTests: XCTestCase {
    func testSmoothedPathSpansItsPoints() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 20), CGPoint(x: 100, y: 0)]
        let rect = FlowEdgeGeometry.smoothedPath(pts).boundingRect
        XCTAssertFalse(rect.isEmpty)
        XCTAssertLessThanOrEqual(rect.minX, 1)
        XCTAssertGreaterThanOrEqual(rect.maxX, 99)
    }
    func testArrowheadNilForTooFewPoints() {
        XCTAssertNil(FlowEdgeGeometry.arrowheadPath(into: .zero, along: [.zero]))
    }
    func testArrowheadNonNilForAnEdge() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)]
        XCTAssertNotNil(FlowEdgeGeometry.arrowheadPath(into: CGPoint(x: 0, y: 100), along: pts))
    }
}
