//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
import IsiXROI

/// A generator with a fixed seed, so that every run draws the same cases.
private struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - Two-click Length

private typealias Placement = TwoClickLengthPlacement<String>

private func endpoint(_ x: CGFloat, _ y: CGFloat, image: Int = 0, time: Int = 0, reference: String? = "sop",
                      series: String? = "series", frame: String = "frame") -> Placement.Endpoint {
    Placement.Endpoint(imagePoint: CGPoint(x: x, y: y), imageIndex: image, temporalIndex: time, reference: reference,
                       patient: series.map { Placement.Patient(series: $0, frameOfReference: frame) })
}

private func distance(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(b.x - a.x, b.y - a.y)) }

struct TwoClickLengthPlacementTests {

    @Test func theFirstClickWaitsAndTheSecondMeasuresThroughTheVolume() {
        let a = endpoint(2, 3, image: 0, reference: "a"), b = endpoint(2, 3, image: 4, reference: "b")
        #expect(Placement(first: nil).step(at: a, viewDistance: distance) == .first(a, replacing: false))
        #expect(Placement(first: a).step(at: b, viewDistance: distance) == .measure(from: a, to: b))

        // A slab takes both clicks on the image it shows; a click on another
        // image of it waits, and its point is no end of a length in depth.
        var slabA = endpoint(10, 10), slabB = endpoint(40, 10), slabOther = endpoint(40, 10, image: 4, reference: "slice 4")
        slabA.onSlab = true; slabB.onSlab = true; slabOther.onSlab = true
        #expect(Placement(first: nil).step(at: slabA, viewDistance: distance) == .first(slabA, replacing: false))
        #expect(Placement(first: slabA).step(at: slabB, viewDistance: distance) == .drag(from: slabA.imagePoint, to: slabB.imagePoint))
        #expect(Placement(first: slabA).step(at: slabOther, viewDistance: distance) == .needsThinSlices)
        #expect(Placement(first: a).step(at: slabOther, viewDistance: distance) == .needsThinSlices)
        #expect(Placement(first: slabA).step(at: b, viewDistance: distance) == .first(b, replacing: true))
    }

    @Test func twoClicksOnOneImageAreTheDragBetweenThem() {
        let a = endpoint(4, 5), b = endpoint(14, 9)
        #expect(Placement(first: a).step(at: b, viewDistance: distance) == .drag(from: a.imagePoint, to: b.imagePoint))
        // The same place twice is no length: the first point stays.
        #expect(Placement(first: a).step(at: endpoint(5, 6), viewDistance: distance) == .samePlace)
        // In view points: a zoom of 10 makes one pixel a drag.
        #expect(Placement(first: a).step(at: endpoint(5, 5)) { distance($0, $1) * 10 } ==
                .drag(from: a.imagePoint, to: CGPoint(x: 5, y: 5)))
        // Without patient geometry too.
        let c = endpoint(2, 3, series: nil), d = endpoint(12, 3, series: nil)
        #expect(Placement(first: c).step(at: d, viewDistance: distance) == .drag(from: c.imagePoint, to: d.imagePoint))
    }

    @Test func anotherImageOrTimePointIsAnotherImage() {
        let a = endpoint(4, 5)
        for other in [endpoint(14, 9, image: 1), endpoint(14, 9, time: 1), endpoint(14, 9, reference: "other")] {
            #expect(Placement(first: a).step(at: other, viewDistance: distance) != .drag(from: a.imagePoint, to: other.imagePoint))
        }
        // An image without a reference is never the first click's image.
        let unknown = endpoint(4, 5, reference: nil, series: nil)
        #expect(Placement(first: unknown).step(at: endpoint(14, 9, reference: nil, series: nil), viewDistance: distance) == .needsGeometry)
    }

    @Test func anotherImageWithoutGeometryNeedsIt() {
        let a = endpoint(2, 3, reference: "a")
        let flat = endpoint(12, 3, image: 3, reference: "b", series: nil)
        #expect(Placement(first: a).step(at: flat, viewDistance: distance) == .needsGeometry)
        #expect(Placement(first: nil).step(at: flat, viewDistance: distance) == .first(flat, replacing: false))
    }

    @Test func anotherSeriesFrameOrTimePointStartsAgain() {
        let a = endpoint(2, 3, image: 0, reference: "a")
        for b in [endpoint(2, 3, image: 4, reference: "b", series: "other"), endpoint(2, 3, image: 4, reference: "b", frame: "other"),
                  endpoint(2, 3, image: 4, time: 2, reference: "b")] {
            #expect(Placement(first: a).step(at: b, viewDistance: distance) == .first(b, replacing: true))
        }
        // A first point without geometry is replaced by one with it.
        let flat = endpoint(2, 3, reference: "a", series: nil), b = endpoint(2, 3, image: 4, reference: "b")
        #expect(Placement(first: flat).step(at: b, viewDistance: distance) == .first(b, replacing: true))
    }

    @Test func whichClicksTheLengthTakes() {
        let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
        func takes(_ flags: UInt, replaying: Bool = false, is2D: Bool = true, down: Bool = true, drawing: Bool = false, tool: Bool = true) -> Bool {
            Placement.takesClick(replayingDrag: replaying, is2DViewer: is2D, isLeftMouseDown: down, drawingROI: drawing,
                                 modifierFlags: flags) { tool }
        }
        #expect(takes(0) && takes(shift))
        #expect(!takes(command) && !takes(option) && !takes(control) && !takes(shift | command))
        #expect(!takes(0, replaying: true) && !takes(0, is2D: false) && !takes(0, down: false) && !takes(0, drawing: true) && !takes(0, tool: false))
        // The tool is asked last.
        var asked = false
        _ = Placement.takesClick(replayingDrag: false, is2DViewer: false, isLeftMouseDown: true, drawingROI: false, modifierFlags: 0) {
            asked = true; return true
        }
        #expect(!asked)
        #expect(Placement.doubleClickCancels(clickCount: 2, hasHotKeyAction: true))
        #expect(!Placement.doubleClickCancels(clickCount: 2, hasHotKeyAction: false) && !Placement.doubleClickCancels(clickCount: 1, hasHotKeyAction: true))
        #expect(!Placement.isDrag(from: .zero, to: CGPoint(x: 2, y: 2)) && Placement.isDrag(from: .zero, to: CGPoint(x: 3, y: 0)))
    }
}

