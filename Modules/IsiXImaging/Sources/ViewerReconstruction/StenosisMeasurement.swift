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
/// Each section is first segmented from its own centerline alone, between
/// two shares of the intensity there (see `lumen(values:size:settings:struts:)`).
/// The ring of a stent's struts and what lies beyond it stay out of it where
/// the sections around show the ring too, so the neointima of a restenosis
/// inside the stent is no longer enclosed (see
/// `strutRing(values:size:settings:center:contrast:)`); wider tissue darker than the
/// lumen's edge that the lumen surrounds, such as a thrombus, stays out too,
/// and narrower neointima where a section misses the ring the sections
/// around show.
/// Calcified plaque is then taken out of that lumen, never added to it: the
/// calcium the lumen encloses, and the lumen within a margin of calcium. A
/// section without calcium keeps the lumen its centerline finds, whatever
/// the rest of the stretch is, so the calcium never changes the lumen of a
/// vessel where there is none. Calcium dimmer than the limit stays in the
/// lumen; what the limit cannot tell apart is erased by hand, section by
/// section, and the erasure too only takes lumen away.
///
/// Nothing here knows the application: the path, the volume and the settings
/// come in as values, so a synthetic volume measures the same way a CT does.
public enum Stenosis {

    /// Where the measure walks, in patient space (mm): the point of the
    /// centerline, its tangent and the normal of the transverse sections at a
    /// relative position, as the curved MPR's transverse views take them.
    public struct Frame: Equatable, Sendable {
        public var point: SIMD3<Double>
        public var tangent: SIMD3<Double>
        public var normal: SIMD3<Double>

        public init(point: SIMD3<Double>, tangent: SIMD3<Double>, normal: SIMD3<Double>) {
            self.point = point
            self.tangent = tangent
            self.normal = normal
        }

        /// The in-plane axes of the section: x across, y along the normal.
        public var axes: (x: SIMD3<Double>, y: SIMD3<Double>) {
            let x = simd_normalize(simd_cross(tangent, normal))
            let y = simd_normalize(simd_cross(x, tangent))
            return (x, y)
        }
    }

    public struct Settings: Equatable, Sendable {
        /// Between two sections along the centerline, in mm.
        public var step = 0.5
        /// The in-plane sampling of a section, in mm.
        public var pixel = 0.1
        /// No lumen reaches farther than this from the centerline, in mm: the
        /// jugular or the external carotid beyond it are left out.
        public var maxRadius = 8.0
        /// The lumen is what lies between these fractions of the intensity at
        /// the centerline of each section: the lower one is the edge (half of
        /// it, the half maximum against soft tissue near 0 HU), the upper one
        /// the calcium limit, which leaves out the calcium, much brighter than
        /// the contrast.
        public var lowerFraction = 0.5
        /// Calcium is what is brighter than this share of the intensity at
        /// the centerline of its section and than the same share of the
        /// contrast of the reference (see `calcium(values:size:settings:center:contrast:)`):
        /// a centerline dimmed by the partial volume of a tight lumen, by
        /// contrast that fades along the vessel or by the wall it runs on
        /// would take the brighter middle of its own lumen for calcium. The
        /// blooming of calcium brightens the centerline of a tight lumen
        /// beside it, and the share of that centerline with it: calcium
        /// dimmer than it stays in the lumen. Both fractions follow the
        /// contrast of each exam, and mean the same on a series that is not
        /// in HU.
        public var upperFraction = 1.6
        /// The calcium limits the tool offers. Below 130 % of the contrast,
        /// the noise of a CT inside a lumen without calcium reaches the limit.
        public static let calciumLimits: ClosedRange<Double> = 1.3...2.0
        /// The lumen this close to calcium is left out with it, in mm: next to
        /// calcium the samples between the contrast and the limit are its
        /// partial volume and its blooming. Where there is no calcium, it
        /// changes nothing. It is off until asked for: beside dense calcium
        /// the limit alone already falls inside the lumen, and the margin
        /// would take a rim of it.
        public var calciumMargin = 0.0
        /// Samples brighter than the calcium limit are calcium where they
        /// make a region at least this large, in mm². The noise of a CT lifts
        /// samples of a lumen without calcium above the limit in specks
        /// smaller than this; calcium beside a tight lumen, and its blooming
        /// above the limit, make a larger region.
        public var smallestCalcium = 0.5
        /// Below this at the centerline there is no contrast-filled lumen
        /// there (the path runs through the wall or beside the vessel), in
        /// HU: the section is left out rather than measured on soft tissue.
        public var minimumLumenValue: Float = 150
        /// A neighbouring vessel that touches the lumen joins it through a neck
        /// narrower than twice this, in mm: opening the mask by it cuts the neck.
        /// Tissue darker than the lumen's edge that the lumen surrounds stays
        /// out of it where it is wider than three times this, with the edge at
        /// half of the centerline or lower; the specks of a lumen that the
        /// noise drops below such an edge are narrower (see
        /// `tissueRadius(neck:lowerFraction:ringMissed:)` for higher edges,
        /// and for a section in a stent whose ring it misses).
        public var neck = 0.5

        /// The vessel the three limits that follow its size are those of:
        /// `maxRadius`, `minimumLumenValue` and `neck`. The edge of the lumen,
        /// the calcium limit and its margin are shares of each exam's
        /// contrast and stay as they were set.
        public private(set) var vessel = Vessel.carotid
        /// With these, each section also measures the vessel around its
        /// lumen, out to the fat, and the plaque between the two (see
        /// `wall(values:size:lumen:settings:limits:)`). A coronary artery
        /// takes them with its limits; without them nothing but the lumen is
        /// measured.
        public var plaque: PlaqueLimits?

        public init() {}

        public init(vessel: Vessel) { measure(as: vessel) }

        /// Takes the limits of `vessel`.
        ///
        /// A carotid: a lumen up to 8 mm from the centerline (the bulb), a
        /// centerline of 150 HU or more, necks under 1 mm cut.
        ///
        /// A coronary artery: the left main, the widest, is 4 to 5 mm
        /// across, and the great cardiac vein, the appendage and the
        /// ventricle lie a few millimetres from the arteries, so nothing
        /// farther than 4 mm from the centerline is lumen. Its lumen is 1 to
        /// 4 mm across, and the partial volume of a CT dims the middle of
        /// the narrow ones: the centerline has contrast from 130 HU, the
        /// upper limit of plaque without calcium, which a path through the
        /// wall reads. A neck is cut under 0.6 mm: a side branch that leaves
        /// the lumen is that narrow where a carotid's neighbour is twice it,
        /// and the opening that cuts a wider neck would take a tight lumen
        /// with it.
        public mutating func measure(as vessel: Vessel) {
            self.vessel = vessel
            switch vessel {
            case .carotid: (maxRadius, minimumLumenValue, neck, plaque) = (8.0, 150, 0.5, nil)
            case .coronary: (maxRadius, minimumLumenValue, neck, plaque) = (4.0, 130, 0.3, plaque ?? PlaqueLimits())
            }
        }
    }

    /// The vessel a stretch is measured as (see `Settings.measure(as:)`). A
    /// coronary artery tapers along a stretch and is measured against a
    /// reference on each side of the narrowing (see
    /// `result(of:proximal:distal:)`), and its degree is read by diameter.
    public enum Vessel: String, Sendable, CaseIterable {
        case carotid, coronary
    }

    /// What was erased by hand from the lumen of one section: a stroke of a
    /// round eraser, as the points it passed through, in patient space, and
    /// its radius, in mm. In patient space it stays where the plaque is when
    /// the section is segmented again with other settings.
    public struct Erasure: Equatable, Sendable {
        public var points: [SIMD3<Double>]
        public var radius: Double

        public init(points: [SIMD3<Double>], radius: Double) {
            self.points = points
            self.radius = radius
        }
    }

    /// What took the whole lumen of a section whose centerline has contrast.
    public enum LumenTaken: Equatable, Sendable {
        /// The calcium the lumen enclosed and the margin around calcium.
        case byCalcium
        /// The eraser, from what the calcium had left.
        case byHand
    }

    /// One transverse section of the lumen.
    public struct Section: Sendable {
        /// From the start of the stretch, in mm.
        public var position: Double
        /// On the whole centerline, 0 to 1.
        public var relativePosition: Double
        /// Where the section was taken.
        public var frame: Frame
        /// In mm²; 0 when no lumen was found, or when none of it was left.
        public var area: Double
        /// The smallest width of the lumen over all directions (its minimum
        /// Feret diameter), in mm.
        public var minDiameter: Double
        /// The intensity the thresholds were taken from.
        public var centerValue: Float
        /// The contrast of the reference, which calcium has to be brighter
        /// than a share of too, or the section's own center when it was
        /// measured without one, and no calcium was told.
        public var contrast: Float = 0
        /// The lumen's outline, in patient space, for drawing: it holds all
        /// of the lumen (see `outline(of:size:)`).
        public var contour: [SIMD3<Double>]
        /// The outlines of what the lumen surrounds but leaves out, inside
        /// `contour`, in patient space, for drawing with it: tissue darker
        /// than its edge, calcium, what was erased (see `holeOutlines(of:size:)`).
        public var holeContours: [[SIMD3<Double>]] = []
        /// Whether part of the lumen was erased by hand: the area and the
        /// diameter are then those of what was left.
        public var corrected = false
        /// What took the whole lumen, when a lumen was found there and none
        /// of it was left: the section is then not valid, as one without
        /// contrast is not, but it is not one without contrast.
        public var lumenTaken: LumenTaken?
        /// Whether calcium touched the lumen, or was taken out of it. Where
        /// none did, plaque dimmer than the limit stays in the area.
        public var calciumBeside = false
        /// Whether the sections around show the ring of a stent's struts and
        /// this one does not (`Struts.Verdict.missed`): the end of a stent,
        /// where the struts fade, a ring too blurred, or the first section
        /// past the stent. Its lumen is the threshold's, and may hold the
        /// struts and their blur.
        public var strutRingMissed = false
        /// Whether the stretch the section was measured in holds a stent (see
        /// `Struts.holdsStent(_:places:blurred:)`), which lets its sections
        /// be read as a wider blur leaves a ring: a section measured again
        /// alone is read as its stretch was.
        public var stretchHoldsStent = false
        /// The vessel around the lumen and its plaque, when the section was
        /// measured with plaque limits and its vessel has an outer wall.
        public var wall: Wall?

        public var isValid: Bool { area > 0 }
        /// The diameter of the circle of the same area, √(4A/π).
        public var equivalentDiameter: Double { (4 * area / .pi).squareRoot() }
    }

    // MARK: - One section

    /// The intensity at the center of a square grid of `size` × `size`
    /// samples: the median of the 5 × 5 samples around it, against noise.
    public static func centerValue(of values: [Float], size: Int) -> Float {
        median(of: values, size: size, around: (size / 2) * size + size / 2)
    }

    /// The median of the 5 × 5 samples around a pixel of a square grid of
    /// `size` × `size` samples, those of them the grid holds.
    static func median(of values: [Float], size: Int, around pixel: Int) -> Float {
        let (px, py) = (pixel % size, pixel / size)
        var around: [Float] = []
        for y in max(py - 2, 0)...min(py + 2, size - 1) {
            for x in max(px - 2, 0)...min(px + 2, size - 1) { around.append(values[y * size + x]) }
        }
        around.sort()
        return around[around.count / 2]
    }

    /// The intensity in the middle of the lumen a section's centerline
    /// finds: the median of the 5 × 5 samples around the pixel of that lumen
    /// farthest from its edge, or the intensity at the centerline when that
    /// is brighter; nil when the section has no lumen. A centerline that runs
    /// near the wall of its lumen is dimmed by the partial volume of the
    /// wall; the middle of the lumen is not. The lumen is grown as
    /// `lumen(values:size:settings:contrast:)` grows it, without the upper limit:
    /// from a centerline on the wall of a wide lumen, the upper share of its
    /// dimmed intensity leaves the middle out, and the rim left can be
    /// narrower than the neck. Calcium or bone that joins the lumen only
    /// makes the intensity brighter, and less calcium is told.
    static func middleValue(values: [Float], size: Int, settings: Settings) -> Float? {
        var whole = settings
        whole.upperFraction = .infinity
        guard let found = lumen(values: values, size: size, settings: whole) else { return nil }
        let depth = distanceTransform(found.mask, size: size)
        var deepest = found.seed
        for i in depth.indices where depth[i] > depth[deepest] { deepest = i }
        return max(found.centerValue, median(of: values, size: size, around: deepest))
    }

    /// A lumen as `lumen(values:size:settings:struts:)` finds it: the mask, the
    /// intensity at the center and the pixel it was grown from.
    typealias Lumen = (mask: [Bool], centerValue: Float, seed: Int)

    /// The lumen as the section's own centerline finds it, short of the ring
    /// of a stent's struts that the section alone shows (see
    /// `strutRing(values:size:settings:contrast:)`); `contrast` is the
    /// contrast of the reference, when there is one.
    static func lumen(values: [Float], size: Int, settings: Settings, contrast: Float? = nil) -> Lumen? {
        lumen(values: values, size: size, settings: settings,
              struts: strutRing(values: values, size: size, settings: settings, contrast: contrast).map { .told($0) } ?? .none)
    }

