#!/usr/bin/env python3
"""The Curved MPR draws the slab its window shows, whatever path it installs.

The window keeps the slab in millimeters, which its thickness field and slab
slider show, and gives it to its curved path, which the curved MPR and the
planes draw: the thickness itself, whatever it is. Up to 2 mm the path had no
slab, so the curved view drew one plane where the field, the bubble and the
three planes had the window's slab, and it opened without one. The window gave
it only when the thickness changed, so a path installed afterwards drew the
slab it brought, while the field kept its thickness:
- the Path Assistant's path, made anew, had none: the window said 100 mm and
  the curved MPR drew the thin image;
- an undone or redone edit of the path brought back the slab of its time;
- an undo right after a saved path was reopened brought back the empty path
  of the opening, with no slab, and the views drew the new path with it;
- a path a view installs (will edit, setCurvedPath:, did edit) kept its own.
A path file loaded (the saved path of a reopened window, Load Path, a file
dropped) gives the window its slab, and an imported centerline, which has
none, takes the window's: the import moved the window to the thin end.

The slab of a file stays within the slider's ends (thickSlabThinEnd, the
finest spacing of the volume, to dcmIntervalMax, the volume). A file of a
version that kept no slab at 2 mm or less has 0, which VRView takes for no
slab and -setClippingRangeThickness: replaced with 0.5: below the thin end of
0.625 mm (slices of 0.625 mm) or 1 mm (slices of 2 mm with pixels of 1 mm).
The field, the knob and the bubble show the thin end for it, and a slab
thicker than the volume its thick end.

The window opens at its thin end, the exact one: the left end of the slider
is that slab, not one a thousandth under two decimals of it (0.619 mm, 0.999
mm), which the export's interval fields keep as their bound (dcmIntervalMin).
The field takes what is typed within the ends: 0.3 and 500 go to the ends,
and the thin end read back from its own two decimals is the thin end. The
field, the bubble and the window say one number after each.

-showWindow: clears the path and restores the saved one. The launcher calls
it three times as a window opens, and each call pushed the path it cleared
onto the undo queue: a reopened window had the empty path of the opening and
twice the path reopened to undo, three undos that changed nothing visible but
the last, which emptied the path. The opening now leaves nothing to undo, nor
does a later call that brings back the path shown; a Reset (the toolbar's
-showWindow:) that changed the path can still be undone, and the edits after
the opening undo one at a time.

A press in a plane put the planes' cameras on the undo queue as it began,
whatever it did: a click that added a node left the cameras and the path, so
each node took two Cmd-Z, one of which changed nothing, and a click that
changed nothing left an entry too. The press now keeps the cameras as it
begins and puts them on the queue as it ends only if they moved (the lines
rotated, a plane moved, zoomed, scrolled, or windowed in VR: the MIP planes
show a window of their own), and a press that edits the path has the path's
entry alone, though it moves the cross to the node: two nodes added are
undone by two Cmd-Z, and the third beeps. A click on a node that leaves it
where it was, or a node the plane refuses, leaves the path as it was, and
the path's entry goes: the cross moved to the node is undone instead. A
wheel step during a press is the press's, and those after a press whose
release never came (an image drag) are undone with it by the next Cmd-Z.
The cameras moved as the three planes show them: a place or slab moved by
more than half a screen point of the plane that shows it largest (a
camera's parallelScale is half the height its plane shows; the stand-in
planes have the heights of a window reopened in the app, 641, 217 and 429
points), a zoom that moved its plane's corners as much, an aim or a plane's
lines turned by more than 0.05°, angles read 360° apart being the same. A
still click at the cross's centre, which moves the cross to the point
clicked a fraction of a point away, and lines that read -360° for 0° after
a click left an entry whose Cmd-Z changed nothing in the planes; a cross
moved 0.7 or 1.2 points of the tallest plane, lines turned half a degree, a plane
zoomed in, a zoom that moved a plane's corners 0.7 point, and planes tilted
or rolled 1° about their aim, the camera moving less than half a point,
still leave one.
What the plane's mouse down, mouse up and scrollWheel send the window is
read from CPRMPRDCMView.swift.

CPRCurvedPath is compiled as it is, with Nitrogen's N3BezierPath,
HorosObjCException, CPRCenterlineImport and the rules of the slab's scale and
text (ThickSlabSliderScale, SlabThicknessText), and these pieces of
CPRController.swift and ThickSlabSliderHost.swift are taken as they are and
run on stand-ins for the views and the volume rendering view: the window's
thickness in millimeters, its setter and -setClippingRangeThickness:, the
opening of the slab, its ends, the slider's position and the field's
thickness, the slab of the path for that thickness,
-setCurvedPath:, the undo queue (-addToUndoQueue:, -prepareObjectForUndo:,
-executeUndo:, -undo:, -redo:), the path files (-saveBezierPathToFile:,
-loadBezierPathFromFile:, -importPatientSpaceCenterlineFromFile:), the
restore of the saved path by -showWindow: and the views' edits
(-CPRViewWillEditCurvedPath:, -CPRViewDidUpdateCurvedPath:,
-CPRViewDidEditCurvedPath:). After each step, the window's path and the
seven views' copies have the slab of the thickness the window shows.

CPRController.swift is read for the rest: the Path Assistant installs its
new path through -setCurvedPath:, nothing else replaces the window's path
without it, -showWindow: restores the saved path while it is still the
opening, the 16-bit export asks for the slab and the projection of the curved
view, and the frames of the Slab series are the planes the generator makes.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import former_sdk_objects  # noqa: E402
import n3_geometry_harness  # noqa: E402

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'],
                                           stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            return b''
    full = root / path
    return full.read_bytes() if full.exists() else b''


def code(text):
    """Without comments, so that what they recall is not taken for a call."""
    text = '\n'.join(line.split('//')[0] for line in text.split('\n'))
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


SWIFT_SOURCES = [
    'Horos/Sources/CPRCurvedPath.swift',
    'Horos/Sources/CPRGeneratorRequest.swift',
    'Horos/Sources/CurvedMPRPath.swift',
    'Horos/Sources/CPRCenterlineImport.swift',
]
# The rules the pieces ask, as this checkout has them at any revision.
RULES = [
    'Modules/IsiXImaging/Sources/ViewerReconstruction/ThickSlabSliderScale.swift',
    'Modules/IsiXImaging/Sources/ViewerReconstruction/SlabThicknessText.swift',
]
HEADERS = [
    'Horos/Sources/CPRCurvedPath.h',
    'Horos/Sources/CPRVolumeData.h',
    'Horos/Sources/CPRProjectionOperation.h',
    'Horos/Sources/HorosObjCException.h',
    'Nitrogen/Sources/N3Geometry.h',
    'Nitrogen/Sources/N3BezierCore.h',
    'Nitrogen/Sources/N3BezierCoreAdditions.h',
    'Nitrogen/Sources/N3BezierPath.h',
]
# (source, extra clang flags).
OBJC_SOURCES = [
    ('Horos/Sources/HorosObjCException.m', ['-fobjc-exceptions']),
]
if revision and subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{revision}:Horos/Sources/CPRCurvedPath+CAPI.m'],
                               capture_output=True).returncode == 0:
    OBJC_SOURCES.append(('Horos/Sources/CPRCurvedPath+CAPI.m', ['-DHOROS_BRIDGING_HEADER=1']))

# Nitrogen's N3 geometry: the Objective-C of a revision that still has it,
# otherwise the Swift of this checkout, from n3_geometry_harness.
N3_OBJC = [(path, ['-fno-objc-arc']) for path in ('Nitrogen/Sources/N3Geometry.m', 'Nitrogen/Sources/N3BezierCore.m',
                                                  'Nitrogen/Sources/N3BezierCoreAdditions.m', 'Nitrogen/Sources/N3BezierPath.m')]
if subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{revision or "HEAD"}:Nitrogen/Sources/N3Geometry.m'],
                  capture_output=True).returncode == 0 and (revision or (root / 'Nitrogen/Sources/N3Geometry.m').exists()):
    OBJC_SOURCES = N3_OBJC + OBJC_SOURCES
    N3_LIBRARIES = None
else:
    N3_LIBRARIES = 'n3'

BRIDGING = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
#import "N3Geometry.h"
#import "N3BezierPath.h"
#import "CPRVolumeData.h"
#import "CPRProjectionOperation.h"
#import "CPRCurvedPath.h"
'''

# The requests name their operation classes; no operation runs here.
OPERATION_STUBS = r'''
import Foundation
final class CPRStraightenedOperation: NSObject {}
final class CPRStretchedOperation: NSObject {}
final class CPRObliqueSliceOperation: NSObject {}
'''

DRIVER = r'''
import Cocoa

var wrong: [String] = []
func expect(_ ok: Bool, _ message: String) {
    if !ok { wrong.append(message) }
}

private func debugAssert(_ condition: @autoclosure () -> Bool)
%(debugAssert)s

private func addObject(_ array: NSMutableArray?, _ object: Any?)
%(addObject)s

private func valueWithPointer(_ object: Any?) -> NSValue
%(valueWithPointer)s

private func curvedPathOf(_ object: Any?) -> CPRCurvedPath?
%(curvedPathOf)s

private func setCurvedPathOf(_ object: Any?, _ path: CPRCurvedPath?)
%(setCurvedPathOf)s

/// The preferences the pieces read, at the values a launch leaves.
struct PreferenceKey<Value> { let value: Value }
enum ReconstructionPreferences {
    static let undoQueueSize = PreferenceKey(value: 20)
    /// The curve of the slab slider, which the checks switch.
    nonisolated(unsafe) static var logarithmicThickSlabSlider = PreferenceKey(value: false)
}
private let unknownVolumeSlabMaximum = 100.0
func onMainRunLoop(_ body: @escaping () -> Void) { body() }
/// The geometry of the series a window reconstructs.
final class DCMPix {
    var pwidth = 0, pheight = 0
    var pixelSpacingX = 0.0, pixelSpacingY = 0.0, sliceInterval = 0.0, sliceThickness = 0.0
}
enum VolumeRenderingPreferences { static let superSampling = PreferenceKey<Float>(value: 1) }
final class PreferenceStoreStandIn {
    subscript<Value>(key: PreferenceKey<Value>) -> Value { return key.value }
}

final class Point3D: NSObject {
    var x: Float, y: Float, z: Float
    init(_ x: Float, _ y: Float, _ z: Float) { self.x = x; self.y = y; self.z = z }
    static func point(withX x: Float, y: Float, z: Float) -> Point3D { return Point3D(x, y, z) }
}

final class Camera: NSObject, NSCopying {
    var position: Point3D? = Point3D(0, 0, 0)
    var focalPoint: Point3D? = Point3D(0, 0, 1)
    var viewUp: Point3D? = Point3D(0, 1, 0)
    var viewAngle: Float = 30, eyeAngle: Float = 2, parallelScale: Float = 120
    var clippingRangeNear: Float = 0.5, clippingRangeFar: Float = 600, wl: Float = 40, ww: Float = 400
    func copy(with zone: NSZone? = nil) -> Any {
        let camera = Camera()
        camera.position = position.map { Point3D($0.x, $0.y, $0.z) }
        camera.focalPoint = focalPoint.map { Point3D($0.x, $0.y, $0.z) }
        camera.viewUp = viewUp.map { Point3D($0.x, $0.y, $0.z) }
        (camera.viewAngle, camera.eyeAngle, camera.parallelScale) = (viewAngle, eyeAngle, parallelScale)
        (camera.clippingRangeNear, camera.clippingRangeFar, camera.wl, camera.ww) = (clippingRangeNear, clippingRangeFar, wl, ww)
        return camera
    }
}

final class PixStandIn {
    func orientation(_ o: UnsafeMutablePointer<Float>) {
        for i in 0..<9 { o[i] = i % 4 == 0 ? 1 : 0 }
    }
}

/// VRView's slab: in its units, `factor` per millimeter; off at 0, when it
/// ignores a thickness in millimeters and answers 0 mm, as VRView+Crop does.
final class VRStandIn {
    let factor = 2.0
    var stored = 0.0
    var activated = false
    var lowResLODFactor: Float = 1
    var dontResetImage = false
    var clippingRangeThickness: Double {
        get { return stored }
        set { stored = newValue; activated = newValue != 0 }
    }
    func getClippingRangeThickness() -> Double { return stored }
    func getClippingRangeThicknessInMm() -> Double { return activated ? stored / factor : 0 }
    func setClippingRangeThicknessInMm(_ c: Double) {
        if activated { clippingRangeThickness = c * factor }
    }
}

/// A CPR view: it keeps a copy of the path it is given, and draws its slab.
class PathViewStandIn: NSObject {
    var _curvedPath: CPRCurvedPath?
    @objc var curvedPath: CPRCurvedPath! {
        get { return _curvedPath }
        set {
            if _curvedPath !== newValue {
                _curvedPath = newValue?.copy() as? CPRCurvedPath
            }
        }
    }
    var orangeSlabThickness: CGFloat = 0
    var purpleSlabThickness: CGFloat = 0
    var blueSlabThickness: CGFloat = 0
}

/// One of the three planes, with the volume rendering view of the window.
typealias CPRMPRDCMView = PlaneStandIn
final class PlaneStandIn: PathViewStandIn {
    var vrView: VRStandIn?
    var camera: Camera? = Camera()
    var angleMPR: Float = 0
    var bounds: NSRect
    let pix: PixStandIn? = PixStandIn()
    init(height: CGFloat) { bounds = NSRect(x: 0, y: 0, width: 956, height: height) }
    func restoreCamera() {}
    func updateViewMPR(onLoading: Bool) {}
}

final class StenosisStandIn {
    func curvedPathDidChange() {}
}

/// -undo: and -redo: beep when their queue is empty; here they count.
enum NSSound {
    static var beeps = 0
    static func beep() { beeps += 1 }
}

%(curvedPathSet)s

/// The window's paths, with the reading and the writing of their file as they are.
final class CurvedPathLibrary {
    weak var controller: CPRController?
    var paths = CurvedPathSet()
    static var defaultName: String { "Path" }
    init(controller: CPRController) { self.controller = controller }
    func rebuildMenu() {}

    static func archive(_ path: CPRCurvedPath) -> Data?
%(libraryArchive)s

    static func path(from archive: Data) -> CPRCurvedPath?
%(libraryPath)s

    func save(toFile file: String?)
%(librarySave)s

    func load(fromFile file: String?) -> Bool
%(libraryLoad)s
}

/// The CPRController state the pieces read, with its methods as they are.
final class CPRController: NSObject {
    lazy var pathLibrary = CurvedPathLibrary(controller: self)

    func showLoadedPath(_ newCurvedPath: CPRCurvedPath)
%(showLoadedPath)s

    var _curvedPath: CPRCurvedPath? = CPRCurvedPath()
    var _clippingRangeThickness: Float = 0
    var _straightenedCPRAngle: Double = 0
    var baseNormal = N3VectorMake(0, 0, 0)
    var centerline: NSMutableArray? = NSMutableArray()
    var undoQueue: NSMutableArray? = NSMutableArray()
    var redoQueue: NSMutableArray? = NSMutableArray()
    var pressInPlane: (cameras: Any?, pathEntry: AnyObject?)?
    weak var queueTopAtPress: AnyObject?
    var wheelRun: (plane: CPRMPRDCMView, entry: AnyObject?)?
    /// The redraws in full detail, by the plane each was for.
    var fullDetailRedraws: [CPRMPRDCMView] = []
    @objc func delayedFullLODRendering(_ sender: Any!) {
        wheelRun = nil
        if let plane = sender as? CPRMPRDCMView { fullDetailRedraws.append(plane) }
    }
    var _clippingRangeMode: Int32 = 1 // MIP, as the window opens.
    var _delegateCurveViewDebuggingStorage: NSMutableArray?
    var isInitializing = false
    var thickSlabThinEnd = 1.0
    var dcmIntervalMin: Float = 0
    var dcmIntervalMax: Float = 0
    var curvedPathCreationMode = true
    var stenosisTool: StenosisStandIn? = StenosisStandIn()
    let preferenceStore = PreferenceStoreStandIn()
    let vr = VRStandIn()
    var hiddenVRView: VRStandIn? { return vr }
    // The planes' heights in points of a window reopened in the app: the first, the tallest, shows a world unit largest.
    var mprView1: PlaneStandIn? = PlaneStandIn(height: 641)
    var mprView2: PlaneStandIn? = PlaneStandIn(height: 217)
    var mprView3: PlaneStandIn? = PlaneStandIn(height: 429)
    var cprView: PathViewStandIn? = PathViewStandIn()
    var topTransverseView: PathViewStandIn? = PathViewStandIn()
    var middleTransverseView: PathViewStandIn? = PathViewStandIn()
    var bottomTransverseView: PathViewStandIn? = PathViewStandIn()

    override init() {
        super.init()
        for view in [mprView1, mprView2, mprView3] { view?.vrView = vr }
        for view in views { view?.curvedPath = _curvedPath }
    }

    var views: [PathViewStandIn?] {
        return [mprView1, mprView2, mprView3, cprView, topTransverseView, middleTransverseView, bottomTransverseView]
    }

    @objc var curvedPath: CPRCurvedPath! {
        get { return _curvedPath }
        set { self.setCurvedPathValue(newValue) }
    }

    var clippingRangeThickness: Float {
        get { return _clippingRangeThickness }
        set { self.setClippingRangeThicknessValue(newValue) }
    }

    func selectedView() -> PlaneStandIn? { return mprView1 }
    func restartSimplificationIfNodesChanged(since previousNodes: NSArray?) {}
    func updateViewsAccordingToFrame(_ sender: Any?) {}
    func refreshThickSlabSliderPosition() {}

    func curvedPathSlabThickness() -> CGFloat
%(curvedPathSlabThickness)s

    static func slabVolumeMaximum(of pixList: [DCMPix]) -> Float
%(slabVolumeMaximum)s

    static func slabThinEnd(of pixList: [DCMPix]) -> Double
%(slabThinEnd)s

    func openSlab(of pixList: [DCMPix])
%(openSlab)s

    func slabWithinEnds(_ thickness: Double) -> Float
%(slabWithinEnds)s

    var thickSlabSliderScale: ThickSlabSliderScale
%(thickSlabSliderScale)s

    var slabSliderPosition: Double
%(slabSliderPosition)s

    var slabFieldThickness: Double
%(slabFieldThickness)s

    func getClippingRangeThicknessInMm() -> Float
%(getClippingRangeThicknessInMm)s

    func setClippingRangeThicknessInMm(_ c: Float)
%(setClippingRangeThicknessInMm)s

    func setClippingRangeThicknessValue(_ f: Float)
%(setClippingRangeThicknessValue)s

    func setCurvedPathValue(_ newCurvedPath: CPRCurvedPath?)
%(setCurvedPathValue)s

    func add(toUndoQueue string: String!)
%(addToUndoQueue)s

    func prepareObject(forUndo string: String!) -> Any!
%(prepareObjectForUndo)s

    func executeUndo(_ u: NSMutableArray!)
%(executeUndo)s

    func undo(_ sender: Any!)
%(undo)s

    func redo(_ sender: Any!)
%(redo)s

    func apply(lastEntryOf queue: NSMutableArray?, keepingWhatItReplacesIn other: NSMutableArray?)
%(applyLastEntry)s

    func pushUndoEntry(_ entry: Any?)
%(pushUndoEntry)s

    func planePressBegan()
%(planePressBegan)s

    func planePressEnded()
%(planePressEnded)s

    func planeWheelStep(in plane: CPRMPRDCMView)
%(planeWheelStep)s

    func planeWheelSettle()
%(planeWheelSettle)s

    func camerasDiffer(_ entry: Any?, _ otherEntry: Any?) -> Bool
%(camerasDiffer)s

    func showCurvedPathInViews(except sender: AnyObject? = nil)
%(showCurvedPathInViews)s

    func showChangedCurvedPath()
%(showChangedCurvedPath)s

    func saveBezierPathToFile(_ path: String!)
%(saveBezierPathToFile)s

    func loadBezierPathFromFile(_ path: String!)
%(loadBezierPathFromFile)s

    func importPatientSpaceCenterline(fromFile path: String!) -> Bool
%(importPatientSpaceCenterline)s

    func restoreCurvedPath(savedIn file: String?)
%(restoreCurvedPath)s

    func delegateCurveViewDebugging() -> NSMutableArray
%(delegateCurveViewDebugging)s

    static func sameNodes(_ nodes: NSArray?, _ otherNodes: NSArray?) -> Bool
%(sameNodes)s

    func forgetCenterlineIfNodesChange(to newCurvedPath: CPRCurvedPath?)
%(forgetCenterlineIfNodesChange)s

    func cprViewWillEditCurvedPath(_ CPRMPRDCMView: Any!)
%(cprViewWillEditCurvedPath)s

    func cprViewDidUpdateCurvedPath(_ CPRMPRDCMView: Any!)
%(cprViewDidUpdateCurvedPath)s

    func cprViewDidEditCurvedPath(_ CPRMPRDCMView: Any!)
%(cprViewDidEditCurvedPath)s

    /// Vessel Analysis, off here: an edit of the path traces nothing.
    func traceIfVesselAnalysisAsks() {}
}

let nodes = [N3VectorMake(0, 0, 0), N3VectorMake(10, 5, 2), N3VectorMake(20, 0, 4), N3VectorMake(30, -5, 6)]

/// -showWindow:, at the opening and at every later call (the launcher's two
/// more, Reset): the slab's ends for the series and its thinnest slab, then
/// the path, without nodes or the one saved in `file`, restored by the first
/// plane.
func show(_ window: CPRController, series: [DCMPix], saved file: String?) {
    window.openSlab(of: series)
    window.restoreCurvedPath(savedIn: file)
    window.isInitializing = false
}

/// A series of slices `sliceInterval` apart and `sliceThickness` thick, with
/// square pixels of `pixel` mm, whose longest side is `volume` mm, across.
func series(sliceInterval: Double, sliceThickness: Double, pixel: Double, volume: Double) -> [DCMPix] {
    let pix = DCMPix()
    (pix.pwidth, pix.pheight) = (Int((volume / pixel).rounded()), Int((volume / pixel).rounded()))
    (pix.pixelSpacingX, pix.pixelSpacingY, pix.sliceInterval, pix.sliceThickness) = (pixel, pixel, sliceInterval, sliceThickness)
    return Array(repeating: pix, count: max(1, Int(volume / 2 / abs(sliceInterval == 0 ? 1 : sliceInterval))))
}

/// A window as the launcher opens it, with three -showWindow: calls: for a
/// series of 0.625 mm slices with pixels of 1 mm by default, at the thin end,
/// and with a path without nodes unless `file` keeps one.
func openWindow(sliceInterval: Double = 0.625, sliceThickness: Double? = nil, pixel: Double = 1, volume: Double = 282,
                saved file: String? = nil) -> CPRController {
    let window = CPRController()
    window.vr.clippingRangeThickness = 1 // The MIP mode turns the slab on.
    window.isInitializing = true
    let images = series(sliceInterval: sliceInterval, sliceThickness: sliceThickness ?? abs(sliceInterval), pixel: pixel, volume: volume)
    for _ in 0..<3 { show(window, series: images, saved: file) }
    return window
}

/// A node the user adds in a plane with the Curved Path tool: the plane
/// edits its copy of the path and tells the window.
func drawNode(_ window: CPRController, _ node: N3Vector, in view: PathViewStandIn?) {
    window.cprViewWillEditCurvedPath(view)
    view?.curvedPath?.addPatientNode(node)
    window.cprViewDidUpdateCurvedPath(view)
    window.cprViewDidEditCurvedPath(view)
}

/// What a plane's mouse down sends its window as a single click begins, and
/// what its mouse up sends, as CPRMPRDCMView.swift has them.
func pressBegins(_ window: CPRController) {
%(pressBegins)s
}

func pressEnds(_ window: CPRController) {
%(pressEnds)s
}

/// What a plane's scrollWheel sends its window before it moves the plane.
func wheelStep(_ window: CPRController, in plane: CPRMPRDCMView) {
%(wheelStep)s
}
func wheelStep(_ window: CPRController) { wheelStep(window, in: window.mprView2!) }


/// A press in a plane: its mouse down, what the press does, its mouse up.
func press(_ window: CPRController, _ work: () -> Void) {
    pressBegins(window)
    work()
    pressEnds(window)
}

/// The planes' cameras changed as `change` says, as -updateViewMPR keeps the
/// camera of the volume rendering view it reads back.
func changeCameras(_ window: CPRController, _ change: (Camera) -> Void) {
    for plane in [window.mprView1, window.mprView2, window.mprView3] {
        let camera = plane?.camera?.copy() as? Camera
        if let camera { change(camera) }
        plane?.camera = camera
    }
}

/// -CPRView:setCrossCenter: once a node is added or dragged: the cross, and
/// with it the planes, goes to the node.
func moveCross(_ window: CPRController, to node: N3Vector) {
    changeCameras(window) { camera in
        camera.position = Point3D(Float(node.x), Float(node.y), Float(node.z) + 300)
        camera.focalPoint = Point3D(Float(node.x), Float(node.y), Float(node.z))
    }
}

/// A click in a plane with the Curved Path tool that adds a node.
func clickNode(_ window: CPRController, _ node: N3Vector, in view: PlaneStandIn?) {
    press(window) {
        drawNode(window, node, in: view)
        moveCross(window, to: node)
    }
}

/// The lines of the planes rotated by `degrees`, as a drag on a line does.
func rotateLines(_ window: CPRController, by degrees: Float) {
    let radians = degrees * .pi / 180
    changeCameras(window) { camera in camera.viewUp = Point3D(sin(radians), cos(radians), 0) }
    window.mprView1?.angleMPR += degrees
}

/// The planes moved by a step along their normal, as a wheel step does.
func scroll(_ window: CPRController) {
    changeCameras(window) { camera in camera.position?.z += 1; camera.focalPoint?.z += 1 }
}

func focalDepth(_ window: CPRController) -> Float {
    return window.mprView1?.camera?.focalPoint?.z ?? -1
}

/// The cross moved along x by `points` screen points of the first plane, the
/// tallest (a camera's parallelScale is half the height its plane shows), as a
/// click at the cross's centre moves it to the point clicked.
func nudgeCross(_ window: CPRController, byPoints points: Float) {
    let plane = window.mprView1
    let units = points * 2 * (plane?.camera?.parallelScale ?? 0) / Float(plane?.bounds.height ?? 1)
    changeCameras(window) { camera in camera.position?.x += units; camera.focalPoint?.x += units }
}

/// The first plane zoomed in so that its corners moved `points` screen points:
/// a corner r points from the centre goes to r × scale / new scale.
func zoomFirstPlane(_ window: CPRController, cornersBy points: Float) {
    let plane = window.mprView1, scale = plane?.camera?.parallelScale ?? 0
    let halfDiagonal = Float(hypot(plane?.bounds.width ?? 0, plane?.bounds.height ?? 0)) / 2
    plane?.camera?.parallelScale = scale * halfDiagonal / (halfDiagonal + points)
}

func entries(_ window: CPRController) -> [String] {
    return (window.undoQueue as? [[String: Any]] ?? []).map { $0["type"] as? String ?? "?" }
}

func viewUp(_ window: CPRController) -> Float {
    return window.mprView1?.camera?.viewUp?.x ?? -1
}

/// What -assistedCurvedPath: does once it has the centerline: a new path,
/// handed to -setCurvedPath:, then to the seven views.
func pathAssistant(_ window: CPRController) {
    let newCP = CPRCurvedPath()
    for node in nodes { newCP.addPatientNode(node) }
    window.curvedPath = newCP
    for view in window.views { view?.curvedPath = window._curvedPath }
}

/// The window's path and the views' copies have the slab of the thickness
/// the window shows.
func drawsShownSlab(_ window: CPRController, _ what: String) {
    let shown = window.getClippingRangeThicknessInMm()
    // The slab is the thickness shown, also at 2 mm or less.
    let slab: CGFloat = shown > 0 ? CGFloat(shown) : 0
    let pathSlab = window._curvedPath?.thickness ?? -1
    expect(pathSlab == slab, "\(what): the window shows \(shown) mm and its path draws a slab of \(pathSlab) mm")
    let names = ["plane 1", "plane 2", "plane 3", "the curved MPR", "the top section", "the middle section", "the bottom section"]
    for (name, view) in zip(names, window.views) {
        let viewSlab = view?.curvedPath?.thickness ?? -1
        expect(viewSlab == slab, "\(what): the window shows \(shown) mm and \(name) draws a slab of \(viewSlab) mm")
    }
}

func shows(_ window: CPRController, _ millimeters: Float, _ what: String) {
    let shown = window.getClippingRangeThicknessInMm()
    expect(abs(shown - millimeters) < 1e-4, "\(what): the window shows \(shown) mm, not \(millimeters) mm")
}

/// The field (the window's thickness), the knob and its bubble show one
/// slab, between the slider's ends, on either curve of the slider, and write
/// one number for it, in a language with a point and in one with a comma.
func slabAgrees(_ window: CPRController, _ what: String) {
    let shown = Double(window.getClippingRangeThicknessInMm())
    let thin = window.thickSlabThinEnd, thick = Double(window.dcmIntervalMax)
    // The thickness is kept as a Float.
    expect(shown >= thin - 1e-6 && shown <= thick + 1e-6, "\(what): the field says \(shown) mm, outside the slider's \(thin) to \(thick) mm")
    expect(window.slabFieldThickness == shown, "\(what): the field binds \(window.slabFieldThickness) mm, not the window's \(shown) mm")
    for exponential in [false, true] {
        ReconstructionPreferences.logarithmicThickSlabSlider = PreferenceKey(value: exponential)
        let scale = window.thickSlabSliderScale
        expect(scale.minimum == thin && scale.maximum == thick && scale.exponential == (exponential && thick > thin),
               "\(what): the slider's scale runs from \(scale.minimum) to \(scale.maximum) mm, not \(thin) to \(thick) mm")
        let knob = scale.thickness(at: window.slabSliderPosition)
        let curve = exponential ? "logarithmic" : "linear"
        expect(abs(knob - shown) < 1e-4, "\(what): the field says \(shown) mm and the knob and its bubble \(knob) mm (\(curve) slider)")
        for language in ["en_US", "it_IT", "pt_BR"] {
            let locale = Locale(identifier: language)
            let bubble = SlabThicknessText.text(knob, locale: locale), field = SlabThicknessText.number(shown, locale: locale)
            expect(bubble == field + " mm", "\(what): the bubble says \(bubble) and the field \(field) (\(curve) slider, \(language))")
        }
    }
    ReconstructionPreferences.logarithmicThickSlabSlider = PreferenceKey(value: false)
}

func nodeCount(_ window: CPRController) -> Int {
    return window._curvedPath?.nodes.count ?? 0
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])

/// A path of three nodes saved as the window closes, at `millimeters`.
func savedPath(_ millimeters: Float, _ name: String) -> String {
    let window = openWindow()
    for node in nodes.prefix(3) { drawNode(window, node, in: window.mprView2) }
    window.setClippingRangeThicknessInMm(millimeters)
    let file = folder.appendingPathComponent(name).path
    window.saveBezierPathToFile(file)
    expect(FileManager.default.fileExists(atPath: file), "the path at \(millimeters) mm was not saved")
    return file
}

let thick = savedPath(100, "CPR-thick")
let thin = savedPath(0.625, "CPR-thin")
/// The thin end of the window the saved paths were drawn in, and of a default one.
let thinEnd: Float = 0.625

/// A path of three nodes kept with a slab of `thickness`, as a file from
/// elsewhere may have it.
func pathFile(_ thickness: CGFloat, _ name: String) -> String {
    let path = CPRCurvedPath()
    for node in nodes.prefix(3) { path.addPatientNode(node) }
    path.thickness = thickness
    let file = folder.appendingPathComponent(name)
    try? NSKeyedArchiver.archivedData(withRootObject: path, requiringSecureCoding: true).write(to: file)
    return file.path
}

opening: do {
    let window = openWindow()
    drawsShownSlab(window, "the window as it opens")
    // The window opens at its thin end, exactly, with the slab in the curved view.
    shows(window, thinEnd, "the window as it opens")
    expect(window.getClippingRangeThicknessInMm() == thinEnd && window.thickSlabThinEnd == Double(thinEnd),
           "the window opens at \(window.getClippingRangeThicknessInMm()) mm with a thin end of \(window.thickSlabThinEnd) mm, not at 0.625 mm")
    expect(window.cprView?.curvedPath?.thickness == CGFloat(thinEnd), "the curved view opens with a slab of \(window.cprView?.curvedPath?.thickness ?? -1) mm, not the window's")
    slabAgrees(window, "the window as it opens")
    expect(window.undoQueue?.count == 0, "a new window has \(window.undoQueue?.count ?? -1) paths to undo, not none")
    for node in nodes { drawNode(window, node, in: window.mprView3) }
    drawsShownSlab(window, "a path drawn at the thin end")
    window.setClippingRangeThicknessInMm(12)
    drawsShownSlab(window, "the slab set to 12 mm")
    window.setClippingRangeThicknessInMm(1.5)
    drawsShownSlab(window, "the slab set to 1.5 mm")
    // The curved view has the slab at 1 and at 2 mm, where it had none.
    for millimeters in [Float(1), 2, 3] {
        window.setClippingRangeThicknessInMm(millimeters)
        expect(window.cprView?.curvedPath?.thickness == CGFloat(millimeters),
               "at \(millimeters) mm the curved view draws a slab of \(window.cprView?.curvedPath?.thickness ?? -1) mm")
        drawsShownSlab(window, "the slab set to \(millimeters) mm")
        slabAgrees(window, "the slab set to \(millimeters) mm")
    }
}

ends: do {
    // Slices 2 mm thick every 1 mm with pixels of 0.7 mm: the thin end is 0.7 mm; the volume is 180 mm across.
    let window = openWindow(sliceInterval: -1, sliceThickness: 2, pixel: 0.7, volume: 180)
    expect(window.thickSlabThinEnd == 0.7 && window.dcmIntervalMax == 180, "the ends are \(window.thickSlabThinEnd) and \(window.dcmIntervalMax) mm, not 0.7 and 180 mm")
    expect(abs(window.dcmIntervalMin - 0.699) < 1e-6, "the export's interval starts at \(window.dcmIntervalMin) mm, not 0.699 mm")
    for node in nodes { drawNode(window, node, in: window.mprView3) }
    for exponential in [false, true] {
        ReconstructionPreferences.logarithmicThickSlabSlider = PreferenceKey(value: exponential)
        // The left end of the slider is the thin end itself.
        window.slabSliderPosition = 0
        expect(window.getClippingRangeThicknessInMm() == Float(0.7), "the left end is a slab of \(window.getClippingRangeThicknessInMm()) mm, not 0.7 mm")
        slabAgrees(window, "the knob at the left end")
        drawsShownSlab(window, "the knob at the left end")
        window.slabSliderPosition = 1
        shows(window, 180, "the knob at the right end")
        slabAgrees(window, "the knob at the right end")
        // What is typed beyond an end goes to the end, and the three places say so.
        for (typed, kept) in [(0.3, Float(0.7)), (500, 180), (-2, 0.7), (12.375, 12.4), (2, 2), (0.7, 0.7)] {
            window.slabFieldThickness = typed
            expect(window.getClippingRangeThicknessInMm() == kept, "\(typed) typed is a slab of \(window.getClippingRangeThicknessInMm()) mm, not \(kept) mm")
            slabAgrees(window, "\(typed) typed in the field")
            drawsShownSlab(window, "\(typed) typed in the field")
        }
    }
    ReconstructionPreferences.logarithmicThickSlabSlider = PreferenceKey(value: false)
    // The thin end read back from its own text: 0.62 for slices of 0.625 mm.
    let fine = openWindow()
    fine.setClippingRangeThicknessInMm(10)
    for locale in ["en_US", "it_IT"].map(Locale.init(identifier:)) {
        let written = SlabThicknessText.number(fine.thickSlabThinEnd, locale: locale)
        expect(written == (locale.identifier == "it_IT" ? "0,62" : "0.62"), "the thin end is written \(written)")
        fine.slabFieldThickness = SlabThicknessText.value(of: written) ?? -1
        expect(fine.getClippingRangeThicknessInMm() == thinEnd, "the thin end typed as \(written) is a slab of \(fine.getClippingRangeThicknessInMm()) mm, not 0.625 mm")
        slabAgrees(fine, "the thin end typed as \(written)")
        fine.setClippingRangeThicknessInMm(10)
    }
    // A series that says neither its interval nor its pixels opens at 1 mm, not at none.
    let unknown = CPRController()
    unknown.vr.clippingRangeThickness = 1
    show(unknown, series: [DCMPix()], saved: nil)
    shows(unknown, 1, "a window of a series without geometry")
    expect(unknown.thickSlabThinEnd == 1 && unknown.dcmIntervalMax == 100, "its ends are \(unknown.thickSlabThinEnd) and \(unknown.dcmIntervalMax) mm, not 1 and 100 mm")
}

reopened: do {
    let window = openWindow()
    window.loadBezierPathFromFile(thick)
    shows(window, 100, "a reopened window whose path was saved at 100 mm")
    drawsShownSlab(window, "a reopened window whose path was saved at 100 mm")
    expect(window._curvedPath?.nodes.count == 3, "the reopened path has \(window._curvedPath?.nodes.count ?? 0) nodes, not 3")
    window.loadBezierPathFromFile(thin)
    shows(window, thinEnd, "a path saved at the thin end, loaded at 100 mm")
    slabAgrees(window, "a path saved at the thin end, loaded at 100 mm")
    drawsShownSlab(window, "a path saved at the thin end, loaded at 100 mm")
}

reopenedThin: do {
    let saved = (try? Data(contentsOf: URL(fileURLWithPath: thin))).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CPRCurvedPath.self, from: $0) }
    expect(saved?.thickness == CGFloat(thinEnd), "a path saved at the thin end keeps a slab of \(saved?.thickness ?? -1) mm, not the thin end's")
    // The thin end: 0.625 mm for slices of 0.625 mm; 1 mm, the pixels', for
    // slices of 2 mm. A file that keeps no slab (0), as a version that kept
    // none at 2 mm or less wrote it, or a thinner one, opens there.
    for (sliceInterval, volume, thinEnd) in [(0.625, 282.0, Float(0.625)), (2, 240, 1)] {
        for (file, kept) in [(thin, "the thin end of 0.625 mm"), (pathFile(0, "CPR-0"), "none"), (pathFile(0.3, "CPR-0.3"), "0.3 mm")] {
            let window = openWindow(sliceInterval: sliceInterval, volume: volume, saved: file)
            let what = "a window of \(sliceInterval) mm slices reopened with a path that keeps a slab of \(kept)"
            expect(window.thickSlabThinEnd == Double(thinEnd), "\(what): the slider starts at \(window.thickSlabThinEnd) mm, not \(thinEnd) mm")
            shows(window, thinEnd, what)
            slabAgrees(window, what)
            drawsShownSlab(window, what)
            expect(nodeCount(window) == 3, "\(what): the path has \(nodeCount(window)) nodes, not 3")
        }
    }
}

reopenedThick: do {
    let window = openWindow(saved: thick)
    shows(window, 100, "a window reopened with a path saved at 100 mm")
    slabAgrees(window, "a window reopened with a path saved at 100 mm")
    let small = openWindow(volume: 80, saved: thick)
    shows(small, 80, "a path saved at 100 mm reopened on a volume of 80 mm")
    slabAgrees(small, "a path saved at 100 mm reopened on a volume of 80 mm")
    drawsShownSlab(small, "a path saved at 100 mm reopened on a volume of 80 mm")
}

reopenedUndo: do {
    let window = openWindow(saved: thick)
    let loaded = window._curvedPath?.nodes
    expect(window.undoQueue?.count == 0,
           "a reopened window has \(window.undoQueue?.count ?? -1) paths to undo, not none: the opening's own")
    let beeps = NSSound.beeps
    window.undo(nil)
    expect(NSSound.beeps == beeps + 1, "an undo right after the window reopened found something to undo")
    expect(CPRController.sameNodes(window._curvedPath?.nodes, loaded),
           "an undo right after the window reopened left \(nodeCount(window)) nodes, not the 3 reopened")
    drawsShownSlab(window, "an undo right after the window reopened at 100 mm")
    // The edits after the opening undo one at a time, down to the path reopened.
    drawNode(window, nodes[3], in: window.mprView2)
    drawNode(window, N3VectorMake(40, 0, 8), in: window.mprView1)
    window.undo(nil)
    expect(nodeCount(window) == 4, "the undo of the last node drawn after the reopening left \(nodeCount(window)) nodes, not 4")
    window.undo(nil)
    expect(nodeCount(window) == 3, "the undo of the first node drawn after the reopening left \(nodeCount(window)) nodes, not 3")
    window.undo(nil)
    expect(CPRController.sameNodes(window._curvedPath?.nodes, loaded),
           "an undo past the edits after the reopening left \(nodeCount(window)) nodes, not the 3 reopened")
    shows(window, 100, "the edits after the reopening undone")
    drawsShownSlab(window, "the edits after the reopening undone")
}

reset: do {
    let window = openWindow(saved: thick)
    show(window, series: series(sliceInterval: 0.625, sliceThickness: 0.625, pixel: 1, volume: 282), saved: thick)
    expect(window.undoQueue?.count == 0, "a Reset that brought back the path shown left \(window.undoQueue?.count ?? -1) paths to undo")
    drawNode(window, nodes[3], in: window.mprView3)
    show(window, series: series(sliceInterval: 0.625, sliceThickness: 0.625, pixel: 1, volume: 282), saved: thick)
    expect(nodeCount(window) == 3, "a Reset left \(nodeCount(window)) nodes, not the 3 saved")
    shows(window, 100, "a Reset of a path saved at 100 mm")
    window.undo(nil)
    expect(nodeCount(window) == 4, "the undo of a Reset brought back \(nodeCount(window)) nodes, not the 4 drawn")
    window.undo(nil)
    expect(nodeCount(window) == 3, "the undo of the node drawn before a Reset left \(nodeCount(window)) nodes, not 3")
    drawsShownSlab(window, "the undo of a Reset")
}

assistant: do {
    let window = openWindow()
    window.loadBezierPathFromFile(thick)
    pathAssistant(window)
    shows(window, 100, "the Path Assistant at 100 mm")
    drawsShownSlab(window, "the Path Assistant at 100 mm")
    window.setClippingRangeThicknessInMm(40)
    drawsShownSlab(window, "the slab set to 40 mm after the Path Assistant")
}

installedByAView: do {
    let window = openWindow()
    window.loadBezierPathFromFile(thick)
    window.cprViewWillEditCurvedPath(window.mprView1)
    let fresh = CPRCurvedPath()
    for node in nodes { fresh.addPatientNode(node) }
    window.mprView1?.curvedPath = fresh
    window.cprViewDidEditCurvedPath(window.mprView1)
    shows(window, 100, "a new path installed by a plane at 100 mm")
    drawsShownSlab(window, "a new path installed by a plane at 100 mm")
}

undone: do {
    let window = openWindow()
    for node in nodes.prefix(3) { drawNode(window, node, in: window.mprView1) }
    window.setClippingRangeThicknessInMm(10)
    window.undo(nil)
    expect(window._curvedPath?.nodes.count == 2, "the undo left \(window._curvedPath?.nodes.count ?? 0) nodes, not 2")
    shows(window, 10, "an undo at 10 mm of a node drawn at the thin end")
    drawsShownSlab(window, "an undo at 10 mm of a node drawn at the thin end")
    window.redo(nil)
    expect(window._curvedPath?.nodes.count == 3, "the redo left \(window._curvedPath?.nodes.count ?? 0) nodes, not 3")
    drawsShownSlab(window, "a redo at 10 mm")
    drawNode(window, nodes[3], in: window.mprView2)
    window.setClippingRangeThicknessInMm(1)
    window.undo(nil)
    drawsShownSlab(window, "an undo at 1 mm of a node drawn at 10 mm")
}

undonePastTheOpening: do {
    let window = openWindow()
    window.loadBezierPathFromFile(thick)
    window.undo(nil)
    drawsShownSlab(window, "an undo after the window reopened at 100 mm")
    for node in nodes { drawNode(window, node, in: window.mprView2) }
    shows(window, 100, "a path drawn after that undo")
    drawsShownSlab(window, "a path drawn after that undo")
}

imported: do {
    let window = openWindow()
    window.setClippingRangeThicknessInMm(10)
    let packed = nodes.flatMap { [NSNumber(value: Double($0.x)), NSNumber(value: Double($0.y)), NSNumber(value: Double($0.z))] }
    let file = folder.appendingPathComponent("centerline.xyz")
    try? CPRCenterlineImport.patientSpaceText(from: packed).write(to: file, atomically: true, encoding: .utf8)
    window.loadBezierPathFromFile(file.path)
    expect(window._curvedPath?.nodes.count == nodes.count,
           "the imported centerline has \(window._curvedPath?.nodes.count ?? 0) nodes, not \(nodes.count)")
    shows(window, 10, "a centerline imported at 10 mm")
    drawsShownSlab(window, "a centerline imported at 10 mm")
}

nodesClicked: do {
    let window = openWindow()
    for node in nodes.prefix(2) { clickNode(window, node, in: window.mprView2) }
    expect(entries(window) == ["curvedPath", "curvedPath"],
           "two clicks that added a node each left \(entries(window)) to undo, not the path before each node")
    let beeps = NSSound.beeps
    window.undo(nil)
    expect(nodeCount(window) == 1, "the first Cmd-Z after two nodes added left \(nodeCount(window)) nodes, not 1")
    window.undo(nil)
    expect(nodeCount(window) == 0, "the second Cmd-Z after two nodes added left \(nodeCount(window)) nodes, not 0")
    window.undo(nil)
    expect(NSSound.beeps == beeps + 1, "the third Cmd-Z after two nodes added found something to undo instead of beeping")
    window.redo(nil)
    window.redo(nil)
    expect(nodeCount(window) == 2, "two Cmd-Shift-Z after the nodes were undone left \(nodeCount(window)) nodes, not 2")
}

nodeDragged: do {
    let window = openWindow()
    for node in nodes.prefix(3) { clickNode(window, node, in: window.mprView1) }
    let drawn = window._curvedPath?.nodes
    let moved = N3VectorMake(12, 9, 2)
    press(window) {
        // The node's drag: will edit at the mouse down, did edit and the
        // cross to the node at the mouse up.
        window.cprViewWillEditCurvedPath(window.mprView1)
        window.mprView1?.curvedPath?.removeNode(at: 1)
        window.mprView1?.curvedPath?.insertPatientNode(moved, at: 1)
        window.cprViewDidEditCurvedPath(window.mprView1)
        moveCross(window, to: moved)
    }
    expect(entries(window) == ["curvedPath", "curvedPath", "curvedPath", "curvedPath"],
           "a node dragged after three clicks left \(entries(window)) to undo, not the path before each edit")
    window.undo(nil)
    expect(CPRController.sameNodes(window._curvedPath?.nodes, drawn), "a Cmd-Z did not bring back the node dragged")
}

camerasMoved: do {
    let window = openWindow()
    clickNode(window, nodes[0], in: window.mprView3)
    let before = viewUp(window)
    press(window) { rotateLines(window, by: 30) }
    expect(entries(window) == ["curvedPath", "mprCamera"],
           "a press that rotated the lines after a node left \(entries(window)) to undo, not the path and the cameras")
    window.undo(nil)
    expect(viewUp(window) == before && window.mprView1?.angleMPR == 0,
           "the Cmd-Z of a rotation left the planes rotated (\(viewUp(window)), \(window.mprView1?.angleMPR ?? -1)°)")
    expect(nodeCount(window) == 1, "the Cmd-Z of a rotation left \(nodeCount(window)) nodes, not the 1 added before")
    window.redo(nil)
    expect(viewUp(window) != before && window.mprView1?.angleMPR == 30, "the Cmd-Shift-Z of a rotation left the planes as before it")
    let kept = entries(window)
    press(window) {}
    expect(entries(window) == kept, "a click that changed nothing left \(entries(window)) to undo, not \(kept)")
    // A camera the volume rendering view reads back unchanged differs by rounding.
    press(window) { changeCameras(window) { camera in camera.position?.x += 1e-5; camera.ww *= 1 + 1e-7 } }
    expect(entries(window) == kept, "a click whose cameras came back rounded left \(entries(window)) to undo, not \(kept)")
    press(window) { changeCameras(window) { camera in camera.parallelScale *= 0.8 } }
    expect(entries(window) == kept + ["mprCamera"], "a press that zoomed the planes left \(entries(window)) to undo, not one more camera")
}

// A run of wheel steps leaves one entry, the cameras as its first step found
// them (an entry per event filled the queue with the depths a scroll went
// through); a step after a pause, or after something else went on the queue,
// begins another run.
wheelRun: do {
    let window = openWindow()
    let depth = focalDepth(window)
    for _ in 0..<5 { wheelStep(window); scroll(window) }
    expect(entries(window) == ["mprCamera"], "five wheel steps in a row left \(entries(window)) to undo, not one entry of the cameras")
    window.undo(nil)
    expect(focalDepth(window) == depth, "the Cmd-Z of a run of wheel steps left the planes at \(focalDepth(window)), not at \(depth) where the run began")
    expect(entries(window) == [], "the Cmd-Z of a run of wheel steps left \(entries(window)) to undo")
    // After the undo the run's entry is gone: the next step begins a run.
    for _ in 0..<2 { wheelStep(window); scroll(window) }
    expect(entries(window) == ["mprCamera"], "two wheel steps after an undo left \(entries(window)) to undo, not one entry")
    // The redraw in full detail came: the run is over.
    window.delayedFullLODRendering(window.mprView2)
    for _ in 0..<2 { wheelStep(window); scroll(window) }
    expect(entries(window) == ["mprCamera", "mprCamera"], "a second run of wheel steps, after the redraw in full detail, left \(entries(window)) to undo, not one entry more")
    // A step in another plane ends the run with its redraw, and begins one.
    window.fullDetailRedraws = []
    wheelStep(window, in: window.mprView3!); scroll(window)
    expect(entries(window).count == 3 && window.fullDetailRedraws.count == 1 && window.fullDetailRedraws.first === window.mprView2,
           "a wheel step in another plane left \(entries(window)) to undo and \(window.fullDetailRedraws.count) redraws of the plane scrolled before, not an entry more and one")
    // A press before the redraw in full detail has it first: that redraw
    // centres the other planes on the plane scrolled, and a press that took
    // their older cross put the plane back where the run began.
    window.fullDetailRedraws = []
    press(window) { changeCameras(window) { camera in camera.parallelScale *= 0.8 } }
    expect(window.fullDetailRedraws.count == 1 && window.fullDetailRedraws.first === window.mprView3,
           "a press during a run of wheel steps had \(window.fullDetailRedraws.count) redraws of the plane scrolled first, not one")
    wheelStep(window); scroll(window)
    expect(entries(window) == ["mprCamera", "mprCamera", "mprCamera", "mprCamera", "mprCamera"],
           "a wheel step after a press that zoomed left \(entries(window)) to undo, not the zoom's entry and a run's")
}

// Something new to undo empties the redo queue: after an undo, a redo
// brought an old state back over the edit made since. A click that changes
// nothing leaves the redo as it was.
redoAfterAnEdit: do {
    let window = openWindow()
    for node in nodes.prefix(3) { clickNode(window, node, in: window.mprView1) }
    window.undo(nil)
    window.undo(nil)
    expect(window.redoQueue?.count == 2 && nodeCount(window) == 1, "two Cmd-Z after three nodes left \(window.redoQueue?.count ?? -1) to redo and \(nodeCount(window)) nodes")
    press(window) {}
    expect(window.redoQueue?.count == 2, "a click that changed nothing left \(window.redoQueue?.count ?? -1) to redo, not the two undone")
    clickNode(window, nodes[3], in: window.mprView1)
    expect(window.redoQueue?.count == 0, "a node added after two Cmd-Z left \(window.redoQueue?.count ?? -1) entries to redo, not none")
    window.redo(nil)
    expect(nodeCount(window) == 2, "a redo after a new node left \(nodeCount(window)) nodes, not the 2 the edit left")
    window.undo(nil)
    wheelStep(window); scroll(window)
    expect(window.redoQueue?.count == 0, "a wheel step after a Cmd-Z left \(window.redoQueue?.count ?? -1) entries to redo, not none")
}

pressWithoutRelease: do {
    let window = openWindow()
    pressBegins(window)
    rotateLines(window, by: 15)
    // The release never came: the next press ends this one first.
    press(window) {}
    expect(entries(window) == ["mprCamera"], "a rotation whose release never came, then a click, left \(entries(window)) to undo")
    window.undo(nil)
    expect(window.mprView1?.angleMPR == 0, "the Cmd-Z of a rotation whose release never came left the lines at \(window.mprView1?.angleMPR ?? -1)°")
}

nodeClickedInPlace: do {
    let window = openWindow()
    for node in nodes.prefix(3) { clickNode(window, node, in: window.mprView1) }
    press(window) {
        // A click on the first node that does not drag it: will edit at the
        // mouse down, did edit with the nodes as they were and the cross to
        // the node at the mouse up.
        window.cprViewWillEditCurvedPath(window.mprView1)
        window.cprViewDidEditCurvedPath(window.mprView1)
        moveCross(window, to: nodes[0])
    }
    expect(entries(window) == ["curvedPath", "curvedPath", "curvedPath", "mprCamera"],
           "a click on a node that left it where it was left \(entries(window)) to undo, not the path before each node and the cameras")
    window.undo(nil)
    let crossX = window.mprView1?.camera?.focalPoint?.x ?? -1
    expect(nodeCount(window) == 3 && crossX == Float(nodes[2].x),
           "the Cmd-Z of a click on a node left \(nodeCount(window)) nodes and the cross at x \(crossX), not 3 and the last node's \(nodes[2].x)")
    window.undo(nil)
    expect(nodeCount(window) == 2, "the Cmd-Z after the one of a click on a node left \(nodeCount(window)) nodes, not 2")
}

nodeRefused: do {
    let window = openWindow()
    clickNode(window, nodes[0], in: window.mprView2)
    // A node the plane refuses: will edit, did edit with the path as it was,
    // and the cross stays.
    press(window) {
        window.cprViewWillEditCurvedPath(window.mprView2)
        window.cprViewDidEditCurvedPath(window.mprView2)
    }
    expect(entries(window) == ["curvedPath"], "a node the plane refused left \(entries(window)) to undo, not the path before the first node")
}

wheelDuringPress: do {
    let window = openWindow()
    let depth = focalDepth(window)
    pressBegins(window)
    rotateLines(window, by: 10)
    wheelStep(window)
    scroll(window)
    pressEnds(window)
    expect(entries(window) == ["mprCamera"], "a rotation with a wheel step during it left \(entries(window)) to undo, not one entry")
    window.undo(nil)
    expect(window.mprView1?.angleMPR == 0 && focalDepth(window) == depth,
           "the Cmd-Z of a rotation with a wheel step during it left the lines at \(window.mprView1?.angleMPR ?? -1)° and the plane at \(focalDepth(window)), not at 0° and \(depth) as before the press")
}

wheelAfterLostRelease: do {
    let window = openWindow()
    clickNode(window, nodes[0], in: window.mprView1)
    pressBegins(window) // An image drag begins: the release never comes.
    for _ in 0..<3 { wheelStep(window); scroll(window) }
    window.undo(nil)
    expect(focalDepth(window) == 0 && nodeCount(window) == 1,
           "a Cmd-Z after three wheel steps that followed a press without a release left the plane at \(focalDepth(window)) and \(nodeCount(window)) nodes, not at 0 with the node")
}

windowOfThePlanes: do {
    let window = openWindow()
    // A click with a 2D tool after a window preset gives the MIP planes'
    // cameras the window the planes show, which an undo would not change.
    press(window) { changeCameras(window) { camera in camera.wl = 300; camera.ww = 1500 } }
    expect(entries(window).isEmpty, "a click that gave the MIP planes' cameras their window left \(entries(window)) to undo")
    window._clippingRangeMode = 0 // VR, whose planes show the cameras' window.
    press(window) { changeCameras(window) { camera in camera.wl = 40; camera.ww = 400 } }
    expect(entries(window) == ["mprCamera"], "a press that changed the VR planes' window left \(entries(window)) to undo, not the cameras")
}

stillClicks: do {
    let window = openWindow()
    clickNode(window, nodes[0], in: window.mprView2)
    // A still click at the cross's centre moves the cross to the point
    // clicked, a fraction of a point away, which none of the three planes shows.
    press(window) { nudgeCross(window, byPoints: 0.4) }
    expect(entries(window) == ["curvedPath"], "a still click that moved the cross 0.4 point left \(entries(window)) to undo, not the node's path alone")
    // Lines that read a turn of 360° apart are where they were.
    window.mprView2?.angleMPR = 1.39e-6
    press(window) { window.mprView2?.angleMPR = -360 }
    expect(entries(window) == ["curvedPath"], "a click after which a plane's lines read -360° for 0° left \(entries(window)) to undo")
    press(window) { window.mprView3?.angleMPR = 360.00002 }
    expect(entries(window) == ["curvedPath"], "a click after which a plane's lines read 360° for 0° left \(entries(window)) to undo")
    // What a plane shows stays: the cross moved 1.2 points of the tallest
    // plane (0.41 point of the shortest), lines turned half a degree.
    var kept = entries(window)
    press(window) { nudgeCross(window, byPoints: 1.2) }
    expect(entries(window) == kept + ["mprCamera"], "a click that moved the cross 1.2 points left \(entries(window)) to undo, not one more camera")
    kept = entries(window)
    press(window) { nudgeCross(window, byPoints: 0.7) } // More than a pixel of a Retina screen.
    expect(entries(window) == kept + ["mprCamera"], "a click that moved the cross 0.7 point left \(entries(window)) to undo, not one more camera")
    kept = entries(window)
    press(window) { window.mprView1?.angleMPR += 0.5 }
    expect(entries(window) == kept + ["mprCamera"], "a click that turned a plane's lines half a degree left \(entries(window)) to undo, not one more camera")
    // A move of 0.4 point of the first plane is 1.07 points in the third
    // zoomed four times.
    window.mprView3?.camera?.parallelScale = 30
    kept = entries(window)
    press(window) { nudgeCross(window, byPoints: 0.4) }
    expect(entries(window) == kept + ["mprCamera"], "a move of 1.07 points in a zoomed plane left \(entries(window)) to undo, not one more camera")
    // Planes tilted 1° about their focal points, whose cameras moved less
    // than half a point, and planes rolled 1° with their lines' angles kept.
    let tilted = openWindow(), radians = Float.pi / 180
    var moved: Float = 0
    press(tilted) {
        changeCameras(tilted) { camera in
            guard let p = camera.position, let f = camera.focalPoint else { return }
            let (x, z) = (p.x - f.x, p.z - f.z)
            camera.position = Point3D(f.x + x * cos(radians) + z * sin(radians), p.y, f.z - x * sin(radians) + z * cos(radians))
            moved = max(moved, hypot((camera.position?.x ?? 0) - p.x, (camera.position?.z ?? 0) - p.z))
        }
    }
    let halfPoint = (tilted.mprView1?.camera?.parallelScale ?? 0) / Float(tilted.mprView1?.bounds.height ?? 1)
    expect(moved > 0 && moved < halfPoint, "the tilt of 1° moved a camera \(moved) units, not less than half a point (\(halfPoint))")
    expect(entries(tilted) == ["mprCamera"], "a press that tilted the planes 1° left \(entries(tilted)) to undo, not the cameras")
    let rolled = openWindow()
    press(rolled) { changeCameras(rolled) { camera in camera.viewUp = Point3D(sin(radians), cos(radians), 0) } }
    expect(entries(rolled) == ["mprCamera"], "a press that rolled the planes 1° left \(entries(rolled)) to undo, not the cameras")
    // A zoom shows at the plane's corners, which move more than its centre.
    let zoomed = openWindow()
    press(zoomed) { zoomFirstPlane(zoomed, cornersBy: 0.3) }
    expect(entries(zoomed).isEmpty, "a zoom that moved a plane's corners 0.3 point left \(entries(zoomed)) to undo")
    press(zoomed) { zoomFirstPlane(zoomed, cornersBy: 0.7) }
    expect(entries(zoomed) == ["mprCamera"], "a zoom that moved a plane's corners 0.7 point left \(entries(zoomed)) to undo, not the cameras")
}

if !wrong.isEmpty {
    for line in wrong { print("FAIL: " + line) }
    exit(1)
}
'''


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


controller = code(source('Horos/Sources/CPRController.swift').decode('utf-8'))
check(bool(controller), 'no CPRController.swift')
PIECES = {}
for name, signature in [('debugAssert', 'private func debugAssert('),
                        ('addObject', 'private func addObject('),
                        ('valueWithPointer', 'private func valueWithPointer('),
                        ('curvedPathOf', 'private func curvedPathOf('),
                        ('setCurvedPathOf', 'private func setCurvedPathOf('),
                        ('getClippingRangeThicknessInMm', 'public dynamic func getClippingRangeThicknessInMm('),
                        ('setClippingRangeThicknessInMm', 'dynamic func setClippingRangeThicknessInMm('),
                        ('setClippingRangeThicknessValue', 'private func setClippingRangeThicknessValue('),
                        ('setCurvedPathValue', 'private func setCurvedPathValue('),
                        ('addToUndoQueue', 'override dynamic func add(toUndoQueue string: String!)'),
                        ('prepareObjectForUndo', 'public dynamic func prepareObject(forUndo string: String!)'),
                        ('executeUndo', 'private dynamic func executeUndo('),
                        ('undo', 'override dynamic func undo('),
                        ('redo', 'override dynamic func redo('),
                        ('saveBezierPathToFile', 'public dynamic func saveBezierPathToFile('),
                        ('loadBezierPathFromFile', 'public dynamic func loadBezierPathFromFile('),
                        ('importPatientSpaceCenterline', 'public dynamic func importPatientSpaceCenterline(fromFile'),
                        ('delegateCurveViewDebugging', 'private func delegateCurveViewDebugging('),
                        ('sameNodes', 'private static func sameNodes('),
                        ('forgetCenterlineIfNodesChange', 'private func forgetCenterlineIfNodesChange('),
                        ('cprViewWillEditCurvedPath', 'public dynamic func cprViewWillEditCurvedPath('),
                        ('cprViewDidUpdateCurvedPath', 'public dynamic func cprViewDidUpdateCurvedPath('),
                        ('cprViewDidEditCurvedPath', 'public dynamic func cprViewDidEditCurvedPath(')]:
    PIECES[name] = block(controller, signature)
    check(bool(PIECES[name]), f'CPRController.swift: no {signature.strip("(")}')
# The path file is read and written by the window's path library, which shows
# the path read through the window; a revision before it did both itself.
library = code(source('Horos/Sources/CurvedPathLibrary.swift').decode('utf-8'))
for name, text, signature, former in [('showLoadedPath', controller, 'func showLoadedPath(', '{}'),
                                      ('libraryArchive', library, 'private static func archive(', '{ nil }'),
                                      ('libraryPath', library, 'private static func path(from', '{ nil }'),
                                      ('librarySave', library, 'func save(toFile', '{}'),
                                      ('libraryLoad', library, 'func load(fromFile', '{ false }')]:
    PIECES[name] = block(text, signature) or former
    check(revision or PIECES[name] != former, f'no {signature.strip("(")}')
PIECES['curvedPathSet'] = '' if not library else re.sub(r'^import Foundation$', '', source(
    'Modules/IsiXImaging/Sources/ViewerReconstruction/CurvedPathSet.swift').decode('utf-8'), flags=re.M)
if not PIECES['curvedPathSet']:
    PIECES['curvedPathSet'] = 'struct CurvedPathSet {}'
# The pieces of the undo queue that -undo:, -redo: and the planes' presses
# share; a revision without them ran no press through them.
for name, signature in [('applyLastEntry', 'private func apply(lastEntryOf queue:'),
                        ('pushUndoEntry', 'private func pushUndoEntry('),
                        ('planePressBegan', 'func planePressBegan('),
                        ('planePressEnded', 'func planePressEnded('),
                        ('planeWheelStep', 'func planeWheelStep('),
                        ('planeWheelSettle', 'func planeWheelSettle('),
                        ('camerasDiffer', 'private func camerasDiffer('),
                        ('showCurvedPathInViews', 'private func showCurvedPathInViews('),
                        ('showChangedCurvedPath', 'private func showChangedCurvedPath(')]:
    PIECES[name] = block(controller, signature)
    check(revision or bool(PIECES[name]), f'CPRController.swift: no {signature.strip("(")}')
# What a plane's mouse down sends its window as a single click begins, and
# its mouse up: the press's undo messages.
view = code(source('Horos/Sources/CPRMPRDCMView.swift').decode('utf-8'))
mouse_down = block(view, 'override dynamic func mouseDown(with theEvent: NSEvent)')
mouse_up = block(view, 'override dynamic func mouseUp(with theEvent: NSEvent)')
check(bool(mouse_down) and bool(mouse_up), 'CPRMPRDCMView.swift: no mouseDown or mouseUp')
PRESS = re.compile(r'windowControllerIvar\?\.(?:add\(toUndoQueue:\s*"mprCamera"\)|planePress\w+\(\)|planeWheel\w+\((?:in: self)?\))')
scroll_wheel = block(view, 'override dynamic func scrollWheel(with theEvent: NSEvent)')
check(bool(scroll_wheel), 'CPRMPRDCMView.swift: no scrollWheel')
for name, body in [('pressBegins', mouse_down), ('pressEnds', mouse_up), ('wheelStep', scroll_wheel)]:
    PIECES[name] = '\n'.join('    ' + found.group(0).replace('windowControllerIvar?.', 'window.').replace('in: self', 'in: plane')
                             for found in PRESS.finditer(body)) or '    _ = window'
# The press begins before the click goes to the lines, a 2D tool or the
# volume, and every mouse up ends it, whatever the click did.
began = [found.start() for found in re.finditer(r'windowControllerIvar\?\.planePressBegan\(\)', mouse_down)]
settled = mouse_down.find('windowControllerIvar?.planeWheelSettle()')
check(revision or 0 <= settled < mouse_down.find('self.magicTrick()', settled) < began[0],
      "a plane's mouse down does not have the pending redraw of a wheel run before the plane takes the cross")
check(revision or (len(began) == 1 and began[0] < mouse_down.find('self.mouseOnLines(')),
      "a plane's mouse down does not begin the press once, before the click goes to the lines or a tool")
ended = [found.start() for found in PRESS.finditer(mouse_up)]
check(revision or (len(ended) == 1 and mouse_up[:ended[0]].count('{') - mouse_up[:ended[0]].count('}') == 1),
      "a plane's mouse up does not end the press whatever the click did")
check(revision or re.search(r'func delayedFullLODRendering\(_ sender: Any!\) \{\s*wheelRun = nil', controller),
      'the redraw in full detail does not end the run of wheel steps')
# The window's extension for its slab.
host = code(source('Horos/Sources/ThickSlabSliderHost.swift').decode('utf-8'))
for name, signature in [('curvedPathSlabThickness', 'func curvedPathSlabThickness('),
                        ('slabVolumeMaximum', 'static func slabVolumeMaximum('),
                        ('slabThinEnd', 'static func slabThinEnd('),
                        ('openSlab', 'func openSlab('),
                        ('slabWithinEnds', 'func slabWithinEnds('),
                        ('thickSlabSliderScale', 'var thickSlabSliderScale: ThickSlabSliderScale'),
                        ('slabSliderPosition', 'var slabSliderPosition: Double'),
                        ('slabFieldThickness', 'var slabFieldThickness: Double')]:
    PIECES[name] = block(host, signature)
    check(revision or bool(PIECES[name]), f'ThickSlabSliderHost.swift: no {signature.strip("(")}')
# Formerly the slab of the window's thickness was written in
# -setClippingRangeThickness: alone, the path had none at 2 mm or less, the
# window opened at the slice interval, 1 mm at most, with the slider's thin
# end a thousandth under two decimals of it, and the field took what was typed.
FORMER = {
    'curvedPathSlabThickness': '{ let thickness = self.getClippingRangeThicknessInMm(); '
                               'return thickness > 2.0 ? CGFloat(thickness) : 0 }',
    'slabVolumeMaximum': '{ return Float((pixList.first.map { Double($0.pwidth) * $0.pixelSpacingX } ?? 100).rounded(.up)) }',
    'slabThinEnd': '{ return 1 }',
    'openSlab': '''{
        let interval = Float(pixList.first?.sliceInterval ?? 0)
        setClippingRangeThicknessInMm(interval > 1 ? 1 : interval)
        let hundredths = Int32(Double(getClippingRangeThicknessInMm()) * 100.0)
        dcmIntervalMin = max(Float(Double(Float(Double(Float(hundredths)) / 100.0)) - 0.001), 0.01)
        thickSlabThinEnd = Double(dcmIntervalMin)
        dcmIntervalMax = Self.slabVolumeMaximum(of: pixList)
    }''',
    'slabWithinEnds': '{ let slab = Float(thickness); '
                      'return dcmIntervalMax > dcmIntervalMin ? min(max(slab, dcmIntervalMin), dcmIntervalMax) : slab }',
    'thickSlabSliderScale': '{ ThickSlabSliderScale(minimum: Double(dcmIntervalMin), maximum: Double(dcmIntervalMax), '
                            'exponential: preferenceStore[ReconstructionPreferences.logarithmicThickSlabSlider]) }',
    'slabSliderPosition': '{ get { thickSlabSliderScale.position(for: Double(getClippingRangeThicknessInMm())) } '
                          'set { setClippingRangeThicknessInMm(Float(thickSlabSliderScale.thickness(at: newValue))) } }',
    'slabFieldThickness': '{ get { Double(getClippingRangeThicknessInMm()) } set { setClippingRangeThicknessInMm(Float(newValue)) } }',
}
# -showWindow: restores the saved path through restoreCurvedPath(savedIn:)
# while it is still the opening; formerly it cleared and loaded the path itself.
show_window = block(controller, 'override dynamic func showWindow(')
PIECES['restoreCurvedPath'] = block(controller, 'private func restoreCurvedPath(')
check(revision or bool(PIECES['restoreCurvedPath']), 'CPRController.swift: no restoreCurvedPath')
restored = show_window.find('self.restoreCurvedPath(savedIn: savedCurvedPathFile())')
check(revision or 0 <= restored < show_window.find('self.isInitializing = false'),
      '-showWindow: does not restore the saved path through restoreCurvedPath(savedIn:) before the opening ends')
check(revision or 'loadBezierPathFromFile' not in show_window, '-showWindow: loads the saved path itself')
# The file's slab is kept within the slider's ends, which -showWindow: sets,
# through the opening the MPR shares, before it restores the path; the
# stand-in's show() does likewise.
opened = show_window.rfind('self.openSlab(of: pixListStorage[0].object as? [DCMPix] ?? [])')
check(revision or 0 <= opened < restored,
      "-showWindow: restores the saved path before it sets the slider's ends, which keep the file's slab within them")
check(revision or 'slabWithinEnds(Double(newCurvedPath.thickness))' in PIECES['showLoadedPath'],
      "a loaded path's slab is not kept within the window's exact ends")

# The 16-bit export, of the image shown and of each step of a rotation, asks
# the generator for the slab and the projection of the curved view: without
# them it was the curve's one plane at any thickness.
shown_slab = block(controller, 'func setShownSlab(')
for line in ('request?.slabWidth = self._curvedPath?.thickness ?? 0', 'request?.slabSampleDistance = 0',
             'straightened?.projectionMode = CPRProjectionMode(self._clippingRangeMode)',
             'stretched?.projectionMode = CPRProjectionMode(self._clippingRangeMode)'):
    check(revision or line in shown_slab, f'the 16-bit export does not set: {line}')
export = controller[controller.find('dicomExport?.rotateRawDataBy90degrees = false'):controller.find('CPRSlabExportSeriesType.rawValue) {\n                    let progress')]
for kind, made in (('straightened', 'requestStraightened = CPRStraightenedGeneratorRequest()'),
                   ('stretched', 'requestStretched = CPRStretchedGeneratorRequest()')):
    requests = export.split(made)[1:]
    check(revision or len(requests) == 2, f'the 16-bit export makes {len(requests)} {kind} requests for the image shown and the rotation, not 2')
    for request in requests:
        asked = request.find('CPRGenerator.synchronousRequestVolume(')
        slab = request.find(f'setShownSlab({kind}: request{kind.capitalize()})')
        check(revision or 0 <= slab and (asked < 0 or slab < asked), f'a {kind} request of the 16-bit export has no slab or projection')

# The frames of the Slab series are the planes the generator makes at the
# export's interval: one fewer was counted where the width is a whole number
# of intervals, and the last plane was not written.
frames = block(controller, 'public dynamic var exportSequenceNumberOfFrames: Int')
check(revision or 'return CurvedSlabSampling.planes(width: Double(slabWidth), step: Double(sliceInterval))' in frames,
      'the frames of the Slab series are not the planes the generator makes')
for name in ('CPRStraightenedOperation', 'CPRStretchedOperation'):
    operation = code(source(f'Horos/Sources/{name}.swift').decode('utf-8'))
    planes = block(operation, 'private func slabPlanes(')
    check(revision or ('CurvedSlabSampling.planes(width: Double(request?.slabWidth ?? 0), spacing: Double(volumeData?.minPixelSpacing ?? 0)' in planes
                       and 'fixedDistance: Double(request?.slabSampleDistance ?? 0))' in planes),
          f'{name} does not sample its slab by CurvedSlabSampling')
    for function, value in (('_slabSampleDistance', 'CGFloat(slabPlanes().distance)'), ('_pixelsDeep', 'UInt(slabPlanes().count)')):
        check(revision or value in block(operation, f'private func {function}('), f'{name}: {function} is not the sampling rule\'s')
cleared = show_window.find('self.cprViewWillEditCurvedPath(mprView1)')
loaded = show_window.find('if let path = savedCurvedPathFile()')
if 0 <= cleared < loaded:
    FORMER['restoreCurvedPath'] = ('{\n' + show_window[cleared:show_window.index('}', loaded) + 1]
                                   .replace('savedCurvedPathFile()', 'file') + '\n}')

# The Path Assistant makes its path anew and hands it to -setCurvedPath:.
assisted = block(controller, 'func assistedCurvedPath(')
made = assisted.find('let newCP = CPRCurvedPath()')
installed = assisted.find('self.curvedPath = newCP')
check(0 <= made < installed, 'the Path Assistant does not hand its new path to -setCurvedPath:')
check('thickness' not in assisted, 'the Path Assistant sets a slab of its own')
# Nothing else replaces the window's path: the window's first path, made before
# -showWindow: sets the slab, and the copy -setCurvedPath: keeps.
replaced = re.findall(r'(?<![\w.])_curvedPath\s*=(?!=)[^\n]*', controller)
check(sorted(line.strip() for line in replaced)
      == ['_curvedPath = CPRCurvedPath()', '_curvedPath = newCurvedPath?.copy() as? CPRCurvedPath'],
      f'the window replaces its path without -setCurvedPath:: {replaced}')

with tempfile.TemporaryDirectory(prefix='horos-cpr-slab-path-') as tmp:
    tmp = Path(tmp)
    for path in HEADERS + [path for path, _ in OBJC_SOURCES] + SWIFT_SOURCES:
        (tmp / Path(path).name).write_bytes(source(path))
    for path in RULES:
        (tmp / Path(path).name).write_bytes((root / path).read_bytes())
    (tmp / 'harness.h').write_text(BRIDGING)
    driver = DRIVER
    for name, body in PIECES.items():
        driver = driver.replace(f'%({name})s', body or FORMER.get(name, '{ fatalError() }'))
    (tmp / 'main.swift').write_text(driver)
    (tmp / 'OperationStubs.swift').write_text(OPERATION_STUBS)
    files = tmp / 'files'
    files.mkdir()
    objects = []
    try:
        if N3_LIBRARIES:
            n3_geometry_harness.build(tmp / N3_LIBRARIES, 'debug', headers=tmp)
            objects += n3_geometry_harness.libraries(tmp / N3_LIBRARIES)
            # The constants CPRCurvedPath.h declares extern, which the slice reads.
            objects.append(former_sdk_objects.app(tmp / N3_LIBRARIES))
        for path, flags in OBJC_SOURCES:
            name = Path(path).name
            obj = tmp / (Path(path).stem + '.o')
            # The app's prefix header brings Cocoa into every source.
            run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-g', '-iquote', str(tmp),
                 *flags, '-c', str(tmp / name), '-o', str(obj)])
            objects.append(str(obj))
        run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-suppress-warnings', '-Onone',
             '-import-objc-header', str(tmp / 'harness.h'), '-Xcc', '-iquote', '-Xcc', str(tmp),
             *[str(tmp / Path(path).name) for path in SWIFT_SOURCES + RULES], str(tmp / 'OperationStubs.swift'),
             str(tmp / 'main.swift'), *objects,
             '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(tmp / 'harness')])
    except subprocess.CalledProcessError as e:
        failures.append('the harness did not build: ' + (e.stderr or b'').decode(errors='replace')[-2000:])
    except RuntimeError as e:
        failures.append('the N3 geometry did not build: ' + str(e)[-2000:])
    else:
        try:
            result = subprocess.run([str(tmp / 'harness'), str(files)], capture_output=True, text=True, timeout=300)
            for line in result.stdout.splitlines():
                if line.startswith('FAIL: '):
                    failures.append(line[len('FAIL: '):])
            if result.returncode != 0 and not any(line.startswith('FAIL: ') for line in result.stdout.splitlines()):
                failures.append('the harness failed: ' + (result.stderr or result.stdout)[-800:])
        except subprocess.TimeoutExpired:
            failures.append('the harness timed out')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the Curved MPR draws the slab its window shows after the Path Assistant, an undo or a redo, '
      'a reopened or loaded path, an imported centerline and a path a view installs; a reopened window '
      'keeps its slab within the slider and has nothing to undo, and a Reset that changed the path can be undone; '
      'the window opens at its exact thin end, with the slab in the curved view at any thickness, what is typed stays '
      'within the ends, and the field, the knob and the bubble say one number; '
      'a click that adds or drags a node leaves one undo entry, and a press leaves the cameras only when it moved them '
      'as the planes show')