// MARK: - ROI selector

/// Plain geometry for the tests: the even-odd rule, a segment against a
/// rectangle by halving, and the crossing of two segments.
private struct TestGeometry: ROISelectorGeometry {
    func segment(from start: CGPoint, to end: CGPoint, intersects rect: CGRect) -> Bool {
        if NSPointInRect(start, rect) || NSPointInRect(end, rect) { return true }
        if hypot(start.x - end.x, start.y - end.y) <= 1 { return false }
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        if !box.isEmpty && !NSIntersectsRect(box, rect) { return false }
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        return segment(from: start, to: mid, intersects: rect) || segment(from: mid, to: end, intersects: rect)
    }

    func polygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y <= point.y && point.y < b.y || b.y <= point.y && point.y < a.y) &&
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    func segment(_ a1: CGPoint, _ a2: CGPoint, crosses b1: CGPoint, _ b2: CGPoint) -> Bool {
        func side(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        let d1 = side(b1, b2, a1), d2 = side(b1, b2, a2), d3 = side(a1, a2, b1), d4 = side(a1, a2, b2)
        return (d1 > 0) != (d2 > 0) && (d3 > 0) != (d4 > 0)
    }
}

/// A ROI as the former -mouseDraggedROISelector: tested it.
private struct FormerROI {
    var type: Int16
    var rect: CGRect
    var points: [CGPoint]
}

