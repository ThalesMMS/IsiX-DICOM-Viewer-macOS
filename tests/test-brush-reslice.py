#!/usr/bin/env python3
"""2D viewer reslice: brush ROIs follow the slices, in patient coordinates.

Compiles BrushResample.swift and BrushReslice.swift with stand-ins for ROI,
DCMPix and the viewer, and carries masks of a small volume that is not a
cube (7 x 5 pixels of 0.5 x 0.8 mm, 4 slices 1.5 mm apart, origin away from
zero) between stacks built as the reslice and its flips build them. The
expected pixels are written out from the voxels by hand, not computed with
the code under test:

- axial to coronal and to sagittal, with the column running from head to
  feet, and a mirrored sagittal: each voxel lands on its own pixel, so a
  shift of one slice, a swap of axes or a mirror fails;
- the source slices listed in inverted order give the same masks;
- a coronal whose rows are resampled finer (the reslice of small series)
  takes every new row from the nearest slice;
- axial to coronal to sagittal to axial gives the original pixels back, and
  going back and forth reuses the original brushes instead of resampling the
  last result; a brush changed in between becomes the source;
- empty slices stay empty, two masks stay apart, a mask outside the target
  makes no ROI, a mask already on the target is not added twice, and the
  second phase of a 4D series gets its own masks only;
- name, colour, opacity, visibility, lock, selectability, group, comment and
  thickness are kept.

Given back later, as -setOrientation: does: resampled off the main thread,
placed once the main queue runs, the pending source taken by a reslice made
meanwhile, whose own result replaces the older one.

The wiring: -setOrientation: takes the brushes before the reslice and gives
them back later after the flips, only when it succeeded; -processReslice:: does it
for a new viewer; -finalizeSeriesViewing forgets them with the series.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from sources import ROOT, source_text

stubs = r'''
import Foundation
import CoreGraphics

struct RGBColor { var red: UInt16; var green: UInt16; var blue: UInt16 }
enum ToolMode: Int { case tROI = 6, tPlain = 20 }
extension Notification.Name { static let OsirixROIChange = Notification.Name("OsirixROIChangeNotification") }

final class DCMPix: NSObject {
    var originX: Double, originY: Double, originZ: Double
    var o: [Double]
    var pixelSpacingX: Double, pixelSpacingY: Double
    var pwidth: Int, pheight: Int
    init(origin: SIMD3<Double>, row: SIMD3<Double>, column: SIMD3<Double>, sx: Double, sy: Double, w: Int, h: Int) {
        originX = origin.x; originY = origin.y; originZ = origin.z
        let n = SIMD3(row.y * column.z - row.z * column.y, row.z * column.x - row.x * column.z, row.x * column.y - row.y * column.x)
        o = [row.x, row.y, row.z, column.x, column.y, column.z, n.x, n.y, n.z]
        pixelSpacingX = sx; pixelSpacingY = sy; pwidth = w; pheight = h
    }
    func orientationDouble(_ p: UnsafeMutablePointer<Double>) { for i in 0..<9 { p[i] = o[i] } }
}

final class ROI: NSObject {
    var name: String?
    var rgbcolor = RGBColor(red: 0, green: 0, blue: 0)
    var opacity: Float = 0.5
    var hidden = false, locked = false, selectable = true, displayTextualData = true, textNameOnly = false
    var groupID: TimeInterval = 0
    var comments: String? = ""
    var thickness: Float = 2
    var type: ToolMode = .tPlain
    var textureBuffer: UnsafeMutablePointer<UInt8>?
    var textureWidth: Int32 = 0, textureHeight: Int32 = 0
    var textureUpLeftCornerX: Int32 = 0, textureUpLeftCornerY: Int32 = 0
    var spacing = (Float(0), Float(0))
    /// What the ROI's plain setters change for the brushes drawn next.
    static var globalWrites = 0
    func setColor(_ a: RGBColor, globally g: Bool) { rgbcolor = a; if g { ROI.globalWrites += 1 } }
    func setOpacity(_ a: Float, globally g: Bool) { opacity = a; if g { ROI.globalWrites += 1 } }
    func setThickness(_ a: Float, globally g: Bool) { thickness = a; if g { ROI.globalWrites += 1 } }
    init?(texture: UnsafeMutablePointer<UInt8>?, textWidth: Int32, textHeight: Int32, textName: String?,
          positionX: Int32, positionY: Int32, spacingX: Float, spacingY: Float, imageOrigin: NSPoint) {
        guard let texture, textWidth > 0, textHeight > 0 else { return nil }
        textureBuffer = .allocate(capacity: Int(textWidth * textHeight))
        textureBuffer!.update(from: texture, count: Int(textWidth * textHeight))
        textureWidth = textWidth; textureHeight = textHeight
        textureUpLeftCornerX = positionX; textureUpLeftCornerY = positionY
        name = textName; spacing = (spacingX, spacingY)
    }
}

final class DCMView: NSObject {
    var needsDisplay = false
    var set = 0
    func roiSet(_ roi: ROI) { set += 1 }
}

public final class ViewerController: NSObject {
    var horos_maxMovieIndex: Int16 = 1
    var pix: [NSMutableArray] = []
    var rois: [NSMutableArray] = []
    var horos_imageView: DCMView? = DCMView()
    func horos_pixList(at i: Int) -> NSMutableArray? { i < pix.count ? pix[i] : nil }
    func horos_roiList(at i: Int) -> NSMutableArray? { i < rois.count ? rois[i] : nil }
}
'''

driver = r'''
import Foundation
import CoreGraphics
import simd

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}

// The volume: x 0..<7 (0.5 mm), y 0..<5 (0.8 mm), z 0..<4 (1.5 mm).
let W = 7, H = 5, N = 4
let sx = 0.5, sy = 0.8, sz = 1.5
let O = SIMD3<Double>(10, -20, 30)
let X = SIMD3<Double>(1, 0, 0), Y = SIMD3<Double>(0, 1, 0), Z = SIMD3<Double>(0, 0, 1)

typealias Voxel = SIMD3<Int>
// Two masks: a lone voxel near a corner, and an L away from the middle.
let lone: Set<Voxel> = [Voxel(1, 3, 2)]
let ell: Set<Voxel> = [Voxel(4, 0, 0), Voxel(5, 0, 0), Voxel(6, 0, 0), Voxel(6, 1, 0), Voxel(6, 1, 1), Voxel(6, 1, 3)]

func axialPix() -> [DCMPix] {
    (0..<N).map { z in DCMPix(origin: O + Double(z) * sz * Z, row: X, column: Y, sx: sx, sy: sy, w: W, h: H) }
}
// Coronal as the reslice of an axial stack leaves it: one slice per y, x
// along the row, the column from the last slice down (head to feet).
func coronalPix() -> [DCMPix] {
    (0..<H).map { y in DCMPix(origin: O + Double(y) * sy * Y + Double(N - 1) * sz * Z, row: X, column: -Z, sx: sx, sy: sz, w: W, h: N) }
}
// Sagittal: one slice per x, y along the row, head to feet.
func sagittalPix() -> [DCMPix] {
    (0..<W).map { x in DCMPix(origin: O + Double(x) * sx * X + Double(N - 1) * sz * Z, row: Y, column: -Z, sx: sy, sy: sz, w: H, h: N) }
}
// Mirrored sagittal: y runs the other way.
func mirroredSagittalPix() -> [DCMPix] {
    (0..<W).map { x in DCMPix(origin: O + Double(x) * sx * X + Double(H - 1) * sy * Y + Double(N - 1) * sz * Z, row: -Y, column: -Z, sx: sy, sy: sz, w: H, h: N) }
}
// Coronal with rows every 0.5 mm instead of every 1.5 mm.
let fineRows = Int((Double(N - 1) * sz / 0.5).rounded()) + 1
func fineCoronalPix() -> [DCMPix] {
    (0..<H).map { y in DCMPix(origin: O + Double(y) * sy * Y + Double(N - 1) * sz * Z, row: X, column: -Z, sx: sx, sy: 0.5, w: W, h: fineRows) }
}

/// The pixels of each slice, by hand: slice index -> pixels.
typealias Pixels = [Int: Set<SIMD2<Int>>]
func axialPixels(_ v: Set<Voxel>) -> Pixels { var p = Pixels(); for a in v { p[a.z, default: []].insert(SIMD2(a.x, a.y)) }; return p }
func coronalPixels(_ v: Set<Voxel>) -> Pixels { var p = Pixels(); for a in v { p[a.y, default: []].insert(SIMD2(a.x, N - 1 - a.z)) }; return p }
func sagittalPixels(_ v: Set<Voxel>) -> Pixels { var p = Pixels(); for a in v { p[a.x, default: []].insert(SIMD2(a.y, N - 1 - a.z)) }; return p }
func mirroredPixels(_ v: Set<Voxel>) -> Pixels { var p = Pixels(); for a in v { p[a.x, default: []].insert(SIMD2(H - 1 - a.y, N - 1 - a.z)) }; return p }
// Row k of the fine coronal is 0.5 k mm below the top slice: the nearest slice
// is z = N - 1 - round(k / 3) (rows 1.5 mm apart hold 3 fine rows).
func finePixels(_ v: Set<Voxel>) -> Pixels {
    var p = Pixels()
    for a in v { for k in 0..<fineRows where N - 1 - Int((Double(k) / 3).rounded()) == a.z { p[a.y, default: []].insert(SIMD2(a.x, k)) } }
    return p
}

func makeBrush(_ pixels: Set<SIMD2<Int>>, name: String, color: RGBColor) -> ROI {
    let x0 = pixels.map(\.x).min()!, y0 = pixels.map(\.y).min()!
    let w = pixels.map(\.x).max()! - x0 + 1, h = pixels.map(\.y).max()! - y0 + 1
    var bytes = [UInt8](repeating: 0, count: w * h)
    for p in pixels { bytes[(p.y - y0) * w + p.x - x0] = 255 }
    let roi = bytes.withUnsafeMutableBufferPointer {
        ROI(texture: $0.baseAddress, textWidth: Int32(w), textHeight: Int32(h), textName: name, positionX: Int32(x0), positionY: Int32(y0),
            spacingX: 0.5, spacingY: 0.8, imageOrigin: NSPoint(x: 0, y: 0))!
    }
    roi.rgbcolor = color
    return roi
}
let red = RGBColor(red: 65535, green: 0, blue: 0), blue = RGBColor(red: 0, green: 0, blue: 65535)

func viewer(_ pixes: [DCMPix], masks: [(String, RGBColor, Pixels)]) -> ViewerController {
    let v = ViewerController()
    v.pix = [NSMutableArray(array: pixes)]
    let lists = NSMutableArray()
    for i in pixes.indices {
        let slice = NSMutableArray()
        for (name, color, pixels) in masks { if let p = pixels[i] { slice.add(makeBrush(p, name: name, color: color)) } }
        lists.add(slice)
    }
    v.rois = [lists]
    return v
}

/// The brushes of a viewer, as pixels by name and slice.
func read(_ v: ViewerController, phase: Int = 0) -> [String: Pixels] {
    var out: [String: Pixels] = [:]
    for (i, entry) in (v.horos_roiList(at: phase) ?? NSMutableArray()).enumerated() {
        for case let roi as ROI in entry as! NSArray where roi.type == .tPlain {
            for b in 0..<Int(roi.textureHeight) { for a in 0..<Int(roi.textureWidth) where roi.textureBuffer![b * Int(roi.textureWidth) + a] != 0 {
                let inserted = out[roi.name!, default: [:]][i, default: []].insert(SIMD2(Int(roi.textureUpLeftCornerX) + a, Int(roi.textureUpLeftCornerY) + b)).inserted
                if !inserted { print("FAIL: pixel twice for \(roi.name!)"); failures += 1 }
            } }
        }
    }
    return out
}
func count(_ v: ViewerController) -> Int {
    (v.horos_roiList(at: 0) ?? NSMutableArray()).reduce(0) { $0 + (($1 as! NSArray).count) }
}

/// The reslice as the viewer does it: brushes taken, slices replaced, ROI lists
/// emptied, brushes given back.
@MainActor func reslice(_ v: ViewerController, to pixes: [DCMPix]) {
    let brushes = BrushReslice.capture(from: v)
    v.pix = [NSMutableArray(array: pixes)]
    v.rois = [NSMutableArray(array: pixes.map { _ in NSMutableArray() })]
    brushes?.apply(to: v)
}

@MainActor func run() {
    let masks: [(String, RGBColor, Pixels)] = [("lone", red, axialPixels(lone)), ("ell", blue, axialPixels(ell))]

    // 1. Axial to coronal, sagittal, mirrored sagittal and fine coronal.
    for (label, target, expected) in [("coronal", coronalPix(), coronalPixels), ("sagittal", sagittalPix(), sagittalPixels),
                                      ("mirrored sagittal", mirroredSagittalPix(), mirroredPixels), ("fine coronal", fineCoronalPix(), finePixels)] {
        let v = viewer(axialPix(), masks: masks)
        reslice(v, to: target)
        let got = read(v)
        check(got["lone"] == expected(lone), "\(label): lone voxel \(String(describing: got["lone"])) expected \(expected(lone))")
        check(got["ell"] == expected(ell), "\(label): L \(String(describing: got["ell"])) expected \(expected(ell))")
        let slicesWith = (got["lone"]?.keys.count ?? 0) + (got["ell"]?.keys.count ?? 0)
        check(count(v) == slicesWith, "\(label): one ROI per mask and slice, \(count(v)) for \(slicesWith)")
    }

    // 2. The source slices in inverted order.
    do {
        let pixes = Array(axialPix().reversed())
        let inverted: [(String, RGBColor, Pixels)] = masks.map { (n, c, p) in (n, c, Dictionary(uniqueKeysWithValues: p.map { (N - 1 - $0.key, $0.value) })) }
        let v = viewer(pixes, masks: inverted)
        reslice(v, to: coronalPix())
        check(read(v)["lone"] == coronalPixels(lone) && read(v)["ell"] == coronalPixels(ell), "inverted source order: same coronal masks")
    }

    // 3. Round trips and successive reslices.
    do {
        let v = viewer(axialPix(), masks: masks)
        let original = read(v)
        reslice(v, to: coronalPix()); reslice(v, to: sagittalPix()); reslice(v, to: axialPix())
        check(read(v) == original, "axial, coronal, sagittal, axial: the original pixels")
        reslice(v, to: fineCoronalPix())
        // Back from the fine coronal: from the original brushes, not the fine rows.
        reslice(v, to: axialPix())
        check(read(v) == original, "axial, fine coronal, axial: the original pixels")
        for _ in 0..<5 { reslice(v, to: mirroredSagittalPix()); reslice(v, to: axialPix()) }
        check(read(v) == original && count(v) == 4, "five round trips: no loss, no duplicate (\(count(v)) ROIs)")
    }

    // 4. A brush changed on the resliced slices becomes the source.
    do {
        let v = viewer(axialPix(), masks: masks)
        reslice(v, to: coronalPix())
        // Coronal slice 2 gets a new mask at (0, 0): voxel x 0, y 2, z N - 1.
        (v.horos_roiList(at: 0)![2] as! NSMutableArray).add(makeBrush([SIMD2(0, 0)], name: "drawn", color: red))
        reslice(v, to: axialPix())
        let got = read(v)
        check(got["drawn"] == [N - 1: [SIMD2(0, 2)]], "a brush drawn on the coronal lands on its voxel: \(String(describing: got["drawn"]))")
        check(got["lone"] == axialPixels(lone) && got["ell"] == axialPixels(ell), "the other masks come back too")
    }

    // 5. Empty slices, a mask out of the target, a mask already there, an empty viewer.
    do {
        let v = viewer(axialPix(), masks: masks)
        // A target that covers only y 0 and 1: the lone voxel (y 3) has nowhere to go.
        let part = Array(coronalPix()[0..<2])
        reslice(v, to: part)
        let got = read(v)
        check(got["lone"] == nil, "a mask outside the target makes no ROI")
        check(got["ell"] == coronalPixels(ell), "the other mask still lands")
        check(count(v) == 2, "no ROI on an empty slice: \(count(v))")

        let w = viewer(axialPix(), masks: masks)
        let brushes = BrushReslice.capture(from: w)
        w.pix = [NSMutableArray(array: coronalPix())]
        w.rois = [NSMutableArray(array: coronalPix().map { _ in NSMutableArray() })]
        (w.rois[0][1] as! NSMutableArray).add(makeBrush([SIMD2(0, 0)], name: "ell", color: blue))
        brushes?.apply(to: w)
        check(read(w)["ell"] == [1: [SIMD2(0, 0)]], "a mask the target already has is not added again")
        check(read(w)["lone"] == coronalPixels(lone), "the others are")

        check(BrushReslice.capture(from: viewer(axialPix(), masks: [])) == nil, "no brush: nothing taken")
    }

    // 6. Two phases: each keeps its own masks.
    do {
        let v = viewer(axialPix(), masks: [("lone", red, axialPixels(lone))])
        let second = viewer(axialPix(), masks: [("ell", blue, axialPixels(ell))])
        v.horos_maxMovieIndex = 2
        v.pix.append(second.pix[0]); v.rois.append(second.rois[0])
        let brushes = BrushReslice.capture(from: v)
        v.pix = [NSMutableArray(array: coronalPix()), NSMutableArray(array: coronalPix())]
        v.rois = [NSMutableArray(array: coronalPix().map { _ in NSMutableArray() }), NSMutableArray(array: coronalPix().map { _ in NSMutableArray() })]
        brushes?.apply(to: v)
        check(read(v, phase: 0) == ["lone": coronalPixels(lone)], "phase 1: its mask only")
        check(read(v, phase: 1) == ["ell": coronalPixels(ell)], "phase 2: its mask only")
    }

    // 7. What a brush keeps.
    do {
        let v = viewer(axialPix(), masks: [("lone", red, axialPixels(lone))])
        let source = (v.horos_roiList(at: 0)![2] as! NSArray)[0] as! ROI
        source.opacity = 0.3; source.hidden = true; source.locked = true; source.selectable = false
        source.groupID = 1234.5; source.comments = "TotalSegmentator"; source.thickness = 3; source.displayTextualData = false
        source.textNameOnly = true
        reslice(v, to: sagittalPix())
        let made = (v.horos_roiList(at: 0)![1] as! NSArray)[0] as! ROI
        check(made.name == "lone" && made.rgbcolor.red == 65535 && made.rgbcolor.blue == 0, "name and colour")
        check(made.opacity == 0.3 && made.hidden && made.locked && !made.selectable, "opacity, hidden, locked, not selectable")
        check(made.groupID == 1234.5 && made.comments == "TotalSegmentator" && made.thickness == 3 && !made.displayTextualData, "group, comment, thickness, text")
        check(made.textNameOnly, "a name-only label stays name-only")
        check(made.spacing == (Float(sy), Float(sz)), "the ROI has the slice's spacing: \(made.spacing)")
        check(ROI.globalWrites == 0, "the defaults of the next brushes are left alone")
        check(v.horos_imageView!.set == 1 && v.horos_imageView!.needsDisplay, "the view knows the ROI and redraws")
        BrushReslice.forget(v)
        reslice(v, to: axialPix())
        check(read(v)["lone"] == axialPixels(lone), "after forgetting, the brushes on screen are the source")
    }

    // 8. Same dimensions, other geometry: a stack shifted by one slice moves the mask.
    do {
        let v = viewer(axialPix(), masks: [("lone", red, axialPixels(lone))])
        let shifted = (0..<N).map { z in DCMPix(origin: O + Double(z + 1) * sz * Z, row: X, column: Y, sx: sx, sy: sy, w: W, h: H) }
        reslice(v, to: shifted)
        check(read(v)["lone"] == [1: [SIMD2(1, 3)]], "a stack one slice higher: the voxel one slice lower in it \(String(describing: read(v)["lone"]))")
    }

    // 9. Off the main thread, as -setOrientation: gives them back: nothing at
    //    once, the same ROIs once the main queue has run; a new reslice meanwhile
    //    takes the pending source, and the older result is not placed.
    do {
        func settle(_ v: ViewerController, until done: () -> Bool) {
            let end = Date().addingTimeInterval(10)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let v = viewer(axialPix(), masks: masks)
        let brushes = BrushReslice.capture(from: v)
        v.pix = [NSMutableArray(array: coronalPix())]
        v.rois = [NSMutableArray(array: coronalPix().map { _ in NSMutableArray() })]
        brushes?.applyLater(to: v)
        check(count(v) == 0, "later: no ROI at once")
        check(BrushReslice.capture(from: v) === brushes, "later: a reslice meanwhile takes the pending source")
        settle(v) { count(v) > 0 }
        check(read(v)["lone"] == coronalPixels(lone) && read(v)["ell"] == coronalPixels(ell), "later: the coronal masks once resampled")

        let w = viewer(axialPix(), masks: masks)
        let first = BrushReslice.capture(from: w)
        w.pix = [NSMutableArray(array: coronalPix())]
        w.rois = [NSMutableArray(array: coronalPix().map { _ in NSMutableArray() })]
        first?.applyLater(to: w)
        let again = BrushReslice.capture(from: w)
        BrushReslice.forget(w)
        w.pix = [NSMutableArray(array: sagittalPix())]
        w.rois = [NSMutableArray(array: sagittalPix().map { _ in NSMutableArray() })]
        again?.applyLater(to: w)
        settle(w) { count(w) > 0 }
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        let got = read(w)
        check(got["lone"] == sagittalPixels(lone) && got["ell"] == sagittalPixels(ell), "later twice: the sagittal masks")
        check(count(w) == (got["lone"]?.keys.count ?? 0) + (got["ell"]?.keys.count ?? 0), "later twice: the coronal result was not placed (\(count(w)) ROIs)")
    }

    // 9. Stacks the row-by-row path does not take: every other slice turned
    // half a turn in its plane, and slices unevenly spaced.
    do {
        let turned = (0..<N).map { z -> DCMPix in
            z % 2 == 0 ? DCMPix(origin: O + Double(z) * sz * Z, row: X, column: Y, sx: sx, sy: sy, w: W, h: H)
                       : DCMPix(origin: O + Double(W - 1) * sx * X + Double(H - 1) * sy * Y + Double(z) * sz * Z, row: -X, column: -Y, sx: sx, sy: sy, w: W, h: H)
        }
        func turnedPixels(_ v: Set<Voxel>) -> Pixels {
            var p = Pixels()
            for a in v { p[a.z, default: []].insert(a.z % 2 == 0 ? SIMD2(a.x, a.y) : SIMD2(W - 1 - a.x, H - 1 - a.y)) }
            return p
        }
        let v = viewer(turned, masks: [("lone", red, turnedPixels(lone)), ("ell", blue, turnedPixels(ell))])
        reslice(v, to: coronalPix())
        check(read(v)["lone"] == coronalPixels(lone) && read(v)["ell"] == coronalPixels(ell), "slices turned in their plane: same coronal masks")

        // The top slice 0.3 mm higher: still the nearest to the coronal's first row.
        let uneven = (0..<N).map { z in DCMPix(origin: O + (Double(z) * sz + (z == N - 1 ? 0.3 : 0)) * Z, row: X, column: Y, sx: sx, sy: sy, w: W, h: H) }
        let w = viewer(uneven, masks: masks)
        reslice(w, to: coronalPix())
        check(read(w)["lone"] == coronalPixels(lone) && read(w)["ell"] == coronalPixels(ell), "unevenly spaced slices: same coronal masks")
    }
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("PASS: masks land on their voxels in every plane, round trips are exact, metadata kept, no duplicates")
'''

failed = False
with tempfile.TemporaryDirectory(prefix='horos-brush-reslice-') as directory:
    work = Path(directory)
    files = []
    for name in ('BrushResample', 'BrushReslice'):
        (work / f'{name}.swift').write_text(source_text(name))
        files.append(str(work / f'{name}.swift'))
    (work / 'Stubs.swift').write_text(stubs)
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                            *files, str(work / 'Stubs.swift'), str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True, timeout=300)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=120)
    print(run.stdout.strip())
    failed = run.returncode != 0

# The orientation tool and the reslice are in ViewerController+Orientation.swift
# and ViewerController+Reslice.swift, or in ViewerController.m before.
viewer = (((ROOT / 'Horos/Sources/ViewerController.m').read_bytes()) if (ROOT / 'Horos/Sources/ViewerController.m').exists() else b'').decode('latin1')
if '- (BOOL) setOrientation: (int) newOrientationTool' in viewer:
    set_orientation = viewer[viewer.index('- (BOOL) setOrientation: (int) newOrientationTool'):]
    set_orientation = set_orientation[:set_orientation.index('\n}\n')]
    process_reslice = viewer[viewer.index('-(BOOL) processReslice:(long) directionm :(BOOL) newViewer'):]
    process_reslice = process_reslice[:process_reslice.index('\n}\n')]
    capture = set_orientation.find('[HorosBrushReslice captureFromViewer:self]')
    checks = [
        (0 <= capture < set_orientation.find('switch( currentOrientationTool)'), 'the brushes are taken before the reslice'),
        (re.search(r'currentOrientationTool = newOrientationTool;\s*\[brushes applyLaterToViewer:self\];', set_orientation) is not None,
         'given back after the flips and rotations, off the main thread, only when the reslice succeeded'),
        (set_orientation.find('[brushes release]') > set_orientation.find('[brushes applyLaterToViewer:self]'), 'and released'),
        ('newViewer ? [[HorosBrushReslice captureFromViewer:self] retain] : nil' in process_reslice
         and '[brushes applyToViewer:reslicedViewer];' in process_reslice, 'a new viewer gets them from -processReslice::'),
    ]
else:
    orientation = source_text('ViewerController+Orientation')
    set_orientation = orientation[orientation.index('    func setOrientation(_ newOrientationTool: Int32) -> Bool {'):]
    set_orientation = set_orientation[:set_orientation.index('\n    }\n')]
    reslice = source_text('ViewerController+Reslice')
    process_reslice = reslice[reslice.index('    func processReslice(_ directionm: Int, _ newViewer: Bool) -> Bool {'):]
    capture = set_orientation.find('let brushes = BrushReslice.capture(from: self)')
    checks = [
        (0 <= capture < set_orientation.find('switch (current, newOrientationTool)'), 'the brushes are taken before the reslice'),
        (re.search(r'horos_currentOrientationTool = Int16\(truncatingIfNeeded: newOrientationTool\)\s*brushes\?\.applyLater\(to: self\)',
                   set_orientation) is not None,
         'given back after the flips and rotations, off the main thread, only when the reslice succeeded'),
        ('let brushes = newViewer ? BrushReslice.capture(from: self) : nil' in process_reslice
         and 'brushes?.apply(to: reslicedViewer)' in process_reslice, 'a new viewer gets them from -processReslice::'),
    ]
checks.append(('BrushReslice.forget(self)' in source_text('ViewerController+RetrieveAndView'), 'the series goes, the source goes'))
for ok, what in checks:
    if not ok:
        print('FAIL:', what); failed = True
sys.exit(1 if failed else 0)
