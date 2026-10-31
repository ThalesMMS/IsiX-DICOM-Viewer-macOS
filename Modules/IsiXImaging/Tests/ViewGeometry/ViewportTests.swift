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
@testable import IsiXImaging

// The viewport of a view against the code DCMView ran before ViewportState,
// ViewportRestoration and the conversions of ViewTransform: each `former…`
// function is that code with the view's state turned into arguments. Results
// are compared as bits, on random inputs of a fixed seed and on edge cases.

private let deg2rad = Double.pi / 180

/// A fixed-seed generator, so that a failure can be replayed.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct Former {
    var scale: Float, origin: CGPoint, rotation: Float, xFlipped: Bool, yFlipped: Bool
    var startScale: Float, originStart: CGPoint, rotationStart: Float

    var viewport: ViewportState {
        var state = ViewportState(scale: scale, origin: origin, rotation: rotation, xFlipped: xFlipped, yFlipped: yFlipped)
        state.scaleAtDragStart = startScale
        state.originAtDragStart = originStart
        state.rotationAtDragStart = rotationStart
        return state
    }

    static func random(_ g: inout SplitMix) -> Former {
        let rotations: [Float] = [0, 90, 180, 270, 360, -45]
        return Former(scale: Float.random(in: 0.01...12, using: &g),
                      origin: CGPoint(x: Double.random(in: -900...900, using: &g), y: Double.random(in: -900...900, using: &g)),
                      rotation: Bool.random(using: &g) ? rotations.randomElement(using: &g)! : Float.random(in: 0...360, using: &g),
                      xFlipped: Bool.random(using: &g), yFlipped: Bool.random(using: &g),
                      startScale: Float.random(in: 0.01...12, using: &g),
                      originStart: CGPoint(x: Double.random(in: -900...900, using: &g), y: Double.random(in: -900...900, using: &g)),
                      rotationStart: Float.random(in: -30...400, using: &g))
    }

    // -rotatePoint:
    func rotatePoint(_ a: NSPoint, frame size: NSSize, pwidth: Int, pheight: Int) -> NSPoint {
        var a = a
        if xFlipped { a.x = size.width - a.x }
        if yFlipped { a.y = size.height - a.y }
        a.x -= size.width / 2
        a.y -= size.height / 2
        let angle = Double(rotation) * deg2rad
        let xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        let yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))
        a.y = CGFloat(yy)
        a.x = CGFloat(xx)
        a.x -= (origin.x)
        a.y += (origin.y)
        a.x += CGFloat(Double(pwidth) / 2.0)
        a.y += CGFloat(Double(pheight) / 2.0)
        return a
    }

    // -ConvertFromGL2View:
    func gl2View(_ a: NSPoint, size: NSSize, pix: (Int, Int, Double)?) -> NSPoint {
        var a = a
        if let pix {
            a.y *= CGFloat(pix.2)
            a.y -= CGFloat(Double(pix.1) * pix.2 * 0.5)
            a.x -= CGFloat(Float(pix.0) * 0.5)
        }
        let scaleValue = CGFloat(scale)
        a.y -= (origin.y) / scaleValue
        a.x += (origin.x) / scaleValue
        let angle = Double(-rotation) * deg2rad
        let xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        let yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))
        a.y = CGFloat(yy)
        a.x = CGFloat(xx)
        a.y *= scaleValue
        a.y += size.height / 2.0
        a.x *= scaleValue
        a.x += size.width / 2.0
        if xFlipped { a.x = size.width - a.x }
        if yFlipped { a.y = size.height - a.y }
        a.x -= size.width / 2.0
        a.y -= size.height / 2.0
        return a
    }

    // -ConvertFromUpLeftView2GL:
    func upLeft2GL(_ a: NSPoint, size: NSSize, pix: (Int, Int, Double)?) -> NSPoint {
        var a = a
        let scaleValue = CGFloat(scale)
        if xFlipped { a.x = size.width - a.x }
        if yFlipped { a.y = size.height - a.y }
        a.x -= size.width / 2
        a.x /= scaleValue
        a.y -= size.height / 2
        a.y /= scaleValue
        let angle = Double(rotation) * deg2rad
        let xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        let yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))
        a.y = CGFloat(yy)
        a.x = CGFloat(xx)
        a.x -= (origin.x) / scaleValue
        a.y += (origin.y) / scaleValue
        if let pix {
            a.x += CGFloat(Float(pix.0) * 0.5)
            a.y += CGFloat(Double(pix.1) * pix.2 * 0.5)
            a.y /= CGFloat(pix.2)
        }
        return a
    }

    // -positionWithoutRotation:
    func positionWithoutRotation(_ tPt: NSPoint, spacingX: Double, spacingY: Double) -> NSPoint {
        var tPt = tPt
        let scaleValue = CGFloat(scale)
        var unrotatedRect = NSMakeRect(tPt.x / scaleValue, tPt.y / scaleValue, 1, 1)
        var centeredRect = unrotatedRect
        var ratio: Float = 1
        if spacingX != 0 && spacingY != 0 { ratio = Float(spacingX / spacingY) }
        centeredRect.origin.y -= origin.y * CGFloat(ratio) / scaleValue
        centeredRect.origin.x -= -origin.x / scaleValue
        unrotatedRect.origin.x = centeredRect.origin.x * CGFloat(cos(Double(-rotation) * deg2rad)) + centeredRect.origin.y * CGFloat(sin(Double(-rotation) * deg2rad)) / CGFloat(ratio)
        unrotatedRect.origin.y = -centeredRect.origin.x * CGFloat(sin(Double(-rotation) * deg2rad)) + centeredRect.origin.y * CGFloat(cos(Double(-rotation) * deg2rad)) / CGFloat(ratio)
        unrotatedRect.origin.y *= CGFloat(ratio)
        unrotatedRect.origin.y += origin.y * CGFloat(ratio) / scaleValue
        unrotatedRect.origin.x += -origin.x / scaleValue
        tPt = NSMakePoint(unrotatedRect.origin.x, unrotatedRect.origin.y)
        tPt.x = (tPt.x) * scaleValue - unrotatedRect.size.width / 2
        tPt.y = (tPt.y) / CGFloat(ratio) * scaleValue - unrotatedRect.size.height / 2 / CGFloat(ratio)
        return tPt
    }

    // -mouseDraggedZoom:, the scale already through the setter.
    func zoomOrigin(click: NSPoint?, drawing: NSSize) -> (Float, Float) {
        var o = NSMakePoint(0, 0)
        if var oo = click {
            let scaleValue = CGFloat(scale), startScaleValue = CGFloat(startScale)
            oo.x = (oo.x - drawing.width / 2.0) - (((oo.x - drawing.width / 2.0) * scaleValue) / startScaleValue)
            oo.y = (oo.y - drawing.height / 2.0) - (((oo.y - drawing.height / 2.0) * scaleValue) / startScaleValue)
            oo.y = -oo.y
            if xFlipped { oo.x = -oo.x }
            if yFlipped { oo.y = -oo.y }
            let angle = Double(rotation) * deg2rad
            o.x = oo.x * cos(angle) + oo.y * sin(angle)
            o.y = oo.x * sin(angle) - oo.y * cos(angle)
        }
        let scaleValue = CGFloat(scale), startScaleValue = CGFloat(startScale)
        return (Float(((originStart.x * scaleValue) / startScaleValue) + o.x), Float(((originStart.y * scaleValue) / startScaleValue) + o.y))
    }

    // -mouseDraggedTranslate:
    func translateOrigin(start: NSPoint, current: NSPoint, backing: Double) -> (Float, Float) {
        var xmove: Float, ymove: Float, xx: Float, yy: Float
        xmove = Float(current.x - start.x)
        ymove = Float(-(current.y - start.y))
        xmove = Float(Double(xmove) * backing)
        ymove = Float(Double(ymove) * backing)
        if xFlipped { xmove = -xmove }
        if yFlipped { ymove = -ymove }
        let angle = Double(rotation) * deg2rad
        xx = Float(Double(xmove) * cos(angle) + Double(ymove) * sin(angle))
        yy = Float(Double(xmove) * sin(angle) - Double(ymove) * cos(angle))
        return (Float(originStart.x + CGFloat(xx)), Float(originStart.y + CGFloat(yy)))
    }

    // -mouseDraggedRotate:, the point already from the centre of the view.
    func rotateRotation(_ current: NSPoint) -> Float {
        var sign: Float = 1
        if xFlipped { sign = -sign }
        if yFlipped { sign = -sign }
        var rot = Float(Double(rotationStart) + Double(sign) * atan2(current.x, current.y) / deg2rad)
        while rot < 0 { rot += 360 }
        while rot > 360 { rot -= 360 }
        return rot
    }
}