/// The former loop of -mouseDraggedROISelector: for one ROI.
private func formerSelectorHit(_ roi: FormerROI, rotated: Bool, rect: CGRect, poly: [CGPoint], scale: Float, g: TestGeometry) -> Bool {
    var intersected = false
    let roiType = roi.type
    func textRect() -> CGRect {
        let w = Float(roi.rect.size.width / CGFloat(scale)), h = Float(roi.rect.size.height / CGFloat(scale))
        let o = roi.rect.origin
        return NSMakeRect(o.x - CGFloat(w) / 2.0, o.y - CGFloat(h) / 2.0, CGFloat(w), CGFloat(h))
    }
    let open: Set<Int16> = [5, 12, 19, 10, 14]
    if !rotated {
        if roiType == 13 {
            intersected = NSIntersectsRect(rect, textRect())
        } else if roiType == 6 {
            intersected = NSIntersectsRect(rect, roi.rect)
        } else if roiType == 19 {
            intersected = NSPointInRect(roi.points[0], rect)
        } else {
            let points = roi.points
            if points.count != 0 {
                var j = 0
                while j < points.count - 1 && !intersected {
                    intersected = g.segment(from: points[j], to: points[j + 1], intersects: rect)
                    j += 1
                }
                if !intersected && !open.contains(roiType) {
                    intersected = g.segment(from: points.last!, to: points[0], intersects: rect)
                }
            }
        }
    } else {
        if roiType == 13 {
            let r = textRect()
            for corner in [NSMakePoint(NSMinX(r), NSMinY(r)), NSMakePoint(NSMinX(r), NSMaxY(r)),
                           NSMakePoint(NSMaxX(r), NSMaxY(r)), NSMakePoint(NSMaxX(r), NSMinY(r))] where !intersected {
                intersected = g.polygon(poly, contains: corner)
            }
        } else if roiType == 19 {
            intersected = g.polygon(poly, contains: roi.points[0])
        } else {
            let points = roi.points
            var j = 0
            while j < points.count && !intersected { intersected = g.polygon(poly, contains: points[j]); j += 1 }
            j = 0
            while j < 4 && !intersected { intersected = g.polygon(points, contains: poly[j]); j += 1 }
            if !intersected && points.count != 0 {
                func edges(_ p1: CGPoint, _ p2: CGPoint) -> Bool {
                    g.segment(p1, p2, crosses: poly[0], poly[1]) || g.segment(p1, p2, crosses: poly[1], poly[2]) ||
                        g.segment(p1, p2, crosses: poly[2], poly[3]) || g.segment(p1, p2, crosses: poly[3], poly[0])
                }
                var j = 0
                while j < points.count - 1 && !intersected { intersected = edges(points[j], points[j + 1]); j += 1 }
                if !intersected && !open.contains(roiType) { intersected = edges(points.last!, points[0]) }
            }
        }
    }
    return intersected
}

struct ROISelectorRegionTests {

    @Test func theRectangleIsAtLeastOnePixel() {
        #expect(ROISelectorRegion.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 4, y: 30)) == CGRect(x: 4, y: 20, width: 6, height: 10))
        #expect(ROISelectorRegion.rect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 10.5, y: 20)) == CGRect(x: 10, y: 20, width: 1, height: 1))
        // The corner went through a single-precision min().
        let corner = ROISelectorRegion.rect(from: CGPoint(x: 0.1, y: 0.2), to: CGPoint(x: 5, y: 5)).origin
        #expect(corner == CGPoint(x: CGFloat(Float(0.1)), y: CGFloat(Float(0.2))))
        #expect(ROISelectorRegion.corners(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 5, y: 7)) ==
                [CGPoint(x: 1, y: 2), CGPoint(x: 1, y: 7), CGPoint(x: 5, y: 7), CGPoint(x: 5, y: 2)])
    }

    @Test func shapesAndClosedContours() {
        let flat = ROISelectorRegion(area: .rect(.zero)), turned = ROISelectorRegion(area: .quad([.zero, .zero, .zero, .zero]))
        #expect(flat.shapeKind(type: 13) == .text && flat.shapeKind(type: 19) == .point && flat.shapeKind(type: 6) == .rectangle)
        #expect(turned.shapeKind(type: 6) == .contour && turned.shapeKind(type: 13) == .text && flat.shapeKind(type: 11) == .contour)
        #expect([5, 12, 19, 10, 14].allSatisfy { !ROISelectorRegion.isClosed(type: $0) })
        #expect([6, 9, 11, 15, 20].allSatisfy { ROISelectorRegion.isClosed(type: $0) })
    }

    @Test func theRegionTouchesTheROIsTheFormerSelectorDid() {
        var random = Seeded(state: 1687)
        let g = TestGeometry()
        let types: [Int16] = [5, 6, 9, 10, 11, 12, 13, 14, 15, 19]
        var touched = 0, cases = 0
        for _ in 0..<600 {
            func point() -> CGPoint { CGPoint(x: CGFloat.random(in: 0..<100, using: &random), y: CGFloat.random(in: 0..<100, using: &random)) }
            let start = point(), end = point()
            let rect = ROISelectorRegion.rect(from: start, to: end)
            let poly = ROISelectorRegion.corners(from: start, to: end).map { CGPoint(x: $0.x * 0.8 + $0.y * 0.3, y: $0.y * 0.9 - $0.x * 0.2 + 20) }
            let scale = Float.random(in: 0.5..<4, using: &random)
            for type in types {
                let count = type == 19 ? 1 : Int.random(in: 0..<7, using: &random)
                let roi = FormerROI(type: type, rect: CGRect(origin: point(), size: CGSize(width: 20, height: 12)),
                                    points: (0..<count).map { _ in point() })
                if type == 19 && roi.points.isEmpty { continue }
                for rotated in [false, true] {
                    let region = ROISelectorRegion(area: rotated ? .quad(poly) : .rect(rect))
                    let shape: ROISelectorRegion.Shape
                    switch region.shapeKind(type: type) {
                    case .text: shape = .text(roi.rect, scale: scale)
                    case .rectangle: shape = .rectangle(roi.rect)
                    case .point: shape = .point(roi.points[0])
                    case .contour: shape = .contour(roi.points, closed: ROISelectorRegion.isClosed(type: type))
                    }
                    // The former loop tested a rectangle ROI over a rotated image by its spline points.
                    let hit = region.touches(shape, geometry: g)
                    let former = formerSelectorHit(roi, rotated: rotated, rect: rect, poly: poly, scale: scale, g: g)
                    #expect(hit == former, "type \(type), rotated \(rotated)")
                    touched += hit ? 1 : 0
                    cases += 1
                }
            }
        }
        // Both answers occur.
        #expect(touched > cases / 20 && touched < cases - cases / 20)
    }
}

