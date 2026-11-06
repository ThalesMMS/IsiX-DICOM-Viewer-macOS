#!/usr/bin/env python3
"""The volume of a mask series against Compute Volume, within its tolerance.

ROI > ROI Volume > Generate Mask Series counts the voxels of a binary mask of
the ROIs of one name; Compute Volume integrates the areas of the same ROIs by
the trapezoid rule between their planes. The two are measured here on
synthetic stacks with the code the app runs for each: the fill Set Pixels and
the mask use (IsiXROI's ROIPolygonFill, vertices truncated to the pixel grid)
and the voxel count (ROIMaskVolume) for the mask, and the app's own
ROIVolumeGeometry, compiled from Horos/Sources, for Compute Volume, with the
areas a polygon ROI gives (the shoelace of its points times the pixel area).

The tolerance is IsiXROI's ROIMaskVolumeAgreement, fixed before anything is
measured:

* the ends: the mask holds interval x (A_first + A_last) / 2 more than the
  trapezoid over every run of consecutive images with ROIs, a whole slab for
  an image alone. For a brush, whose area is its pixels, that is the whole
  difference, to rounding;
* the outlines: within half a pixel diagonal along the outline of each plane,
  one interval thick.

Checked: a sphere sampled every 2 mm, the same sphere with two images left
without ROIs (two runs, which Compute Volume does not bridge either), an
ellipse stack with anisotropic pixels, a brush stack (exact), and two copies
of the same ROI on every image, which Compute Volume sums and the mask
unions: that one must be refused.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from isix_modules import module_flags  # noqa: E402

root = Path(__file__).resolve().parents[1]
geometry = [root / 'Horos/Sources' / name for name in
            ('VRMeasurementGeometry.swift', 'ROILineGeometry.swift', 'ROIIntersliceGeometry.swift', 'ROIVolumeGeometry.swift')]
for path in geometry:
    assert path.is_file(), f'FAIL: {path.name} is missing'

DRIVER = r'''
import CoreGraphics
import Foundation
import IsiXROI

typealias Outline = [(x: Double, y: Double)]

struct Stack {
    var width = 160, height = 160
    var spacingX: Double, spacingY: Double, interval: Double
    var imageCount: Int
    /// The outlines of each image, in pixels.
    var rois: [Int: [Outline]]
    /// Brush images: the pixels painted, which are also their area.
    var brushes: [Int: [(Int, Int)]] = [:]
}

func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, count: Int = 96) -> Outline {
    (0..<count).map { i in
        let a = 2 * Double.pi * Double(i) / Double(count)
        return (cx + rx * cos(a), cy + ry * sin(a))
    }
}

func shoelace(_ p: Outline) -> Double {
    var twice = 0.0
    for i in p.indices { let a = p[i], b = p[(i + 1) % p.count]; twice += a.x * b.y - b.x * a.y }
    return abs(twice) / 2
}

struct Result { var mask: Double; var computeVolume: Double; var ends: Double; var tolerance: Double; var agrees: Bool }

func measure(_ stack: Stack) -> Result {
    var voxels = 0
    var planes: [ROIMaskVolumeAgreement.Plane] = []
    var slices: [ROIVolumeSlice] = []
    for image in 0..<stack.imageCount {
        var pixels = [Float](repeating: 0, count: stack.width * stack.height)
        var area = 0.0
        var count = 0
        pixels.withUnsafeMutableBufferPointer { buffer in
            let plane = ROIPlane(pixels: buffer.baseAddress!, width: stack.width, height: stack.height, sliceCount: 1,
                                 orientation: 2, stackNo: 0, isRGB: false)
            for outline in stack.rois[image] ?? [] {
                let vertices = outline.map { ROIPixelPoint(CGPoint(x: $0.x, y: $0.y)) }
                ROIPolygonFill.fill(vertices, on: plane, minimum: -.greatestFiniteMagnitude, maximum: .greatestFiniteMagnitude,
                                    outside: false, value: 1, addition: false, restore: false, restoreImage: { _ in nil })
                let a = shoelace(outline) * stack.spacingX * stack.spacingY
                area += a
                count += 1
                planes.append(.init(image: image, areaMm2: a,
                                    perimeterMm: ROIMaskVolumeAgreement.perimeterMm(of: outline, pixelSpacingX: stack.spacingX, pixelSpacingY: stack.spacingY)))
            }
            if let painted = stack.brushes[image] {
                for (x, y) in painted { buffer[y * stack.width + x] = 1 }
                let a = Double(painted.count) * stack.spacingX * stack.spacingY
                area += a
                count += 1
                planes.append(.init(image: image, areaMm2: a, perimeterMm: 0))
            }
        }
        voxels += pixels.withUnsafeBufferPointer { ROIMaskVolume.voxelCount($0) }
        if count > 0 {
            slices.append(ROIVolumeSlice(areaCm2: area / 100, originX: -64, originY: -64, originZ: Double(image) * stack.interval,
                                         normalX: 0, normalY: 0, normalZ: 1, componentCount: count, maskPixelCount: 0,
                                         pixelAreaMm2: 0, spacingBetweenSlicesMm: stack.interval))
        }
    }
    let positions = (0..<stack.imageCount).map { Double($0) * stack.interval }
    let series = positions.map { ROIPatientPoint(x: -64, y: -64, z: $0) }
    guard let computeVolume = ROIVolumeGeometry.volume(from: slices, seriesOrigins: series, interpolateMissing: false, meshPointCount: 0)?.volumeCm3,
          let interval = ROIMaskVolume.sliceInterval(positions: positions, sliceThickness: 0, spacingBetweenSlices: 0),
          let mask = ROIMaskVolume(voxelCount: voxels, pixelSpacingX: stack.spacingX, pixelSpacingY: stack.spacingY, sliceInterval: interval)
    else { preconditionFailure("no volume") }
    return Result(mask: mask.volumeCm3, computeVolume: computeVolume,
                  ends: ROIMaskVolumeAgreement.endsMm3(planes, sliceInterval: interval) / 1000,
                  tolerance: ROIMaskVolumeAgreement.toleranceMm3(planes, sliceInterval: interval, pixelSpacingX: stack.spacingX, pixelSpacingY: stack.spacingY) / 1000,
                  agrees: ROIMaskVolumeAgreement.agrees(maskCm3: mask.volumeCm3, computeVolumeCm3: computeVolume, planes: planes, sliceInterval: interval,
                                                        pixelSpacingX: stack.spacingX, pixelSpacingY: stack.spacingY))
}

func report(_ name: String, _ r: Result) {
    let outline = r.mask - r.computeVolume - r.ends
    print(String(format: "%@: mask %.4f cm3, Compute Volume %.4f cm3, ends %.4f cm3, outline %+.4f cm3 within %.4f cm3",
                 name, r.mask, r.computeVolume, r.ends, outline, r.tolerance))
}

func sphere(radius: Double, spacing: Double, interval: Double, skipping: Set<Int> = []) -> Stack {
    var rois: [Int: [Outline]] = [:]
    let count = 40
    for image in 0..<count where !skipping.contains(image) {
        let z = (Double(image) - 19.5) * interval
        let squared = radius * radius - z * z
        guard squared > 0 else { continue }
        let r = squared.squareRoot() / spacing
        rois[image] = [ellipse(80.37, 79.81, r, r)]
    }
    return Stack(spacingX: spacing, spacingY: spacing, interval: interval, imageCount: count, rois: rois)
}

@main struct Check {
    static func main() {
        var failures: [String] = []

        let whole = measure(sphere(radius: 30, spacing: 0.8, interval: 2))
        report("sphere", whole)
        if !whole.agrees { failures.append("the sphere does not agree") }

        let gaps = measure(sphere(radius: 30, spacing: 0.8, interval: 2, skipping: [15, 22]))
        report("sphere with two gaps", gaps)
        if !gaps.agrees { failures.append("the sphere with gaps does not agree") }
        // Three runs: the ends of each count, and Compute Volume bridges no gap.
        if !(gaps.ends > whole.ends * 2.5) { failures.append("the gaps do not add the ends of their runs: \(gaps.ends) vs \(whole.ends)") }

        var rois: [Int: [Outline]] = [:]
        for image in 3..<17 { rois[image] = [ellipse(70.6, 84.2, 38.3 - Double(image), 21.7 + Double(image) / 2)] }
        let anisotropic = measure(Stack(spacingX: 0.6, spacingY: 0.9, interval: 3, imageCount: 20, rois: rois))
        report("ellipses, 0.6 x 0.9 mm pixels", anisotropic)
        if !anisotropic.agrees { failures.append("the ellipses do not agree") }

        var brushes: [Int: [(Int, Int)]] = [:]
        for image in 2..<9 {
            brushes[image] = (20..<(60 + image)).flatMap { y in (30..<(70 + 3 * image)).map { ($0, y) } }
        }
        let brush = measure(Stack(spacingX: 0.5, spacingY: 0.5, interval: 1.5, imageCount: 12, rois: [:], brushes: brushes))
        report("brush", brush)
        if !brush.agrees || abs(brush.mask - brush.computeVolume - brush.ends) > 1e-9 {
            failures.append("the ends do not explain the whole difference of a brush")
        }

        let circle = ellipse(80, 80, 30, 30)
        let doubled = measure(Stack(spacingX: 1, spacingY: 1, interval: 1, imageCount: 10,
                                    rois: Dictionary(uniqueKeysWithValues: (1..<9).map { ($0, [circle, circle]) })))
        report("two copies of one ROI on every image", doubled)
        if doubled.agrees { failures.append("overlapping ROIs are accepted") }

        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='isix-roi-mask-volume-') as folder:
    path = Path(folder)
    flags = module_flags('IsiXROI', path / 'modules')
    (path / 'Check.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *flags, *map(str, geometry),
                            str(path / 'Check.swift'), '-o', str(path / 'check')],
                           capture_output=True, text=True)
    if build.returncode:
        print('FAIL: the measurement does not compile')
        print(build.stderr.strip()[-2000:])
        raise SystemExit(1)
    run = subprocess.run([str(path / 'check')], capture_output=True, text=True)
    print(run.stdout.strip())
    if run.returncode:
        print(run.stderr.strip()[-1500:])
        print('FAIL: the mask volume and Compute Volume do not agree within the tolerance')
        raise SystemExit(1)

print('PASS: the mask volume matches Compute Volume once the ends are counted, within half a pixel along the outlines')