    /// The lumen as the section's own centerline finds it, in a square grid
    /// of `size` × `size` samples, row after row, centered on the
    /// centerline: what lies between the lower and the upper fraction of the
    /// intensity at the center, within `maxRadius` and short of the ring of
    /// a stent's struts and what lies beyond it where `struts` tells one
    /// (see `strutRing(values:size:settings:center:contrast:)`), grown from
    /// the center, opened by the neck, with what it encloses but wide tissue
    /// darker than its edge (see `fillHoles(_:size:values:edge:tissueRadius:seed:)`),
    /// narrower where `struts` says the section misses its ring.
    /// Returns the mask, the intensity at the center and the pixel the lumen
    /// was grown from; nil when the center has no contrast, or no lumen lies
    /// within a millimetre of it. Nothing else decides what the lumen is: the
    /// calcium and the eraser only take pixels out of this mask.
    static func lumen(values: [Float], size: Int, settings: Settings, struts: Struts.Verdict) -> Lumen? {
        let beyondStruts: [Bool]?
        if case .told(let beyond) = struts { beyondStruts = beyond } else { beyondStruts = nil }
        let c = size / 2
        let pixelsPerMM = 1 / settings.pixel
        let radius = settings.maxRadius * pixelsPerMM
        let center = centerValue(of: values, size: size)
        guard center >= settings.minimumLumenValue, center > 0 else { return nil }
        let lower = Float(settings.lowerFraction) * center, upper = Float(settings.upperFraction) * center

        var inside = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x - c), dy = Double(y - c)
                let v = values[y * size + x]
                inside[y * size + x] = dx * dx + dy * dy <= radius * radius && v >= lower && v <= upper
                    && !(beyondStruts?[y * size + x] ?? false)
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
        fillHoles(&lumen, size: size, values: values, edge: lower,
                  tissueRadius: tissueRadius(neck: neck, lowerFraction: settings.lowerFraction, ringMissed: struts == .missed), seed: seed)
        return (lumen, center, seed)
    }

    /// The radius, in the unit of `neck`, of the disc that tissue darker than
    /// the lumen's edge holds and the noise of a CT does not: one and a half
    /// times the neck while the edge is at most half of the intensity at the
    /// centerline. The nearer the edge comes to that intensity, the larger
    /// the specks the noise drops below it inside a lumen, and they merge:
    /// above half, the radius grows with the cube of 0.5 / (1 − `lowerFraction`).
    /// The neointima of a restenosis is no hole of the lumen once the ring of
    /// the struts is out (see `strutRing(values:size:settings:center:contrast:)`), so
    /// the disc is that of a thrombus or of soft plaque the lumen surrounds,
    /// 1.5 mm across: in lumens of 1.5 to 6 mm at 220 to 400 HU, in the noise
    /// of a CT of 30 to 80 HU over 0.5 to 1.5 mm, the specks stay under it
    /// at every edge from 50 to 80 %, but in a lumen of 6 mm at 220 HU in
    /// 80 HU of noise over 1.5 mm, at 50 and 55 %, which loses 4 to 6 % of
    /// its area. Tissue narrower than that stays in the lumen, as it did
    /// before any was left out. In a section of a stent whose ring is
    /// `ringMissed` (the sections around show it, the section does not), the
    /// ring and its blur stay in the lumen and enclose the neointima of a
    /// restenosis, narrower than that disc: there the radius is a third of
    /// it, half the neck, so the neointima more than 0.5 mm across stays out
    /// and such a section reads no more than the ring alone makes it.
    static func tissueRadius(neck: Double, lowerFraction: Double, ringMissed: Bool = false) -> Double {
        let nearness = 0.5 / max(1 - lowerFraction, 0.05)
        return neck * (ringMissed ? 0.5 : 1.5) * max(1, nearness * nearness * nearness)
    }

    /// The calcium of a section whose centerline is `center` bright, or nil
    /// when it has none, or when there is no `contrast`, the contrast of the
    /// reference (see `contrast(of:settings:sample:)`), to tell it by.
    ///
    /// Calcium is a region, 8-connected, of at least
    /// `Settings.smallestCalcium`, of samples brighter than the upper
    /// fraction of `center`, which the lumen of the section already stops
    /// at, and than the same fraction of `contrast`: by the share of its own
    /// centerline alone, a section dimmed by the partial volume of a tight
    /// lumen, by contrast that fades along the vessel or by a centerline on
    /// its wall would take the middle of its lumen, or its noise, for
    /// calcium. With each region goes what is 8-connected to it among the
    /// samples brighter than the share of `center`: its partial volume,
    /// which the lumen of the section stops at too.
    ///
    /// What the share cannot tell from calcium is calcium by this rule too.
    /// A lumen brighter than the share of the reference is, where its own
    /// centerline is dimmer than its middle and its lumen encloses that
    /// middle: a centerline on the wall of a lumen a fifth brighter than the
    /// reference, at the lowest limit and in the noise of a CT, can lose the
    /// middle of its lumen; at 160 %, a lumen two fifths brighter. Contrast
    /// brighter than the share beside the lumen, a chamber or a brighter
    /// vessel within a few tenths of a millimetre, is too: the lumen is then
    /// told to touch calcium, and a margin takes a rim of it there.
    ///
    /// Calcium dimmer than the share of `center` is not calcium here, and
    /// stays in the lumen until it is erased by hand: the blooming of a
    /// plaque brightens a centerline that runs near it, and the share of
    /// that centerline with it.
    static func calcium(values: [Float], size: Int, settings: Settings, center: Float, contrast: Float?) -> [Bool]? {
        guard let contrast else { return nil }
        let c = size / 2
        let pixelsPerMM = 1 / settings.pixel
        let radius = settings.maxRadius * pixelsPerMM
        let fraction = Float(settings.upperFraction)
        let own = fraction * center, limit = fraction * max(center, contrast)
        var bright = [Bool](repeating: false, count: size * size), above = bright
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x - c), dy = Double(y - c)
                guard dx * dx + dy * dy <= radius * radius else { continue }
                let v = values[y * size + x]
                bright[y * size + x] = v > own
                above[y * size + x] = v > limit
            }
        }
        let calcium = Self.regions(of: above, size: size, atLeast: Int((settings.smallestCalcium * pixelsPerMM * pixelsPerMM).rounded()))
        guard calcium.contains(true) else { return nil }
        return reach(of: calcium, through: bright, size: size)
    }

    /// The lumen in a square grid of `size` × `size` samples, row after row,
    /// centered on the centerline. Returns the mask, the intensity at the
    /// center, when a lumen was found and none of it was left, what took it,
    /// whether calcium touched the lumen or was taken out of it, and whether
    /// `erased` took a pixel of it; nil when the center has no contrast.
    ///
    /// The lumen is the one the section's own centerline finds (see
    /// `lumen(values:size:settings:contrast:)`). Without calcium (see
    /// `calcium(values:size:settings:center:contrast:)`), or without
    /// `contrast`, the contrast of the reference, that is the lumen. With
    /// calcium, the calcium the lumen encloses and the lumen within
    /// `Settings.calciumMargin` of calcium leave it.
    /// `erased`, a grid of the same size or none, is what was erased by
    /// hand, and leaves it too. What either cuts off from the part nearest to
    /// the pixel the lumen was grown from leaves with them. Neither ever adds
    /// a pixel: the lumen is never larger than the centerline alone finds it.
    /// A lumen taken whole is an empty mask.
    public static func segment(values: [Float], size: Int, settings: Settings, contrast: Float? = nil,
                               erased: [Bool] = []) -> Segmentation? {
        lumen(values: values, size: size, settings: settings, contrast: contrast).map {
            segment($0, values: values, size: size, settings: settings, contrast: contrast, erased: erased)
        }
    }

    public typealias Segmentation = (mask: [Bool], centerValue: Float, lumenTaken: LumenTaken?, calciumBeside: Bool, erasedSome: Bool)

    /// The lumen `found` in the grid `values`, less the calcium and what was erased.
    private static func segment(_ found: Lumen, values: [Float], size: Int, settings: Settings, contrast: Float?,
                                erased: [Bool]) -> Segmentation {
        var mask = found.mask
        // The calcium the lumen encloses, which only filling its holes put
        // back, and the margin around calcium: what lies between the contrast
        // and the limit beside it is the calcium's own edge, not lumen.
        var cut = false, beside = false
        if let calcium = Self.calcium(values: values, size: size, settings: settings, center: found.centerValue, contrast: contrast) {
            // In pixels, with room for the residue of the division: a margin
            // of 0.3 mm reaches the pixels 3 away.
            let margin = settings.calciumMargin > 0 ? settings.calciumMargin / settings.pixel + 1e-6 : 0
            let toCalcium = margin > 0 ? distanceTransform(calcium.map { !$0 }, size: size, borderIsOutside: false) : []
            for i in mask.indices where mask[i] && (calcium[i] || (margin > 0 && toCalcium[i] <= margin)) {
                mask[i] = false
                cut = true
            }
            beside = cut || touches(found.mask, calcium, size: size)
        }
        let takenByCalcium = cut && !mask.contains(true)
        var erasedSome = false
        if erased.count == mask.count {
            for i in mask.indices where mask[i] && erased[i] {
                mask[i] = false
                erasedSome = true
            }
        }
        if cut || erasedSome, let kept = nearest(in: mask, size: size, to: found.seed, within: size) {
            mask = component(of: mask, size: size, from: kept)
        }
        let taken: LumenTaken? = takenByCalcium ? .byCalcium : erasedSome && !mask.contains(true) ? .byHand : nil
        return (mask, found.centerValue, taken, beside, erasedSome)
    }

    /// The grid of a section with the samples its erasures cover: each stroke
    /// is the discs of its radius along the lines between its points, taken
    /// onto the section's plane.
    public static func erasedMask(_ erasures: [Erasure], frame: Frame, size: Int, pixel: Double) -> [Bool] {
        var mask = [Bool](repeating: false, count: size * size)
        let c = Double(size / 2)
        let (xAxis, yAxis) = frame.axes
        for erasure in erasures {
            let radius = erasure.radius / pixel
            let points = erasure.points.map { p -> SIMD2<Double> in
                let d = p - frame.point
                return SIMD2(simd_dot(d, xAxis) / pixel + c, simd_dot(d, yAxis) / pixel + c)
            }
            guard let first = points.first else { continue }
            for (a, b) in zip([first] + points, points) {
                let low = simd_min(a, b) - SIMD2(repeating: radius), high = simd_max(a, b) + SIMD2(repeating: radius)
                let (x0, x1) = (max(Int(low.x.rounded(.down)), 0), min(Int(high.x.rounded(.up)), size - 1))
                let (y0, y1) = (max(Int(low.y.rounded(.down)), 0), min(Int(high.y.rounded(.up)), size - 1))
                guard x0 <= x1, y0 <= y1 else { continue }
                let ab = b - a
                let squared = simd_dot(ab, ab)
                for y in y0...y1 {
                    for x in x0...x1 {
                        let p = SIMD2(Double(x), Double(y))
                        let u = squared > 0 ? min(max(simd_dot(p - a, ab) / squared, 0), 1) : 0
                        if simd_length_squared(p - (a + u * ab)) <= radius * radius { mask[y * size + x] = true }
                    }
                }
            }
        }
        return mask
    }

    /// The smallest width of a mask over directions every 2°, in pixels: the
    /// distance between the outermost pixel centers on each direction.
    public static func minimumWidth(of mask: [Bool], size: Int) -> Double {
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

    /// The outline of a mask, one point every 2°: along each ray, the last
    /// lumen pixel before the first one outside, past the holes of the mask
    /// (see `holeOutlines(of:size:)`): the outline holds all of the lumen,
    /// and what the lumen surrounds but leaves out is drawn by the outlines
    /// of its holes. The rays leave from the center of the grid, or, when the
    /// center is not lumen (erased by hand, say), from the lumen pixel
    /// nearest to the lumen's centroid. In pixels from the center of the grid.
    public static func outline(of mask: [Bool], size: Int) -> [SIMD2<Double>] {
        let outside = Self.outside(of: mask, size: size)
        let c = Double(size / 2)
        var origin = SIMD2(c, c)
        if !mask[(size / 2) * size + size / 2] {
            var sum = SIMD2<Double>(0, 0), count = 0.0
            for y in 0..<size { for x in 0..<size where mask[y * size + x] { sum += SIMD2(Double(x), Double(y)); count += 1 } }
            guard count > 0 else { return [] }
            let centroid = sum / count
            let at = Int(centroid.y.rounded()) * size + Int(centroid.x.rounded())
            guard let pixel = nearest(in: mask, size: size, to: at, within: size) else { return [] }
            origin = SIMD2(Double(pixel % size), Double(pixel / size))
        }
        var points: [SIMD2<Double>] = []
        for step in 0..<180 {
            let angle = Double(step) * .pi / 90
            let direction = SIMD2(cos(angle), sin(angle))
            var last = 0.0
            var r = 0.0
            while r < 2 * c {
                let x = Int((origin.x + r * direction.x).rounded()), y = Int((origin.y + r * direction.y).rounded())
                if x < 0 || y < 0 || x >= size || y >= size || outside[y * size + x] { break }
                if mask[y * size + x] { last = r }
                r += 0.5
            }
            points.append(origin - SIMD2(c, c) + direction * (last + 0.5))
        }
        return points
    }

    /// The outlines of the holes of a mask, what it encloses without holding
    /// it: tissue darker than the lumen's edge, calcium the lumen surrounds,
    /// what was erased inside it. Each is a closed polygon along the sides of
    /// the pixels between a hole and the mask, so the area it encloses is
    /// the hole's own; where two pixels of holes touch only at a corner, they
    /// are two holes. In pixels from the center of the grid.
    public static func holeOutlines(of mask: [Bool], size: Int) -> [[SIMD2<Double>]] {
        let outside = Self.outside(of: mask, size: size)
        let hole = mask.indices.map { !mask[$0] && !outside[$0] }
        guard hole.contains(true) else { return [] }
        func isHole(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < size && y < size && hole[y * size + x] }
        // The sides between a hole pixel and a neighbour out of the hole, each
        // going round the pixel so that the hole lies on its left. Pixel
        // (x, y) has its corners at (x, y) to (x + 1, y + 1) on a grid of
        // corners size + 1 wide.
        let corners = size + 1
        var sides: [(from: Int, to: Int, step: SIMD2<Int>)] = []
        var leaving: [Int: [Int]] = [:]
        for y in 0..<size {
            for x in 0..<size where hole[y * size + x] {
                let around = [((x, y - 1), (x, y), (x + 1, y)), ((x + 1, y), (x + 1, y), (x + 1, y + 1)),
                              ((x, y + 1), (x + 1, y + 1), (x, y + 1)), ((x - 1, y), (x, y + 1), (x, y))]
                for (neighbour, a, b) in around where !isHole(neighbour.0, neighbour.1) {
                    leaving[a.1 * corners + a.0, default: []].append(sides.count)
                    sides.append((a.1 * corners + a.0, b.1 * corners + b.0, SIMD2(b.0 - a.0, b.1 - a.1)))
                }
            }
        }
        let c = Double(size / 2)
        func point(_ corner: Int) -> SIMD2<Double> {
            SIMD2(Double(corner % corners) - 0.5 - c, Double(corner / corners) - 0.5 - c)
        }
        var used = [Bool](repeating: false, count: sides.count)
        var outlines: [[SIMD2<Double>]] = []
        for start in sides.indices where !used[start] {
            var polygon: [SIMD2<Double>] = []
            var current = start
            var previous: SIMD2<Int>? = nil
            while true {
                used[current] = true
                let side = sides[current]
                if side.step != previous { polygon.append(point(side.from)) }
                previous = side.step
                if side.to == sides[start].from { break }
                // At a corner two holes touch, turn toward the pixel the side
                // went along, which keeps each hole to itself.
                let left = SIMD2(-side.step.y, side.step.x)
                let next = (leaving[side.to] ?? []).filter { !used[$0] }
                guard let chosen = next.first(where: { sides[$0].step == left })
                        ?? next.first(where: { sides[$0].step == side.step }) ?? next.first else { break }
                current = chosen
            }
            outlines.append(polygon)
        }
        return outlines
    }

    /// The size of the square grid a section is sampled on, in samples.
    static func gridSize(_ settings: Settings) -> Int { 2 * Int((settings.maxRadius / settings.pixel).rounded()) + 1 }

    /// The grid of a section, `gridSize(settings)` samples a side, row after
    /// row, centered on the frame's point.
    static func grid(at frame: Frame, settings: Settings, sample: (SIMD3<Double>) -> Float) -> [Float] {
        let size = gridSize(settings)
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
        return values
    }

    /// The contrast calcium has to be brighter than a share of: the median,
    /// over the sections at `frames` that have a lumen, of the intensity in
    /// the middle of that lumen (see `middleValue(values:size:settings:)`);
    /// nil when none has. Taken on the reference, the healthy lumen NASCET
    /// compares with, it moves neither with the blooming of calcium beside
    /// tight sections nor with the partial volume that dims them, however
    /// much of the stretch they are, nor with a centerline that runs near
    /// the wall of the reference. Plaque in the reference only raises it, and
    /// less calcium is then told.
    public static func contrast(of frames: [Frame], settings: Settings, sample: (SIMD3<Double>) -> Float) -> Float? {
        let size = gridSize(settings)
        return median(frames.compactMap { middleValue(values: grid(at: $0, settings: settings, sample: sample), size: size, settings: settings) })
    }

    private static func median(_ values: [Float]) -> Float? {
        let sorted = values.sorted()
        return sorted.isEmpty ? nil : sorted[sorted.count / 2]
    }

    /// Measures the section at a relative position of the path, less what
    /// `erasures` took out of its lumen by hand. Calcium has to be brighter
    /// than the share of `contrast`, the contrast of the reference, too;
    /// without one, no calcium is told, and the lumen is the one the
    /// section's centerline finds. The ring of a stent's struts is the one
    /// this section alone shows; a stretch tells it along the vessel (see
    /// `sections(at:settings:reference:contrast:sample:)` and
    /// `section(_:of:settings:contrast:sample:)`).
    public static func section(at relativePosition: Double, position: Double, frame: Frame, settings: Settings,
                               contrast: Float? = nil, erasures: [Erasure] = [], sample: (SIMD3<Double>) -> Float) -> Section {
        let values = grid(at: frame, settings: settings, sample: sample)
        let ring = strutRing(values: values, size: gridSize(settings), settings: settings, contrast: contrast)
        return section(Place(position: position, relativePosition: relativePosition, frame: frame, erasures: erasures), values: values,
                       struts: ring.map { .told($0) } ?? .none, settings: settings, contrast: contrast)
    }

    /// The section at `place`, from its grid, `values`, and `struts`, the
    /// ring of a stent's struts there and what lies beyond it, as the
    /// sections around tell it (see `Struts.Verdict`).
    /// It is corrected by hand when its erasures took a pixel of its lumen: a
    /// stroke beside the lumen changes nothing, and does not mark the numbers.
    private static func section(_ place: Place, values: [Float], struts: Struts.Verdict, settings: Settings, contrast: Float?) -> Section {
        let size = gridSize(settings)
        let (xAxis, yAxis) = place.frame.axes
        let erased = place.erasures.contains { !$0.points.isEmpty }
            ? erasedMask(place.erasures, frame: place.frame, size: size, pixel: settings.pixel) : []
        guard let grown = lumen(values: values, size: size, settings: settings, struts: struts) else {
            return Section(position: place.position, relativePosition: place.relativePosition, frame: place.frame, area: 0, minDiameter: 0,
                           centerValue: 0, contrast: contrast ?? 0, contour: [], strutRingMissed: struts == .missed)
        }
        let found = segment(grown, values: values, size: size, settings: settings, contrast: contrast, erased: erased)
        let mask = found.mask
        let pixelArea = settings.pixel * settings.pixel
        let area = Double(mask.reduce(0) { $0 + ($1 ? 1 : 0) }) * pixelArea
        let inPatientSpace = { (p: SIMD2<Double>) in place.frame.point + p.x * settings.pixel * xAxis + p.y * settings.pixel * yAxis }
        var measured = Section(position: place.position, relativePosition: place.relativePosition, frame: place.frame, area: area,
                       minDiameter: minimumWidth(of: mask, size: size) * settings.pixel, centerValue: found.centerValue,
                       contrast: contrast ?? found.centerValue, contour: outline(of: mask, size: size).map(inPatientSpace),
                       holeContours: holeOutlines(of: mask, size: size).map { $0.map(inPatientSpace) }, corrected: found.erasedSome,
                       lumenTaken: found.lumenTaken, calciumBeside: found.calciumBeside, strutRingMissed: struts == .missed)
        if let limits = settings.plaque { measured.wall = wall(values: values, size: size, lumen: mask, settings: settings, limits: limits) }
        return measured
    }

    /// A section to measure: where it lies from the start of the stretch,
    /// in mm, and on the whole centerline, 0 to 1, the frame there, and what
    /// was erased by hand from its lumen.
    public struct Place: Sendable {
        public var position: Double
        public var relativePosition: Double
        public var frame: Frame
        public var erasures: [Erasure]

        public init(position: Double, relativePosition: Double, frame: Frame, erasures: [Erasure] = []) {
            self.position = position
            self.relativePosition = relativePosition
            self.frame = frame
            self.erasures = erasures
        }
    }

    /// The sections at `places`, with calcium brighter than the share of
    /// `contrast`, or, without one, of the contrast of the places within
    /// `reference`, in mm from the start (see
    /// `contrast(of:settings:sample:)`), or of all of them when none of
    /// those has a lumen. Returns the contrast with them. The sections of the
    /// reference are sampled once, for the contrast and for their own
    /// measure. A stretch measured against two references gives the proximal
    /// one in `proximalReference`, and the contrast is that of both.
    ///
    /// The ring of a stent's struts that a section shows (see
    /// `strutRing(values:size:settings:center:contrast:)`) is taken where at
    /// least `Struts.alongTheVessel` other sections within as many steps, or
    /// a millimetre, show one too: the struts of a stent run along it for
    /// 8 mm or more, the noise of a CT that can make one section look like a
    /// ring does not. Elsewhere the section is measured without it; where
    /// the sections around show a ring and it does not, with narrower
    /// neointima left out (see `tissueRadius(neck:lowerFraction:ringMissed:)`).
    public static func sections(at places: [Place], settings: Settings, reference: ClosedRange<Double>?,
                                proximalReference: ClosedRange<Double>? = nil, contrast: Float? = nil,
                                sample: (SIMD3<Double>) -> Float) -> (sections: [Section], contrast: Float?) {
        let size = gridSize(settings)
        var known = [[Float]?](repeating: nil, count: places.count)
        var contrast = contrast
        if contrast == nil {
            var middles: [Float] = []
            for (i, place) in places.enumerated()
            where (reference?.contains(place.position) ?? false) || (proximalReference?.contains(place.position) ?? false) {
                let values = grid(at: place.frame, settings: settings, sample: sample)
                known[i] = values
                if let middle = middleValue(values: values, size: size, settings: settings) { middles.append(middle) }
            }
            contrast = median(middles) ?? self.contrast(of: places.map(\.frame), settings: settings, sample: sample)
        }
        let grids = places.indices.map { known[$0] ?? grid(at: places[$0].frame, settings: settings, sample: sample) }
        let sharp = grids.map { sharpStrutRing(values: $0, size: size, settings: settings, contrast: contrast) }
        var read = [[Bool]??](repeating: nil, count: places.count)
        func blurred(_ i: Int) -> [Bool]? {
            if let ring = read[i] { return ring }
            let ring = blurredStrutRing(values: grids[i], size: size, settings: settings, contrast: contrast)
            read[i] = .some(ring)
            return ring
        }
        let stented = Struts.holdsStent(sharp, places: places, blurred: blurred)
        let rings = Struts.candidates(sharp, stented: stented, blurred: blurred)
        let sections = places.indices.map { i in
            var measured = section(places[i], values: grids[i], struts: Struts.verdict(at: i, of: places, rings: rings, settings: settings),
                                   settings: settings, contrast: contrast)
            measured.stretchHoldsStent = stented
            return measured
        }
        return (sections, contrast)
    }

    /// The section at `index` of the stretch `places`, measured again alone
    /// (after a stroke of the eraser, its undo or a reset), with the ring of
    /// a stent's struts that the stretch tells it: the places within
    /// `Struts.reach(_:)` of it are sampled for their rings, and only it is
    /// measured. `contrast` is the one the stretch was measured with.
    ///
    /// `stented` says whether the stretch holds a stent
    /// (`Section.stretchHoldsStent`, as the stretch was measured), which
    /// lets the sections near this one be read as a wider blur leaves a
    /// ring; without it, every place of the stretch is sampled to tell.
    public static func section(_ index: Int, of places: [Place], settings: Settings, contrast: Float?, stented: Bool? = nil,
                               sample: (SIMD3<Double>) -> Float) -> Section {
        let size = gridSize(settings), reach = Struts.reach(settings)
        let around = places.indices.filter { abs(places[$0].position - places[index].position) <= reach }
        let near = around.map { places[$0] }
        let grids = near.map { grid(at: $0.frame, settings: settings, sample: sample) }
        let sharp = grids.map { sharpStrutRing(values: $0, size: size, settings: settings, contrast: contrast) }
        let known = stented ?? {
            let all = places.map { grid(at: $0.frame, settings: settings, sample: sample) }
            return Struts.holdsStent(all.map { sharpStrutRing(values: $0, size: size, settings: settings, contrast: contrast) }, places: places) { i in
                blurredStrutRing(values: all[i], size: size, settings: settings, contrast: contrast)
            }
        }()
        let rings = Struts.candidates(sharp, stented: known) { i in
            blurredStrutRing(values: grids[i], size: size, settings: settings, contrast: contrast)
        }
        let at = around.firstIndex(of: index) ?? 0
        var measured = section(places[index], values: grids[at], struts: Struts.verdict(at: at, of: near, rings: rings, settings: settings),
                               settings: settings, contrast: contrast)
        measured.stretchHoldsStent = known
        return measured
    }

    /// The sections of the stretch between two relative positions of a path
    /// `length` mm long, every `settings.step` mm, both ends included, with
    /// calcium brighter than the share of the contrast of `reference`, in mm
    /// from the start (the default reference when there is none), or of the
    /// whole stretch when no section of the reference has a lumen.
    /// `erasures` holds what was erased by hand, by the index of its section.
    public static func sections(from start: Double, to end: Double, length: Double, settings: Settings,
                                erasures: [Int: [Erasure]] = [:], reference: ClosedRange<Double>? = nil,
                                frame: (Double) -> Frame, sample: (SIMD3<Double>) -> Float) -> [Section] {
        let (a, b) = (min(start, end), max(start, end))
        let stretch = (b - a) * length
        guard stretch > 0, length > 0 else { return [] }
        let count = Int((stretch / settings.step).rounded(.down)) + 1
        let places = (0..<count).map { i -> Place in
            let position = min(Double(i) * settings.step, stretch)
            let relative = a + position / length
            return Place(position: position, relativePosition: relative, frame: frame(relative), erasures: erasures[i] ?? [])
        }
        return sections(at: places, settings: settings, reference: reference ?? defaultReference(stretch: stretch), sample: sample).sections
    }

    // MARK: - The stretch

    /// The default reference: the distal end of the stretch, a quarter of it,
    /// between 2 and 10 mm. In mm from the start.
    public static func defaultReference(stretch: Double) -> ClosedRange<Double> {
        let width = min(max(stretch / 4, 2), 10, stretch)
        return (stretch - width)...stretch
    }

    /// The default proximal reference of a stretch measured against two:
    /// its proximal end, a quarter of it, between 2 and 10 mm. In mm from
    /// the start.
    public static func defaultProximalReference(stretch: Double) -> ClosedRange<Double> {
        0...min(max(stretch / 4, 2), 10, stretch)
    }

    /// One of the references of a stretch: where it is, in mm from the
    /// start, the middle of its valid sections, and their mean area and
    /// mean minimum diameter.
    public struct ReferenceSide: Equatable, Sendable {
        public var range: ClosedRange<Double>
        public var position: Double
        public var area: Double
        public var diameter: Double
    }

    public struct Result: Equatable, Sendable {
        public var minimumArea: Double
        /// From the start of the stretch, in mm.
        public var minimumPosition: Double
        public var minimumIndex: Int
        /// The mean area of the reference sections.
        public var referenceArea: Double
        /// The mean area of the whole stretch.
        public var meanArea: Double
        /// (1 − A_min / A_ref) × 100.
        public var nascetByArea: Double
        /// The smallest minimum diameter of the stretch, in mm.
        public var minimumDiameter: Double
        /// √(4 A_min / π), in mm.
        public var equivalentDiameter: Double
        /// The mean minimum diameter of the reference sections, in mm.
        public var referenceDiameter: Double
        /// (1 − D_min / D_ref) × 100.
        public var nascetByDiameter: Double
        /// Where a lumen corrected by hand comes into the numbers: the
        /// section of the minimum area, the one of the minimum diameter, any
        /// section of the reference, and how many valid sections in all.
        public var minimumCorrected = false
        public var minimumDiameterCorrected = false
        public var referenceCorrected = false
        public var correctedCount = 0
        /// The sections with contrast at the centerline whose whole lumen
        /// the calcium and its margin took, and those the eraser emptied:
        /// left out of the numbers, as sections without contrast are, so the
        /// summary has to say how many.
        public var takenByCalciumCount = 0
        public var takenByHandCount = 0
        /// Whether a section outside the reference lost its whole lumen to
        /// the calcium: the narrowest lumen may be among those left out, and
        /// the stenosis then at least as severe as the numbers say.
        public var takenByCalciumOutsideReference = false
        /// The sections with contrast at the centerline, and those of them
        /// where calcium touched the lumen or was taken out of it; and
        /// whether it did at the section of the minimum area. Elsewhere,
        /// plaque dimmer than the limit stays in the area.
        public var sectionsWithContrast = 0
        public var calciumBesideCount = 0
        public var minimumCalciumBeside = false
        /// The contrast of the reference, which calcium was brighter than a
        /// share of.
        public var contrast: Double = 0
        /// The valid sections beside sections that show the ring of a
        /// stent's struts that show none themselves (`Section.strutRingMissed`),
        /// and whether the section of the minimum area, or one of the
        /// reference, is among them: their areas may hold the struts, so the
        /// summary has to say so.
        public var strutRingMissedCount = 0
        public var minimumStrutRingMissed = false
        public var referenceStrutRingMissed = false
        /// The two references of a stretch measured against a proximal and
        /// a distal one; nil when it was measured against one. The
        /// reference area and diameter are then those between the two, at
        /// the narrowest section (see `result(of:proximal:distal:)`).
        public var proximalReference: ReferenceSide?
        public var distalReference: ReferenceSide?
    }

    /// The degree of the stretch; nil without a valid section in the stretch
    /// and in the reference. Sections corrected by hand count as the others
    /// do, with what was left of their lumen, in the stretch and in the
    /// reference alike. Sections whose lumen was taken whole are left out of
    /// the numbers, and counted; the result says whether one of the calcium's
    /// lies outside the reference, where the narrowest lumen may be.
    public static func result(of sections: [Section], reference: ClosedRange<Double>) -> Result? {
        result(of: sections, references: [reference])
    }

    /// The degree of a stretch against a reference on each side of the
    /// narrowing, as a vessel that tapers is measured: the reference of the
    /// narrowest section is what the vessel would be there, between the
    /// proximal and the distal one by where it lies between their middles
    /// (the proximal one before it, the distal one beyond). The area is
    /// read at the section of the minimum area and the diameter at the one
    /// of the minimum diameter. Nil without a valid section in the stretch
    /// and in each reference.
    public static func result(of sections: [Section], proximal: ClosedRange<Double>, distal: ClosedRange<Double>) -> Result? {
        result(of: sections, references: [proximal, distal])
    }

    private static func result(of sections: [Section], references: [ClosedRange<Double>]) -> Result? {
        let valid = sections.indices.filter { sections[$0].isValid }
        func inReference(_ position: Double) -> Bool { references.contains { $0.contains(position) } }
        let referenceSections = valid.filter { inReference(sections[$0].position) }.map { sections[$0] }
        let sides = references.compactMap { range -> ReferenceSide? in
            let within = valid.map { sections[$0] }.filter { range.contains($0.position) }
            guard !within.isEmpty else { return nil }
            let count = Double(within.count)
            return ReferenceSide(range: range, position: within.map(\.position).reduce(0, +) / count,
                                 area: within.map(\.area).reduce(0, +) / count, diameter: within.map(\.minDiameter).reduce(0, +) / count)
        }
        guard let minimumIndex = valid.min(by: { sections[$0].area < sections[$1].area }), sides.count == references.count,
              let first = sides.first, let last = sides.last else { return nil }
        /// What the vessel would be at `position`: the one reference, or between the two.
        func reference(at position: Double, _ value: KeyPath<ReferenceSide, Double>) -> Double {
            guard last.position > first.position else { return (first[keyPath: value] + last[keyPath: value]) / 2 }
            let share = min(max((position - first.position) / (last.position - first.position), 0), 1)
            return first[keyPath: value] + share * (last[keyPath: value] - first[keyPath: value])
        }
        let minimum = sections[minimumIndex]
        let narrowest = valid.min { sections[$0].minDiameter < sections[$1].minDiameter }.map { sections[$0] }
        let referenceArea = reference(at: minimum.position, \.area)
        let referenceDiameter = reference(at: narrowest?.position ?? minimum.position, \.diameter)
        let minimumDiameter = narrowest?.minDiameter ?? 0
        let meanArea = valid.map { sections[$0].area }.reduce(0, +) / Double(valid.count)
        let contrasts = sections.map(\.contrast).filter { $0 > 0 }.sorted()
        var result = Result(minimumArea: minimum.area, minimumPosition: minimum.position, minimumIndex: minimumIndex,
                      referenceArea: referenceArea, meanArea: meanArea,
                      nascetByArea: referenceArea > 0 ? (1 - minimum.area / referenceArea) * 100 : 0,
                      minimumDiameter: minimumDiameter, equivalentDiameter: minimum.equivalentDiameter,
                      referenceDiameter: referenceDiameter,
                      nascetByDiameter: referenceDiameter > 0 ? (1 - minimumDiameter / referenceDiameter) * 100 : 0,
                      minimumCorrected: minimum.corrected, minimumDiameterCorrected: narrowest?.corrected ?? false,
                      referenceCorrected: referenceSections.contains { $0.corrected },
                      correctedCount: valid.filter { sections[$0].corrected }.count,
                      takenByCalciumCount: sections.filter { $0.lumenTaken == .byCalcium }.count,
                      takenByHandCount: sections.filter { $0.lumenTaken == .byHand }.count,
                      takenByCalciumOutsideReference: sections.contains { $0.lumenTaken == .byCalcium && !inReference($0.position) },
                      sectionsWithContrast: sections.filter { $0.centerValue > 0 }.count,
                      calciumBesideCount: sections.filter { $0.centerValue > 0 && $0.calciumBeside }.count,
                      minimumCalciumBeside: minimum.calciumBeside,
                      contrast: contrasts.isEmpty ? 0 : Double(contrasts[contrasts.count / 2]),
                      strutRingMissedCount: valid.filter { sections[$0].strutRingMissed }.count,
                      minimumStrutRingMissed: minimum.strutRingMissed,
                      referenceStrutRingMissed: referenceSections.contains { $0.strutRingMissed })
        if references.count == 2 { (result.proximalReference, result.distalReference) = (first, last) }
        return result
    }

    // MARK: - The struts of a stent

    /// What tells the ring of a stent's struts, in shares of the intensity
    /// of the lumen of its section (see `strutRing(values:size:settings:center:contrast:)`),
    /// and in mm.
    enum Struts {
        /// The rays a section is read along, 2° apart.
        static let rays = 180
        static let directions: [SIMD2<Double>] = (0..<rays).map { r in
            let angle = Double(r) * 2 * .pi / Double(rays)
            return SIMD2(cos(angle), sin(angle))
        }
        /// A crest of the ring that the lumen runs into is brighter than the
        /// lumen by this share; one beyond a dip rises as much above it.
        static let brighter: Float = 0.15
        /// The crests of a ring that the lumen runs into almost all round
        /// (`runningInto` of them), a patent stent's, are brighter than the
        /// lumen by this share, at their median: the bright rim that an
        /// edge-enhancing reconstruction kernel puts round a lumen is dimmer.
        static let brighterRing: Float = 0.25
        static let runningInto = 0.9
        /// The lumen's intensity is the median of the samples within this
        /// distance of the centerline, or the centerline's own when brighter.
        static let lumen = 1.0
        /// Below this share the lumen dips toward tissue; a crest of the ring
        /// beyond a dip is at least as bright.
        static let dip: Float = 0.75
        /// The ring is thin: from its crest to tissue, darker than half the
        /// lumen, there is at most this much.
        static let thin = 1.0
        /// A ridge of the ring with tissue on both sides is at most this wide
        /// above tissue.
        static let ridge = 2.0
        /// Read as a blur of half a millimetre or more leaves it (see
        /// `Reading.blurred`): tissue lies up to `blurredThin` beyond the
        /// crest; the lumen dips before the ring once it falls under
        /// `shallowDip` of its intensity, and a crest after a dip that stays
        /// above `dip` is as bright as the lumen and rises `steeperRise` of
        /// it above the dip; a ridge wider than `ridge` above tissue is still
        /// one where it is at most `blurredHalf` wide at half its height
        /// above the dip, that level being above tissue. Where no circle
        /// holds the crests of `coverage` of the rays, one that holds those
        /// of `weakCoverage` does when the rays without a crest on it are
        /// brighter on the circle than within `furtherIn` before it by
        /// `weakRise` of the lumen, on enough of them to make up the share.
        static let blurredThin = 1.2
        static let shallowDip: Float = 0.82
        static let steeperRise: Float = 0.2
        static let blurredHalf = 2.0
        static let weakCoverage = 0.45
        static let weakRise: Float = 0.15
        /// Read so, a section is quiet: its noise (see `noise(values:size:settings:)`)
        /// is at most this share of its lumen. The rings of stents blurred
        /// by 0.5 to 0.55 mm lie in noise of up to 5.9 % of the lumen; the
        /// lumens that reading takes for rings, in 6.8 % or more.
        static let quiet: Float = 0.062
        /// The crests of the ring lie at most this far from its circle.
        static let tolerance = 0.3
        /// The share of the rays whose crests make the ring: the blooming of
        /// dense calcium over half of the wall of a tight lumen gives crests
        /// on up to 60 % of them.
        static let coverage = 0.65
        /// A stent cut across at a slant, or squashed, shows its ring oval:
        /// the crests may lie on an ellipse whose axes are at most in this
        /// ratio, where it holds the crests of this share of the rays more
        /// than the circle does, or where no circle holds enough of them.
        static let oval = 1.6
        static let ovalGain = 0.1
        /// Read from the centerline, a circle that this share of the rays
        /// shows, its middle at least `offCenter` away, is read again from
        /// its middle, in mm.
        static let partialCoverage = 0.3
        static let offCenter = 0.2
        /// A centerline brighter than the contrast of the reference by this
        /// share that shows no circle is read for one against that contrast.
        static let brightenedCenterline: Float = 0.25
        /// Read again so, the lumen's intensity is the median of the lumen
        /// within the circle at least this far from it, in mm, when that
        /// lumen is at least `smallestLumen` mm², and never brighter than the
        /// contrast of the reference; the median of the ring's crests is
        /// brighter than that contrast by `brighterThanTheLumen`; and no run
        /// of the rays wider than `gapFromMiddle`, in degrees, misses the
        /// circle but where calcium hides it: calcium round most of an oval
        /// lumen leaves a wider gap, where the lumen bulges past the circle.
        static let awayFromStruts = 0.75
        static let smallestLumen = 0.3
        static let brighterThanTheLumen: Float = 0.05
        static let gapFromMiddle = 50.0
        /// The centerline lies at least this far inside the ring, or
        /// `insetFromMiddle` read from its middle, whose radius is at least
        /// `smallest`.
        static let inset = 0.3
        static let insetFromMiddle = 0.15
        static let smallest = 0.75
        /// On the circle fitted on one half of the rays, the other half is
        /// brighter than this much further in by `brighterThanFurtherIn`.
        static let furtherIn = 1.0
        static let brighterThanFurtherIn: Float = 0.05
        /// How far short of the ring the lumen may dip toward tissue.
        static let dipWithin = 1.0
        /// In a stretch, how many other sections near a section show a ring
        /// where it is taken (see `sections(at:settings:reference:contrast:sample:)`).
        static let alongTheVessel = 3

        /// How far along the vessel the sections that tell a section's ring
        /// lie, in mm: as many steps as `alongTheVessel`, or a millimetre.
        static func reach(_ settings: Settings) -> Double {
            max(1, Double(alongTheVessel) * settings.step) + 1e-6
        }

        /// What a stretch tells of the ring of a stent's struts in one of its
        /// sections: none; the ring the section shows, and what lies beyond
        /// it, where the sections around show one too; or missed, where they
        /// do and the section does not.
        enum Verdict: Equatable {
            case none
            case told([Bool])
            case missed
        }

        /// The verdict at `index` of `places`, whose sections show `rings`:
        /// it depends on the places within `reach(_:)` of it alone.
        static func verdict(at index: Int, of places: [Place], rings: [[Bool]?], settings: Settings) -> Verdict {
            let reach = reach(settings)
            let around = places.indices.filter { j in
                j != index && rings[j] != nil && abs(places[j].position - places[index].position) <= reach
            }.count
            guard around >= alongTheVessel else { return .none }
            return rings[index].map { .told($0) } ?? .missed
        }

        /// The shortest stent, in mm, and the share of the sections along
        /// that length that show a ring read as a wider blur leaves it where
        /// a stretch holds a stent no section shows sharp (see
        /// `holdsStent(_:places:blurred:)`).
        static let stentLength = 8.0
        static let alongAStent = 0.5

        /// Whether a stretch holds a stent: one of its sections shows the
        /// ring of the struts alone (`sharp`), or, read as a wider blur
        /// leaves a ring (`blurred`, asked for the sections whose rays saw a
        /// circle and told none), `alongAStent` of the sections along
        /// `stentLength` somewhere in it do: of the stents of 4 mm and more
        /// blurred by 0.5 to 0.55 mm, half the sections show it in 84 of 100,
        /// three in four in 74. A scanner blurs a whole stent
        /// alike, so one blurred by half a millimetre or more shows no
        /// section sharp; what the blurred reading takes for a ring and is
        /// none (calcium round most of an oval lumen, the lumen round a dark
        /// island) seldom runs the length of a stent. A stretch shorter than
        /// a stent with no sharp ring holds none.
        static func holdsStent(_ sharp: [(beyond: [Bool]?, seen: Bool)], places: [Place], blurred: (Int) -> [Bool]?) -> Bool {
            if sharp.contains(where: { $0.beyond != nil }) { return true }
            guard let first = places.first, let last = places.last, last.position - first.position >= stentLength - 1e-6 else { return false }
            let shows = sharp.indices.map { sharp[$0].seen && blurred($0) != nil }
            var end = 0, count = 0
            for start in places.indices {
                while end < places.count, places[end].position - places[start].position <= stentLength + 1e-6 {
                    if shows[end] { count += 1 }
                    end += 1
                }
                // The places from `start` within the length of a stent: all of it, or the stretch ends short of it.
                guard end < places.count || places[end - 1].position - places[start].position >= stentLength - 1e-6 else { break }
                if Double(count) >= alongAStent * Double(end - start) { return true }
                if shows[start] { count -= 1 }
            }
            return false
        }

        /// The rings the sections of a stretch are told with (see
        /// `verdict(at:of:rings:settings:)`): the one each shows alone,
        /// `sharp`, or, in a stretch that holds a stent (`stented`, see
        /// `holdsStent(_:places:blurred:)`), the one a section whose rays saw
        /// a circle and told none shows read as a wider blur leaves it,
        /// `blurred`. That reading takes for a ring what the first does not,
        /// the ring of a stent blurred by 0.5 mm or more, and more that is
        /// none: calcium round most of an oval lumen, the lumen round a dark
        /// island. A stretch that holds no stent is never read so, and stays
        /// as it was.
        static func candidates(_ sharp: [(beyond: [Bool]?, seen: Bool)], stented: Bool, blurred: (Int) -> [Bool]?) -> [[Bool]?] {
            sharp.indices.map { i in sharp[i].beyond ?? (stented && sharp[i].seen ? blurred(i) : nil) }
        }
    }

    typealias Circle = (center: SIMD2<Double>, radius: Double)

    /// The ring of a stent's struts as a section shows it, in pixels: an
    /// ellipse, as the struts of a stent cut across at a slant, or squashed,
    /// make, or a circle where both of its half-axes are one.
    struct Shape: Equatable {
        var center: SIMD2<Double>
        /// The half-axes, `axes.x` along `direction` and `axes.y` across it.
        var axes: SIMD2<Double>
        var direction = SIMD2<Double>(1, 0)

        init(center: SIMD2<Double>, radius: Double) {
            self.center = center
            axes = SIMD2(radius, radius)
        }

        init(center: SIMD2<Double>, axes: SIMD2<Double>, direction: SIMD2<Double>) {
            self.center = center
            self.axes = axes
            self.direction = direction
        }

        init(_ circle: Circle) { self.init(center: circle.center, radius: circle.radius) }

        var isCircle: Bool { axes.x == axes.y }
        /// The radius of the circle of the same area.
        var radius: Double { isCircle ? axes.x : (axes.x * axes.y).squareRoot() }
        var shortest: Double { min(axes.x, axes.y) }
        var ratio: Double { max(axes.x, axes.y) / min(axes.x, axes.y) }

        /// A vector in the frame of the axes.
        private func local(_ v: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(simd_dot(v, direction), direction.x * v.y - direction.y * v.x)
        }

        /// How far the shape lies from its center toward the unit vector `u`.
        func reach(toward u: SIMD2<Double>) -> Double {
            isCircle ? axes.x : 1 / simd_length(local(u) / axes)
        }

        /// How far `p` lies from the shape, along the line from its center.
        func distance(_ p: SIMD2<Double>) -> Double {
            if isCircle { return abs(simd_length(p - center) - axes.x) }
            let d = p - center, length = simd_length(d)
            return length > 0 ? abs(length - reach(toward: d / length)) : shortest
        }

        /// Where a ray from (0, 0) along the unit vector `d` leaves the
        /// shape, from (0, 0); nil when it misses it.
        func crossing(_ d: SIMD2<Double>) -> Double? {
            if isCircle {
                let along = simd_dot(d, center)
                let discriminant = along * along - simd_length_squared(center) + axes.x * axes.x
                return discriminant > 0 ? along + discriminant.squareRoot() : nil
            }
            let q = local(d) / axes, w = local(center) / axes
            let a = simd_length_squared(q), b = simd_dot(q, w)
            let discriminant = b * b - a * (simd_length_squared(w) - 1)
            return discriminant > 0 ? (b + discriminant.squareRoot()) / a : nil
        }

        /// Whether `p` lies inside the shape, at least `inset` from it.
        func holds(_ p: SIMD2<Double>, inset: Double) -> Bool {
            if isCircle { return simd_length(p - center) <= axes.x - inset }
            let d = p - center, length = simd_length(d)
            return length > 0 ? length <= reach(toward: d / length) - inset : shortest >= inset
        }

        func moved(by offset: SIMD2<Double>) -> Shape {
            var moved = self
            moved.center += offset
            return moved
        }
    }

    /// The ring of a stent's struts that a section shows, as
    /// `strutRing(values:size:settings:center:contrast:)` tells it; nil when
    /// its centerline has no contrast.
    static func strutRing(values: [Float], size: Int, settings: Settings, contrast: Float?) -> [Bool]? {
        sharpStrutRing(values: values, size: size, settings: settings, contrast: contrast).beyond
    }

    /// The same, with whether the rays from the centerline saw a circle at
    /// all, a ring or part of one.
    static func sharpStrutRing(values: [Float], size: Int, settings: Settings, contrast: Float?) -> (beyond: [Bool]?, seen: Bool) {
        let center = centerValue(of: values, size: size)
        guard center >= settings.minimumLumenValue, center > 0 else { return (nil, false) }
        return strutRing(values: values, size: size, settings: settings, center: center, contrast: contrast, reading: .sharp)
    }

    /// The ring of a stent's struts that a section shows read as a blur of
    /// half a millimetre or more leaves it (`Reading.blurred`), for a
    /// section whose rays saw a circle and told no ring, in a stretch that
    /// holds a stent or to tell whether it holds one (see
    /// `Struts.holdsStent(_:places:blurred:)`); nil when it shows none so
    /// either, or when its noise
    /// is more than `Struts.quiet` of its lumen: in more noise than that,
    /// this reading takes a lumen for a ring.
    static func blurredStrutRing(values: [Float], size: Int, settings: Settings, contrast: Float?) -> [Bool]? {
        let center = centerValue(of: values, size: size)
        guard center >= settings.minimumLumenValue, center > 0 else { return nil }
        let lumen = lumenLevel(values: values, size: size, settings: settings, center: center)
        guard noise(values: values, size: size, settings: settings) <= Struts.quiet * lumen else { return nil }
        return strutRing(values: values, size: size, settings: settings, center: center, contrast: contrast, reading: .blurred).beyond
    }

    /// The intensity of the lumen a ring is told against: the median of the
    /// samples within `Struts.lumen` of the centerline, or the centerline's
    /// own, `center`, when brighter.
    static func lumenLevel(values: [Float], size: Int, settings: Settings, center: Float) -> Float {
        let c = Double(size / 2)
        let pixelsPerMM = 1 / settings.pixel
        let within = min(Int((Struts.lumen * pixelsPerMM).rounded()), Int((settings.maxRadius * pixelsPerMM).rounded(.down)))
        var near: [Float] = []
        near.reserveCapacity(Struts.rays * (within + 1))
        for direction in Struts.directions {
            for k in 0...within { near.append(interpolated(values, size: size, at: SIMD2(c, c) + Double(k) * direction)) }
        }
        near.sort()
        return max(center, near[near.count / 2])
    }

    /// The ring of a stent's struts and what lies beyond it, seen from the
    /// centerline of a section `center` bright, in its grid of `size` × `size`
    /// samples; nil when the section has no such ring. `contrast` is the
    /// contrast of the reference, when there is one.
    ///
    /// Struts that lie close make, blurred, one thin ring brighter than the
    /// lumen, whose peak can stay under the calcium limit: by the threshold
    /// alone the ring and its blur are lumen, a patent stent measures about
    /// twice its area, and the neointima of a restenosis, which the lumen and
    /// the ring enclose, can be filled in with it. The ring is read on the
    /// profiles of the section along rays from its centerline (see
    /// `ringCrests(_:lumen:runsInto:thin:ridge:pastTissue:)`), against the
    /// intensity of the lumen: the median of the samples within 1 mm of the
    /// centerline, or the centerline's own when brighter, and, for a crest
    /// the lumen runs into, the contrast of the reference when brighter
    /// still. A centerline in a dark spot of its lumen (the noise of a CT, a
    /// thrombus, the dark jet of unopacified inflow) would otherwise take the
    /// lumen round it for a ring. The crests of 65 % of the rays lie within
    /// 0.3 mm of one circle around the centerline, or of one ellipse whose
    /// axes are at most 1.6 to 1, as a stent squashed or cut across at a
    /// slant shows its ring, where the ellipse holds the crests of a tenth
    /// of the rays more than the circle does or no circle holds enough: no
    /// run of the other rays is then wider than 50°, as the struts show all
    /// round and calcium round most of an oval lumen does not, and each
    /// quarter of the rays is held out as from the middle of a circle (see
    /// below). A ray without a crest that runs into calcium brighter than
    /// the limit before it falls to tissue, a dense nodule in the neointima
    /// beside the lumen left, cannot show the ring behind it, and is left
    /// out of the share of the rays that must show it. The circle through the
    /// crests of either half of the rays is, on the other half, brighter than
    /// 1 mm further in; and where the lumen runs into more than nine tenths
    /// of the crests with no dip before them, as in a patent stent, their
    /// median is a quarter brighter than the lumen, as the rim an
    /// edge-enhancing kernel puts round a lumen is not.
    ///
    /// A centerline off the axis of the lumen left by a restenosis, toward
    /// the struts, is brightened by their blur, and its rays cross the ring
    /// at a slant; a section across the stent at a slant shows the ring
    /// oval. Where the rays from the centerline show part of a ring (30 % of
    /// them on one circle, its middle 0.2 mm or more away) or a whole one
    /// whose halves do not hold out, and there is a contrast of the
    /// reference, the ring is read again along rays from the middle of that
    /// circle; a centerline a quarter brighter than that contrast that shows
    /// no such circle against its own intensity is looked at again against
    /// the contrast. Read again, against the lumen within the circle
    /// 0.75 mm or more from it, never brighter than the contrast of the
    /// reference (the contrast itself where tissue fills the circle there):
    /// the crests of 65 % of the rays, but those that run into calcium
    /// brighter than the limit well inside the circle, lie within 0.3 mm of
    /// one circle, which lies 0.15 mm or more beyond the centerline; no run
    /// of the other rays is wider than 50°, as the free part of the wall of
    /// an oval lumen with calcium round the rest is; each quarter of the
    /// rays is, on the circle through the crests of the other three,
    /// brighter than 1 mm further in; the median of the crests is brighter
    /// than the lumen and than the contrast of the reference by 5 %, as the
    /// lumen round a dark island the centerline runs in is not; and a
    /// patent stent's crests are a quarter brighter than the lumen the
    /// centerline sees too. Read so, the lumen may run into the ring past the
    /// neointima before it. The ring of a patent stent that the centerline
    /// tells is never read again: the rim of a kernel is not, either.
    ///
    /// Calcium over up to half of the wall and a lumen whose centerline runs
    /// on its wall make no such ring, nor, in a stretch, does the noise of a
    /// CT (see `sections(at:settings:reference:contrast:sample:)`); calcium
    /// round most of the lumen, thin and brighter than it, can, and leaves
    /// with it. A ring dimmed where struts are missing over more than about
    /// 120°, blurred by 0.5 mm or more, more oval than a ratio of 1.5 between
    /// its axes, whose circle passes within 0.15 mm of the centerline, or at
    /// the end of a stent, where the struts fade, may not be told, nor the
    /// ring of a patent stent less than a quarter brighter than its lumen;
    /// the rim of a kernel that brightens the edge of a lumen by a quarter or
    /// more can be taken for one. Where no ring is told, the lumen is the
    /// threshold's, as before.
    ///
    /// Along each ray from the centerline the lumen stops just beyond the
    /// crest of the ring, which lies on the struts' inner face or a little
    /// inside it, or as far beyond the circle where it crosses the ray when
    /// no crest of it was told there; where it dips toward tissue within
    /// 1 mm short of the ring and rises again toward it (the neointima of a
    /// restenosis, or the part of it the blur lifts), at its own edge against
    /// that dip: as far from the darkest of the dip toward the centerline's
    /// intensity as the lumen's edge is from 0. The lumen's own edge, where
    /// the struts are missing, does not rise again, and the threshold sets
    /// it. The centerline always stays in its own lumen.
    static func strutRing(values: [Float], size: Int, settings: Settings, center: Float, contrast: Float? = nil) -> [Bool]? {
        strutRing(values: values, size: size, settings: settings, center: center, contrast: contrast, reading: .sharp).beyond
    }

    /// The ring read as `reading` says, and whether the rays from the
    /// centerline saw a circle at all, a ring or part of one: where they
    /// saw none, no other reading is tried.
    static func strutRing(values: [Float], size: Int, settings: Settings, center: Float, contrast: Float?,
                          reading: Reading) -> (beyond: [Bool]?, seen: Bool) {
        let c = Double(size / 2)
        let pixelsPerMM = 1 / settings.pixel
        let lumen = lumenLevel(values: values, size: size, settings: settings, center: center)
        let levels = Levels(center: center, lumen: lumen, runsInto: max(lumen, contrast ?? 0))
        let hidden = Hidden(limit: Float(settings.upperFraction) * max(center, contrast ?? center), within: nil)
        var first = ring(values: values, size: size, settings: settings, levels: levels, from: SIMD2(c, c), hidden: hidden, reading: reading)
        // The blur of the struts brightens a centerline beside them, and the
        // crests are then no brighter than it: where the centerline sees
        // nothing and is a quarter brighter than the contrast of the
        // reference, part of a circle to read again is looked for against
        // that contrast, never a ring taken straight away.
        var seen = false
        var sawNothing = false
        switch first {
        case .seen: seen = true
        case .none: sawNothing = true
        default: break
        }
        if seen || sawNothing, let contrast, lumen > (1 + Struts.brightenedCenterline) * contrast {
            let against = Levels(center: contrast, lumen: contrast, runsInto: contrast)
            switch ring(values: values, size: size, settings: settings, levels: against, from: SIMD2(c, c), hidden: hidden, reading: reading) {
            case .around(let circle): first = .around(circle)
            case .seen: seen = true
            default: break
            }
        }
        switch first {
        case .told(let beyond):
            return (beyond, true)
        case .around(let circle):
            guard let contrast else { return (nil, true) }
            // The lumen's own intensity, within the circle away from the blur
            // of the struts, which brightens a centerline beside them, and
            // never brighter than the contrast of the reference: in a small
            // stent that blur brightens the whole lumen left. A crest the
            // lumen runs into is brighter than that lumen, or than the
            // contrast of the reference when brighter still, as from the
            // centerline: a lumen brighter than the reference is no crest.
            let reach = circle.radius - Struts.awayFromStruts * pixelsPerMM
            var inside: [Float] = [], room = 0
            if reach > 0 {
                let (x0, x1) = (max(Int((circle.center.x - reach).rounded(.down)), 0), min(Int((circle.center.x + reach).rounded(.up)), size - 1))
                let (y0, y1) = (max(Int((circle.center.y - reach).rounded(.down)), 0), min(Int((circle.center.y + reach).rounded(.up)), size - 1))
                for y in y0...y1 {
                    for x in x0...x1 where simd_length(SIMD2(Double(x), Double(y)) - circle.center) <= reach {
                        room += 1
                        if values[y * size + x] >= lumen / 2 { inside.append(values[y * size + x]) }
                    }
                }
            }
            let smallest = Int(Struts.smallestLumen * pixelsPerMM * pixelsPerMM)
            var own = Levels(center: min(center, contrast), lumen: min(lumen, contrast), runsInto: levels.runsInto)
            if inside.count >= smallest, let middle = median(inside) {
                own = Levels(center: min(center, middle, contrast), lumen: min(lumen, middle, contrast), runsInto: max(min(lumen, middle), contrast))
            } else if room >= smallest {
                // Tissue fills the circle away from the struts: the lumen
                // left lies against them, and the centerline in it is as
                // bright as their crests. The contrast of the reference
                // stands for the lumen.
                own.runsInto = contrast
            }
            let again = Again(centerline: levels, contrast: contrast)
            let behind = Hidden(limit: Float(settings.upperFraction) * max(center, contrast),
                                within: Int((circle.radius - 2 * Struts.tolerance * pixelsPerMM).rounded(.down)))
            guard case .told(let beyond) = ring(values: values, size: size, settings: settings, levels: own, from: circle.center,
                                                hidden: behind, reading: reading, again: again) else { return (nil, true) }
            return (beyond, true)
        case .seen, .none:
            return (nil, seen)
        }
    }

    /// The noise of a section, as a standard deviation: from the median of
    /// the absolute differences between samples half a millimetre apart,
    /// between 3 and 7 mm from its centerline, where tissue mostly lies; the
    /// edges of what lies there are too few to move that median.
    static func noise(values: [Float], size: Int, settings: Settings) -> Float {
        let c = size / 2
        let step = max(Int((0.5 / settings.pixel).rounded()), 1)
        let (inner, outer) = (3 / settings.pixel, min(7, settings.maxRadius - 0.5) / settings.pixel)
        func inRing(_ x: Int, _ y: Int) -> Bool {
            let d = Double((x - c) * (x - c) + (y - c) * (y - c)).squareRoot()
            return d >= inner && d <= outer
        }
        var differences: [Float] = []
        for y in stride(from: c % step, to: size - step, by: step) {
            for x in stride(from: c % step, to: size - step, by: step) where inRing(x, y) {
                let v = values[y * size + x]
                if inRing(x + step, y) { differences.append(abs(values[y * size + x + step] - v)) }
                if inRing(x, y + step) { differences.append(abs(values[(y + step) * size + x] - v)) }
            }
        }
        guard !differences.isEmpty else { return 0 }
        differences.sort()
        return differences[differences.count / 2] / 0.954
    }



    /// The intensities a ring is told by: the centerline's, the lumen's, and
    /// the one a crest the lumen runs into is brighter than.
    struct Levels {
        var center: Float
        var lumen: Float
        var runsInto: Float
    }

    /// A ring read again from the middle of a circle: the intensities the
    /// centerline gave, which the lumen is cut by, and the contrast of the
    /// reference.
    struct Again {
        var centerline: Levels
        var contrast: Float
    }

    /// Calcium brighter than `limit` that a ray without a crest runs into
    /// within `within` pixels of where it starts, or before it falls to
    /// tissue, hides the ring behind it.
    struct Hidden {
        var limit: Float
        var within: Int?
    }

    /// How the crests of a ring are read: as struts blurred by less than half
    /// a millimetre leave them, or as a wider blur does, which lowers the
    /// crests, widens them and fills the dip before them. The blurred reading
    /// takes for a ring what the first does not, and more that is none
    /// (calcium round most of an oval lumen, the lumen round a dark island):
    /// it is only used in a stretch that holds a stent, for a section that
    /// shows the first none (see `Struts.holdsStent(_:places:blurred:)`).
    struct Reading {
        var thin: Double
        var dip: Float
        var rise: Float
        var weak: Bool
        static let sharp = Reading(thin: Struts.thin, dip: Struts.dip, rise: Struts.brighter, weak: false)
        static let blurred = Reading(thin: Struts.blurredThin, dip: Struts.shallowDip, rise: Struts.steeperRise, weak: true)
    }

    /// A ring told along rays from a point, and what lies beyond it; or, from
    /// the centerline, the circle part of the rays show, to be read again
    /// from its middle (see `strutRing(values:size:settings:center:contrast:)`);
    /// or neither.
    enum Told {
        case told([Bool])
        case around(Circle)
        /// Part of the rays from the centerline show a circle, which is
        /// neither a ring nor to be read again.
        case seen
        case none
    }

    /// The ring of a stent's struts read along rays from `origin`, in pixels
    /// of the grid: its centerline, or, read `again`, the middle of the
    /// circle that the rays from the centerline showed.
    static func ring(values: [Float], size: Int, settings: Settings, levels: Levels, from origin: SIMD2<Double>, hidden: Hidden,
                     reading: Reading = .sharp, again: Again? = nil) -> Told {
        let rays = Struts.rays, directions = Struts.directions
        let c = Double(size / 2)
        let pixelsPerMM = 1 / settings.pixel
        // Where the centerline lies from the origin.
        let centerline = SIMD2(c, c) - origin
        let fromMiddle = again != nil
        let steps = Int((settings.maxRadius * pixelsPerMM - simd_length(centerline)).rounded(.down))
        guard steps > 0 else { return .none }
        let (center, lumen, runsInto) = (levels.center, levels.lumen, levels.runsInto)
        func pixels(_ mm: Double) -> Int { Int((mm * pixelsPerMM).rounded()) }
        func sample(_ r: Int, _ k: Int) -> Float { interpolated(values, size: size, at: origin + Double(k) * directions[r]) }

        // The profiles and their crests, ray by ray, until, from the
        // centerline, too few rays are left to hold part of the ring. A ray
        // that runs into calcium brighter than the limit before the ring
        // cannot show the ring behind it, and is left out of the share of the
        // rays that must show it.
        let some = Int((Struts.partialCoverage * Double(rays)).rounded(.up))
        let tissue = lumen / 2
        var profiles: [[Float]] = [], options: [[Int]] = [], missed = 0, blocked = 0
        var isBlocked = [Bool](repeating: false, count: rays)
        profiles.reserveCapacity(rays)
        options.reserveCapacity(rays)
        for r in 0..<rays {
            let p = (0...steps).map { sample(r, $0) }
            let found = ringCrests(p, lumen: lumen, runsInto: runsInto, thin: pixels(reading.thin), ridge: pixels(Struts.ridge), pastTissue: fromMiddle,
                                   reading: reading)
            if found.isEmpty {
                let within = hidden.within ?? (p.firstIndex { $0 < tissue } ?? steps)
                if p[0...min(within, steps)].contains(where: { $0 > hidden.limit }) {
                    blocked += 1
                    isBlocked[r] = true
                } else {
                    missed += 1
                    if !fromMiddle && missed > rays - some { return .none }
                }
            }
            profiles.append(p)
            options.append(found)
        }
        guard blocked <= rays / 2 else { return .none }
        let needed = Int((Struts.coverage * Double(rays - blocked)).rounded(.up))
        func point(_ crest: Int?, on r: Int) -> SIMD2<Double> { directions[r] * Double(crest ?? 0) }
        let tolerance = Struts.tolerance * pixelsPerMM

        // The circle, or the ellipse, through the crests of `count` rays at
        // least, fitted again on the nearest of them to the circle through
        // all, then on those within the tolerance, each ray taking its crest
        // nearest to it.
        func fit(_ count: Int, oval: Bool = false) -> (ring: Shape, crests: [Int?], on: [Int])? {
            var crests = options.map(\.first)
            func onRing(_ ring: Shape) -> [Int] {
                crests.indices.filter { r in crests[r].map { ring.distance(point($0, on: r)) <= tolerance } ?? false }
            }
            func through(_ points: [SIMD2<Double>]) -> Shape? {
                guard oval else { return circle(through: points).map(Shape.init) }
                return ellipse(through: points).flatMap { $0.ratio <= Struts.oval ? $0 : nil }
            }
            var told = crests.indices.filter { crests[$0] != nil }
            guard told.count >= count, let first = circle(through: told.map { point(crests[$0], on: $0) }).map(Shape.init) else { return nil }
            told.sort { first.distance(point(crests[$0], on: $0)) < first.distance(point(crests[$1], on: $1)) }
            guard var ring = through(told.prefix(count).map { point(crests[$0], on: $0) }) else { return nil }
            for _ in 0..<3 {
                for r in 0..<rays where options[r].count > 1 {
                    crests[r] = options[r].min { ring.distance(point($0, on: r)) < ring.distance(point($1, on: r)) }
                }
                let on = onRing(ring)
                guard on.count >= count, let next = through(on.map { point(crests[$0], on: $0) }) else { return nil }
                ring = next
            }
            let on = onRing(ring)
            guard on.count >= count else { return nil }
            return (ring: ring, crests: crests, on: on)
        }
        // From the centerline, a circle off it that part of the rays show, or
        // a ring whose halves do not hold out, is read again from its middle.
        func around(_ ring: Shape?, offCenter: Bool = true) -> Told {
            guard !fromMiddle, let ring else { return .none }
            guard ring.shortest >= Struts.smallest * pixelsPerMM, ring.holds(SIMD2(0, 0), inset: Struts.insetFromMiddle * pixelsPerMM),
                  !offCenter || simd_length(ring.center) >= Struts.offCenter * pixelsPerMM else { return .seen }
            return .around((origin + ring.center, ring.radius))
        }
        let enough = missed <= rays - blocked - needed
        var chosen = enough ? fit(needed) : nil
        if enough, let oval = fit(needed, oval: true),
           chosen.map({ oval.on.count >= $0.on.count + Int(Struts.ovalGain * Double(rays)) }) ?? true {
            chosen = oval
        }
        // Read as a wider blur leaves it, a ray with no crest on a circle
        // that part of the rays show counts toward the share where it is
        // brighter on the circle than within the millimetre before it.
        if chosen == nil, reading.weak,
           let partial = fit(Int((Struts.weakCoverage * Double(rays - blocked)).rounded(.up))) {
            let shown = Set(partial.on), w = Int(tolerance.rounded()), before = pixels(Struts.furtherIn)
            let weak = (0..<rays).filter { r in
                guard !shown.contains(r), !isBlocked[r], let x = partial.ring.crossing(directions[r]) else { return false }
                let at = Int(x.rounded())
                guard at - before >= 0, at + w <= steps, let top = profiles[r][max(at - w, 0)...(at + w)].max(),
                      let low = profiles[r][(at - before)...at].min() else { return false }
                return top - low >= Struts.weakRise * lumen
            }.count
            if partial.on.count + weak >= needed { chosen = partial }
        }
        guard let (ring, crests, on) = chosen else { return around(fit(some)?.ring) }
        let isOn = Set(on)
        // Read from the middle of a circle, and on an ellipse, the struts of
        // a stent show all round, but where calcium hides them. Calcium round
        // most of an oval lumen leaves a gap where the lumen bulges past the
        // circle, which the circle would cut across, and is itself part of an
        // ellipse with a gap where there is none.
        if fromMiddle || !ring.isCircle {
            var longest = 0, run = 0
            for k in 0..<(2 * rays) {
                if isOn.contains(k % rays) || isBlocked[k % rays] { run = 0 } else { run += 1; longest = max(longest, min(run, rays)) }
            }
            guard Double(longest) <= Struts.gapFromMiddle / 360 * Double(rays) else { return .none }
        }
        guard ring.holds(centerline, inset: (fromMiddle ? Struts.insetFromMiddle : Struts.inset) * pixelsPerMM),
              ring.shortest >= Struts.smallest * pixelsPerMM else { return around(ring) }

        // Held out: on the rays held out, the circle through the crests of
        // the others is brighter than further in, ray by ray (the brightest
        // sample within the tolerance of the circle against the brightest
        // within as wide a window further in). On a lumen's own noise, the
        // circle of the others falls anywhere on them. From the centerline
        // each half of a circle is held out; from the middle of a circle, and
        // of an ellipse, each quarter, as an oval ring bends the circle of
        // one half away from the other, and half an ellipse leaves the other
        // half open.
        let window = Int(tolerance.rounded()), furtherIn = pixels(Struts.furtherIn)
        func brighterThanFurtherIn(heldOut held: (Int) -> Bool) -> Float? {
            let others = on.filter { !held($0) }.map { point(crests[$0], on: $0) }
            guard let fitted = ring.isCircle ? circle(through: others).map(Shape.init) : ellipse(through: others) else { return nil }
            var differences: [Float] = []
            for r in 0..<rays where held(r) && !isBlocked[r] {
                guard let x = fitted.crossing(directions[r]) else { continue }
                let at = Int(x.rounded())
                let w = max(1, min(window, at / 4)), inside = max(at - furtherIn, w)
                guard at + w <= steps, inside + w < at - w,
                      let onCircle = profiles[r][(at - w)...(at + w)].max(),
                      let further = profiles[r][(inside - w)...(inside + w)].max() else { continue }
                differences.append((onCircle - further) / lumen)
            }
            let open = (0..<rays).filter { held($0) && !isBlocked[$0] }.count
            guard differences.count >= max(open / 2, rays / 8) else { return nil }
            return differences.sorted()[differences.count / 2]
        }
        if fromMiddle || !ring.isCircle || reading.weak {
            let quarters = (0..<4).compactMap { q in brighterThanFurtherIn { $0 * 4 / rays == q } }
            guard quarters.count >= 2, let least = quarters.min(), least >= Struts.brighterThanFurtherIn else {
                return fromMiddle ? .none : around(ring, offCenter: false)
            }
        } else {
            guard let one = brighterThanFurtherIn(heldOut: { !(0..<(rays / 2)).contains($0) }),
                  let other = brighterThanFurtherIn(heldOut: { !((rays / 2)..<rays).contains($0) }),
                  min(one, other) >= Struts.brighterThanFurtherIn else { return around(ring, offCenter: false) }
        }

        // A ring the lumen runs into almost all round, its first crest on the
        // ray with no dip between the lumen and it, is a patent stent's, or
        // the rim of an edge-enhancing kernel, which is dimmer. A centerline
        // in a dark spot reaches its lumen after the spot. From the middle of
        // a circle it is a patent stent's only where the rays run in the
        // lumen from that middle on, and brighter than the lumen as the
        // centerline sees it too.
        let dipLevel = Struts.dip * lumen
        let runInto = on.compactMap { r -> Float? in
            let p = profiles[r]
            guard let k = crests[r], k == options[r].first, let reached = fromMiddle ? 0 : p[...k].firstIndex(where: { $0 >= dipLevel }),
                  !p[reached...k].contains(where: { $0 < dipLevel }) else { return nil }
            return p[k]
        }
        let middle = Int(origin.y.rounded()) * size + Int(origin.x.rounded())
        let patent = Double(runInto.count) > Struts.runningInto * Double(on.count)
            && (!fromMiddle || median(of: values, size: size, around: middle) >= dipLevel)
        if patent {
            guard runInto.sorted()[runInto.count / 2] >= (1 + Struts.brighterRing) * max(runsInto, again?.centerline.runsInto ?? 0) else { return .none }
        }
        // From the middle of a circle the ring is brighter than the lumen and
        // than the contrast of the reference: the lumen round a dark island
        // that the centerline runs in is not.
        if let again {
            let tops = on.compactMap { r in crests[r].map { profiles[r][$0] } }.sorted()
            guard tops[tops.count / 2] >= (1 + Struts.brighterThanTheLumen) * max(lumen, again.contrast) else { return .none }
        }

        // Where the lumen stops is read along rays from the centerline, which
        // lies in it: from the middle of a circle, rays also cross the
        // neointima before the lumen left. Each ray from the centerline takes
        // the crest of the ring nearest to it, or where the ring crosses it,
        // and the centerline's intensities.
        var cutProfiles = profiles, cutCrests: [Int?] = (0..<rays).map { isOn.contains($0) ? crests[$0] : nil }
        var cutRing = ring
        if fromMiddle {
            cutRing = ring.moved(by: -centerline)
            let cutSteps = Int((settings.maxRadius * pixelsPerMM).rounded(.down))
            cutProfiles = (0..<rays).map { r in (0...cutSteps).map { interpolated(values, size: size, at: SIMD2(c, c) + Double($0) * directions[r]) } }
            cutCrests = (0..<rays).map { r in
                ringCrests(cutProfiles[r], lumen: lumen, runsInto: runsInto, thin: pixels(reading.thin), ridge: pixels(Struts.ridge), reading: reading)
                    .filter { cutRing.distance(point($0, on: r)) <= tolerance }
                    .min { cutRing.distance(point($0, on: r)) < cutRing.distance(point($1, on: r)) }
            }
        }
        guard let beyond = cut(values: values, size: size, settings: settings, ring: cutRing, crests: cutCrests, profiles: cutProfiles,
                               center: again?.centerline.center ?? center, patent: patent) else { return .none }
        return .told(beyond)
    }

    /// What lies beyond `ring`, a ring of a stent's struts in pixels from the
    /// centerline of a section, along the rays from that centerline whose
    /// profiles are `profiles` and the crests of that ring on them `crests`;
    /// nil when the centerline would lie beyond it.
    ///
    /// Along each ray the lumen stops just beyond the crest, which lies on
    /// the struts' inner face or a little inside it, or as far beyond where
    /// the ring crosses the ray when it has no crest; where it dips toward
    /// tissue within 1 mm short of the ring and rises again toward it (the
    /// neointima of a restenosis, or the part of it the blur lifts), at its
    /// own edge against that dip: as far from the darkest of the dip toward
    /// `center`, the centerline's intensity, as the lumen's edge is from 0.
    /// The lumen's own edge, where the struts are missing, does not rise
    /// again, and the threshold sets it. In a patent stent the lumen fills
    /// the struts, up to their inner face: it holds the crest, half a sample
    /// beyond. In a restenosis, the blur lifts the neointima beside where the
    /// lumen left touches the struts above its edge, and the lumen stops at
    /// the crest.
    static func cut(values: [Float], size: Int, settings: Settings, ring: Shape, crests: [Int?], profiles: [[Float]], center: Float,
                    patent: Bool) -> [Bool]? {
        let rays = Struts.rays, directions = Struts.directions
        let c = Double(size / 2), origin = SIMD2(c, c)
        let steps = profiles[0].count - 1
        // Where the lumen stops along each ray, smoothed over 5 rays.
        func smoothed(_ cut: [Double]) -> [Double] {
            (0..<rays).map { r in ((r - 2)...(r + 2)).map { cut[($0 + rays) % rays] }.sorted()[2] }
        }
        var cut = smoothed((0..<rays).map { r in
            (crests[r].map(Double.init) ?? ring.crossing(directions[r]) ?? Double(steps)) + (patent ? 0.5 : 0)
        })
        let dip = Struts.dip * center, rise = Struts.brighter * center, dipWithin = Int((Struts.dipWithin / settings.pixel).rounded())
        for r in 0..<rays {
            let p = profiles[r]
            let from = min(Int(cut[r].rounded(.down)), steps)
            let near = max(from - dipWithin, 0)..<max(from, 0)
            guard var k = near.min(by: { p[$0] < p[$1] }), p[k] < dip,
                  let after = p[k...from].max(), after - p[k] >= rise else { continue }
            let edge = p[k] + Float(settings.lowerFraction) * (center - p[k])
            while k > near.lowerBound && p[k - 1] < edge { k -= 1 }
            cut[r] = Double(k)
        }
        cut = smoothed(cut)

        // Beyond the farthest cut every pixel is beyond.
        var beyond = [Bool](repeating: true, count: size * size)
        let step = 2 * Double.pi / Double(rays)
        let farthest = (cut.max() ?? 0) + 1
        let (x0, x1) = (max(Int((origin.x - farthest).rounded(.down)), 0), min(Int((origin.x + farthest).rounded(.up)), size - 1))
        let (y0, y1) = (max(Int((origin.y - farthest).rounded(.down)), 0), min(Int((origin.y + farthest).rounded(.up)), size - 1))
        for y in y0...y1 {
            for x in x0...x1 {
                let d = SIMD2(Double(x), Double(y)) - origin
                var angle = atan2(d.y, d.x)
                if angle < 0 { angle += 2 * .pi }
                let f = angle / step
                let r = Int(f) % rays, w = f - Double(Int(f))
                beyond[y * size + x] = simd_length(d) >= cut[r] * (1 - w) + cut[(r + 1) % rays] * w
            }
        }
        // The centerline stays in its own lumen.
        guard !beyond[(size / 2) * size + size / 2] else { return nil }
        return beyond
    }

    /// Where a ray from a section's centerline, or from the middle of a ring,
    /// whose lumen is `lumen` bright may cross the ring of a stent's struts:
    /// the indices of the crests along its profile `p`, nearest first. Tissue
    /// is darker than half the lumen. The lumen runs into the ring: a crest
    /// brighter than `runsInto` (the lumen, or the contrast of the reference
    /// when brighter) by 15 %, and tissue at most `thin` samples beyond it.
    /// Or the lumen ends, or dips under 75 % of the lumen, toward the
    /// neointima of a restenosis, and then the ring: a crest rising 15 % of
    /// the lumen above the dip and at least as bright as 75 % of it, with
    /// tissue at most `thin` samples beyond it, and, where tissue lies before
    /// it too, at most `ridge` samples wide above tissue, or, `pastTissue`,
    /// as bright as a crest the lumen runs into: from the middle of a ring,
    /// a ray crosses the neointima before the lumen left runs into the
    /// struts. A ray may cross calcium before the ring, and gives a crest for
    /// each.
    static func ringCrests(_ p: [Float], lumen: Float, runsInto: Float, thin: Int, ridge: Int, pastTissue: Bool = false,
                           reading: Reading = .sharp) -> [Int] {
        let tissue = lumen / 2, dip = Struts.dip * lumen, rise = Struts.brighter * lumen
        // Read as a wider blur leaves it (`Reading.blurred`): the dip may
        // stay shallower, and a crest after such a dip is then as bright as
        // the lumen and rises more above it.
        let shallow = max(reading.dip, Struts.dip) * lumen, steeper = reading.rise * lumen
        var crests: [Int] = []
        guard let end = p.firstIndex(where: { $0 < tissue }) else { return crests }
        var from = 0
        if let start = p[..<end].firstIndex(where: { $0 >= (1 + Struts.brighter) * runsInto }) {
            var crest = start
            for k in start..<end where p[k] > p[crest] { crest = k }
            if end - crest <= thin { crests.append(crest) }
            from = end
        }
        while from < p.count, let down = p[from...].firstIndex(where: { $0 < shallow }) {
            var lowest = p[down], start: Int? = nil
            for k in down..<p.count {
                lowest = min(lowest, p[k])
                let deep = lowest < dip
                if p[k] >= (deep ? dip : lumen) && p[k] >= lowest + (deep ? rise : steeper) { start = k; break }
            }
            guard let start, let stop = p[start...].firstIndex(where: { $0 < tissue }) else { break }
            var crest = start
            for k in start..<stop where p[k] > p[crest] { crest = k }
            let aboveTissue = (down..<crest).last { p[$0] < tissue }.map { $0 + 1 }
            var narrow = aboveTissue.map({ stop - $0 <= ridge }) ?? true
            if !narrow, reading.weak, let floor = p[down..<crest].min() {
                // A ridge the blur widened above tissue: narrow at half its height above the dip.
                let level = (p[crest] + floor) / 2
                let left = (down..<crest).last { p[$0] < level }.map { $0 + 1 } ?? down
                let right = p[crest...].firstIndex { $0 < level } ?? p.count
                narrow = level >= tissue && Double(right - left) <= Struts.blurredHalf / Struts.ridge * Double(ridge)
            }
            if stop - crest <= thin, narrow
                || (pastTissue && p[crest] >= (1 + Struts.brighter) * runsInto) { crests.append(crest) }
            from = stop
        }
        return crests
    }

    /// The circle nearest to `points` by least squares on x² + y² + Dx + Ey + F
    /// (Kåsa's fit); nil for fewer than three points, or points on a line.
    static func circle(through points: [SIMD2<Double>]) -> Circle? {
        guard points.count >= 3 else { return nil }
        var normal = simd_double3x3(0), right = SIMD3<Double>(0, 0, 0)
        for p in points {
            let row = SIMD3(p.x, p.y, 1)
            normal += simd_double3x3(rows: [row * row.x, row * row.y, row])
            right -= row * (p.x * p.x + p.y * p.y)
        }
        guard abs(normal.determinant) > 1e-9 else { return nil }
        let s = normal.inverse * right
        let center = SIMD2(-s.x / 2, -s.y / 2)
        let squared = simd_length_squared(center) - s.z
        return squared > 0 ? (center, squared.squareRoot()) : nil
    }

    /// The ellipse nearest to `points` by least squares on the conic
    /// a x² + b xy + c y² + d x + e y + f = 0 with a + c = 1, which keeps a
    /// near circle near a circle, fitted on the points moved to their mean
    /// and scaled to a spread of one; nil for fewer than six points, or a
    /// conic that is no ellipse.
    static func ellipse(through points: [SIMD2<Double>]) -> Shape? {
        guard points.count >= 6 else { return nil }
        let mean = points.reduce(SIMD2<Double>(0, 0), +) / Double(points.count)
        let spread = (points.reduce(0.0) { $0 + simd_length_squared($1 - mean) } / Double(points.count)).squareRoot()
        guard spread > 1e-9 else { return nil }
        var normal = [Double](repeating: 0, count: 25), right = [Double](repeating: 0, count: 5)
        for p in points {
            let q = (p - mean) / spread
            let row = [q.x * q.x - q.y * q.y, q.x * q.y, q.x, q.y, 1]
            let value = -(q.x * q.x + q.y * q.y) / 2
            for i in 0..<5 {
                right[i] += row[i] * value
                for j in 0..<5 { normal[i * 5 + j] += row[i] * row[j] }
            }
        }
        guard let s = solve(normal, right) else { return nil }
        let (a, b, c, d, e, f) = (0.5 + s[0], s[1], 0.5 - s[0], s[2], s[3], s[4])
        let determinant = 4 * a * c - b * b
        guard determinant > 1e-12 else { return nil }
        let (x0, y0) = ((b * e - 2 * c * d) / determinant, (b * d - 2 * a * e) / determinant)
        let level = -(f + (d * x0 + e * y0) / 2)
        let half = ((a - c) * (a - c) + b * b).squareRoot() / 2
        let (large, small) = ((a + c) / 2 + half, (a + c) / 2 - half)
        guard level > 0, small > 0 else { return nil }
        let angle = atan2(b, a - c) / 2
        return Shape(center: mean + spread * SIMD2(x0, y0), axes: spread * SIMD2((level / large).squareRoot(), (level / small).squareRoot()),
                     direction: SIMD2(cos(angle), sin(angle)))
    }

    /// The solution of the square system `matrix` x = `vector`, the matrix
    /// row after row, by Gaussian elimination with partial pivoting; nil
    /// when the matrix is singular.
    private static func solve(_ matrix: [Double], _ vector: [Double]) -> [Double]? {
        let n = vector.count
        var a = matrix, b = vector
        for k in 0..<n {
            var pivot = k
            for i in (k + 1)..<n where abs(a[i * n + k]) > abs(a[pivot * n + k]) { pivot = i }
            guard abs(a[pivot * n + k]) > 1e-12 else { return nil }
            if pivot != k {
                for j in 0..<n { a.swapAt(k * n + j, pivot * n + j) }
                b.swapAt(k, pivot)
            }
            for i in (k + 1)..<n {
                let factor = a[i * n + k] / a[k * n + k]
                for j in k..<n { a[i * n + j] -= factor * a[k * n + j] }
                b[i] -= factor * b[k]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for k in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[k]
            for j in (k + 1)..<n { sum -= a[k * n + j] * x[j] }
            x[k] = sum / a[k * n + k]
        }
        return x
    }

    /// The grid of `size` × `size` samples interpolated bilinearly at a point
    /// in pixels, clamped to the grid.
    static func interpolated(_ values: [Float], size: Int, at point: SIMD2<Double>) -> Float {
        let fx = min(max(point.x, 0), Double(size - 1)), fy = min(max(point.y, 0), Double(size - 1))
        let x0 = min(Int(fx), size - 2), y0 = min(Int(fy), size - 2)
        let ax = Float(fx - Double(x0)), ay = Float(fy - Double(y0))
        let top = values[y0 * size + x0] * (1 - ax) + values[y0 * size + x0 + 1] * ax
        let bottom = values[(y0 + 1) * size + x0] * (1 - ax) + values[(y0 + 1) * size + x0 + 1] * ax
        return top * (1 - ay) + bottom * ay
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

    /// The regions of the mask, 8-connected, of at least `minimum` pixels.
    static func regions(of mask: [Bool], size: Int, atLeast minimum: Int) -> [Bool] {
        var result = [Bool](repeating: false, count: mask.count)
        var seen = [Bool](repeating: false, count: mask.count)
        for start in mask.indices where mask[start] && !seen[start] {
            var stack = [start], members = [start]
            seen[start] = true
            while let p = stack.popLast() {
                let (x, y) = (p % size, p / size)
                for ny in max(y - 1, 0)...min(y + 1, size - 1) {
                    for nx in max(x - 1, 0)...min(x + 1, size - 1) where mask[ny * size + nx] && !seen[ny * size + nx] {
                        seen[ny * size + nx] = true
                        stack.append(ny * size + nx)
                        members.append(ny * size + nx)
                    }
                }
            }
            if members.count >= minimum {
                for m in members { result[m] = true }
            }
        }
        return result
    }

    /// The pixels of `mask` 8-connected within it to a pixel of `seeds`,
    /// which `mask` holds.
    static func reach(of seeds: [Bool], through mask: [Bool], size: Int) -> [Bool] {
        var result = seeds
        var stack = seeds.indices.filter { seeds[$0] }
        while let p = stack.popLast() {
            let (x, y) = (p % size, p / size)
            for ny in max(y - 1, 0)...min(y + 1, size - 1) {
                for nx in max(x - 1, 0)...min(x + 1, size - 1) where mask[ny * size + nx] && !result[ny * size + nx] {
                    result[ny * size + nx] = true
                    stack.append(ny * size + nx)
                }
            }
        }
        return result
    }

    /// Whether a pixel of `mask` is a pixel of `other` or has one among its 8 neighbours.
    static func touches(_ mask: [Bool], _ other: [Bool], size: Int) -> Bool {
        for i in mask.indices where mask[i] {
            let (x, y) = (i % size, i / size)
            for ny in max(y - 1, 0)...min(y + 1, size - 1) {
                for nx in max(x - 1, 0)...min(x + 1, size - 1) where other[ny * size + nx] { return true }
            }
        }
        return false
    }

    /// The pixels of the mask 4-connected to `start`.
    public static func component(of mask: [Bool], size: Int, from start: Int) -> [Bool] {
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

    /// Adds to the lumen grown from `seed` what it encloses, except the
    /// tissue there: what is darker than the lumen's `edge` and holds a disc
    /// of more than `tissueRadius` pixels, with the darker samples joined to
    /// it, and what that leaves cut off from the seed.
    ///
    /// The holes of a lumen are mostly lumen. Calcium brighter than the upper
    /// limit is left out of the threshold, and so is a sample of the lumen
    /// that the noise of a CT drops below the edge; filling the holes puts
    /// them back, and the calcium exclusion then takes out the calcium.
    /// Tissue that the lumen surrounds is no lumen: soft plaque or a
    /// thrombus, or the neointima of a restenosis inside a stent whose ring
    /// was not told (see `strutRing(values:size:settings:center:contrast:)`). It is
    /// told from the noise by its size: in the noise of a CT, the samples
    /// below the edge inside a lumen make specks narrower than twice
    /// `tissueRadius` (see `tissueRadius(neck:lowerFraction:ringMissed:)`).
    /// Tissue narrower than that stays in the lumen.
    static func fillHoles(_ lumen: inout [Bool], size: Int, values: [Float], edge: Float, tissueRadius: Double, seed: Int) {
        var filled = lumen
        fillHoles(&filled, size: size)
        let dark = filled.indices.map { filled[$0] && !lumen[$0] && values[$0] < edge }
        guard dark.contains(true) else {
            lumen = filled
            return
        }
        let depth = distanceTransform(dark, size: size)
        let tissue = reach(of: depth.map { $0 > tissueRadius }, through: dark, size: size)
        guard tissue.contains(true) else {
            lumen = filled
            return
        }
        for i in filled.indices where tissue[i] { filled[i] = false }
        lumen = component(of: filled, size: size, from: seed)
    }

    /// Adds to the mask what it encloses: the pixels outside it that the
    /// grid's border cannot reach.
    public static func fillHoles(_ mask: inout [Bool], size: Int) {
        let outside = Self.outside(of: mask, size: size)
        for i in mask.indices where !outside[i] { mask[i] = true }
    }

    /// The pixels outside the mask that the grid's border reaches, 4-connected.
    static func outside(of mask: [Bool], size: Int) -> [Bool] {
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
        return outside
    }

    /// For each pixel of the mask, the distance in pixels to the nearest pixel
    /// outside it (0 outside), by the 3-4 chamfer, which stays within a few
    /// percent of the Euclidean distance. What lies beyond the grid is
    /// outside the mask, unless `borderIsOutside` says the mask goes on there.
    public static func distanceTransform(_ mask: [Bool], size: Int, borderIsOutside: Bool = true) -> [Double] {
        let far = Int.max / 4
        var d = mask.map { $0 ? far : 0 }
        let beyond = borderIsOutside ? 0 : far
        func at(_ x: Int, _ y: Int) -> Int { (x < 0 || y < 0 || x >= size || y >= size) ? beyond : d[y * size + x] }
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
