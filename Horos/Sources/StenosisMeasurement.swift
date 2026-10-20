//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import simd

/// The measure of a stenosis along a stretch of the curved MPR's centerline:
/// the lumen's cross-sectional area every half millimetre, and from it the
/// NASCET degree, by area and by diameter.
///
/// NASCET compares the narrowest lumen with a healthy reference distal to it,
/// (1 − narrowest / reference) × 100. Applied to the cross-sectional area on
/// CT angiography it grades a carotid stenosis about as well as the diameter
/// does against duplex (Carnicelli et al., J Vasc Surg 2013;58:659–665). The
/// guideline thresholds of 50 % and 70 % are diameter ones: for a round lumen,
/// 50 % in diameter is 75 % in area.
///
/// Nothing here knows the application: the path, the volume and the settings
/// come in as values, so a synthetic volume measures the same way a CT does.
enum Stenosis {

    /// Where the measure walks, in patient space (mm): the point of the
    /// centerline, its tangent and the normal of the transverse sections at a
    /// relative position, as the curved MPR's transverse views take them.
    struct Frame {
        var point: SIMD3<Double>
        var tangent: SIMD3<Double>
        var normal: SIMD3<Double>

        /// The in-plane axes of the section: x across, y along the normal.
        var axes: (x: SIMD3<Double>, y: SIMD3<Double>) {
            let x = simd_normalize(simd_cross(tangent, normal))
            let y = simd_normalize(simd_cross(x, tangent))
            return (x, y)
        }
    }

    struct Settings: Equatable {
        /// Between two sections along the centerline, in mm.
        var step = 0.5
        /// The in-plane sampling of a section, in mm.
        var pixel = 0.1
        /// No lumen reaches farther than this from the centerline, in mm: the
        /// jugular or the external carotid beyond it are left out.
        var maxRadius = 8.0
        /// The lumen is what lies between these fractions of the intensity at
        /// the centerline: the lower one is the edge (half of it, the half
        /// maximum against soft tissue near 0 HU), the upper one leaves out the
        /// calcium, much brighter than the contrast.
        var lowerFraction = 0.5
        var upperFraction = 1.6
        /// Below this at the centerline there is no contrast-filled lumen
        /// there (the path runs through the wall or beside the vessel), in
        /// HU: the section is left out rather than measured on soft tissue.
        var minimumLumenValue: Float = 150
        /// A neighbouring vessel that touches the lumen joins it through a neck
        /// narrower than twice this, in mm: opening the mask by it cuts the neck.
        var neck = 0.5
    }

    /// One transverse section of the lumen.
    struct Section {
        /// From the start of the stretch, in mm.
        var position: Double
        /// On the whole centerline, 0 to 1.
        var relativePosition: Double
        /// In mm²; 0 when no lumen was found.
        var area: Double
        /// The smallest width of the lumen over all directions (its minimum
        /// Feret diameter), in mm.
        var minDiameter: Double
        /// The intensity the thresholds were taken from.
        var centerValue: Float
        /// The lumen's outline, in patient space, for drawing.
        var contour: [SIMD3<Double>]

        var isValid: Bool { area > 0 }
        /// The diameter of the circle of the same area, √(4A/π).
        var equivalentDiameter: Double { (4 * area / .pi).squareRoot() }
    }

    // MARK: - One section

