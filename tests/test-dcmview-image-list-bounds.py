#!/usr/bin/env python3
"""-[DCMView setIndex:] reads each list of the series within that list's own length.

A view is given three lists, one after the other: the pixels, the files and
the ROI lists. The index is clamped to the pixels, and the other two were read
at that index as if they had as many entries. They need not: a file with
several frames may be listed once, a caller may give no file at all, and the
ROI lists are an array the viewer hands to plugins, which may set another or
change it in place. Reading an NSArray past its end raises, and the exception
left the image half shown: the textures of the former image, no notification,
no tiles.

The checks compile -setIndex:, -setIndexWithReset:: and the helpers they call
from Horos/Sources/DCMView+ImageList.swift, with the real guard of
HorosObjCException and the rule of IsiXImaging's SeriesDisplay, over a view of
the members they use, and show an image:
- lists of the same length: the image, its own ROI list (the same object), its
  ROIs recomputed, the age of its file's study;
- a ROI list shorter than the pixels: the image past its end is shown with an
  empty list of its own, and the body runs to its end;
- no file, and one file for all the pixels: the image is shown, the age is
  that of the first file's study when there is one;
- an index past the pixels: the last image;
- -setIndexWithReset:: with a ROI list shorter than the pixels, and with a
  list of no pixels, which clears the view as -setIndex: does.
In none of them an exception reaches the guard.

One more: an observer of the notification of the change raises. The guard
logs it, the image is the view's, and the view is marked for display. The mark
was inside the guard, after the notification: an exception there left the
former picture on screen while the index went on.

The sources are those of the working tree, or of the revision given as the
first argument.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import objc_exception_guards  # noqa: E402

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def text(path):
    if revision is None:
        return (root / path).read_text()
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')


def method(source, signature, required=True):
    """The method of the extension that `signature` opens, to its closing brace."""
    start = source.find(signature)
    if start < 0:
        if required:
            print(f'FAIL: DCMView+ImageList.swift has no `{signature.strip()}`', file=sys.stderr)
            raise SystemExit(1)
        return ''
    return source[start:source.index('\n    }\n', start) + len('\n    }\n')]


image_list = text('Horos/Sources/DCMView+ImageList.swift')
methods = '\n'.join([
    method(image_list, '    @objc(setIndexWithReset::)'),
    method(image_list, '    @objc(setIndex:)'),
    method(image_list, '    private func applyWindowLevelOfImage()'),
    method(image_list, '    private func mouseMovedEvent('),
    method(image_list, '    private func listedROIs()', required=False),
    method(image_list, '    private func listedPix(', required=False),
    method(image_list, '    private func updateYearOld()'),
])
guard = 'HorosObjCException.' + ('caught' if 'HorosObjCException.caught {' in methods else 'caughtWithoutAllocation')

HARNESS = r'''
import AppKit

let ROI_sleep = 0
var logged: [String] = []

@MainActor func inputLogException(_ exception: NSException?, _ function: String) {
    if let exception { logged.append("\(function): \(exception.name.rawValue): \(exception.reason ?? "")") }
}

final class ROI: NSObject {
    weak var curView: DCMView?
    var recomputed = 0
    var roImode = 0
    func recompute() { recomputed += 1 }
}
final class DicomStudy: NSObject {
    let age: String
    init(age: String) { self.age = age }
    func yearOld() -> String? { age }
    func yearOldAcquisition() -> String? { age }
}
final class DicomSeries: NSObject {
    var study: DicomStudy?
    init(study: DicomStudy) { self.study = study }
}
final class DicomImage: NSObject {
    var series: DicomSeries?
    init(age: String) { self.series = DicomSeries(study: DicomStudy(age: age)) }
    func completePath() -> String? { "/series/image.dcm" }
}
final class DCMPix: NSObject {
    var wl: Float = 40, ww: Float = 400
    var suvConverted = false
    var loads = 0
    func checkLoad() { loads += 1 }
    func checkImageAvailble(_ ww: Float, _ wl: Float) {}
    func updateToApply() -> Bool { false }
}
struct WindowLevelState {
    var width: Float = 400, level: Float = 40
    mutating func mirror(level: Float, width: Float, suvConverted: Bool, _ factor: () -> Float) { (self.level, self.width) = (level, width) }
}
struct Viewport { var origin = NSPoint.zero; var scale: CGFloat = 1 }
struct StackNavigation { var current = -1 }
final class ViewerMessages { func viewerFactorPET2SUV() -> Float { 1 } }
func viewerMessages(_ controller: Any?) -> ViewerMessages? { nil }
enum ViewerThickSlab { @MainActor static func imageChanged(in view: DCMView) {} }
extension Notification.Name { static let OsirixDCMViewIndexChanged = Notification.Name("OsirixDCMViewIndexChanged") }

/// The members of the view the methods use.
class DCMView: NSView {
    var horos_dcmPixList: NSMutableArray?
    var horos_dcmFilesList: NSArray?
    var horos_dcmRoiList: NSMutableArray?
    var horos_curRoiList: NSMutableArray!
    var horos_curROI: ROI?
    var curDCM: DCMPix!
    var stackNavigation = StackNavigation()
    var horos_curImage: Int { stackNavigation.current }
    var windowLevelState = WindowLevelState()
    var viewport = Viewport()
    var horos_noScale = false
    var horos_COPYSETTINGSINSERIES = false
    var yearOld: String?
    var textures = 0, tilings = 0, moves = 0, displays = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { displays += 1 }; super.needsDisplay = newValue }
    }

    func stopROIEditing() {}
    func is2DViewer() -> Bool { false }
    func windowController() -> Any? { nil }
    func updatePresentationStateFromSeries() {}
    func updatePresentationState(fromSeriesOnlyImageLevel: Bool) {}
    func scaleToFit() {}
    func loadTextures() { textures += 1 }
    func reapplyWindowLevel() {}
    func updateTilingViews() { tilings += 1 }
    @objc(mouseMoved:) override func mouseMoved(with event: NSEvent) { moves += 1 }
}

extension DCMView {
METHODS
}

func check(_ condition: Bool, _ what: String) {
    if !condition {
        FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!)
        exit(1)
    }
}

@MainActor func view(pixels: Int, files: [DicomImage]?, rois: Int?) -> DCMView {
    let view = DCMView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    view.horos_dcmPixList = NSMutableArray(array: (0..<pixels).map { _ in DCMPix() })
    view.horos_dcmFilesList = files.map { NSArray(array: $0) }
    view.horos_dcmRoiList = rois.map { count in NSMutableArray(array: (0..<count).map { _ in NSMutableArray(object: ROI()) }) }
    return view
}

@MainActor func pix(_ view: DCMView, _ index: Int) -> DCMPix? { view.horos_dcmPixList?.object(at: index) as? DCMPix }

/// The body ran to its end: the tiles are told last.
@MainActor func shown(_ view: DCMView, _ index: Int, _ what: String) {
    check(logged.isEmpty, "\(what): an exception reached the guard: \(logged)")
    check(view.horos_curImage == index && view.curDCM === pix(view, index), "\(what): image \(view.horos_curImage) is shown, not \(index)")
    check(view.curDCM.loads == 1 && view.textures == 1 && view.tilings == 1 && view.moves == 1, "\(what): the image was not shown to the end")
}

// Lists of the same length.
var each = view(pixels: 3, files: [DicomImage(age: "30 y"), DicomImage(age: "31 y"), DicomImage(age: "32 y")], rois: 3)
each.setIndex(1)
shown(each, 1, "three pixels, files and ROI lists")
check(each.horos_curRoiList === (each.horos_dcmRoiList?.object(at: 1) as AnyObject), "the image's ROI list is not the series' own")
check((each.horos_curRoiList.firstObject as? ROI)?.recomputed == 1, "the image's ROIs were not recomputed")
check(each.yearOld?.contains("31 y") == true, "the age is not that of the image's file: \(each.yearOld ?? "nil")")

// An index past the pixels is the last image.
each = view(pixels: 3, files: [DicomImage(age: "30 y"), DicomImage(age: "31 y"), DicomImage(age: "32 y")], rois: 3)
each.setIndex(99)
shown(each, 2, "an index past the pixels")

// A ROI list shorter than the pixels.
var short = view(pixels: 3, files: [DicomImage(age: "30 y"), DicomImage(age: "31 y"), DicomImage(age: "32 y")], rois: 1)
short.setIndex(2)
shown(short, 2, "a ROI list of one entry for three pixels")
check(short.horos_curRoiList != nil && short.horos_curRoiList.count == 0, "an image past the end of the ROI list has ROIs")
check(short.horos_curRoiList !== (short.horos_dcmRoiList?.object(at: 0) as AnyObject), "an image past the end of the ROI list took another image's list")
short = view(pixels: 3, files: nil, rois: 0)
short.setIndex(0)
shown(short, 0, "a ROI list of no entry")

// No file, and one file for all the pixels.
var files = view(pixels: 3, files: [], rois: nil)
files.setIndex(1)
shown(files, 1, "a list of no file")
check(files.horos_noScale == false, "a list of no file reads as the empty placeholder")
files = view(pixels: 3, files: [DicomImage(age: "44 y")], rois: nil)
files.setIndex(2)
shown(files, 2, "one file for three pixels")
check(files.yearOld?.contains("44 y") == true, "the age is not that of the only file's study: \(files.yearOld ?? "nil")")

// -setIndexWithReset:: has no guard of its own: one here says what it raised.
@MainActor func reset(_ view: DCMView, _ index: Int, _ what: String) {
    let raised = HorosObjCException.caught { view.setIndexWithReset(index, true) }
    check(raised == nil, "\(what): -setIndexWithReset:: raised \(raised?.name.rawValue ?? ""): \(raised?.reason ?? "")")
}
short = view(pixels: 3, files: [DicomImage(age: "30 y")], rois: 1)
reset(short, 2, "a ROI list of one entry for three pixels")
check(short.horos_curImage == 2 && short.curDCM === pix(short, 2) && short.horos_curRoiList.count == 0 && short.textures == 1,
      "-setIndexWithReset:: did not show the image past the end of the ROI list")
let empty = view(pixels: 0, files: nil, rois: nil)
reset(empty, 0, "a list of no pixels")
check(empty.curDCM == nil && empty.horos_curImage == -1 && empty.horos_curRoiList == nil, "a list of no pixels does not clear the view")
empty.setIndex(0)
check(logged.isEmpty && empty.curDCM == nil && empty.horos_curImage == -1, "-setIndex: on a list of no pixels: \(logged)")

// An entry of the pixel list that is not an image: no image is shown, as with
// no list, and the rest of the change of image runs.
let foreign = view(pixels: 3, files: nil, rois: 3)
foreign.horos_dcmPixList?.replaceObject(at: 1, with: NSString(string: "not an image"))
foreign.setIndex(1)
check(logged.isEmpty && foreign.curDCM == nil && foreign.horos_curImage == -1 && foreign.horos_curRoiList == nil,
      "-setIndex: on an entry that is not an image does not clear the view: \(logged)")
check(foreign.textures == 1 && foreign.tilings == 1, "-setIndex: on an entry that is not an image did not run to its end")
reset(foreign, 1, "an entry that is not an image")
check(foreign.curDCM == nil && foreign.horos_curImage == -1, "-setIndexWithReset:: on an entry that is not an image does not clear the view")
foreign.setIndex(2)
check(logged.isEmpty && foreign.horos_curImage == 2 && foreign.curDCM === pix(foreign, 2), "the image after an entry that is not one is not shown")

// What the change of image calls raises, here an observer of its notification: the guard logs it, and the view is
// marked for display all the same. It was marked inside the guard, after the notification: the view went on showing
// the former image, every image a player stepped to, until something else displayed it.
let raising = view(pixels: 3, files: nil, rois: 3)
let observer = NotificationCenter.default.addObserver(forName: .OsirixDCMViewIndexChanged, object: raising, queue: nil) { _ in
    NSException(name: .rangeException, reason: "an observer raises", userInfo: nil).raise()
}
raising.setIndex(1)
NotificationCenter.default.removeObserver(observer)
check(logged.count == 1 && logged[0].contains("an observer raises"), "the exception of an observer did not reach the guard: \(logged)")
check(raising.horos_curImage == 1 && raising.curDCM === pix(raising, 1), "the image whose notification raised is not the view's")
check(raising.displays == 1, "the view is not marked for display when what the change of image calls raises: \(raising.displays)")
logged.removeAll()

print("PASS: -setIndex: and -setIndexWithReset:: read the files and the ROI lists within their own length, show no image for an entry that is not one, and mark the view for display when what the change of image calls raises")
'''

with tempfile.TemporaryDirectory(prefix='horos-image-list-bounds-') as name:
    directory = Path(name)
    (directory / 'main.swift').write_text(HARNESS.replace('METHODS', methods))
    (directory / 'guards.swift').write_text(objc_exception_guards.source(text(objc_exception_guards.PATH), log=False))
    (directory / 'SeriesDisplay.swift').write_text(text('Modules/IsiXImaging/Sources/ViewSeries/SeriesDisplay.swift'))
    for file in ('HorosObjCException.h', 'HorosObjCException.m'):
        (directory / file).write_text(text('Horos/Sources/' + file))
    (directory / 'bridge.h').write_text('#import "HorosObjCException.h"\n')
    subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-I', str(directory), str(directory / 'HorosObjCException.m'),
                    '-o', str(directory / 'exception.o')], check=True)
    for level in ('-Onone', '-O'):
        binary = directory / f'harness{level}'
        built = subprocess.run(['xcrun', 'swiftc', level, '-swift-version', '6', '-module-name', 'ImageListBounds',
                                '-import-objc-header', str(directory / 'bridge.h'), str(directory / 'main.swift'),
                                str(directory / 'guards.swift'), str(directory / 'SeriesDisplay.swift'),
                                str(directory / 'exception.o'), '-o', str(binary)], capture_output=True, text=True)
        if built.returncode != 0:
            print(f'FAIL: the methods of DCMView+ImageList.swift do not compile at {level} ({guard}):\n{built.stderr[-6000:]}', file=sys.stderr)
            raise SystemExit(1)
        done = subprocess.run([str(binary)], capture_output=True, text=True, timeout=120)
        if done.returncode != 0:
            reason = (done.stderr.strip().splitlines() or ['no message'])[-1]
            print(f'FAIL: at {level}, the process ended with {done.returncode}: {reason}', file=sys.stderr)
            raise SystemExit(1)
        print(level, done.stdout.strip())