private func same(_ a: CGPoint, _ b: CGPoint) -> Bool {
    a.x.bitPattern == b.x.bitPattern && a.y.bitPattern == b.y.bitPattern
}

private func same(_ a: (x: Float, y: Float), _ b: (Float, Float)) -> Bool {
    a.x.bitPattern == b.0.bitPattern && a.y.bitPattern == b.1.bitPattern
}

@Suite struct ViewportConversionTests {
    @Test func conversionsMatchTheFormerCode() {
        var g = SplitMix(state: 1685)
        var compared = 0
        for _ in 0..<20000 {
            let v = Former.random(&g)
            let size = CGSize(width: Double(Int.random(in: 64...3000, using: &g)), height: Double(Int.random(in: 64...3000, using: &g)))
            let pix = (Int.random(in: 1...4096, using: &g), Int.random(in: 1...4096, using: &g),
                       Bool.random(using: &g) ? 1.0 : Double.random(in: 0.25...4, using: &g))
            let image = Bool.random(using: &g) ? nil : pix
            let extent = image.map { ViewTransform.ImageExtent(width: $0.0, height: $0.1, pixelRatio: $0.2) }
            let p = CGPoint(x: Double.random(in: -4000...4000, using: &g), y: Double.random(in: -4000...4000, using: &g))
            let state = v.viewport

            #expect(same(ViewTransform.rotatedPoint(p, viewport: state, frameSize: size, imageWidth: pix.0, imageHeight: pix.1, deg2rad: deg2rad),
                         v.rotatePoint(p, frame: size, pwidth: pix.0, pheight: pix.1)))
            #expect(same(ViewTransform.imageToView(p, viewport: state, drawingSize: size, image: extent, deg2rad: deg2rad),
                         v.gl2View(p, size: size, pix: image)))
            #expect(same(ViewTransform.upLeftViewToImage(p, viewport: state, drawingSize: size, image: extent, deg2rad: deg2rad),
                         v.upLeft2GL(p, size: size, pix: image)))
            let spacing = Bool.random(using: &g) ? (0.0, 0.5) : (Double.random(in: 0.1...3, using: &g), Double.random(in: 0.1...3, using: &g))
            #expect(same(ViewTransform.positionWithoutRotation(p, scale: v.scale, origin: v.origin, rotation: v.rotation,
                                                               pixelSpacingX: spacing.0, pixelSpacingY: spacing.1, deg2rad: deg2rad),
                         v.positionWithoutRotation(p, spacingX: spacing.0, spacingY: spacing.1)))
            compared += 4
        }
        #expect(compared == 80000)
    }

    @Test func aRoundTripComesBack() {
        let state = ViewportState(scale: 2, origin: CGPoint(x: 30, y: -12), rotation: 90, xFlipped: true, yFlipped: false)
        let image = ViewTransform.ImageExtent(width: 512, height: 400, pixelRatio: 1)
        let size = CGSize(width: 800, height: 600)
        let p = CGPoint(x: 100, y: 37)
        let view = ViewTransform.imageToView(p, viewport: state, drawingSize: size, image: image, deg2rad: deg2rad)
        let back = ViewTransform.upLeftViewToImage(CGPoint(x: view.x + size.width / 2, y: view.y + size.height / 2), viewport: state,
                                                   drawingSize: size, image: image, deg2rad: deg2rad)
        #expect(abs(back.x - p.x) < 1e-3 && abs(back.y - p.y) < 1e-3)
    }

    @Test func theCanvasTransformIsTheFormerOne() {
        let state = ViewportState(scale: 3, origin: CGPoint(x: 10.3, y: -7.7), rotation: 33, xFlipped: true, yFlipped: true)
        let t = ViewTransform.canvasTransform(viewport: state, drawingSize: CGSize(width: 640, height: 480), pixelRatio: 1.5)
        #expect(t.scaleX == Double(Float(2.0 / -640.0)) && t.scaleY == Double(Float(-2.0 / -480.0)))
        #expect(t.rotation == 33 && t.translateX == Double(Float(10.3)) && t.translateY == Double(Float(7.7)) && t.pixelRatio == 1.5)
    }
}

