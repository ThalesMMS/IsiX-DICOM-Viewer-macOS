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
import IsiXImaging

/// The words of a stenosis measure (see Stenosis), as the tool's strip shows
/// them and as Copy Summary copies them: the numbers, then how the lumen was
/// told from what is around it.
///
/// A report that takes the numbers has to take with them what was left out
/// of the lumen and by which rule, and whether someone corrected the lumen by
/// hand: a number that comes from a corrected section carries an asterisk,
/// and a line under the numbers says what the asterisk means. Sections whose
/// whole lumen the calcium exclusion or the eraser took are left out of the
/// numbers, and a line says how many. When the calcium exclusion took one
/// outside the reference, the narrowest lumen may be among them: the minimum
/// and the degrees carry a dagger, and the line says the stenosis is at
/// least that severe. The rule says where the lumen stops, at the share of
/// each section's own centerline intensity, and what calcium is left out even
/// where the lumen surrounds it: what is also brighter than the same share of
/// the intensity in the middle of the reference's lumen. Under it, a line says
/// where calcium above the limit touched the lumen, and where none did, that
/// plaque dimmer than the limit is in the area.
struct StenosisSummary {
    var stretchLength: Double
    var result: Stenosis.Result
    /// In mm from the start of the stretch.
    var reference: ClosedRange<Double>
    var settings: Stenosis.Settings
    /// The plaque of the stretch; nil when it was not measured, or when no
    /// section has an outer wall to measure it to.
    var plaque: Stenosis.Plaque?
    /// Whose decimal separator the numbers take: the user's region, so that
    /// «Copy Summary» pastes «12,6 mm²» into a report in Portuguese or German.
    var locale: Locale = .current

    /// Whether the stretch was measured as a coronary artery, against a
    /// proximal and a distal reference: its numbers then open with the
    /// degree by diameter, the one a coronary CT is read by, and say what
    /// each reference measured and that the reference at the narrowest
    /// section lies between them. A carotid's are as they always were.
    private var coronary: (proximal: Stenosis.ReferenceSide, distal: Stenosis.ReferenceSide)? {
        guard settings.vessel == .coronary, let proximal = result.proximalReference, let distal = result.distalReference else { return nil }
        return (proximal, distal)
    }

    var opensWithTheDegree: Bool { coronary != nil }

    var title: String {
        coronary != nil
            ? String(format: NSLocalizedString("Coronary stenosis, curved MPR stretch of %@ mm", comment: "Stenosis summary, first line, of a stretch measured as a coronary artery"), decimal(1, stretchLength))
            : String(format: NSLocalizedString("Stenosis, curved MPR stretch of %@ mm", comment: "Stenosis summary, first line"), decimal(1, stretchLength))
    }

