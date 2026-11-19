//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
import IsiXVolumeRendering

@Suite struct AdvancedCLUTFunctionsTests {

    private typealias Point = AdvancedCLUTFunctions.Point

    /// The opacity function at `x` as VTK evaluates it: linear between the
    /// nodes, the first and last nodes' values beyond them.
    private func opacity(_ functions: AdvancedCLUTFunctions, at x: Double) -> Double {
        let nodes = functions.opacity
        guard let first = nodes.first, let last = nodes.last else { return 0 }
        if x < first.x { return first.opacity }
        if x >= last.x { return last.opacity }
        let upper = nodes.firstIndex { $0.x > x }!
        let a = nodes[upper - 1], b = nodes[upper]
        return a.opacity + (x - a.x) / (b.x - a.x) * (b.opacity - a.opacity)
    }

    /// The opacity of `curves` at a value of the series, as the editor draws
    /// them: linear between a curve's points, 0 outside every curve.
    private func drawn(_ curves: [[Point]], at value: Double, divisor: Double) -> Double {
        for curve in curves where curve[0].value <= value && value <= curve[curve.count - 1].value {
            let upper = curve.firstIndex { $0.value >= value }!
            let b = curve[upper], a = upper > 0 ? curve[upper - 1] : b
            let ya = a.height * a.height / divisor, yb = b.height * b.height / divisor
            return b.value == a.value ? yb : ya + (value - a.value) / (b.value - a.value) * (yb - ya)
        }
        return 0
    }