@Suite struct ViewportDragTests {
    @Test func dragsMatchTheFormerCode() {
        var g = SplitMix(state: 524)
        for _ in 0..<20000 {
            let v = Former.random(&g)
            let state = v.viewport
            let drawing = CGSize(width: Double(Int.random(in: 64...3000, using: &g)), height: Double(Int.random(in: 64...3000, using: &g)))
            let click: CGPoint? = Bool.random(using: &g) ? nil : CGPoint(x: Double.random(in: 0...3000, using: &g),
                                                                         y: Double.random(in: 0...3000, using: &g))
            #expect(same(state.zoomDragOrigin(click: click, drawingSize: drawing, deg2rad: deg2rad), v.zoomOrigin(click: click, drawing: drawing)))

            let start = CGPoint(x: Double.random(in: 0...2000, using: &g), y: Double.random(in: 0...2000, using: &g))
            let current = CGPoint(x: Double.random(in: 0...2000, using: &g), y: Double.random(in: 0...2000, using: &g))
            let backing = Bool.random(using: &g) ? 2.0 : 1.0
            #expect(same(state.translateDragOrigin(from: start, to: current, backingScale: backing, deg2rad: deg2rad),
                         v.translateOrigin(start: start, current: current, backing: backing)))

            let fromCentre = CGPoint(x: Double.random(in: -1000...1000, using: &g), y: Double.random(in: -1000...1000, using: &g))
            #expect(state.rotateDragRotation(fromCentre: fromCentre, deg2rad: deg2rad).bitPattern == v.rotateRotation(fromCentre).bitPattern)