    /// The numbers, a line each, and under them the meaning of the asterisk
    /// when a lumen corrected by hand comes into any of them, and of the
    /// dagger when the narrowest lumen may be among the sections left out.
    var numbers: [String] {
        let bound = result.takenByCalciumOutsideReference
        func marked(_ line: String, _ corrected: Bool, _ atLeast: Bool = false) -> String {
            line + (corrected ? " *" : "") + (atLeast ? " †" : "")
        }
        let byArea = result.minimumCorrected || result.referenceCorrected
        let byDiameter = result.minimumDiameterCorrected || result.referenceCorrected
        var lines = coronary.map { proximal, distal in [
            marked(String(format: NSLocalizedString("Stenosis by diameter: %@ %%", comment: "Stenosis summary of a coronary artery: the degree, (1 − minimum diameter / reference diameter) × 100"), decimal(0, result.nascetByDiameter)), byDiameter, bound),
            marked(String(format: NSLocalizedString("Minimum diameter: %@ mm (equivalent %@ mm)", comment: "Stenosis summary"), decimal(2, result.minimumDiameter), decimal(2, result.equivalentDiameter)), result.minimumDiameterCorrected, bound),
            marked(String(format: NSLocalizedString("Reference diameter: %@ mm at the narrowest, between proximal %@ mm and distal %@ mm", comment: "Stenosis summary of a coronary artery: the reference diameter interpolated at the narrowest section, then the mean diameters of the proximal and of the distal reference"), decimal(2, result.referenceDiameter), decimal(2, proximal.diameter), decimal(2, distal.diameter)), result.referenceCorrected),
            marked(String(format: NSLocalizedString("Stenosis by area: %@ %%", comment: "Stenosis summary of a coronary artery: (1 − minimum area / reference area) × 100"), decimal(0, result.nascetByArea)), byArea, bound),
            marked(String(format: NSLocalizedString("Minimum area: %@ mm² at %@ mm", comment: "Stenosis summary"), decimal(1, result.minimumArea), decimal(1, result.minimumPosition)), result.minimumCorrected, bound),
            marked(String(format: NSLocalizedString("Reference area: %@ mm² at the narrowest, between proximal %@ mm² (%@–%@ mm) and distal %@ mm² (%@–%@ mm)", comment: "Stenosis summary of a coronary artery: the reference area interpolated at the narrowest section, then the mean area of the proximal reference with where it lies along the stretch, and the same of the distal one"), decimal(1, result.referenceArea), decimal(1, proximal.area), decimal(1, proximal.range.lowerBound), decimal(1, proximal.range.upperBound), decimal(1, distal.area), decimal(1, distal.range.lowerBound), decimal(1, distal.range.upperBound)), result.referenceCorrected),
            marked(String(format: NSLocalizedString("Mean area of the stretch: %@ mm²", comment: "Stenosis summary"), decimal(1, result.meanArea)), result.correctedCount > 0),
        ] } ?? [
            marked(String(format: NSLocalizedString("Minimum area: %@ mm² at %@ mm", comment: "Stenosis summary"), decimal(1, result.minimumArea), decimal(1, result.minimumPosition)), result.minimumCorrected, bound),
            marked(String(format: NSLocalizedString("Reference area: %@ mm² (%@–%@ mm)", comment: "Stenosis summary"), decimal(1, result.referenceArea), decimal(1, reference.lowerBound), decimal(1, reference.upperBound)), result.referenceCorrected),
            marked(String(format: NSLocalizedString("Mean area of the stretch: %@ mm²", comment: "Stenosis summary"), decimal(1, result.meanArea)), result.correctedCount > 0),
            marked(String(format: NSLocalizedString("NASCET by area: %@ %%", comment: "Stenosis summary"), decimal(0, result.nascetByArea)), byArea, bound),
            marked(String(format: NSLocalizedString("Minimum diameter: %@ mm (equivalent %@ mm)", comment: "Stenosis summary"), decimal(2, result.minimumDiameter), decimal(2, result.equivalentDiameter)), result.minimumDiameterCorrected || result.minimumCorrected, bound),
            marked(String(format: NSLocalizedString("Reference diameter: %@ mm", comment: "Stenosis summary"), decimal(2, result.referenceDiameter)), result.referenceCorrected),
            marked(String(format: NSLocalizedString("NASCET by diameter: %@ %%", comment: "Stenosis summary"), decimal(0, result.nascetByDiameter)), byDiameter, bound),
        ]
        if result.correctedCount > 0 {
            lines.append(String(format: NSLocalizedString("* With the lumen corrected by hand (sections corrected: %@)", comment: "Stenosis summary: what the asterisk after a number means; the argument is how many sections of the stretch were corrected"), String(result.correctedCount)))
        }
        if result.takenByCalciumCount > 0 {
            lines.append(bound
                ? String(format: NSLocalizedString("† Sections left out, no lumen after the calcium exclusion: %@; the narrowest lumen may be among them, so the stenosis is at least this severe", comment: "Stenosis summary: what the dagger after the minimum and the degrees means; the argument is how many sections lost their whole lumen to the calcium limit and its margin, some of them outside the reference, and are not in the numbers above"), String(result.takenByCalciumCount))
                : String(format: NSLocalizedString("Sections left out, no lumen after the calcium exclusion: %@", comment: "Stenosis summary: how many sections lost their whole lumen to the calcium limit and its margin, and are not in the numbers above"), String(result.takenByCalciumCount)))
        }
        if result.takenByHandCount > 0 {
            lines.append(String(format: NSLocalizedString("Sections left out, erased whole by hand: %@", comment: "Stenosis summary: how many sections had their whole lumen erased by hand, and are not in the numbers above"), String(result.takenByHandCount)))
        }
        if let line = strutsLine { lines.append(line) }
        return lines + plaqueLines
    }

