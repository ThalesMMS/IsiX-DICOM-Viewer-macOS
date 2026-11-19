#!/usr/bin/env python3
"""A change of plane or a resampling in place that fails or is refused leaves the 2D viewer as it was.

The orientation matrix of the 2D viewer reslices its series
(-setOrientation:), and -resampleDataWithXFactor:yFactor:zFactor: (a plugin's
call, and the opening of small images) resamples it in place. Either can fail
for want of memory, and the resampling is refused, with only a beep, while
other windows (MPR, volume rendering) use the series' volume, which cannot be
released under them. The viewer then still shows its own slices, so nothing
of it may change:

* a reslice that fails keeps the orientation (and the matrix its cell), the
  zoom, and the mark of a post-processed series as it was (unmarked for a
  series read from its files, marked for one that already was), gives no
  brushes back, and gives back the fusion and the key images alone that the
  change of plane undoes before the reslice; so does a change of plane
  refused because the series is not a volume, for the key images;
* a resampling refused because other windows use the volume, or that fails
  for memory in its first or in a later time point, or that the viewer does
  not take after all (its window is closing), keeps the series and its time
  points, the post-processed mark, the resampling ratio, the ROIs (no copies
  added on the slices that did not change) and the zoom; the Resample by 2
  action, refused, opens no wait window and no alert, and, out of memory,
  shows its alert once;
* +resampleDataFromViewer:…movieIndex: marks the viewer only when it made the
  new series;
* the reslice marks the viewer only once every time point is made.

What succeeds still does what it did: the reslice changes the orientation,
marks the viewer, gives the brushes back and fits the zoom; the resampling
gives every slice the ROIs of its source slice, multiplies the zoom and keeps
the ratio of the series the viewer then shows (the change of series sets it
back to 1, so it is set after).

ViewerController+Orientation.swift and ViewerController+Resampling.swift are
compiled whole with stand-ins of the viewer, its image view, controls and
slices, and of the IsiXImaging types they use; the stand-in change of series
does what the series load does (it keeps the series while other windows use
the volume or the window closes, and otherwise resets the ratio, the ROIs and
the mark). The reslice's own marking is read from ViewerSeriesReslice.swift.

    python3 tests/test-failed-reslice-resample-keeps-viewer.py [<git revision>]

A revision reads the three files from it instead of the tree: the negative
control.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the compiler

ROOT = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(ROOT), 'show', f'{revision}:{path}'], capture_output=True)
        if shown.returncode:
            sys.exit(f'FAIL: {revision} has no {path}')
        return shown.stdout.decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


STUBS = r'''
import AppKit

// The record of what the code under test asked: alerts, wait windows, changes
// of series, zoom fits.
enum Harness {
    static var log: [String] = []
    /// The resampling plan made at this call (1 for the first) has no memory.
    static var noMemoryAtPlan = 0
    static var planCalls = 0
}

extension Notification.Name {
    static let OsirixRecomputeROI = Notification.Name("OsirixRecomputeROINotification")
}

enum HorosAlertPanel {
    @discardableResult
    static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        Harness.log.append("alert " + title); return 1
    }
    @discardableResult
    static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        Harness.log.append("alert " + title); return 1
    }
}

enum HorosObjCException {
    static func caught(_ body: () -> Void) -> NSException? { body(); return nil }
}
func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ place: String) {}
func viewerObjCSendLong(_ target: AnyObject, _ selector: String, _ argument: Any?) -> Int { 0 }
func viewerFormatArgument(_ text: String?) -> CVarArg { (text ?? "") as NSString }

enum PluginManager {
    static func plugins() -> NSDictionary? { nil }
    static func startProtectForCrash(withFilter filter: Any?) {}
    static func endProtectForCrash() {}
}
enum AppController {
    static func willExecutePlugin(_ filter: Any?) -> Bool { true }
}

enum ViewerSender {
    static func selectedCellTag(_ sender: Any?) -> Int { (sender as? Matrix)?.selectedTag ?? 0 }
    static func string(_ sender: Any?, _ key: String) -> String? { nil }
}

// IsiXImaging, as far as these files use it.
struct SeriesReorientation {
    enum Step {
        case flipVertically, flipHorizontally, rotateClockwise
        static let quarterTurnConstant: Int32 = 1
    }
    let resliceDirection: Int
    let steps: [Step]
    init?(from current: Int, to target: Int) {
        guard current != target, (0...2).contains(current), (0...2).contains(target) else { return nil }
        resliceDirection = target == 2 ? 1 : 0
        steps = current == 0 ? [] : [.rotateClockwise]
    }
}
struct SliceStackSpacing {
    struct Tool { var rawValue: Int16 }
    struct Stacked { var rawValue: Int16; var tool: Tool }
    var orientation: Stacked?
    var interval: Double
    init?(orientation1: [Double], orientation2: [Double], origin1: [Double], origin2: [Double]) { return nil }
}
struct VolumeResamplingPlan {
    let width: Int, height: Int, count: Int, zFactor: Float, sourceCount: Int
    var sliceFloatCount: Int { width * height }
    var bufferFloatCount: Int { sliceFloatCount * count }
    init?(width: Int, height: Int, count: Int, sliceInterval: Float, xFactor: Float, yFactor: Float, zFactor: Float) {
        Harness.planCalls += 1
        if Harness.planCalls == Harness.noMemoryAtPlan { return nil }
        self.width = max(1, Int(Float(width) / xFactor))
        self.height = max(1, Int(Float(height) / yFactor))
        self.count = max(1, Int(Float(count) / zFactor))
        self.zFactor = zFactor
        sourceCount = count
    }
    func allocateBuffer() -> UnsafeMutablePointer<Float>? {
        malloc(MemoryLayout<Float>.size * max(bufferFloatCount, 1))?.assumingMemoryBound(to: Float.self)
    }
    func sourceIndex(ofSlice z: Int) -> Int { min(sourceCount - 1, z * sourceCount / count) }
}
struct SliceGeometry {
    var origin: [Double], orientation: [Float]
    var pixelSpacingX: Double, pixelSpacingY: Double, sliceThickness: Double, pixelRatio: Double
    init(origin: [Double], orientation: [Float], pixelSpacingX: Double, pixelSpacingY: Double, sliceThickness: Double, pixelRatio: Double) {
        self.origin = origin; self.orientation = orientation
        self.pixelSpacingX = pixelSpacingX; self.pixelSpacingY = pixelSpacingY
        self.sliceThickness = sliceThickness; self.pixelRatio = pixelRatio
    }
    func resampled(by plan: VolumeResamplingPlan) -> SliceGeometry { self }
}
struct ResampledStackOrigin {
    init(first: SliceGeometry, second: SliceGeometry?, zFactor: Float) {}
    func origin(ofSlice z: Int, pixelSpacingX: Double, pixelSpacingY: Double, sliceThickness: Double) -> [Double] { [0, 0, Double(z)] }
}
enum VolumeResampler {
    static func scaleSlices(_ plan: VolumeResamplingPlan, slices: [UnsafeMutablePointer<Float>?], isRGB: [Bool],
                            into buffer: UnsafeMutablePointer<Float>) {}
    static func scaleAlongZ(_ plan: VolumeResamplingPlan, buffer: UnsafeMutablePointer<Float>, isRGB: Bool) {}
}

final class DCMPix: NSObject, NSCopying {
    var pwidth = 8, pheight = 8, tot = 0, frameNo = 0, id = 0
    var fImage: UnsafeMutablePointer<Float>?
    var pixelSpacingX = 0.75, pixelSpacingY = 0.75, sliceThickness = 1.5, pixelRatio = 1.0, sliceInterval = 1.5
    var originX = 0.0, originY = 0.0, originZ = 0.0
    var isRGB = false
    func copy(with zone: NSZone? = nil) -> Any {
        let copy = DCMPix()
        copy.pwidth = pwidth; copy.pheight = pheight; copy.fImage = fImage
        copy.pixelSpacingX = pixelSpacingX; copy.pixelSpacingY = pixelSpacingY
        return copy
    }
    func orientation(_ c: UnsafeMutablePointer<Float>!) { for i in 0..<9 { c[i] = i % 4 == 0 ? 1 : 0 } }
    func orientationDouble(_ c: UnsafeMutablePointer<Double>!) { for i in 0..<9 { c[i] = i % 4 == 0 ? 1 : 0 } }
    func setOrigin(_ o: UnsafeMutablePointer<Double>!) { originX = o[0]; originY = o[1]; originZ = o[2] }
    func computeSliceLocation() {}
    class func originCorrected(accordingToOrientation pix: DCMPix?) -> NSPoint { .zero }
}
func viewerSetArrayPix(_ pix: DCMPix, _ list: NSMutableArray, _ index: Int) {}

final class ROI: NSObject, NSCopying {
    let name: String
    init(_ name: String) { self.name = name }
    func copy(with zone: NSZone? = nil) -> Any { ROI(name) }
    func setOriginAndSpacing(_ x: Float, _ y: Float, _ origin: NSPoint) {}
}

final class BrushReslice {
    static func capture(from viewer: ViewerController) -> BrushReslice? { BrushReslice() }
    func applyLater(to viewer: ViewerController) { Harness.log.append("brushes given back") }
}

final class DCMView: NSObject {
    var scaleValue: Float = 1.5
    var drawing = true
    var needsDisplay = false
    var flippedData = false
    var curImage = 0
    var curDCM: DCMPix?
    func stopROIEditingForce(_ force: Bool) {}
    func getWLWW(_ wl: UnsafeMutablePointer<Float>!, _ ww: UnsafeMutablePointer<Float>!) { wl.pointee = 40; ww.pointee = 400 }
    func setWLWW(_ wl: Float, _ ww: Float) {}
    func scaleToFit() { scaleValue = 1; Harness.log.append("scale to fit") }
    func sendSyncMessage(_ message: Int) {}
    func setIndex(_ index: Int) { curImage = index }
    func roiSet() {}
}
final class PopUp: NSObject {
    var tag = 0
    var index = 0
    func selectedTag() -> Int { tag }
    @discardableResult func selectItem(withTag tag: Int) -> Bool { self.tag = tag; return true }
    func selectItem(at index: Int) { self.index = index }
}
final class StateButton: NSObject { var state: NSControl.StateValue = .off }
final class Slider: NSObject { var integerValue = 0; var maxValue = 10.0 }
final class Matrix: NSObject {
    var selectedTag = 0
    @discardableResult func selectCell(withTag tag: Int) -> Bool { selectedTag = tag; return true }
}
final class SeriesLoad: NSObject {
    var volumeIsUsedByOtherWindows = false
    func keepingPreviousSeriesForOtherWindows(_ body: () -> Void) { body() }
}
/// What Revert Series of a change of plane reads the series of the files with: nothing here, no case reverts.
final class GeometryState { weak var planeChangedSeries: AnyObject? }
final class DicomSeries: NSObject { var isDeleted = false }
final class DicomImage: NSObject { var series: DicomSeries? }
struct HarnessProcessGraph {}
struct HarnessPreferences {}
struct HarnessSessionGraph { let processGraph = HarnessProcessGraph(); let preferences = HarnessPreferences() }
/// The slab asked for, which a change of plane carries over in millimetres: none in these cases.
@MainActor struct ViewerThickSlab {
    init(viewer: ViewerController, preferences: HarnessPreferences) {}
    func requestedMillimetres() -> Double? { nil }
    func request(millimetres: Double?, fallback: Int) {}
}
@MainActor struct BrowserKeyImages {
    init(processGraph: HarnessProcessGraph) {}
    func load(_ series: DicomSeries, into viewer: ViewerController, keyImagesOnly: Bool) {}
}

@MainActor public class ViewerController: NSObject {
    var horos_currentOrientationTool: Int16 = 0
    var horos_curMovieIndex: Int16 = 0
    var horos_maxMovieIndex: Int16 = 1
    var horos_imageView: DCMView? = DCMView()
    var horos_displayOnlyKeyImages = false
    var horos_keyImagePopUpButton: PopUp? = PopUp()
    var horos_popFusion: PopUp? = PopUp()
    var horos_activatedFusion: StateButton? = StateButton()
    var horos_sliderFusion: Slider? = Slider()
    var horos_stacksFusion: Slider? = Slider()
    var horos_orientationMatrix: Matrix? = Matrix()
    var horos_blending: ViewerController?
    var horos_postprocessed = false
    var horos_resampleRatio: Float = 1
    var horos_orientationVector: Int16 = 0
    var horos_originalOrientation: Int16 = -1
    let horosSeriesLoad = SeriesLoad()
    let geometryState = GeometryState()
    let sessionGraph = HarnessSessionGraph()
    /// The window is closing: a change of series keeps the series.
    var closing = false
    var resliceSucceeds = true
    var pixes: [NSMutableArray] = [], files: [NSMutableArray] = [], rois: [NSMutableArray] = []

    var horos_movieCount: Int { Int(horos_maxMovieIndex) }
    func horos_pixArray(_ index: Int) -> [DCMPix] { (pixes[index] as? [DCMPix]) ?? [] }
    func horos_pixList(at index: Int) -> NSMutableArray? { index < pixes.count ? pixes[index] : nil }
    func horos_fileList(at index: Int) -> NSMutableArray? { index < files.count ? files[index] : nil }
    func horos_roiList(at index: Int) -> NSMutableArray? { index < rois.count ? rois[index] : nil }
    func pixList(_ index: Int) -> NSMutableArray! { pixes[index] }
    func fileList(_ index: Int) -> NSMutableArray! { files[index] }
    var volumic = true
    func isDataVolumicIn4D(_ check4D: Bool) -> Bool { volumic }
    // The pop-up's item 1 shows the key images alone, as the viewer's does.
    func keyImageDisplayButton(_ sender: Any?) { horos_displayOnlyKeyImages = horos_keyImagePopUpButton?.index == 1 }
    func checkEverythingLoaded() {}
    func displayWarningIfGantryTitled() {}
    func displayAWarningIfNonTrueVolumicData() {}
    func activateBlending(_ viewer: ViewerController?) { horos_blending = viewer }
    func processReslice(_ direction: Int, _ newViewer: Bool) -> Bool {
        Harness.log.append("reslice")
        if resliceSucceeds { setPostprocessed(true) }
        return resliceSucceeds
    }
    func vertFlipDataSet(_ sender: Any?) {}
    func horzFlipDataSet(_ sender: Any?) {}
    func rotateDataSet(_ constant: Int32) {}
    func setPostprocessed(_ value: Bool) { horos_postprocessed = value }
    @discardableResult func computeInterval() -> Double { 0 }
    func setFusionMode(_ mode: Int) {}
    func propagateSettings() {}
    func updateImage(_ sender: Any?) {}
    func adjustSlider() {}
    func setWindowTitle(_ sender: Any?) {}
    func flipDataSeries(_ sender: Any?) {}
    func startWaitWindow(_ message: String) -> AnyObject? { Harness.log.append("wait window"); return nil }
    func endWaitWindow(_ window: AnyObject?) {}
}

/// -changeImageData::::, as the series load does it: the series is kept
/// while other windows use the volume or the window closes; otherwise the
/// viewer shows the new one, with one time point, no ROIs, the ratio 1, not
/// post-processed.
@MainActor func viewerChangeImageData(_ viewer: ViewerController, _ f: NSMutableArray?, _ d: NSMutableArray?, _ v: NSData?, _ b: Bool) {
    Harness.log.append("change of series")
    if viewer.closing || viewer.horosSeriesLoad.volumeIsUsedByOtherWindows { return }
    viewer.horos_maxMovieIndex = 1
    viewer.horos_resampleRatio = 1
    viewer.pixes = [f!]; viewer.files = [d!]
    viewer.rois = [NSMutableArray(array: (0..<f!.count).map { _ in NSMutableArray() })]
    viewer.setPostprocessed(false)
}
/// -addMovieSerie:::: one time point more.
@MainActor func viewerAddMovieSerie(_ viewer: ViewerController, _ f: NSMutableArray?, _ d: NSMutableArray?, _ v: NSData?) {
    Harness.log.append("time point added")
    viewer.horos_maxMovieIndex += 1
    viewer.pixes.append(f!); viewer.files.append(d!)
    viewer.rois.append(NSMutableArray(array: (0..<f!.count).map { _ in NSMutableArray() }))
}
'''

DRIVER = r'''
import AppKit

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}

/// A series of `slices` slices per time point, the first slice of each with an ROI.
@MainActor func viewer(slices: Int = 4, timePoints: Int = 1) -> ViewerController {
    let v = ViewerController()
    v.horos_maxMovieIndex = Int16(timePoints)
    for _ in 0..<timePoints {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 64 * slices)
        buffer.initialize(repeating: 0, count: 64 * slices)
        v.pixes.append(NSMutableArray(array: (0..<slices).map { z -> DCMPix in
            let pix = DCMPix(); pix.fImage = buffer + 64 * z; return pix }))
        v.files.append(NSMutableArray(array: (0..<slices).map { "file \($0)" as NSString }))
        v.rois.append(NSMutableArray(array: (0..<slices).map { z in NSMutableArray(array: z == 0 ? [ROI("roi")] : []) }))
    }
    v.horos_imageView?.curDCM = v.pixes[0][0] as? DCMPix
    v.horos_imageView?.scaleValue = 2
    Harness.log = []; Harness.planCalls = 0; Harness.noMemoryAtPlan = 0
    return v
}

/// The ROIs of each slice of each time point.
@MainActor func roiCounts(_ v: ViewerController) -> [[Int]] {
    v.rois.map { list in (0..<list.count).map { ((list[$0] as? NSMutableArray)?.count) ?? -1 } }
}

/// The viewer as the case left it, against what it was.
@MainActor func unchanged(_ v: ViewerController, series: [NSMutableArray], postprocessed: Bool, _ what: String) {
    check(v.pixes.count == series.count && zip(v.pixes, series).allSatisfy { $0 === $1 }, what + ": the series and its time points are kept")
    check(v.horos_movieCount == series.count, what + ": as many time points as before")
    check(v.horos_postprocessed == postprocessed, what + ": post-processed \(v.horos_postprocessed), was \(postprocessed)")
    check(v.horos_resampleRatio == 1, what + ": the resampling ratio is \(v.horos_resampleRatio), was 1")
    check(roiCounts(v).allSatisfy { $0.first == 1 && $0.dropFirst().allSatisfy { $0 == 0 } },
          what + ": the ROIs are those of before, \(roiCounts(v))")
    check(v.horos_imageView?.scaleValue == 2, what + ": the zoom is \(v.horos_imageView?.scaleValue ?? 0), was 2")
    check(!Harness.log.contains("change of series") && !Harness.log.contains("time point added"),
          what + ": no change of series asked, \(Harness.log)")
}

@MainActor func run() {
    // The change of plane.
    do {
        let v = viewer()
        v.horos_imageView?.scaleValue = 1.5
        v.resliceSucceeds = false
        let matrix = v.horos_orientationMatrix!
        matrix.selectCell(withTag: 1)
        v.setOrientationTool(matrix)
        check(Harness.log.contains("alert Not enough memory"), "a failed reslice explains itself, \(Harness.log)")
        check(!v.horos_postprocessed, "a failed reslice leaves a series read from its files unmarked")
        check(v.horos_currentOrientationTool == 0 && matrix.selectedTag == 0,
              "a failed reslice keeps the orientation \(v.horos_currentOrientationTool) and the matrix cell \(matrix.selectedTag)")
        check(v.horos_imageView?.scaleValue == 1.5 && !Harness.log.contains("scale to fit"), "a failed reslice keeps the zoom")
        check(!Harness.log.contains("brushes given back"), "a failed reslice gives no brushes back")
        check(v.horos_imageView?.drawing == true, "the view draws again after a failed reslice")
    }
    do {
        let v = viewer()
        v.horos_postprocessed = true
        v.horos_currentOrientationTool = 1
        v.horos_orientationMatrix?.selectCell(withTag: 1)
        v.resliceSucceeds = false
        check(!v.setOrientation(2), "-setOrientation: answers NO when the reslice fails")
        check(v.horos_postprocessed, "a failed reslice of an already post-processed series leaves it marked")
        check(v.horos_currentOrientationTool == 1 && v.horos_orientationMatrix?.selectedTag == 1, "the orientation stays coronal")
    }
    // The fusion and the key images alone, undone for the reslice, come back when it is not made.
    do {
        let v = viewer(), overlay = viewer()
        v.horos_blending = overlay
        v.horos_displayOnlyKeyImages = true
        v.horos_keyImagePopUpButton?.index = 1
        v.resliceSucceeds = false
        check(!v.setOrientation(1), "-setOrientation: answers NO when the reslice fails")
        check(v.horos_blending === overlay, "a failed reslice leaves the viewer without the fusion it had")
        check(v.horos_displayOnlyKeyImages && v.horos_keyImagePopUpButton?.index == 1,
              "a failed reslice leaves a viewer of key images alone showing every image")
    }
    do {
        let v = viewer()
        v.horos_displayOnlyKeyImages = true
        v.horos_keyImagePopUpButton?.index = 1
        v.volumic = false
        check(!v.setOrientation(1) && !Harness.log.contains("reslice"), "a series that is not a volume is not resliced")
        check(v.horos_displayOnlyKeyImages && v.horos_keyImagePopUpButton?.index == 1,
              "a change of plane refused for a series that is not a volume leaves a viewer of key images alone showing every image")
        check(!v.horos_postprocessed, "a change of plane refused for a series that is not a volume marks the viewer")
    }
    do {
        let v = viewer(), overlay = viewer()
        v.horos_blending = overlay
        v.horos_displayOnlyKeyImages = true
        v.horos_keyImagePopUpButton?.index = 1
        check(v.setOrientation(1), "-setOrientation: answers YES when the reslice is made")
        check(v.horos_blending == nil && !v.horos_displayOnlyKeyImages,
              "a reslice made keeps the fusion or the key images alone it undoes")
    }
    do {
        let v = viewer()
        v.horos_imageView?.scaleValue = 1.5
        check(v.setOrientation(1), "-setOrientation: answers YES when the reslice is made")
        check(v.horos_postprocessed && v.horos_currentOrientationTool == 1 && v.horos_orientationMatrix?.selectedTag == 1,
              "a reslice made marks the viewer and changes the orientation")
        check(Harness.log.contains("brushes given back") && Harness.log.contains("scale to fit"),
              "a reslice made gives the brushes back and fits the zoom, \(Harness.log)")
    }

    // The resampling in place.
    for timePoints in [1, 2] {
        let v = viewer(timePoints: timePoints)
        let series = v.pixes
        v.horosSeriesLoad.volumeIsUsedByOtherWindows = true
        check(!v.resampleData(withXFactor: 2, yFactor: 2, zFactor: 1), "a refused resampling answers NO (\(timePoints) time points)")
        unchanged(v, series: series, postprocessed: false, "refused with other windows on the volume, \(timePoints) time points")
    }
    for (timePoints, failing) in [(1, 1), (2, 1), (2, 2)] {
        let v = viewer(timePoints: timePoints)
        let series = v.pixes
        Harness.noMemoryAtPlan = failing
        check(!v.resampleData(withXFactor: 2, yFactor: 2, zFactor: 1), "a resampling out of memory answers NO")
        unchanged(v, series: series, postprocessed: false, "out of memory in time point \(failing) of \(timePoints)")
    }
    do {
        let v = viewer(timePoints: 2)
        let series = v.pixes
        v.closing = true
        check(!v.resampleData(withXFactor: 2, yFactor: 2, zFactor: 1), "a resampling the viewer does not take answers NO")
        check(v.horos_postprocessed == false && v.horos_resampleRatio == 1 && v.horos_imageView?.scaleValue == 2
              && v.pixes.count == 2 && v.pixes[0] === series[0] && v.pixes[1] === series[1]
              && roiCounts(v).allSatisfy { $0.first == 1 && $0.dropFirst().allSatisfy { $0 == 0 } }
              && !Harness.log.contains("time point added"),
              "a resampling the closing window does not take changes nothing, \(roiCounts(v)), \(Harness.log)")
    }
    do {
        let v = viewer()
        v.horosSeriesLoad.volumeIsUsedByOtherWindows = true
        let series = v.pixes
        v.resampleDataBy2(nil)
        check(!Harness.log.contains("wait window") && !Harness.log.contains { $0.hasPrefix("alert") },
              "Resample by 2, refused, opens no wait window and no alert, \(Harness.log)")
        unchanged(v, series: series, postprocessed: false, "Resample by 2 refused")
    }
    do {
        let v = viewer()
        Harness.noMemoryAtPlan = 1
        let series = v.pixes
        v.resampleDataBy2(nil)
        check(Harness.log.filter { $0 == "alert Not enough memory" }.count == 1, "Resample by 2 out of memory says so once, \(Harness.log)")
        Harness.log.removeAll { $0.hasPrefix("alert") || $0 == "wait window" }
        unchanged(v, series: series, postprocessed: false, "Resample by 2 out of memory")
    }
    do {
        let v = viewer(timePoints: 2)
        check(v.resampleData(withXFactor: 2, yFactor: 2, zFactor: 1), "a resampling made answers YES")
        check(v.horos_postprocessed, "a resampling made marks the viewer")
        check(v.horos_resampleRatio == 2, "a resampling made keeps its ratio, \(v.horos_resampleRatio), after the change of series")
        check(roiCounts(v) == [[1, 0, 0, 0], [1, 0, 0, 0]], "a resampling made gives each slice its source's ROIs, \(roiCounts(v))")
        check(v.horos_imageView?.scaleValue == 4, "a resampling made multiplies the zoom")
    }

    // The resampling of a plugin into lists of its own.
    do {
        let v = viewer()
        Harness.noMemoryAtPlan = 1
        var data: NSData? = nil
        check(!ViewerController.resampleData(fromViewer: v, inPixArray: NSMutableArray(), fileArray: NSMutableArray(), data: &data,
                                             withXFactor: 2, yFactor: 2, zFactor: 1, movieIndex: 0),
              "+resampleDataFromViewer: out of memory answers NO")
        check(!v.horos_postprocessed, "+resampleDataFromViewer: out of memory leaves the viewer unmarked")
        Harness.noMemoryAtPlan = 0
        check(ViewerController.resampleData(fromViewer: v, inPixArray: NSMutableArray(), fileArray: NSMutableArray(), data: &data,
                                            withXFactor: 2, yFactor: 2, zFactor: 1, movieIndex: 0) && v.horos_postprocessed,
              "+resampleDataFromViewer: marks the viewer when it made the series")
    }
}

MainActor.assumeIsolated { run() }
if failures > 0 { exit(1) }
print("PASS: a failed or refused reslice or resampling leaves the viewer as it was; what succeeds still changes it")
'''

failed = False
with tempfile.TemporaryDirectory(prefix='horos-failed-reslice-resample-') as directory:
    work = Path(directory)
    files = []
    for name in ('ViewerController+Orientation', 'ViewerController+Resampling'):
        text = read(f'Horos/Sources/{name}.swift')
        # The stand-ins replace the module.
        text = re.sub(r'^import IsiXImaging$', '', text, flags=re.M)
        path = work / f'{name.replace("+", "_")}.swift'
        path.write_text(text, encoding='utf-8')
        files.append(str(path))
    (work / 'Stubs.swift').write_text(STUBS, encoding='utf-8')
    (work / 'main.swift').write_text(DRIVER, encoding='utf-8')
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings',
                            '-module-cache-path', str(work / 'cache'), *files, str(work / 'Stubs.swift'),
                            str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print('FAIL: the files do not compile with their stand-ins:\n' + (build.stdout + build.stderr)[-4000:])
        sys.exit(1)
    ran = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=120)
    failed = ran.returncode != 0
    # The code's own NSLog lines only when something failed.
    print((ran.stdout + (ran.stderr if failed else '')).strip())

# The reslice makes its time points before the viewer gets them: making them
# marks the viewer only once every one is made.
reslice = read('Horos/Sources/ViewerSeriesReslice.swift')
frames = re.search(r'static func frames\(of viewer: ViewerController.*?\n    }\n', reslice, re.S)
frame = re.search(r'private static func frame\(of viewer: ViewerController.*?\n    }\n', reslice, re.S)
if not frames or not frame:
    print('FAIL: ViewerSeriesReslice no longer has frames(of:) and frame(of:)')
    failed = True
else:
    body = frames.group(0)
    if 'horos_postprocessed' in frame.group(0):
        print('FAIL: each time point of the reslice marks the viewer as it is made, before the others are')
        failed = True
    if not (-1 < body.find('frames.append(frame)') < body.find('viewer.horos_postprocessed = true') < body.find('return frames')):
        print('FAIL: the reslice does not mark the viewer once every time point is made')
        failed = True
sys.exit(1 if failed else 0)