            let delta = Double.random(in: -400...400, using: &g), width = Int.random(in: 1...4096, using: &g)
            #expect(state.zoomDragScale(delta: delta, imageWidth: width).bitPattern
                    == Float(Double(v.startScale) + delta / (80.0 * Double(width) / 512.0)).bitPattern)
        }
    }

    @Test func aDragStartsFromTheViewport() {
        var state = ViewportState(scale: 1.5, origin: CGPoint(x: 4, y: 5), rotation: 12)
        state.beginDrag()
        #expect(state.scaleAtDragStart == 1.5 && state.originAtDragStart == CGPoint(x: 4, y: 5) && state.rotationAtDragStart == 12)
        // A zoom drag of 80 points doubles nothing but adds one unit for an image 512 wide.
        #expect(state.zoomDragScale(delta: 80, imageWidth: 512) == 2.5)
    }

    @Test func boundsAreTheSetters() {
        #expect(ViewportState.boundedScale(.nan) == nil)
        #expect(ViewportState.boundedScale(0) == 0.01 && ViewportState.boundedScale(1000) == 100 && ViewportState.boundedScale(3) == 3)
        #expect(!ViewportState.acceptsCentredScale(0.001) && !ViewportState.acceptsCentredScale(101) && !ViewportState.acceptsCentredScale(.nan))
        #expect(ViewportState.acceptsCentredScale(0.01) && ViewportState.acceptsCentredScale(100))
        #expect(ViewportState.boundedOffset(100000) == 0 && ViewportState.boundedOffset(-99999) == -99999 && ViewportState.boundedOffset(.nan) == 0)
        #expect(ViewportState.normalizedRotation(-90) == 270 && ViewportState.normalizedRotation(450) == 90
                && ViewportState.normalizedRotation(-400) == -40 && ViewportState.normalizedRotation(360) == 360)
        #expect(ViewportState(scale: 0).centredOrigin(forScale: 2) == nil)
        let centred = ViewportState(scale: 2, origin: CGPoint(x: 10, y: -6)).centredOrigin(forScale: 3)
        #expect(centred?.x == 15 && centred?.y == -9)
    }
}