    /// How the lumen was told from the rest: its edge, the calcium limit as
    /// a share of each section's centerline intensity, which the lumen stops
    /// at, the intensity calcium has to be above too to be left out even
    /// where the lumen surrounds it, the same share of the contrast of the
    /// reference, the margin around that calcium, and where calcium above
    /// the limit touched the lumen and was left out.
    var criteria: [String] {
        let limit = decimal(0, settings.upperFraction * 100)
        let value = decimal(0, settings.upperFraction * result.contrast)
        let vessel = coronary == nil ? [] : [
            NSLocalizedString("Measured as a coronary artery: the reference at the narrowest section is interpolated between the proximal and the distal one", comment: "Stenosis summary of a coronary artery, first line of how it was measured"),
        ]
        let wall = settings.plaque.map {
            [String(format: NSLocalizedString("Vessel wall where the fat begins, below %@ HU; plaque as bright as the lumen edge or brighter is in the lumen", comment: "Stenosis summary of a coronary artery, how the plaque was told: the outer wall is where the intensity falls under that of fat"), decimal(0, Double($0.fat)))]
        } ?? []
        return vessel + wall + [
            String(format: NSLocalizedString("Lumen edge at %@ %% of the centerline intensity", comment: "Stenosis summary"), decimal(0, settings.lowerFraction * 100)),
            settings.calciumMargin > 0
                ? String(format: NSLocalizedString("Calcium limit: %@ %% of each section's centerline intensity, which the lumen stops at; calcium also above %@ (the same share of the intensity in the middle of the reference's lumen) is left out even where the lumen surrounds it, and the lumen within %@ mm of it", comment: "Stenosis summary: the calcium limit as a percentage of the intensity at the centerline of each section, where the lumen stops; the intensity calcium has to be above too, the same percentage of the intensity in the middle of the reference's lumen, to be left out even where the lumen surrounds it; and the margin, how far around that calcium the lumen is left out with it"), limit, value, decimal(1, settings.calciumMargin))
                : String(format: NSLocalizedString("Calcium limit: %@ %% of each section's centerline intensity, which the lumen stops at; calcium also above %@ (the same share of the intensity in the middle of the reference's lumen) is left out even where the lumen surrounds it", comment: "Stenosis summary: the calcium limit as a percentage of the intensity at the centerline of each section, where the lumen stops; and the intensity calcium has to be above too, the same percentage of the intensity in the middle of the reference's lumen, to be left out even where the lumen surrounds it; without a margin"), limit, value),
            calciumLine,
        ]
    }

    /// The plaque of a stretch measured with plaque limits: its volume and
    /// the share of the vessel it takes, then each band with the limits it
    /// was read with, and how many sections had no fat around the vessel to
    /// end its wall, which are left out. When none has, that it was not
    /// measured. Nothing for a stretch measured without the limits.
    var plaqueLines: [String] {
        guard let limits = settings.plaque else { return [] }
        guard let plaque, plaque.bandVolumes.count == 4, limits.bands.count == 3 else {
            return [NSLocalizedString("Plaque not measured: no section of the stretch has fat around the vessel to end its wall", comment: "Stenosis summary of a coronary artery: the plaque could not be measured")]
        }
        func hu(_ value: Float) -> String { decimal(0, Double(value)) }
        let shares = plaque.bandShares
        func band(_ index: Int) -> (String, String) { (decimal(1, plaque.bandVolumes[index]), decimal(0, shares[index])) }
        var lines = [
            String(format: NSLocalizedString("Plaque volume: %@ mm³, %@ %% of the vessel (%@ mm³)", comment: "Stenosis summary of a coronary artery: the volume of the plaque along the stretch, the share of the vessel's volume it takes, and the volume within the vessel's outer wall"), decimal(1, plaque.plaqueVolume), decimal(0, plaque.burden), decimal(1, plaque.vesselVolume)),
            String(format: NSLocalizedString("Lipid-rich or necrotic (below %@ HU): %@ mm³, %@ %%", comment: "Stenosis summary: a band of the plaque by its intensity, its volume and its share of the plaque"), hu(limits.bands[0]), band(0).0, band(0).1),
            String(format: NSLocalizedString("Fibro-fatty (%@ to %@ HU): %@ mm³, %@ %%", comment: "Stenosis summary: a band of the plaque by its intensity, its volume and its share of the plaque"), hu(limits.bands[0]), hu(limits.bands[1]), band(1).0, band(1).1),
            String(format: NSLocalizedString("Fibrous (%@ to %@ HU): %@ mm³, %@ %%", comment: "Stenosis summary: a band of the plaque by its intensity, its volume and its share of the plaque"), hu(limits.bands[1]), hu(limits.bands[2]), band(2).0, band(2).1),
            String(format: NSLocalizedString("Calcium (above %@ HU): %@ mm³, %@ %%", comment: "Stenosis summary: a band of the plaque by its intensity, its volume and its share of the plaque"), hu(limits.bands[2]), band(3).0, band(3).1),
        ]
        if plaque.withoutWallCount > 0 {
            lines.append(String(format: NSLocalizedString("Sections left out of the plaque, no fat around the vessel to end its wall: %@ of %@", comment: "Stenosis summary: how many sections with a lumen had no outer wall to find, of how many sections with a lumen"), String(plaque.withoutWallCount), String(plaque.withoutWallCount + plaque.sectionCount)))
        }
        return lines
    }