    /// The 4096 entries the Metal renderer samples over the volume's range,
    /// each checked against the curves: on the curves (away from their ends by
    /// more than one value of the volume) the curve's opacity, elsewhere 0.
    private func checkTable(curves: [[Point]], minimum: Double, maximum: Double, offset: Double, valueFactor: Double,
                            divisor: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let functions = AdvancedCLUTFunctions(curves: curves, minimum: minimum, maximum: maximum, offset: offset,
                                              valueFactor: valueFactor, opacityDivisor: divisor)
        let from = (offset + minimum) * valueFactor, to = (offset + maximum) * valueFactor
        let unit = 1 / valueFactor
        var wrong: [String] = []
        for entry in 0..<4096 {
            let x = from + Double(entry) / 4095 * (to - from)
            let value = x / valueFactor - offset
            let near = curves.contains { curve in
                [curve[0].value, curve[curve.count - 1].value].contains { abs($0 - value) <= unit }
            }
            if near { continue }
            let expected = drawn(curves, at: value, divisor: divisor), found = opacity(functions, at: x)
            if abs(expected - found) > 1e-6 {
                wrong.append(String(format: "%.1f: %.4f, not %.4f", value, found, expected))
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) entries, first \(wrong.prefix(4))", sourceLocation: sourceLocation)
    }

    /// The new curve's shape, which ends at its highest point, and a narrow
    /// curve with both ends above 0.
    private func curves(ramp: Double, narrow: Double) -> [[Point]] {
        [[Point(value: ramp, height: 0), Point(value: ramp + 190, height: 0.027.squareRoot()),
          Point(value: ramp + 392, height: 0.133.squareRoot()), Point(value: ramp + 537, height: 0.682.squareRoot())],
         [Point(value: narrow - 30, height: 0.3), Point(value: narrow, height: 0.9), Point(value: narrow + 30, height: 0.5)]]
    }

    @Test func aCTIsTransparentOutsideItsCurves() {
        // The synthetic CT: −1050 to 1427 HU, held from 0 with factor 1.
        checkTable(curves: curves(ramp: -400, narrow: 300), minimum: -1050, maximum: 1427, offset: 1050, valueFactor: 1,
                   divisor: 1)
        // Volume rendering divides by its supersampling.
        checkTable(curves: curves(ramp: -400, narrow: 300), minimum: -1050, maximum: 1427, offset: 1050, valueFactor: 1,
                   divisor: 2)
    }

    @Test func anMRIsTransparentOutsideItsCurves() {
        checkTable(curves: curves(ramp: 100, narrow: 900), minimum: 0, maximum: 1200, offset: 0, valueFactor: 1, divisor: 1)
    }

    @Test func aScaledVolumeIsTransparentOutsideItsCurves() {
        // A range wider than the 16 bits the view keeps: scaled down.
        let factor = 32000.0 / 43024
        checkTable(curves: curves(ramp: -400, narrow: 2000), minimum: -3024, maximum: 40000, offset: 3024,
                   valueFactor: factor, divisor: 1)
    }

    @Test func theRangeIsInTheVolumesValues() {
        let functions = AdvancedCLUTFunctions(curves: [], minimum: -1050, maximum: 1427, offset: 1050, valueFactor: 1,
                                              opacityDivisor: 1)
        #expect(functions.opacity == [.init(x: 0, opacity: 0), .init(x: 2477, opacity: 0)])
        #expect(functions.colour.isEmpty)
    }

    @Test func aCurveEndAboveZeroStepsDownJustPastIt() {
        let functions = AdvancedCLUTFunctions(curves: [[Point(value: 100, height: 0.5), Point(value: 200, height: 0.8)]],
                                              minimum: 0, maximum: 1000, offset: 0, valueFactor: 1, opacityDivisor: 1)
        let step = AdvancedCLUTFunctions.stepWidth
        let opacity08 = Double(Float(0.8 * 0.8))
        #expect(functions.opacity.map(\.x) == [0, 100 - step, 100, 200, 200 + step, 1000])
        #expect(functions.opacity.map(\.opacity) == [0, 0, 0.25, opacity08, 0, 0])
    }

    @Test func anEndRaisedAtTheValueOfAZeroPointStepsDownToo() {
        // Curves as a file can hold them: standing on 0 and rising at the same
        // value. The raised point is the end, and outside it the opacity is 0.
        // Of the points at one value the last is the node, in its colour too.
        let step = AdvancedCLUTFunctions.stepWidth
        let rising = AdvancedCLUTFunctions(curves: [[Point(value: 300, height: 0), Point(value: 300, height: 0.5, red: 1),
                                                     Point(value: 400, height: 0.5), Point(value: 400, height: 0)]],
                                           minimum: 0, maximum: 1000, offset: 0, valueFactor: 1, opacityDivisor: 1)
        #expect(rising.opacity == [.init(x: 0, opacity: 0), .init(x: 300 - step, opacity: 0), .init(x: 300, opacity: 0.25),
                                   .init(x: 400, opacity: 0), .init(x: 1000, opacity: 0)])
        #expect(rising.colour.filter { $0.x == 300 } == [.init(x: 300, red: 1, green: 0, blue: 0)])
        #expect(opacity(rising, at: 150) == 0)