/// -updatePresentationStateFromSeriesOnlyImageLevel:scale:offset: before
/// ViewportRestoration, its viewport part, with the saved values as arguments
/// and what it did to the view recorded.
private func formerRestoration(image: [String: NSNumber], series: [String: NSNumber], onlyImage: Bool, scale: Bool, offset: Bool,
                               isPreview: Bool, alwaysFit: Bool, copySettings: Bool, frame: CGSize) -> [String] {
    var done: [String] = []
    func value(_ object: [String: NSNumber], _ key: String) -> NSNumber? { object[key] }
    if let flipped = value(image, "xFlipped") { done.append("x \(flipped.boolValue)") }
    else if !onlyImage { done.append("x \(value(series, "xFlipped")?.boolValue ?? false)") } else { done.append("x false") }
    if let flipped = value(image, "yFlipped") { done.append("y \(flipped.boolValue)") }
    else if !onlyImage { done.append("y \(value(series, "yFlipped")?.boolValue ?? false)") } else { done.append("y false") }
    if !isPreview {
        if (scale && !alwaysFit) || !copySettings {
            if let imageScale = value(image, "scale") {
                if imageScale.floatValue != 0 { done.append("scale \(imageScale.floatValue.bitPattern)") } else { done.append("fit") }
            } else if !onlyImage {
                if let seriesScale = value(series, "scale"), seriesScale.floatValue != 0 {
                    done.append("scale \(ViewTransform.restoredScale(seriesScale.floatValue, displayStyle: Int(value(series, "displayStyle")?.int32Value ?? 0), frameSize: frame).bitPattern)")
                } else { done.append("fit") }
            } else { done.append("fit") }
        } else { done.append("fit") }
    } else { done.append("fit") }
    if let angle = value(image, "rotationAngle") { done.append("rotation \(angle.floatValue)") }
    else if !onlyImage { done.append("rotation \(value(series, "rotationAngle")?.floatValue ?? 0)") } else { done.append("rotation 0.0") }
    if !isPreview {
        if (offset && !alwaysFit) || !copySettings {
            var o = NSPoint(x: CGFloat(Float.infinity), y: CGFloat(Float.infinity))
            if let x = value(image, "xOffset") { o.x = CGFloat(x.floatValue) } else if !onlyImage { o.x = CGFloat(value(series, "xOffset")?.floatValue ?? 0) }
            if let y = value(image, "yOffset") { o.y = CGFloat(y.floatValue) } else if !onlyImage { o.y = CGFloat(value(series, "yOffset")?.floatValue ?? 0) }
            if o.x != CGFloat(Float.infinity) && o.y != CGFloat(Float.infinity) { done.append("origin \(o.x) \(o.y)") }
        }
    }
    return done
}

private func restoration(image: [String: NSNumber], series: [String: NSNumber], rule: ViewportRestoration, frame: CGSize) -> [String] {
    var done: [String] = []
    done.append("x \(rule.flip(image: image["xFlipped"]?.boolValue, series: series["xFlipped"]?.boolValue))")
    done.append("y \(rule.flip(image: image["yFlipped"]?.boolValue, series: series["yFlipped"]?.boolValue))")
    switch rule.scale(image: image["scale"]?.floatValue, series: series["scale"]?.floatValue, displayStyle: series["displayStyle"]?.int32Value,
                      frameSize: frame) {
    case .fit: done.append("fit")
    case .value(let s): done.append("scale \(s.bitPattern)")
    }
    done.append("rotation \(rule.rotation(image: image["rotationAngle"]?.floatValue, series: series["rotationAngle"]?.floatValue))")
    if let o = rule.origin(image: (image["xOffset"]?.floatValue, image["yOffset"]?.floatValue),
                           series: (series["xOffset"]?.floatValue, series["yOffset"]?.floatValue)) {
        done.append("origin \(o.x) \(o.y)")
    }
    return done
}

@Suite struct ViewportRestorationTests {
    @Test func theRuleIsTheFormerOne() {
        var g = SplitMix(state: 816)
        let keys = ["xFlipped", "yFlipped", "scale", "displayStyle", "rotationAngle", "xOffset", "yOffset"]
        func saved(_ g: inout SplitMix) -> [String: NSNumber] {
            var values: [String: NSNumber] = [:]
            for key in keys where Bool.random(using: &g) {
                switch key {
                case "xFlipped", "yFlipped": values[key] = NSNumber(value: Bool.random(using: &g))
                case "displayStyle": values[key] = NSNumber(value: Int32.random(in: 0...4, using: &g))
                case "scale": values[key] = NSNumber(value: Bool.random(using: &g) ? 0 : Float.random(in: 0.001...8, using: &g))
                default: values[key] = NSNumber(value: [Float.infinity, 0, -3.5, Float.random(in: -500...500, using: &g)].randomElement(using: &g)!)
                }
            }
            return values
        }
        var cases = 0
        for _ in 0..<4000 {
            let image = saved(&g), series = saved(&g)
            let frame = CGSize(width: Double.random(in: 10...3000, using: &g), height: Double.random(in: 10...3000, using: &g))
            for flags in 0..<64 {
                let f = (0..<6).map { flags & (1 << $0) != 0 }
                let rule = ViewportRestoration(onlyImage: f[0], restoresScale: f[1], restoresOffset: f[2], isPreview: f[3], alwaysFit: f[4],
                                               copiesSettingsInSeries: f[5])
                #expect(restoration(image: image, series: series, rule: rule, frame: frame)
                        == formerRestoration(image: image, series: series, onlyImage: f[0], scale: f[1], offset: f[2], isPreview: f[3],
                                             alwaysFit: f[4], copySettings: f[5], frame: frame))
                cases += 1
            }
        }
        #expect(cases == 256000)
    }
}