    /// Where the stretch shows the struts of a stent and some of its sections
    /// do not (the end of a stent, where they fade, or a ring too blurred):
    /// how many, and whether the narrowest is one of them. Their lumen is the
    /// threshold's, which takes the struts and their blur for lumen. Nil for
    /// a stretch with no such section.
    var strutsLine: String? {
        guard result.strutRingMissedCount > 0 else { return nil }
        let count = String(result.strutRingMissedCount)
        return result.minimumStrutRingMissed
            ? String(format: NSLocalizedString("Stent struts not recognised in %@ sections beside sections that show them, the narrowest included: their areas may include the struts", comment: "Stenosis summary: in how many sections of the stretch the ring of a stent's struts was not told although the sections next to them show it, the section of the minimum area among them; the lumen measured there may take the struts for lumen"), count)
            : String(format: NSLocalizedString("Stent struts not recognised in %@ sections beside sections that show them: their areas may include the struts", comment: "Stenosis summary: in how many sections of the stretch the ring of a stent's struts was not told although the sections next to them show it, not the section of the minimum area; the lumen measured there may take the struts for lumen"), count)
    }

    /// The last line of the criteria: where calcium above the limit touched
    /// the lumen and was left out, and where none did, that plaque dimmer
    /// than the limit is in the area.
    var calciumLine: String {
        let found = String(result.calciumBesideCount), sections = String(result.sectionsWithContrast)
        return result.calciumBesideCount == 0
            ? NSLocalizedString("No calcium above the limit touched the lumen: plaque dimmer than the limit is in the areas", comment: "Stenosis summary, last line: the calcium limit left nothing out of the lumen of any section")
            : result.minimumCalciumBeside
            ? String(format: NSLocalizedString("Calcium above the limit touched the lumen and was left out in %@ of %@ sections, the narrowest included", comment: "Stenosis summary, last line: in how many sections calcium above the limit touched the lumen and was left out of it, of the sections with contrast, the section of the minimum area among them"), found, sections)
            : String(format: NSLocalizedString("Calcium above the limit touched the lumen and was left out in %@ of %@ sections, not at the narrowest: plaque dimmer than the limit is in its area", comment: "Stenosis summary, last line: in how many sections calcium above the limit touched the lumen and was left out of it, of the sections with contrast, not the section of the minimum area"), found, sections)
    }

    /// What the strip beside the chart shows: the numbers, and under them
    /// whether calcium above the limit touched the lumen, which says whether
    /// plaque is in the areas. The strip shows the lumen edge and the calcium
    /// limit on its sliders.
    var strip: [String] { numbers + [calciumLine] }

    var text: String { ([title] + numbers + criteria).joined(separator: "\n") }

    private func decimal(_ digits: Int, _ value: Double) -> String { Self.decimal(digits, value, locale: locale) }

    /// A number with a fixed count of decimals and the locale's separator.
    static func decimal(_ digits: Int, _ value: Double, locale: Locale = .current) -> String {
        String(format: "%.\(digits)f", locale: locale, value)
    }
}