    /// The lumen in a square grid of `size` × `size` samples, row after row,
    /// centered on the centerline. Returns the mask, its area in pixels, and
    /// the intensity at the center; nil when the center has no contrast.
    static func segment(values: [Float], size: Int, settings: Settings) -> (mask: [Bool], centerValue: Float)? {
        let c = size / 2
        let pixelsPerMM = 1 / settings.pixel
        let radius = settings.maxRadius * pixelsPerMM
        // The center: the median of the 5 × 5 samples around it, against noise.
        var around: [Float] = []
        for y in max(c - 2, 0)...min(c + 2, size - 1) {
            for x in max(c - 2, 0)...min(c + 2, size - 1) { around.append(values[y * size + x]) }
        }
        around.sort()
        let center = around[around.count / 2]
        guard center >= settings.minimumLumenValue, center > 0 else { return nil }
        let lower = Float(settings.lowerFraction) * center, upper = Float(settings.upperFraction) * center

        var inside = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x - c), dy = Double(y - c)
                let v = values[y * size + x]
                inside[y * size + x] = dx * dx + dy * dy <= radius * radius && v >= lower && v <= upper
            }
        }
        // The pixel to grow from: the center, or the nearest lumen pixel within
        // a millimetre when the center itself falls just outside.
        guard let seed = nearest(in: inside, size: size, to: c * size + c, within: Int(pixelsPerMM)) else { return nil }

        // Open the mask: erode by the neck, keep the part that holds the seed,
        // grow it back by the neck inside the mask. A lumen narrower than the
        // neck vanishes when eroded: then the mask is taken as it is.
        let neck = settings.neck * pixelsPerMM
        let distanceOut = distanceTransform(inside, size: size)
        let eroded = distanceOut.map { $0 > neck }
        var lumen: [Bool]
        if let core = nearest(in: eroded, size: size, to: seed, within: Int(neck) + 1) {
            let kept = component(of: eroded, size: size, from: core)
            let distanceIn = distanceTransform(kept.map { !$0 }, size: size)
            let grown = zip(distanceIn, inside).map { $0 <= neck + 0.5 && $1 }
            lumen = component(of: grown, size: size, from: seed)
        } else {
            lumen = component(of: inside, size: size, from: seed)
        }
        fillHoles(&lumen, size: size)
        return (lumen, center)
    }

    /// The smallest width of a mask over directions every 2°, in pixels: the
    /// distance between the outermost pixel centers on each direction.
    static func minimumWidth(of mask: [Bool], size: Int) -> Double {
        var points: [SIMD2<Double>] = []
        for y in 0..<size { for x in 0..<size where mask[y * size + x] { points.append(SIMD2(Double(x), Double(y))) } }
        guard points.count > 1 else { return points.isEmpty ? 0 : 1 }
        var best = Double.infinity
        for step in 0..<90 {
            let angle = Double(step) * .pi / 90
            let direction = SIMD2(cos(angle), sin(angle))
            var low = Double.infinity, high = -Double.infinity
            for p in points {
                let t = simd_dot(p, direction)
                low = min(low, t); high = max(high, t)
            }
            best = min(best, high - low)
        }
        return best
    }

    /// The outline of a mask from its center, one point every 2°: along each
    /// ray, the last lumen pixel before the first one outside. In pixels from
    /// the center.
    static func outline(of mask: [Bool], size: Int) -> [SIMD2<Double>] {
        let c = Double(size / 2)
        var points: [SIMD2<Double>] = []
        for step in 0..<180 {
            let angle = Double(step) * .pi / 90
            let direction = SIMD2(cos(angle), sin(angle))
            var last = 0.0
            var r = 0.0
            while r < c {
                let x = Int((c + r * direction.x).rounded()), y = Int((c + r * direction.y).rounded())
                if x < 0 || y < 0 || x >= size || y >= size || !mask[y * size + x] { break }
                last = r
                r += 0.5
            }
            points.append(direction * (last + 0.5))
        }
        return points
    }

    /// Measures the section at a relative position of the path.
    static func section(at relativePosition: Double, position: Double, frame: Frame, settings: Settings,
                        sample: (SIMD3<Double>) -> Float) -> Section {
        let size = 2 * Int((settings.maxRadius / settings.pixel).rounded()) + 1
        let c = size / 2
        let (xAxis, yAxis) = frame.axes
        var values = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            let v = Double(y - c) * settings.pixel
            for x in 0..<size {
                let u = Double(x - c) * settings.pixel
                values[y * size + x] = sample(frame.point + u * xAxis + v * yAxis)
            }
        }
        guard let (mask, centerValue) = segment(values: values, size: size, settings: settings) else {
            return Section(position: position, relativePosition: relativePosition, area: 0, minDiameter: 0, centerValue: 0, contour: [])
        }
        let pixelArea = settings.pixel * settings.pixel
        let area = Double(mask.reduce(0) { $0 + ($1 ? 1 : 0) }) * pixelArea
        let contour = outline(of: mask, size: size).map { frame.point + $0.x * settings.pixel * xAxis + $0.y * settings.pixel * yAxis }
        return Section(position: position, relativePosition: relativePosition, area: area,
                       minDiameter: minimumWidth(of: mask, size: size) * settings.pixel, centerValue: centerValue, contour: contour)
    }

    /// The sections of the stretch between two relative positions of a path
    /// `length` mm long, every `settings.step` mm, both ends included.
    static func sections(from start: Double, to end: Double, length: Double, settings: Settings,
                         frame: (Double) -> Frame, sample: (SIMD3<Double>) -> Float) -> [Section] {
        let (a, b) = (min(start, end), max(start, end))
        let stretch = (b - a) * length
        guard stretch > 0, length > 0 else { return [] }
        let count = Int((stretch / settings.step).rounded(.down)) + 1
        return (0..<count).map { i in
            let position = min(Double(i) * settings.step, stretch)
            let relative = a + position / length
            return section(at: relative, position: position, frame: frame(relative), settings: settings, sample: sample)
        }
    }

    // MARK: - The stretch

    /// The default reference: the distal end of the stretch, a quarter of it,
    /// between 2 and 10 mm. In mm from the start.
    static func defaultReference(stretch: Double) -> ClosedRange<Double> {
        let width = min(max(stretch / 4, 2), 10, stretch)
        return (stretch - width)...stretch
    }

    struct Result: Equatable {
        var minimumArea: Double
        /// From the start of the stretch, in mm.
        var minimumPosition: Double
        var minimumIndex: Int
        /// The mean area of the reference sections.
        var referenceArea: Double
        /// The mean area of the whole stretch.
        var meanArea: Double
        /// (1 − A_min / A_ref) × 100.
        var nascetByArea: Double
        /// The smallest minimum diameter of the stretch, in mm.
        var minimumDiameter: Double
        /// √(4 A_min / π), in mm.
        var equivalentDiameter: Double
        /// The mean minimum diameter of the reference sections, in mm.
        var referenceDiameter: Double
        /// (1 − D_min / D_ref) × 100.
        var nascetByDiameter: Double
    }

    /// The degree of the stretch; nil without a valid section in the stretch
    /// and in the reference.
    static func result(of sections: [Section], reference: ClosedRange<Double>) -> Result? {
        let valid = sections.indices.filter { sections[$0].isValid }
        let referenceSections = valid.filter { reference.contains(sections[$0].position) }.map { sections[$0] }
        guard let minimumIndex = valid.min(by: { sections[$0].area < sections[$1].area }), !referenceSections.isEmpty else { return nil }
        let minimum = sections[minimumIndex]
        let referenceArea = referenceSections.map(\.area).reduce(0, +) / Double(referenceSections.count)
        let referenceDiameter = referenceSections.map(\.minDiameter).reduce(0, +) / Double(referenceSections.count)
        let minimumDiameter = valid.map { sections[$0].minDiameter }.min() ?? 0
        let meanArea = valid.map { sections[$0].area }.reduce(0, +) / Double(valid.count)
        return Result(minimumArea: minimum.area, minimumPosition: minimum.position, minimumIndex: minimumIndex,
                      referenceArea: referenceArea, meanArea: meanArea,
                      nascetByArea: referenceArea > 0 ? (1 - minimum.area / referenceArea) * 100 : 0,
                      minimumDiameter: minimumDiameter, equivalentDiameter: minimum.equivalentDiameter,
                      referenceDiameter: referenceDiameter,
                      nascetByDiameter: referenceDiameter > 0 ? (1 - minimumDiameter / referenceDiameter) * 100 : 0)
    }

    // MARK: - Masks

    /// The pixel of the mask nearest to `pixel` within `within` pixels.
    private static func nearest(in mask: [Bool], size: Int, to pixel: Int, within: Int) -> Int? {
        if mask[pixel] { return pixel }
        let (px, py) = (pixel % size, pixel / size)
        var best: (Int, Int)? = nil
        for y in max(py - within, 0)...min(py + within, size - 1) {
            for x in max(px - within, 0)...min(px + within, size - 1) where mask[y * size + x] {
                let d = (x - px) * (x - px) + (y - py) * (y - py)
                if d <= within * within && (best == nil || d < best!.1) { best = (y * size + x, d) }
            }
        }
        return best?.0
    }

    /// The pixels of the mask 4-connected to `start`.
    static func component(of mask: [Bool], size: Int, from start: Int) -> [Bool] {
        var result = [Bool](repeating: false, count: mask.count)
        guard mask[start] else { return result }
        var stack = [start]
        result[start] = true
        while let p = stack.popLast() {
            let (x, y) = (p % size, p / size)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < size && ny < size {
                let n = ny * size + nx
                if mask[n] && !result[n] { result[n] = true; stack.append(n) }
            }
        }
        return result
    }

    /// Adds to the mask what it encloses: the pixels outside it that the
    /// grid's border cannot reach.
    static func fillHoles(_ mask: inout [Bool], size: Int) {
        var outside = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        for i in 0..<size {
            for p in [i, (size - 1) * size + i, i * size, i * size + size - 1] where !mask[p] && !outside[p] {
                outside[p] = true; stack.append(p)
            }
        }
        while let p = stack.popLast() {
            let (x, y) = (p % size, p / size)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < size && ny < size {
                let n = ny * size + nx
                if !mask[n] && !outside[n] { outside[n] = true; stack.append(n) }
            }
        }
        for i in mask.indices where !outside[i] { mask[i] = true }
    }

    /// For each pixel of the mask, the distance in pixels to the nearest pixel
    /// outside it (0 outside), by the 3-4 chamfer, which stays within a few
    /// percent of the Euclidean distance.
    static func distanceTransform(_ mask: [Bool], size: Int) -> [Double] {
        let far = Int.max / 4
        var d = mask.map { $0 ? far : 0 }
        func at(_ x: Int, _ y: Int) -> Int { (x < 0 || y < 0 || x >= size || y >= size) ? 0 : d[y * size + x] }
        for y in 0..<size {
            for x in 0..<size where d[y * size + x] > 0 {
                d[y * size + x] = min(d[y * size + x], at(x - 1, y) + 3, at(x, y - 1) + 3, at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4)
            }
        }
        for y in stride(from: size - 1, through: 0, by: -1) {
            for x in stride(from: size - 1, through: 0, by: -1) where d[y * size + x] > 0 {
                d[y * size + x] = min(d[y * size + x], at(x + 1, y) + 3, at(x, y + 1) + 3, at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4)
            }
        }
        return d.map { Double($0) / 3 }
    }
}