@Suite struct ViewportPlaneTests {
    @Test func planeBaseAndAnglesMatchTheFormerCode() {
        var g = SplitMix(state: 450)
        for _ in 0..<20000 {
            var p = (0..<3).map { _ in Float.random(in: -500...500, using: &g) }
            var o = (0..<3).map { _ in Float.random(in: -500...500, using: &g) }
            var n = (0..<3).map { _ in Float.random(in: -1...1, using: &g) }
            var projected = [Float](repeating: 0, count: 3), formerProjected = projected
            let distance = ViewTransform.planeBase(&p, &o, &n, &projected)
            // +pbase_Plane::::
            var sub = [p[0] - o[0], p[1] - o[1], p[2] - o[2]]
            let sn = -(n[0] * sub[0] + n[1] * sub[1] + n[2] * sub[2])
            let sd = n[0] * n[0] + n[1] * n[1] + n[2] * n[2]
            let sb = sn / sd
            for i in 0..<3 { formerProjected[i] = p[i] + sb * n[i] }
            for i in 0..<3 { sub[i] = p[i] - formerProjected[i] }
            let formerDistance = Float(sqrt(Double(sub[0] * sub[0] + sub[1] * sub[1] + sub[2] * sub[2])))
            #expect(distance.bitPattern == formerDistance.bitPattern && projected.map(\.bitPattern) == formerProjected.map(\.bitPattern))

            var a = (0..<3).map { _ in Double.random(in: -2...2, using: &g) }
            var b = (0..<3).map { _ in Double.random(in: -2...2, using: &g) }
            let cosTheta = (a[0] * b[0] + a[1] * b[1] + a[2] * b[2])
                / (sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]) * sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2]))
            #expect(ViewTransform.angle(&a, &b, deg2rad: deg2rad).bitPattern == acos(cosTheta).bitPattern)
        }
        var zero = [0.0, 0, 0], one = [1.0, 0, 0]
        #expect(ViewTransform.angle(&zero, &zero, deg2rad: deg2rad) == 0)
        #expect(ViewTransform.angle(&zero, &one, deg2rad: deg2rad) == deg2rad * 180 && ViewTransform.angle(&one, &zero, deg2rad: deg2rad) == deg2rad * 180)
    }

    @Test func imagesKeptByTypeAreTheFormerGroups() {
        #expect(ViewTransform.imagesKeptByType([String]()) == nil)
        #expect(ViewTransform.imagesKeptByType(["A", "A"]) == nil)
        // Six of A, two of B (kept: 2 >= 6 / 2 is false), three of C (kept).
        let types = ["A", "B", "A", "C", "A", "A", "C", "B", "A", "C", "A"]
        #expect(ViewTransform.imagesKeptByType(types) == types.map { $0 != "B" })
        // Integer halves: three and one keep the one (1 >= 3 / 2).
        #expect(ViewTransform.imagesKeptByType(["A", "A", "A", "B"]) == [true, true, true, true])
    }

    @Test func theThickSlabIsTheFormerOne() {
        // Ten images from location 0, 2 mm apart: a slab of 4 from image 2 ends at image 5, towards 0 at image 0.
        #expect(ViewTransform.thickSlabLastIndex(current: 2, count: 10, stack: 4, flipped: false) == 5)
        #expect(ViewTransform.thickSlabLastIndex(current: 2, count: 10, stack: 4, flipped: true) == 0)
        #expect(ViewTransform.thickSlabLastIndex(current: 8, count: 10, stack: 4, flipped: false) == 9)
        let slab = ViewTransform.thickSlab(thickness: 2, location: 4, endLocation: 10)
        #expect(slab.thickness == 8 && slab.location == 7)
        let unknown = ViewTransform.thickSlab(thickness: 2, location: .nan, endLocation: 10)
        #expect(unknown.thickness == 2 && unknown.location.isNaN)
    }
}
