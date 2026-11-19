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

/// The opacity and colour functions a 16-bit CLUT gives the volume of the 3D
/// window: VTK renders with them, and the Metal renderer samples them over the
/// volume's range.
///
/// The CLUT editor draws each curve over the series' own values (Hounsfield
/// units in a CT) and closes it down to 0 at its first and last points. The
/// volume holds a voxel as `(value + offset) · valueFactor`, 0 for the series'
/// minimum, so every node goes through that map: the curves' points and the
/// zero opacity of the volume's range alike. In a CT (a negative minimum) the
/// series' raw maximum, unmapped, lies inside the curves.
///
/// The functions are linear between their nodes and keep their first and last
/// nodes' values beyond them, as VTK's piecewise functions do. Outside the
/// curves the opacity is 0: a curve whose end stands above 0 drops to 0 just
/// past that end, a step as the editor draws it, rather than keeping the end's
/// value up to the volume's maximum or ramping down to the next node. An open
/// end (`hasOpenEnd`) is the exception: its curve goes on to the volume's
/// maximum at that end's height and colour, short of any other curve above it.
public struct AdvancedCLUTFunctions: Sendable, Equatable {

    /// A point of a curve as the editor holds it.
    public struct Point: Sendable, Equatable {
        /// Where the point stands, in the series' values.
        public var value: Double
        /// Its height in the editor, from 0 to 1: the opacity is its square.
        public var height: Double
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(value: Double, height: Double, red: Double = 0, green: Double = 0, blue: Double = 0) {
            self.value = value
            self.height = height
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// A node of the opacity function, at a value of the volume.
    public struct OpacityNode: Sendable, Equatable {
        public var x: Double
        public var opacity: Double

        public init(x: Double, opacity: Double) {
            self.x = x
            self.opacity = opacity
        }
    }

    /// A node of the colour function, at a value of the volume.
    public struct ColourNode: Sendable, Equatable {
        public var x: Double
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(x: Double, red: Double, green: Double, blue: Double) {
            self.x = x
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// How far past a curve's end, in the volume's values, its opacity is back
    /// to 0. The function takes a node per value, so the step needs a width;
    /// the volume's voxels are whole numbers, and the next one is past it.
    public static let stepWidth = 1.0 / 64

    /// The top of a CT's 12-bit range, in Hounsfield units: where the bundled
    /// bone presets end their highest curve, an open end.
    public static let openEnd = 3071.0

    /// Whether the curve's last point is an open end: at `openEnd` or beyond,
    /// at the height of the point before it, after two points at least, as the
    /// CLUT editor finds it to leave it out of the curve's windowing. The curve
    /// stands for the densest values: an extended-scale CT holds metal above
    /// 3071 HU, which the volume shows at that height.
    public static func hasOpenEnd(_ curve: [Point]) -> Bool {
        guard curve.count > 2, let last = curve.last else { return false }
        return isOpenEnd(count: curve.count, lastValue: last.value, lastHeight: last.height, heightBefore: curve[curve.count - 2].height)
    }

    /// The rule of `hasOpenEnd` on the values themselves, for the editor, whose
    /// points are not the functions' points: a curve of `count` points, its
    /// last one at `lastValue` and `lastHeight`, the one before at `heightBefore`.
    public static func isOpenEnd(count: Int, lastValue: Double, lastHeight: Double, heightBefore: Double) -> Bool {
        count > 2 && lastValue >= openEnd && lastHeight == heightBefore
    }

    /// Where the open end of a curve that ends at `end` goes on to: `top`,
    /// short by `margin` of the first value of any of the `others`, the other
    /// curves by their first and last values, that reaches above the end. Nil
    /// when that is not past the end: a curve that begins at or below the end
    /// leaves none. The editor draws the end so far, with no margin.
    public static func openEndReach(from end: Double, top: Double, others: [(first: Double, last: Double)], margin: Double) -> Double? {
        let reach = others.reduce(top) { reach, other in other.last > end ? min(reach, other.first - margin) : reach }
        return reach > end ? reach : nil
    }

    /// The opacity function's nodes, in ascending order, one per value.
    public let opacity: [OpacityNode]
    /// The colour function's nodes, in ascending order, one per value: of two
    /// curves' points at the same value the front curve's, as in the opacity.
    public let colour: [ColourNode]

    /// - Parameters:
    ///   - curves: the editor's curves, each point with its colour.
    ///   - minimum: the series' smallest value, which the volume holds as 0.
    ///   - maximum: the series' largest value.
    ///   - offset: what the volume adds to a value before scaling it.
    ///   - valueFactor: what the volume multiplies the shifted value by.
    ///   - opacityDivisor: what each opacity is divided by: the view's
    ///     supersampling in volume rendering, 1 in a projection. A divisor
    ///     that is not positive divides by 1.
    public init(curves: [[Point]], minimum: Double, maximum: Double, offset: Double, valueFactor: Double,
                opacityDivisor: Double) {
        func volumeValue(_ value: Double) -> Double { (offset + value) * valueFactor }
        let divisor = opacityDivisor > 0 && opacityDivisor.isFinite ? opacityDivisor : 1

        // Each curve's nodes from its lowest value to its highest; the opacity
        // in single precision, as the view always sent it. Of a curve's points
        // at the same value, the last one is the node, as VTK kept it: a curve
        // read from a file can stand on 0 and rise at the same value, and its
        // end is then the raised point.
        let sortedCurves: [[OpacityNode]] = curves.map { curve in
            let nodes = curve.enumerated().map { index, point in
                (index, OpacityNode(x: volumeValue(point.value), opacity: Double(Float(point.height * point.height / divisor))))
            }.filter { $0.1.x.isFinite && $0.1.opacity.isFinite }
                .sorted { ($0.1.x, $0.0) < ($1.1.x, $1.0) }
            var distinct: [OpacityNode] = []
            for (_, node) in nodes {
                if distinct.last?.x == node.x {
                    distinct[distinct.count - 1] = node
                } else {
                    distinct.append(node)
                }
            }
            return distinct
        }

        // Where an open end goes on to, at the end's height and colour: the
        // volume's maximum, short of any other curve that reaches above the
        // end. The extension never overlaps another curve nor shares a node
        // with one, so the curves' order, which a click in the editor changes,
        // does not change it; a curve that begins at or below the end leaves
        // none. From then on the curve is a curve as any other.
        let top = volumeValue(maximum)
        let reaches: [Double?] = sortedCurves.indices.map { i in
            guard Self.hasOpenEnd(curves[i]), let end = sortedCurves[i].last?.x else { return nil }
            let others = sortedCurves.indices.compactMap { k -> (first: Double, last: Double)? in
                guard k != i, let last = sortedCurves[k].last else { return nil }
                return (sortedCurves[k][0].x, last.x)
            }
            return Self.openEndReach(from: end, top: top, others: others, margin: Self.stepWidth)
        }
        let nodeCurves: [[OpacityNode]] = sortedCurves.indices.compactMap { i in
            guard let last = sortedCurves[i].last else { return nil }
            return sortedCurves[i] + (reaches[i].map { [OpacityNode(x: $0, opacity: last.opacity)] } ?? [])
        }
        let spans = nodeCurves.map { $0[0].x...$0[$0.count - 1].x }
        func outsideTheCurves(_ x: Double) -> Bool { x.isFinite && !spans.contains { $0.contains(x) } }

        // The zero opacity: the volume's range, and a step past each curve's
        // end that stands above 0. Within another curve, that curve's points
        // decide alone.
        var values: [Double: Double] = [:]
        for x in [volumeValue(minimum), volumeValue(maximum)] where outsideTheCurves(x) {
            values[x] = 0
        }
        for nodes in nodeCurves {
            if let first = nodes.first, first.opacity > 0, outsideTheCurves(first.x - Self.stepWidth) {
                values[first.x - Self.stepWidth] = 0
            }
            if let last = nodes.last, last.opacity > 0, outsideTheCurves(last.x + Self.stepWidth) {
                values[last.x + Self.stepWidth] = 0
            }
        }
        // Of two curves' points at the same value, the front curve's: the
        // editor draws its first curve on top of the others, and Send to back
        // moves a curve to the end. The curves go in from the back, each one
        // replacing a node at a value it shares, as VTK replaces one.
        for nodes in nodeCurves.reversed() {
            for node in nodes {
                values[node.x] = node.opacity
            }
        }
        opacity = values.sorted { $0.key < $1.key }.map { OpacityNode(x: $0.key, opacity: $0.value) }

        // The colour the same way, a node per value: the front curve's, and of
        // a curve's own points at one value the last, as the opacity takes
        // them. In ascending order, so that curves reordered without a value in
        // common give the same functions, which the view does not apply again.
        var colours: [Double: ColourNode] = [:]
        for i in curves.indices.reversed() {
            var nodes = curves[i].map { ColourNode(x: volumeValue($0.value), red: $0.red, green: $0.green, blue: $0.blue) }
            if let x = reaches[i], let end = curves[i].last {
                nodes.append(ColourNode(x: x, red: end.red, green: end.green, blue: end.blue))
            }
            for node in nodes where node.x.isFinite {
                colours[node.x] = node
            }
        }
        colour = colours.values.sorted { $0.x < $1.x }
    }
}