        let falling = AdvancedCLUTFunctions(curves: [[Point(value: 300, height: 0), Point(value: 400, height: 0),
                                                      Point(value: 400, height: 0.5, blue: 1)]],
                                            minimum: 0, maximum: 1000, offset: 0, valueFactor: 1, opacityDivisor: 1)
        #expect(falling.opacity == [.init(x: 0, opacity: 0), .init(x: 300, opacity: 0), .init(x: 400, opacity: 0.25),
                                    .init(x: 400 + step, opacity: 0), .init(x: 1000, opacity: 0)])
        #expect(falling.colour.filter { $0.x == 400 } == [.init(x: 400, red: 0, green: 0, blue: 1)])
        #expect(opacity(falling, at: 700) == 0)
    }

    @Test func zeroNodesStayOutOfOtherCurves() {
        // The two curves overlap, each raised end inside the other, and the
        // second spans the volume's maximum: none of them gets a zero there.
        let first = [Point(value: 100, height: 0), Point(value: 300, height: 0.5)]
        let second = [Point(value: 250, height: 0.4), Point(value: 1100, height: 0.4)]
        let functions = AdvancedCLUTFunctions(curves: [first, second], minimum: 0, maximum: 1000, offset: 0, valueFactor: 1,
                                              opacityDivisor: 1)
        let step = AdvancedCLUTFunctions.stepWidth
        #expect(functions.opacity.map(\.x) == [0, 100, 250, 300, 1100, 1100 + step])
    }

    @Test func anOpenEndGoesOnToTheVolumesMaximum() {
        // Dark Bone's bone curve, ended at 3071 HU as the bundled preset ends
        // it, on extended-scale CTs, held as they are and scaled down: metal
        // above 3071 HU keeps the curve's last height and colour.
        let grey = (0.2, 0.2, 0.2), bone = (1.0, 0.9, 0.5)
        let curve = [Point(value: 46.7, height: 0, red: grey.0, green: grey.1, blue: grey.2),
                     Point(value: 135, height: 0.26, red: grey.0, green: grey.1, blue: grey.2),
                     Point(value: 244.7, height: 0.53, red: bone.0, green: bone.1, blue: bone.2),
                     Point(value: 3071, height: 0.53, red: bone.0, green: bone.1, blue: bone.2)]
        #expect(AdvancedCLUTFunctions.hasOpenEnd(curve))
        for (minimum, maximum, factor, divisor) in [(-1024.0, 20000.0, 1.0, 1.0), (-10240, 30710, 32000 / 40950.0, 2)] {
            let offset = -minimum
            let functions = AdvancedCLUTFunctions(curves: [curve], minimum: minimum, maximum: maximum, offset: offset,
                                                  valueFactor: factor, opacityDivisor: divisor)
            let plateau = Double(Float(0.53 * 0.53 / divisor))
            for value in [244.7, 1000, 3071, 3072, 8000, maximum] {
                #expect(opacity(functions, at: (offset + value) * factor) == plateau, "\(value) HU of \(minimum)...\(maximum)")
            }
            #expect(functions.colour.last == .init(x: (offset + maximum) * factor, red: bone.0, green: bone.1, blue: bone.2))
        }
    }

    @Test func onlyAnOpenEndGoesOnPastItsCurve() {
        // A last point at 3071 HU at another height, a flat end below 3071 HU
        // and a flat curve of two points step down past their end, on an
        // extended-scale CT as on any volume.
        let step = AdvancedCLUTFunctions.stepWidth
        for curve in [[Point(value: 200, height: 0), Point(value: 1000, height: 0.5), Point(value: 3071, height: 0.3)],
                      [Point(value: 200, height: 0), Point(value: 1000, height: 0.5), Point(value: 2000, height: 0.5)],
                      [Point(value: 3071, height: 0.5), Point(value: 3500, height: 0.5)]] {
            #expect(!AdvancedCLUTFunctions.hasOpenEnd(curve))
            let functions = AdvancedCLUTFunctions(curves: [curve], minimum: -1024, maximum: 20000, offset: 1024, valueFactor: 1,
                                                  opacityDivisor: 1)
            #expect(opacity(functions, at: curve[curve.count - 1].value + 1024 + step) == 0)
            #expect(opacity(functions, at: 21024) == 0)
        }
        // On a CT whose maximum is the open end's value, the curve ends there.
        let open = [Point(value: 200, height: 0), Point(value: 1000, height: 0.5), Point(value: 3071, height: 0.5)]
        let standard = AdvancedCLUTFunctions(curves: [open], minimum: -1024, maximum: 3071, offset: 1024, valueFactor: 1,
                                             opacityDivisor: 1)
        #expect(standard.opacity.map(\.x) == [0, 1224, 2024, 4095, 4095 + step])
        #expect(standard.colour.map(\.x) == [1224, 2024, 4095])
    }

    @Test func anOpenEndStopsShortOfTheCurvesAboveIt() {
        // Dark Bone's bone curve on an extended-scale CT, with curves of the
        // user's above 3071 HU: a band ending at 0, a band ending flat (an
        // open end of its own), and a curve across the bone curve's end. The
        // bone curve's height goes on only up to the next curve above it,
        // so the functions are the same in either order of the curves.
        let step = AdvancedCLUTFunctions.stepWidth, plateau = Double(Float(0.53 * 0.53))
        let bone = [Point(value: 46.7, height: 0), Point(value: 135, height: 0.26), Point(value: 244.7, height: 0.53, red: 1),
                    Point(value: 3071, height: 0.53, red: 1)]
        let band = [Point(value: 3500, height: 0, green: 1), Point(value: 4000, height: 0.8, green: 1),
                    Point(value: 4500, height: 0.8, green: 1), Point(value: 5000, height: 0, green: 1)]
        let flat = [Point(value: 4000, height: 0, blue: 1), Point(value: 4500, height: 0.3, blue: 1), Point(value: 6000, height: 0.3, blue: 1)]
        let across = [Point(value: 3000, height: 0), Point(value: 4000, height: 0.5), Point(value: 5000, height: 0)]
        let cases: [([Point], [(Double, Double)])] = [
            (band, [(3071, plateau), (3499, plateau), (3500, 0), (4200, 0.64), (5001, 0), (10000, 0), (20000, 0)]),
            (flat, [(3071, plateau), (3999, plateau), (4000, 0), (4500, 0.09), (10000, 0.09), (20000, 0.09)]),
            (across, [(3071, plateau), (5001, 0), (10000, 0), (20000, 0)]),
        ]
        for (other, expected) in cases {
            let orders = [[bone, other], [other, bone]].map {
                AdvancedCLUTFunctions(curves: $0, minimum: -1024, maximum: 20000, offset: 1024, valueFactor: 1, opacityDivisor: 1)
            }
            // The same colour in either order: a node of the extension at a
            // value of the other curve's would be the front curve's, in its colour.
            #expect(orders[0].opacity == orders[1].opacity, "above \(other[0].value) HU")
            #expect(orders[0].colour == orders[1].colour, "above \(other[0].value) HU")
            for (value, alpha) in expected {
                #expect(abs(opacity(orders[0], at: value + 1024) - alpha) < 1e-6, "\(value) HU, above \(other[0].value) HU")
            }
        }
        // Up to the band, in the bone curve's colour; the band's own from its first point.
        let withBand = AdvancedCLUTFunctions(curves: [bone, band], minimum: -1024, maximum: 20000, offset: 1024, valueFactor: 1,
                                             opacityDivisor: 1)
        #expect(withBand.colour.map(\.x).filter { $0 > 4095 && $0 < 4524 } == [4524 - step])
        #expect(withBand.colour.first { $0.x == 4524 - step } == .init(x: 4524 - step, red: 1, green: 0, blue: 0))
    }

    /// The rule of an open end on the values themselves, as the editor asks
    /// it, and how far the end goes on: the top, short of a curve that reaches
    /// above the end, by the margin asked.
    @Test func theEditorAsksTheSameOpenEnd() {
        #expect(AdvancedCLUTFunctions.isOpenEnd(count: 3, lastValue: 3071, lastHeight: 0.5, heightBefore: 0.5))
        #expect(AdvancedCLUTFunctions.isOpenEnd(count: 4, lastValue: 4000, lastHeight: 0.5, heightBefore: 0.5))
        #expect(!AdvancedCLUTFunctions.isOpenEnd(count: 2, lastValue: 3071, lastHeight: 0.5, heightBefore: 0.5))
        #expect(!AdvancedCLUTFunctions.isOpenEnd(count: 3, lastValue: 3070, lastHeight: 0.5, heightBefore: 0.5))
        #expect(!AdvancedCLUTFunctions.isOpenEnd(count: 3, lastValue: 3071, lastHeight: 0.5, heightBefore: 0.4))

        #expect(AdvancedCLUTFunctions.openEndReach(from: 3071, top: 30710, others: [], margin: 0) == 30710)
        #expect(AdvancedCLUTFunctions.openEndReach(from: 3071, top: 30710, others: [(first: -200, last: 900)], margin: 0) == 30710)
        #expect(AdvancedCLUTFunctions.openEndReach(from: 3071, top: 30710, others: [(first: 5000, last: 9000), (first: 4000, last: 4500)],
                                                   margin: 0.5) == 3999.5)
        #expect(AdvancedCLUTFunctions.openEndReach(from: 3071, top: 30710, others: [(first: 2000, last: 9000)], margin: 0) == nil)
        #expect(AdvancedCLUTFunctions.openEndReach(from: 3071, top: 3071, others: [], margin: 0) == nil)
    }

    @Test func theFrontCurveHasAValueTwoCurvesShare() {
        // The editor draws its first curve on top, and Send to back moves a
        // curve to the end: at a value two curves share, the first curve's
        // opacity and colour, in either order.
        let joined = [[Point(value: 100, height: 0), Point(value: 200, height: 0.5, red: 1)],
                      [Point(value: 200, height: 0.8, blue: 1), Point(value: 300, height: 0)]]
        for curves in [joined, Array(joined.reversed())] {
            let functions = AdvancedCLUTFunctions(curves: curves, minimum: 0, maximum: 1000, offset: 0, valueFactor: 1,
                                                  opacityDivisor: 1)
            let front = curves[0].first { $0.value == 200 }!
            #expect(functions.opacity.first { $0.x == 200 }?.opacity == Double(Float(front.height * front.height)))
            #expect(functions.colour.filter { $0.x == 200 } == [.init(x: 200, red: front.red, green: front.green, blue: front.blue)])
        }
    }

    @Test func curvesReorderedWithoutAValueInCommonGiveTheSameFunctions() {
        // The view applies functions only when they change: Send to back of a
        // curve that shares no value with the others leaves the volume as it is.
        let curves = [[Point(value: 100, height: 0, red: 1), Point(value: 200, height: 0.5, green: 1), Point(value: 300, height: 0, blue: 1)],
                      [Point(value: 250, height: 0, red: 0.5), Point(value: 400, height: 0.7, green: 0.5), Point(value: 500, height: 0)]]
        let functions = [curves, Array(curves.reversed())].map {
            AdvancedCLUTFunctions(curves: $0, minimum: 0, maximum: 1000, offset: 0, valueFactor: 1, opacityDivisor: 1)
        }
        #expect(functions[0] == functions[1])
        #expect(functions[0].colour.map(\.x) == [100, 200, 250, 300, 400, 500])
    }

    @Test func colourNodesFollowTheCurvesPoints() {
        let functions = AdvancedCLUTFunctions(curves: [[Point(value: -100, height: 0, red: 1, green: 0.5, blue: 0),
                                                        Point(value: 50, height: 0.2, red: 0, green: 0, blue: 1)]],
                                              minimum: -1000, maximum: 1000, offset: 1000, valueFactor: 2, opacityDivisor: 1)
        #expect(functions.colour == [.init(x: 1800, red: 1, green: 0.5, blue: 0), .init(x: 2100, red: 0, green: 0, blue: 1)])
    }

    @Test func aDivisorThatIsNotPositiveDividesByOne() {
        let curve = [[Point(value: 10, height: 0), Point(value: 20, height: 0.5), Point(value: 30, height: 0)]]
        for divisor in [0.0, -2, .nan] {
            let functions = AdvancedCLUTFunctions(curves: curve, minimum: 0, maximum: 100, offset: 0, valueFactor: 1,
                                                  opacityDivisor: divisor)
            #expect(functions.opacity.first { $0.x == 20 }?.opacity == 0.25)
        }
    }
}