// MARK: - Repulsor

/// A point of the former loop: an object moved in place.
private final class FormerPoint {
    var point: CGPoint
    init(_ point: CGPoint) { self.point = point }
}

/// The former point loop of -mouseDraggedRepulsor: for one ROI, on its points
/// and rectangle; the number of change notifications it posted.
private func formerRepulse(_ points: inout [FormerPoint], rect: inout CGRect, type: Int16, center tempPt: CGPoint,
                           radius repulsorRadius: Int32, ratio pixSpacingRatio: Float, scale: Float) -> Int {
    let minD = Float(10.0 / Double(scale)), maxD = Float(50.0 / Double(scale)), maxN = Float(10.0 * Double(scale))
    let repulsorRect = NSMakeRect(tempPt.x - CGFloat(repulsorRadius), tempPt.y - CGFloat(repulsorRadius),
                                  CGFloat(Double(repulsorRadius) * 2.0), CGFloat(Double(repulsorRadius) * 2.0))
    var posts = 0
    var n: Int32 = 0
    var j: Int32 = 0
    while Int(j) < points.count {
        var pt = points[Int(j)].point
        if NSPointInRect(pt, repulsorRect) {
            let dx = Float(pt.x - tempPt.x)
            let dx2 = dx * dx
            let dy = Float((pt.y - tempPt.y) * CGFloat(pixSpacingRatio))
            let dy2 = dy * dy
            let d = Float(sqrt(Double(dx2 + dy2)))
            if d < Float(repulsorRadius) {
                let moveX = dx / d * Float(repulsorRadius) - dx
                let moveY = dy / d * Float(repulsorRadius) - dy
                if type == 19 {
                    rect = NSOffsetRect(rect, CGFloat(moveX), CGFloat(moveY))
                } else {
                    points[Int(j)].point.x += CGFloat(moveX)
                    points[Int(j)].point.y += CGFloat(moveY)
                }
                pt.x += CGFloat(dx / d * Float(repulsorRadius) - dx)
                pt.y += CGFloat(dy / d * Float(repulsorRadius) - dy)
                for delta: Int32 in -1...1 {
                    var k = j + delta
                    if type == 11 || type == 15 {
                        if k == -1 { k = Int32(truncatingIfNeeded: points.count - 1) } else if Int(k) == points.count { k = 0 }
                    }
                    if k != j && k >= 0 && Int(k) < points.count {
                        let pt2 = points[Int(k)].point
                        let dx = Float(pt2.x - pt.x)
                        let dx2 = dx * dx
                        let dy = Float((pt2.y - pt.y) * CGFloat(pixSpacingRatio))
                        let dy2 = dy * dy
                        let d = Float(sqrt(Double(dx2 + dy2)))
                        if d <= minD && d < Float(repulsorRadius) {
                            points.remove(at: Int(k))
                            if delta == -1 { j -= 1 }
                        } else if (d >= maxD || d >= Float(repulsorRadius)) && Float(n) < maxN {
                            let pt3 = NSPoint(x: (pt2.x + pt.x) / 2.0, y: (pt2.y + pt.y) / 2.0)
                            let index = (delta == -1) ? j : j + 1
                            if delta == -1 { j += 1 }
                            points.insert(FormerPoint(pt3), at: Int(index))
                            n += 1
                        }
                    }
                }
                posts += 1
            }
        }
        j += 1
    }
    return posts
}

