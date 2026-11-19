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

/// The plaque of a stretch: what lies between the lumen and the outer wall of
/// the vessel, its volume and what it is made of.
///
/// A coronary artery runs in fat, which a CT reads below −30 HU. The vessel
/// of a section is what is not fat around its lumen, out to the fat: the
/// lumen, the wall and the plaque in it. The plaque is the vessel without
/// the lumen, and its volume the sum of its areas along the stretch. What it
/// is made of is read from the intensity of each of its samples, in bands of
/// HU: the lipid-rich or necrotic core, the fibro-fatty and the fibrous
/// plaque, and calcium.
///
/// Where no fat lies between the vessel and something else that is not fat -
/// the myocardium a segment runs on, a vein crossing it - the vessel has no
/// outer wall a threshold can find: it reaches the limit of the section, and
/// the section is left out of the plaque, and counted.
///
/// The bands read intensities, not tissue. The blur of a CT puts between the
/// lumen and the plaque a rim of samples of every intensity between the two,
/// which falls in the bands on the way; plaque at least as bright as the
/// edge of the lumen, half the intensity of its centerline, is in the lumen.
extension Stenosis {
    public struct PlaqueLimits: Equatable, Sendable {
        /// Below this, in HU, is the fat around the vessel, where its wall ends.
        public var fat: Float = -30
        /// The upper limits, in HU, of the lipid-rich or necrotic, the
        /// fibro-fatty and the fibrous plaque; above the last one, calcium.
        public var bands: [Float] = PlaqueLimits.defaultBands

        public static let defaultBands: [Float] = [30, 130, 350]

        public init() {}

        /// The limits with the bands given, when they are three, rise and
        /// lie above the fat; the default ones otherwise.
        public init(bands: [Float]) {
            if bands.count == 3, bands[0] > fat, bands[0] < bands[1], bands[1] < bands[2] { self.bands = bands }
        }
    }

    /// The vessel of one section: the area within its outer wall, lumen
    /// included, and that of its plaque in each band, in mm².
    public struct Wall: Equatable, Sendable {
        public var vesselArea: Double
        public var plaqueArea: Double
        /// Lipid-rich or necrotic, fibro-fatty, fibrous, calcium.
        public var bandAreas: [Double]
    }

    /// The vessel around `lumen` on the grid of a section: what is brighter
    /// than the fat, joined to the lumen through more than a neck, within
    /// `settings.maxRadius` of the centerline, with what it encloses. Nil
    /// without a lumen, and where the vessel reaches that distance: it is
    /// then joined to something else, and has no outer wall here.
    static func wall(values: [Float], size: Int, lumen: [Bool], settings: Settings, limits: PlaqueLimits) -> Wall? {
        guard lumen.contains(true) else { return nil }
        let c = size / 2
        let reach = settings.maxRadius / settings.pixel
        var tissue = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let (dx, dy) = (Double(x - c), Double(y - c))
                tissue[y * size + x] = dx * dx + dy * dy <= reach * reach && (values[y * size + x] > limits.fat || lumen[y * size + x])
            }
        }
        // Open the tissue by the neck: what is joined to the vessel through
        // less than twice it is another structure.
        let neck = settings.neck / settings.pixel
        let inside = distanceTransform(tissue, size: size)
        let core = inside.map { $0 > neck }
        let seeds = zip(lumen, core).map { $0 && $1 }
        guard seeds.contains(true) else { return nil }
        let kept = Self.reach(of: seeds, through: core, size: size)
        // Back out by the neck: the pixels of the tissue within it of what was kept.
        let fromKept = distanceTransform(kept.map { !$0 }, size: size, borderIsOutside: false)
        var vessel = tissue.indices.map { tissue[$0] && (kept[$0] || fromKept[$0] <= neck) || lumen[$0] }
        fillHoles(&vessel, size: size)
        // At the limit of the section the vessel has not ended.
        let limit = reach - 1.5
        var bandAreas = [Double](repeating: 0, count: limits.bands.count + 1)
        var vesselCount = 0
        for y in 0..<size {
            for x in 0..<size where vessel[y * size + x] {
                let (dx, dy) = (Double(x - c), Double(y - c))
                if dx * dx + dy * dy >= limit * limit { return nil }
                vesselCount += 1
                guard !lumen[y * size + x] else { continue }
                let value = values[y * size + x]
                bandAreas[limits.bands.firstIndex { value <= $0 } ?? limits.bands.count] += 1
            }
        }
        let pixelArea = settings.pixel * settings.pixel
        bandAreas = bandAreas.map { $0 * pixelArea }
        return Wall(vesselArea: Double(vesselCount) * pixelArea, plaqueArea: bandAreas.reduce(0, +), bandAreas: bandAreas)
    }

    /// The plaque of a stretch, in mm³: each section stands for the step
    /// along the centerline around it.
    public struct Plaque: Equatable, Sendable {
        public var vesselVolume: Double
        public var lumenVolume: Double
        public var plaqueVolume: Double
        /// Lipid-rich or necrotic, fibro-fatty, fibrous, calcium.
        public var bandVolumes: [Double]
        /// The sections the volumes come from, and those with a lumen whose
        /// vessel had no outer wall to find, which are left out of them.
        public var sectionCount: Int
        public var withoutWallCount: Int
        public var limits: PlaqueLimits

        /// The share of the vessel the plaque takes, in percent.
        public var burden: Double { vesselVolume > 0 ? plaqueVolume / vesselVolume * 100 : 0 }
        /// The share of the plaque each band takes, in percent.
        public var bandShares: [Double] { bandVolumes.map { plaqueVolume > 0 ? $0 / plaqueVolume * 100 : 0 } }
    }

    /// The plaque of `sections`, measured `step` mm apart with `limits`; nil
    /// when no section has a wall (they were measured without plaque limits,
    /// or none has an outer wall).
    public static func plaque(of sections: [Section], step: Double, limits: PlaqueLimits) -> Plaque? {
        let walls = sections.compactMap { section in section.wall.map { (section.area, $0) } }
        guard !walls.isEmpty else { return nil }
        var bands = [Double](repeating: 0, count: limits.bands.count + 1)
        for (_, wall) in walls { for (i, area) in wall.bandAreas.enumerated() where i < bands.count { bands[i] += area * step } }
        return Plaque(vesselVolume: walls.map(\.1.vesselArea).reduce(0, +) * step, lumenVolume: walls.map(\.0).reduce(0, +) * step,
                      plaqueVolume: walls.map(\.1.plaqueArea).reduce(0, +) * step, bandVolumes: bands, sectionCount: walls.count,
                      withoutWallCount: sections.filter { $0.isValid && $0.wall == nil }.count, limits: limits)
    }
}
