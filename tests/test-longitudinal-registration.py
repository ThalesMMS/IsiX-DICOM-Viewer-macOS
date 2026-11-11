#!/usr/bin/env python3
"""Phantoms for the longitudinal registration core.

Known rigid transforms, landmark error, round trip, refusals, quality verdicts,
companion overlays with independent transforms and blend, the explicit
two-patient comparison selection, and the guided ROI copy planner (A237: each
ROI on its own physical slice, never on the active one). Tolerances are fixed
in the driver before any comparison.
"""
import private_tmpdir  # noqa: F401  - its TMPDIR holds the harness preference domains
import harness_defaults
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402  - ROIInterchange.swift writes IsiXROI's ROIInterchangeDocument
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
driver = r'''
import Foundation
import simd
func expect(_ ok: Bool, _ reason: String) { if !ok { fatalError(reason) } }
let exact = 1e-9, noisy = 0.6

// A known rigid transform: 10 degrees about z, then 5 degrees about x, then a translation.
let rz = simd_quatd(angle: 10 * .pi / 180, axis: SIMD3(0, 0, 1))
let rx = simd_quatd(angle: 5 * .pi / 180, axis: SIMD3(1, 0, 0))
let rotation = double3x3(rx * rz)
let translation = SIMD3<Double>(5, -3, 2)
var known = double4x4(SIMD4(rotation[0].x, rotation[0].y, rotation[0].z, 0), SIMD4(rotation[1].x, rotation[1].y, rotation[1].z, 0),
                      SIMD4(rotation[2].x, rotation[2].y, rotation[2].z, 0), SIMD4(translation.x, translation.y, translation.z, 1))
let knownTransform = RegistrationTransform(matrix: known)
let names = ["L1", "L2", "L3", "L4", "L5"]
let moving: [[Double]] = [[10, 20, 30], [-40, 15, 12], [25, -30, 60], [0, 0, -20], [33, 44, 5]]
let fixed = moving.map { knownTransform.apply($0) }

// 1. Exact recovery.
let result = LandmarkRegistration.solve(fixedNames: names, fixedPoints: fixed, movingNames: names.reversed(), movingPoints: moving.reversed(),
                                        movingBounds: nil, fixedBounds: nil)
expect(result.refusal == nil && result.transform != nil, "exact landmarks solve: \(result.refusal ?? "")")
let solved = result.transform!
var worst = 0.0
for r in 0..<4 { for c in 0..<4 { worst = max(worst, abs(solved.matrix[c][r] - known[c][r])) } }
expect(worst < exact, "matrix recovered within 1e-9 (worst \(worst))")
expect(result.quality!.rmsMM < exact && result.quality!.maxMM < exact, "zero landmark error")
expect(result.quality!.verdict == .accepted, "exact fit accepted")
expect(result.quality!.landmarkCount == 5, "five landmarks counted")
expect(solved.algorithm.contains("Horn") && !solved.version.isEmpty, "algorithm and version recorded")

// 2. Round trip through the inverse and row-major conversion.
for p in moving {
    let back = solved.inverse.apply(solved.apply(p))
    expect(zip(back, p).allSatisfy { abs($0 - $1) < exact }, "inverse round trip")
}
let rebuilt = RegistrationTransform(rowMajor: solved.rowMajor)!
expect(zip(rebuilt.apply(moving[0]), solved.apply(moving[0])).allSatisfy { abs($0 - $1) < exact }, "row-major round trip")
expect(solved.inverse.concatenated(after: solved).isIdentity, "T^-1 T is the identity")
expect(RegistrationTransform(rowMajor: [1, 2, 3]) == nil, "16 finite numbers required")

// 3. Deterministic noise: RMS bounded, still accepted.
let perturbed = fixed.enumerated().map { i, p in [p[0] + 0.4 * (i % 2 == 0 ? 1 : -1), p[1] - 0.3, p[2] + 0.2 * Double(i - 2)] }
let noisyResult = LandmarkRegistration.solve(fixedNames: names, fixedPoints: perturbed, movingNames: names, movingPoints: moving,
                                             movingBounds: nil, fixedBounds: nil)
expect(noisyResult.quality!.rmsMM > 0 && noisyResult.quality!.rmsMM < noisy, "noisy RMS \(noisyResult.quality!.rmsMM) within 0.6 mm")
expect(noisyResult.quality!.verdict == .accepted, "sub-millimetre noise accepted")

// 4. Refusals, each by reason.
expect(LandmarkRegistration.solve(fixedNames: ["A", "B"], fixedPoints: [fixed[0], fixed[1]], movingNames: ["A", "B"], movingPoints: [moving[0], moving[1]],
                                  movingBounds: nil, fixedBounds: nil).refusal?.contains("at least 3") == true, "two landmarks refused")
let line: [[Double]] = [[0, 0, 0], [1, 0, 0], [2, 0, 0], [3, 0, 0]]
expect(LandmarkRegistration.solve(fixedNames: ["A", "B", "C", "D"], fixedPoints: line, movingNames: ["A", "B", "C", "D"], movingPoints: line,
                                  movingBounds: nil, fixedBounds: nil).refusal?.contains("collinear") == true, "collinear refused")
expect(LandmarkRegistration.solve(fixedNames: names, fixedPoints: fixed, movingNames: ["L1", "L2", "L3", "L4", "X"], movingPoints: moving,
                                  movingBounds: nil, fixedBounds: nil).refusal?.contains("two by two") == true, "unpaired name refused")
expect(LandmarkRegistration.solve(fixedNames: ["L1", "L1", "L3", "L4", "L5"], fixedPoints: fixed, movingNames: names, movingPoints: moving,
                                  movingBounds: nil, fixedBounds: nil).refusal?.contains("repeated") == true, "repeated name refused")
expect(LandmarkRegistration.solve(fixedNames: names, fixedPoints: fixed, movingNames: Array(names.prefix(4)), movingPoints: Array(moving.prefix(4)),
                                  movingBounds: nil, fixedBounds: nil).refusal?.contains("same number") == true, "count mismatch refused")
expect(LandmarkRegistration.solve(fixedNames: names, fixedPoints: fixed, movingNames: names, movingPoints: [[Double.nan, 0, 0]] + Array(moving.dropFirst()),
                                  movingBounds: nil, fixedBounds: nil).refusal?.contains("finite") == true, "NaN refused")

// 5. Quality verdicts: a 30 mm outlier rejects; a volume carried away rejects even with perfect landmarks.
var outlier = fixed; outlier[0][0] += 30
let bad = LandmarkRegistration.solve(fixedNames: names, fixedPoints: outlier, movingNames: names, movingPoints: moving, movingBounds: nil, fixedBounds: nil)
expect(bad.quality!.verdict == .rejected && bad.quality!.reasons.contains { $0.contains("RMS") } && !bad.isUsable, "large landmark error rejected with reason")
let movingBox = VolumeBounds(minimum: [-50, -50, -30], maximum: [50, 50, 70])!
let farBox = VolumeBounds(minimum: [400, 400, 400], maximum: [500, 500, 500])!
let away = LandmarkRegistration.solve(fixedNames: names, fixedPoints: fixed, movingNames: names, movingPoints: moving, movingBounds: movingBox, fixedBounds: farBox)
expect(away.quality!.overlapFraction == 0 && away.quality!.verdict == .rejected && away.quality!.reasons.contains { $0.contains("overlap") },
       "no overlap rejected even with zero landmark error")
let nearBox = VolumeBounds(minimum: [-45, -45, -25], maximum: [55, 55, 75])!
let close = LandmarkRegistration.solve(fixedNames: names, fixedPoints: fixed, movingNames: names, movingPoints: moving, movingBounds: movingBox, fixedBounds: nearBox)
expect(close.quality!.overlapFraction > 0.6 && close.quality!.verdict == .accepted, "overlapping volumes accepted (\(close.quality!.overlapFraction))")
expect(VolumeBounds(minimum: [1, 0, 0], maximum: [0, 1, 1]) == nil, "inverted bounds refused")

// 6. Companion overlays: independent transforms, blend, reject and reset.
let session = RegistrationSession(baseSeriesInstanceUID: "1.2.base", baseFrameOfReferenceUID: "1.2.frame.A")
let shared = session.addCompanion(seriesInstanceUID: "1.2.same", frameOfReferenceUID: "1.2.frame.A", blend: 0.5)
expect(shared.isAligned && shared.transform.isIdentity, "same frame of reference starts aligned with the identity")
let other = session.addCompanion(seriesInstanceUID: "1.2.other", frameOfReferenceUID: "1.2.frame.B", blend: 0.3)
expect(!other.isAligned, "a different frame of reference is not assumed aligned")
let generationBefore = session.generation
expect(session.setRegistration("1.2.other", result: result), "accepted registration attaches to its companion")
expect(other.isAligned && !other.transform.isIdentity && shared.transform.isIdentity, "companions keep independent transforms")
expect(!session.setRegistration("1.2.other", result: bad) && !other.isAligned, "a rejected registration leaves the companion unaligned")
session.setBlend("1.2.other", blend: 1.7); expect(other.blend == 1, "blend clamps to 0...1")
session.setBlend("1.2.same", blend: 0.25); expect(shared.blend == 0.25 && other.blend == 1, "blend is per companion")
expect(session.setRegistration("1.2.other", result: result) && other.isAligned, "re-registration restores alignment")
session.reject("1.2.other"); expect(!other.isAligned, "user rejection")
session.reset("1.2.other"); expect(other.transform.isIdentity && !other.isAligned && other.quality == nil, "reset of a foreign frame is identity but unaligned")
session.reset("1.2.same"); expect(shared.isAligned, "reset of a shared frame is aligned identity")
expect(session.generation > generationBefore + 5, "every edit advances the generation panes check")
session.removeCompanion("1.2.other"); expect(session.companions.count == 1, "companion removal")
expect(session.setRegistration("1.2.missing", result: result) == false, "unknown companion ignored")

// 7. Two-patient comparison: explicit, by study UID, persisted, never by name.
let defaults = UserDefaults(suiteName: harnessDomainName("org.horos.test.comparison.\(UUID().uuidString)"))!
expect(PatientComparisonSelection(firstPatientID: "P1", firstStudyInstanceUID: "1.2.s1", secondPatientID: "P2", secondStudyInstanceUID: "1.2.s1") == nil,
       "the same study cannot be compared with itself")
let selection = PatientComparisonSelection(firstPatientID: "P1", firstStudyInstanceUID: "1.2.s1", secondPatientID: "P2", secondStudyInstanceUID: "1.2.s2")!
selection.store(in: defaults)
expect(PatientComparisonSelection.find(in: defaults, studyA: "1.2.s2", patientA: "P2", studyB: "1.2.s1", patientB: "P1") != nil, "found in either order")
expect(PatientComparisonSelection.find(in: defaults, studyA: "1.2.s1", patientA: "P9", studyB: "1.2.s2", patientB: "P2") == nil, "a different patient ID under the same study UID is not the same choice")
expect(PatientComparisonSelection.find(in: defaults, studyA: "1.2.s1", patientA: "P1", studyB: "1.2.s3", patientB: "P2") == nil, "another study is another comparison")
selection.store(in: defaults); expect(PatientComparisonSelection.stored(in: defaults).count == 1, "re-storing the same pair does not duplicate")
expect(PatientComparisonSelection.requiresExplicitChoice(patientA: "P1", nameA: "DOE^JOHN", patientB: "P1", nameB: "DOE^JANE"), "same ID, different names: ask")
expect(PatientComparisonSelection.requiresExplicitChoice(patientA: "P1", nameA: "DOE^JOHN", patientB: "P2", nameB: "DOE^JOHN"), "same name, different IDs: ask")
expect(!PatientComparisonSelection.requiresExplicitChoice(patientA: "P1", nameA: "DOE^JOHN", patientB: "P1", nameB: "DOE^JOHN"), "same patient: no comparison prompt")

// 8. Guided ROI copy.
func series(uid: String, frame: String, count: Int, spacing: Double, transform: RegistrationTransform?, coronal: Bool = false) -> ROIInterchangeSeries {
    let s = ROIInterchangeSeries(); s.studyInstanceUID = "1.2.study"; s.seriesInstanceUID = uid; s.frameOfReferenceUID = frame
    for i in 0..<count {
        let image = ROIInterchangeImage(); image.index = i; image.sopInstanceUID = uid + ".\(i)"; image.rows = 64; image.columns = 64
        image.pixelSpacingX = 1; image.pixelSpacingY = 1; image.sliceThickness = spacing
        var position = coronal ? SIMD3<Double>(-32, Double(i) * spacing, 32) : SIMD3<Double>(-32, -32, Double(i) * spacing)
        var row = coronal ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(1, 0, 0)
        var col = coronal ? SIMD3<Double>(0, 0, -1) : SIMD3<Double>(0, 1, 0)
        if let t = transform { position = t.apply(position); row = t.rotate(row); col = t.rotate(col) }
        image.imagePosition = [position.x, position.y, position.z]
        image.imageOrientation = [row.x, row.y, row.z, col.x, col.y, col.z]
        s.images.append(image)
    }
    return s
}
func polygon(_ name: String, _ points: [(Double, Double)]) -> ROIInterchangeROI {
    let roi = ROIInterchangeROI(); roi.name = name; roi.typeCode = ROIInterchangeType.closedPolygon.rawValue
    roi.points = points.map { NSValue(point: NSPoint(x: $0.0, y: $0.1)) }; return roi
}
let source = series(uid: "1.2.src", frame: "1.2.frame.A", count: 8, spacing: 2, transform: nil)
source.images[1].rois = [polygon("P1", [(10, 10), (20, 10), (20, 20)])]
source.images[3].rois = [polygon("P3", [(30, 30), (40, 30), (40, 40), (30, 40)])]
source.images[5].rois = [polygon("P5", [(5, 50), (15, 50), (10, 50)])] // constant y: a line the coronal plane y = 18 contains
let point = ROIInterchangeROI(); point.name = "Pt6"; point.typeCode = ROIInterchangeType.point2D.rawValue; point.hasRect = true
point.rect = NSRect(x: 12, y: 34, width: 0, height: 0); source.images[6].rois = [point]
let brush = ROIInterchangeROI(); brush.name = "Brush2"; brush.typeCode = ROIInterchangeType.brush.rawValue
brush.brushWidth = 4; brush.brushHeight = 4; brush.brushOriginX = 20; brush.brushOriginY = 40; brush.brushMask = Data(repeating: 1, count: 16)
source.images[2].rois = [brush]

// 8a. Target = source geometry carried by the known transform; copying through it lands on the same slices and pixels.
let carried = series(uid: "1.2.dst", frame: "1.2.frame.B", count: 8, spacing: 2, transform: knownTransform)
let plan = GuidedROICopy.plan(source: source, target: carried, transform: knownTransform, offsetMM: [0, 0, 0])
expect(plan.placements.count == 5 && plan.refused.isEmpty, "every ROI placed: \(plan.summary)")
for p in plan.placed {
    expect(p.targetImageIndex == p.sourceImageIndex, "\(p.name) lands on its own physical slice, not the active one")
    expect(p.throughPlaneMM < 1e-6, "\(p.name) lies on the target plane")
    expect(p.provenance.contains("1.2.src") && p.provenance.contains("Horn"), "provenance names the source series and algorithm")
}
let p1 = plan.placed.first { $0.name == "P1" }!
expect(zip(p1.points, [[10.0, 10.0], [20, 10], [20, 20]]).allSatisfy { abs($0[0] - $1[0]) < 1e-6 && abs($0[1] - $1[1]) < 1e-6 }, "polygon pixels preserved through the rigid carry")
let pt = plan.placed.first { $0.name == "Pt6" }!
expect(abs(pt.rect.origin.x - 12) < 1e-6 && abs(pt.rect.origin.y - 34) < 1e-6, "2D point rect carried")
let br = plan.placed.first { $0.name == "Brush2" }!
expect(abs(br.rect.origin.x - 20) < 1e-6 && abs(br.rect.origin.y - 40) < 1e-6 && br.rect.size.width == 4, "brush origin carried without resampling")
expect(br.mask == Data(repeating: 0xFF, count: 16), "the brush's mask carried whole through the rigid carry")
expect(Set(plan.placed.map(\.targetImageIndex)).count == 5, "five ROIs on five distinct slices (A237)")

// 8b. Same frame, finer target: physical position decides the index.
let finer = series(uid: "1.2.fine", frame: "1.2.frame.A", count: 15, spacing: 1, transform: nil)
let finePlan = GuidedROICopy.plan(source: source, target: finer, transform: .identity, offsetMM: [0, 0, 0])
let fineIndex = Dictionary(uniqueKeysWithValues: finePlan.placed.filter { $0.name != "Brush2" }.map { ($0.name, $0.targetImageIndex) })
expect(fineIndex["P1"] == 2 && fineIndex["P3"] == 6 && fineIndex["P5"] == 10 && fineIndex["Pt6"] == 12, "finer target: 2, 6, 10, 12 (\(fineIndex))")
// A brush is a slab of the volume: every target image whose nearest source image is the brush's takes it,
// the image half way between two taking the one before it.
let fineBrush = finePlan.placed.filter { $0.name == "Brush2" }
expect(fineBrush.map(\.targetImageIndex) == [4, 5], "the brush of the image at 4 mm fills the target images at 4 and 5 mm (\(fineBrush.map(\.targetImageIndex)))")
expect(fineBrush.allSatisfy { $0.rect == NSRect(x: 20, y: 40, width: 4, height: 4) && $0.mask == Data(repeating: 0xFF, count: 16) }, "on the same pixel grid the mask is the same")

// 8c. Manual offset of one slice spacing moves every ROI one slice.
let shifted = GuidedROICopy.plan(source: source, target: series(uid: "1.2.dst2", frame: "1.2.frame.A", count: 8, spacing: 2, transform: nil),
                                 transform: .identity, offsetMM: [0, 0, 2])
expect(shifted.placed.allSatisfy { $0.targetImageIndex == $0.sourceImageIndex + 1 }, "manual +2 mm offset moves one slice")
expect(shifted.offsetMM == [0, 0, 2], "offset recorded in the plan")

// 8d. Coronal target: polygons reprojected onto the coronal plane they share; pixel-geometry ROIs refused, by name.
let coronal = series(uid: "1.2.cor", frame: "1.2.frame.A", count: 64, spacing: 1, transform: nil, coronal: true)
let corPlan = GuidedROICopy.plan(source: source, target: coronal, transform: .identity, offsetMM: [0, 0, 0])
let corStatus = Dictionary(uniqueKeysWithValues: corPlan.placements.map { ($0.name, $0) })
expect(corStatus["Brush2"]!.status == .unsupportedGeometry && corStatus["Brush2"]!.reason.contains("not resampled"), "brush not resampled onto another orientation")
expect(corStatus["Pt6"]!.status == .unsupportedGeometry, "2D point keeps pixel geometry")
expect(corStatus["P5"]!.status == .placed && corStatus["P5"]!.targetImageIndex == 18, "a polygon at constant y lands on the coronal plane y = 18: \(corStatus["P5"]!.reason)")
expect(corStatus["P3"]!.status == .noSlice && corStatus["P3"]!.reason.contains("spans"), "a polygon spanning y is refused, not flattened")
expect(corStatus["P1"]!.status == .noSlice && corStatus["P1"]!.reason.contains("No target image"), "a polygon outside the coronal stack is refused")

// 8e. No target plane near: refused, never dropped onto the active slice.
let far = series(uid: "1.2.far", frame: "1.2.frame.A", count: 4, spacing: 2, transform: RegistrationTransform(rowMajor: [1,0,0,0, 0,1,0,0, 0,0,1,100, 0,0,0,1])!)
let farPlan = GuidedROICopy.plan(source: source, target: far, transform: .identity, offsetMM: [0, 0, 0])
expect(farPlan.placed.isEmpty && farPlan.placements.allSatisfy { $0.status == .noSlice }, "no slice within tolerance refuses every ROI")
expect(GuidedROICopy.planeTolerance(for: far) == 1 && GuidedROICopy.planeTolerance(for: finer) == 0.5, "tolerance is half the slice spacing, at least 0.5 mm")

// 8f. Two phases of one examination on different grids: thinner slices, smaller pixels and another origin.
// A source pixel at i is at -32 + i mm; a target pixel at j is at -32.25 + j / 2 mm: pixel i covers the target pixels 2i and 2i + 1.
let phases = series(uid: "1.2.plain", frame: "1.2.frame.A", count: 8, spacing: 2, transform: nil)
let shape = ROIInterchangeROI(); shape.name = "Bone"; shape.typeCode = ROIInterchangeType.brush.rawValue
shape.brushWidth = 2; shape.brushHeight = 2; shape.brushOriginX = 20; shape.brushOriginY = 40; shape.brushMask = Data([1, 0, 0, 1])
phases.images[2].rois = [shape]
let thin = series(uid: "1.2.contrast", frame: "1.2.frame.A", count: 15, spacing: 1, transform: nil)
for image in thin.images {
    image.pixelSpacingX = 0.5; image.pixelSpacingY = 0.5; image.rows = 128; image.columns = 128
    image.imagePosition = [-32.25, -32.25, image.imagePosition[2]]
}
let resampled = GuidedROICopy.plan(source: phases, target: thin, transform: .identity, offsetMM: [0, 0, 0])
expect(resampled.refused.isEmpty && resampled.placed.map(\.targetImageIndex) == [4, 5], "the brush goes to the thin slices at its position: \(resampled.summary)")
let on = UInt8(0xFF)
let expectedMask = Data([on, on, 0, 0,  on, on, 0, 0,  0, 0, on, on,  0, 0, on, on])
for placed in resampled.placed {
    expect(placed.rect == NSRect(x: 40, y: 80, width: 4, height: 4), "each source pixel covers two target pixels a side, from pixel 40, 80 (\(placed.rect))")
    expect(placed.mask == expectedMask, "the shape of the mask is kept on the finer grid")
}
// The other way, onto thicker slices and larger pixels: one target image, the pixels whose centres are inside the mask.
let block = ROIInterchangeROI(); block.name = "Block"; block.typeCode = ROIInterchangeType.brush.rawValue
block.brushWidth = 8; block.brushHeight = 8; block.brushOriginX = 40; block.brushOriginY = 80; block.brushMask = Data(repeating: 1, count: 64)
thin.images[4].rois = [block]; thin.images[5].rois = [block]
let coarse = GuidedROICopy.plan(source: thin, target: phases, transform: .identity, offsetMM: [0, 0, 0])
expect(coarse.placed.count == 1 && coarse.placed[0].targetImageIndex == 2 && coarse.placed[0].sourceImageIndex == 4,
       "a thick target image takes the brush of its nearest thin image, once: \(coarse.summary)")
expect(coarse.placed[0].rect == NSRect(x: 20, y: 40, width: 4, height: 4) && coarse.placed[0].mask == Data(repeating: on, count: 16), "eight small pixels a side are four large ones")
expect(coarse.refused.count == 1 && coarse.refused[0].status == .noSlice, "the brush of the thin image no thick image is nearest to is said, not copied")
// A manual offset of half a millimetre moves the mask one small pixel.
let nudged = GuidedROICopy.plan(source: phases, target: thin, transform: .identity, offsetMM: [0.5, 0, 0])
expect(nudged.placed.allSatisfy { $0.rect.origin.x == 41 && $0.rect.origin.y == 80 }, "the manual offset moves the resampled mask")

// 8g. The summary stays a few lines however many ROIs there are.
let many = series(uid: "1.2.many", frame: "1.2.frame.A", count: 8, spacing: 2, transform: nil)
for image in many.images {
    image.rois = (0..<30).map { n in
        let roi = ROIInterchangeROI(); roi.name = "Bone \(n)"; roi.typeCode = ROIInterchangeType.brush.rawValue
        roi.brushWidth = 2; roi.brushHeight = 2; roi.brushOriginX = n; roi.brushOriginY = n; roi.brushMask = Data(repeating: 1, count: 4)
        return roi
    }
}
let manyPlaced = GuidedROICopy.plan(source: many, target: series(uid: "1.2.same", frame: "1.2.frame.A", count: 8, spacing: 2, transform: nil), transform: .identity, offsetMM: [0, 0, 0])
expect(manyPlaced.placed.count == 240 && manyPlaced.summary.split(separator: "\n").count <= 6, "240 placements are summed up: \(manyPlaced.summary)")
expect(manyPlaced.summary.hasPrefix("240 ROI(s) placed on 8 target image(s)"), "the summary starts with the counts")
let manyRefused = GuidedROICopy.plan(source: many, target: coronal, transform: .identity, offsetMM: [0, 0, 0])
expect(manyRefused.refused.count == 240 && manyRefused.summary.split(separator: "\n").count == 1 && manyRefused.summary.hasPrefix("240 ROI(s) not copied: is a brush mask"),
       "240 refusals for one reason are one line: \(manyRefused.summary)")

print("PASS: rigid landmark registration recovers a known transform to 1e-9 mm, bounds noisy error, refuses degenerate input, rejects poor fits and lost overlap; companions keep independent transforms and blend; comparisons persist by study UID; guided copy places each ROI on its own physical slice and refuses the rest by name")
'''
with tempfile.TemporaryDirectory(prefix='horos-registration-') as folder:
    tmp = Path(folder); (tmp / 'main.swift').write_text(harness_defaults.DOMAINS + driver)
    subprocess.run(['xcrun', 'swiftc', *isix_modules.module_flags('IsiXROI', tmp / 'modules'),
                    *[str(root / 'Horos/Sources' / name) for name in
                    ('LongitudinalRegistration.swift', 'ROIInterchange.swift', 'ROIIntersliceGeometry.swift')],
                    str(tmp / 'main.swift'), '-o', str(tmp / 'test')], check=True)
    subprocess.run([str(tmp / 'test')], check=True)