struct ROIRepulsorTests {

    @Test func theRepulsorLeavesAxesAnglesArrowsBrushesAndLockedROIs() {
        for type: Int16 in [26, 12, 14, 27, 29, 20] { #expect(!ROIRepulsor.pushes(type: type, locked: false)) }
        for type: Int16 in [5, 6, 9, 10, 11, 15, 19] {
            #expect(ROIRepulsor.pushes(type: type, locked: false))
            #expect(!ROIRepulsor.pushes(type: type, locked: true))
        }
    }

    @Test func aPointUnderTheCircleGoesToItsEdge() {
        let repulsor = ROIRepulsor(center: CGPoint(x: 50, y: 50), radius: 10, pixelRatio: 1, scale: 1)
        let edits = repulsor.edits(points: [CGPoint(x: 54, y: 50), CGPoint(x: 90, y: 90)], type: 10)
        #expect(edits.first == .move(0, dx: 6, dy: 0))
        #expect(edits.last == .pushed)
        // A point outside the circle is left alone.
        #expect(repulsor.edits(points: [CGPoint(x: 70, y: 50)], type: 10).isEmpty)
        // A 2D point moves its rectangle.
        #expect(repulsor.edits(points: [CGPoint(x: 50, y: 46)], type: 19) == [.moveRect(dx: 0, dy: -6), .pushed])
    }

    @Test func theEditsMakeWhatTheFormerLoopMade() {
        var random = Seeded(state: 0x1687)
        var pushes = 0, inserts = 0, removals = 0
        for _ in 0..<400 {
            let type: Int16 = [5, 9, 10, 11, 15, 19][Int.random(in: 0..<6, using: &random)]
            let count = type == 19 ? 1 : Int.random(in: 1..<30, using: &random)
            let original = (0..<count).map { _ in
                CGPoint(x: CGFloat.random(in: 20..<80, using: &random), y: CGFloat.random(in: 20..<80, using: &random))
            }
            let repulsor = ROIRepulsor(center: CGPoint(x: CGFloat.random(in: 30..<70, using: &random), y: CGFloat.random(in: 30..<70, using: &random)),
                                       radius: Int32.random(in: 2..<30, using: &random),
                                       pixelRatio: [1, 0.5, 2.25][Int.random(in: 0..<3, using: &random)],
                                       scale: [0.25, 1, 3.5][Int.random(in: 0..<3, using: &random)])

            var former = original.map(FormerPoint.init)
            var formerRect = CGRect(x: 1, y: 2, width: 0, height: 0)
            let posts = formerRepulse(&former, rect: &formerRect, type: type, center: repulsor.center, radius: repulsor.radius,
                                      ratio: repulsor.pixelRatio, scale: repulsor.scale)

            // The edits applied as the view applies them.
            var points = original.map(FormerPoint.init)
            var rect = CGRect(x: 1, y: 2, width: 0, height: 0)
            var pushed = 0
            for edit in repulsor.edits(points: original, type: type) {
                switch edit {
                case .move(let i, let dx, let dy): points[i].point.x += CGFloat(dx); points[i].point.y += CGFloat(dy)
                case .moveRect(let dx, let dy): rect = NSOffsetRect(rect, CGFloat(dx), CGFloat(dy))
                case .remove(let i): points.remove(at: i); removals += 1
                case .insert(let p, let i): points.insert(FormerPoint(p), at: i); inserts += 1
                case .pushed: pushed += 1
                }
            }
            #expect(points.map(\.point) == former.map(\.point))
            #expect(rect == formerRect)
            #expect(pushed == posts)
            pushes += pushed
        }
        // The cases push, insert and remove points.
        #expect(pushes > 0 && inserts > 0 && removals > 0)
    }
}
