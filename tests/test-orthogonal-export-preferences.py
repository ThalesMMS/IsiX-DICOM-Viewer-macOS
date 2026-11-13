#!/usr/bin/env python3
"""A DICOM export of the orthogonal viewers leaves the stored preferences as they were.

To capture its image the export of the orthogonal MPR and of the orthogonal
PET-CT draws the graphics only, without the text of the annotations, and
hides the colour bars. Neither is a choice of the user. The export once stored
both and put them back at the end of the method: a level that was only the
factory's became the user's, a capture that raised left "Graphic" and no bars
as the user's preferences, an application that ended in the middle kept them,
and every view of the application, the other viewers' included, changed its
annotations and came back for each image written.

-exportDICOMFileInt: of OrthogonalMPRViewer and -exportDICOMFileInt:view: of
OrthogonalMPRPETCTViewer are taken as they stand, with CaptureAnnotations.swift,
and compiled against the real IsiXPreferences and HorosObjCException around
controlled views, whose annotations follow the preference as those of DCMView
do: told by the defaults of a change. For an image written, a capture that
gives nothing, a file that cannot be written and a capture that raises, of one
view or of all the views, the stored preferences and what the launch gave are
afterwards exactly what they were, kept by the user or only the factory's,
also while the capture draws. Meanwhile the views of the export draw the
graphics without bars, the bars being hidden for the process only and the
level of annotations left as the user's wherever the preference is read, so
that the views of another viewer never change nor are drawn again; afterwards
the views of the export are as before, also when the capture raised, and the
exception reaches the caller. The capture of the endoscopy's planes, which
keeps the user's bars, goes through the same type.

The text of these captures and of the web portal's, which turns smart cropping
off for the process only, stores none of the three preferences.
--mpr-source and --petct-source take a Swift source of each viewer, to prove
the regression against an earlier one.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults
import isix_modules
import objc_exception_guards
from sources import source_path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--mpr-source', type=Path, default=source_path('OrthogonalMPRViewer'))
parser.add_argument('--petct-source', type=Path, default=source_path('OrthogonalMPRPETCTViewer'))
args = parser.parse_args()


def export_of(path, start):
    """The export of one image, up to the action of the export sheet."""
    text = path.read_text(encoding='utf-8')
    begin = text.index(start)
    return text[begin:text.index('    @IBAction @objc(endExportDICOMFileSettings:)', begin)]


mpr = export_of(args.mpr_source, '    @objc(exportDICOMFileInt:)\n')
petct = export_of(args.petct_source, '    @objc(exportDICOMFileInt:view:)\n')
# The annotations of a capture, when the exports have them in a type of their own.
capture = ROOT / 'Horos/Sources/CaptureAnnotations.swift'

DRIVER = harness_defaults.DOMAINS + r'''
import AppKit
import IsiXPreferences
import ObjectiveC

let annotNone = 0, annotGraphics = 1, annotBase = 2, annotFull = 3
let barHide = 0, barOrigin = 1, barFused = 2, barBoth = 3
nonisolated(unsafe) var CLUTBARS: Int32 = 0

// The application's defaults are a domain of this test only.
let suite = harnessDomainName("orthogonal-export-preferences-\(getpid())")
let controlled = UserDefaults(suiteName: suite)!
extension UserDefaults { @objc class func controlled_standardUserDefaults() -> UserDefaults { controlled } }
method_exchangeImplementations(class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!,
                               class_getClassMethod(UserDefaults.self, #selector(UserDefaults.controlled_standardUserDefaults))!)
func stored() -> NSDictionary { (controlled.persistentDomain(forName: suite) ?? [:]) as NSDictionary }

enum Outcome: String, CaseIterable { case written = "written", nothing = "nothing captured", unwritten = "file not written", raised = "capture raises" }

/// What a view of the export saw of the application while it was captured.
struct Seen {
    var levels: [Int32], bars: Int32, readLevel: Int, readBars: Int, storedAsBefore: Bool, others: [Int32]
}
nonisolated(unsafe) var outcome = Outcome.written
nonisolated(unsafe) var seen: [Seen] = []
nonisolated(unsafe) var before = NSDictionary()
nonisolated(unsafe) var others: [DCMView] = []
nonisolated(unsafe) var alerts = 0

final class DCMPix {
    var sliceThickness = 1.5, sliceLocation = 12.0
    var slope: Float = 1
    func appliedFactorPET2SUV() -> Float { 1 }
}

/// A view whose annotations follow the preference as DCMView's do: read when
/// it is made, then told by the defaults each time the preference is stored.
class DCMView: NSView {
    var curDCM: DCMPix? = DCMPix()
    var blending: DCMView?
    var blendingFactor: Float = 0
    var curImage: Int16 = 0
    var annotationType: Int32 = 0
    var invalidations = 0
    override var needsDisplay: Bool { didSet { invalidations += 1 } }
    override var visibleRect: NSRect { NSMakeRect(0, 0, 16, 16) }

    init() {
        super.init(frame: NSMakeRect(0, 0, 16, 16))
        annotationType = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "ANNOTATIONS"))
        UserDefaults.standard.addObserver(self, forKeyPath: "ANNOTATIONS", options: .new, context: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    func retire() { UserDefaults.standard.removeObserver(self, forKeyPath: "ANNOTATIONS") }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        let level = Int32(truncatingIfNeeded: controlled[ViewerPreferences.annotations])
        if keyPath == "ANNOTATIONS" && level != annotationType {
            annotationType = level
            needsDisplay = true
        }
    }

    /// The display preferences every view draws with.
    static func setDefaults() { CLUTBARS = Int32(truncatingIfNeeded: controlled[ViewerPreferences.clutBars]) }

    func getWLWW(_ level: UnsafeMutablePointer<Float>, _ width: UnsafeMutablePointer<Float>) { level.pointee = 40; width.pointee = 400 }
    func orientationCorrected(toView orientation: UnsafeMutablePointer<Float>) {}

    private func captured(_ views: [DCMView], _ width: UnsafeMutablePointer<Int>, _ height: UnsafeMutablePointer<Int>,
                          _ spp: UnsafeMutablePointer<Int>, _ bpp: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<UInt8>? {
        seen.append(Seen(levels: views.map(\.annotationType), bars: CLUTBARS,
                         readLevel: UserDefaults.standard.integer(forKey: "ANNOTATIONS"), readBars: UserDefaults.standard.integer(forKey: "CLUTBARS"),
                         storedAsBefore: stored().isEqual(before), others: others.map(\.annotationType)))
        switch outcome {
        case .nothing:
            return nil
        case .raised:
            NSException(name: .rangeException, reason: "the capture raises", userInfo: nil).raise()
            return nil
        case .written, .unwritten:
            width.pointee = 2; height.pointee = 2; spp.pointee = 1; bpp.pointee = 8
            return calloc(4, 1)?.assumingMemoryBound(to: UInt8.self)
        }
    }

    func getRawPixelsWidth(_ width: UnsafeMutablePointer<Int>, height: UnsafeMutablePointer<Int>, spp: UnsafeMutablePointer<Int>,
                           bpp: UnsafeMutablePointer<Int>, screenCapture: Bool, force8bits: Bool, removeGraphical: Bool, squarePixels: Bool,
                           allTiles: Bool, allowSmartCropping: Bool, origin: UnsafeMutablePointer<Float>, spacing: UnsafeMutablePointer<Float>,
                           offset: UnsafeMutablePointer<Int32>, isSigned: UnsafeMutablePointer<ObjCBool>,
                           views: [Any]? = nil, viewsRect: [Any]? = nil) -> UnsafeMutablePointer<UInt8>? {
        captured(views.map { $0.compactMap { $0 as? DCMView } } ?? [self], width, height, spp, bpp)
    }

    func getRawPixelsViewWidth(_ width: UnsafeMutablePointer<Int>, height: UnsafeMutablePointer<Int>, spp: UnsafeMutablePointer<Int>,
                               bpp: UnsafeMutablePointer<Int>, screenCapture: Bool, force8bits: Bool, removeGraphical: Bool, squarePixels: Bool,
                               allowSmartCropping: Bool, origin: UnsafeMutablePointer<Float>, spacing: UnsafeMutablePointer<Float>,
                               offset: UnsafeMutablePointer<Int32>, isSigned: UnsafeMutablePointer<ObjCBool>) -> UnsafeMutablePointer<UInt8>? {
        captured([self], width, height, spp, bpp)
    }
}

final class OrthogonalMPRView: DCMView {
    weak var owner: OrthogonalMPRController?
    func controller() -> OrthogonalMPRController? { owner }
}

class OrthogonalMPRController {
    let planes = [OrthogonalMPRView(), OrthogonalMPRView(), OrthogonalMPRView()]
    init() { for plane in planes { plane.owner = self } }
    func originalView() -> OrthogonalMPRView? { planes[0] }
    func xReslicedView() -> OrthogonalMPRView? { planes[1] }
    func yReslicedView() -> OrthogonalMPRView? { planes[2] }
    func originalDCMFilesList() -> NSMutableArray? { [["completePath": "/source.dcm", "series": ["modality": "CT"]] as NSDictionary] }
    func firtsDCMPixInOriginalDCMPixList() -> DCMPix? { DCMPix() }
}
final class OrthogonalMPRPETCTController: OrthogonalMPRController {}

final class ViewerController {
    func modality() -> String? { "CT" }
    func imageView() -> DCMView? { nil }
}

final class DICOMExport {
    func setSourceFile(_ path: String?) {}
    func setSeriesDescription(_ description: String?) {}
    func setSlope(_ slope: Float) {}
    func setDefaultWWWL(_ width: Int, _ level: Int) {}
    func setPixelSpacing(_ x: Float, _ y: Float) {}
    func setSliceThickness(_ thickness: Double) {}
    func setSlicePosition(_ position: Float) {}
    func setOrientation(_ orientation: UnsafeMutablePointer<Float>) {}
    func setPosition(_ position: UnsafeMutablePointer<Float>) {}
    func setPixelData(_ data: UnsafeMutablePointer<UInt8>, samplesPerPixel: Int32, bitsPerSample: Int32, width: Int, height: Int) -> Int { 0 }
    func setSigned(_ signed: Bool) {}
    func setOffset(_ offset: Int32) {}
    func setModalityAsSource(_ source: Bool) {}
    func writeDCMFile(_ path: String?) -> String? { outcome == .unwritten ? nil : "/exported.dcm" }
}

enum HorosAlertPanel {
    static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) { alerts += 1 }
}

// The fused frame of the PET-CT export: its views blend nothing here.
final class FusionLayer {}
final class OrthogonalFusionSlice {
    var width = 0, height = 0, sliceThickness = 0.0, sliceLocation = 0.0
    var origin: [NSNumber] = [], spacing: [NSNumber] = [], orientation: [NSNumber] = []
    var pixelRGB = Data()
}
func HorosFusionLayerFromView(_ view: DCMView?) -> FusionLayer? { nil }
func HorosPETFusionLUT() -> Data { Data() }
enum OrthogonalFusionSliceExport {
    static func slice(fromPrimary: FusionLayer, secondary: FusionLayer?, lut: Data, blendingFactor: Double, instanceNumber: Int) -> OrthogonalFusionSlice? { nil }
}

func addObject(_ array: NSMutableArray?, _ object: Any?) { if let object { array?.add(object) } }
func cLong(_ value: Double) -> Int { Int(value) }

@MainActor final class OrthogonalMPRViewer: NSObject {
    let preferenceStore: any PreferenceStore = controlled
    let controller: OrthogonalMPRController? = OrthogonalMPRController()
    var exportDCM: DICOMExport?
    var dcmSeriesName: NSTextField?
    var window: NSWindow?
    var viewerIvar: ViewerController? = ViewerController()
    func keyView() -> DCMView? { controller?.originalView() }
    var views: [DCMView] { controller?.planes ?? [] }
    func export() -> NSDictionary? { exportDICOMFileInt(true) }

<THE EXPORT OF THE MPR>
}

@MainActor final class OrthogonalMPRPETCTViewer: NSObject {
    let preferenceStore: any PreferenceStore = controlled
    let CTController: OrthogonalMPRPETCTController? = OrthogonalMPRPETCTController()
    let PETCTController: OrthogonalMPRPETCTController? = OrthogonalMPRPETCTController()
    let PETController: OrthogonalMPRPETCTController? = OrthogonalMPRPETCTController()
    var exportDCM: DICOMExport?
    var dcmSeriesName: NSTextField?
    var window: NSWindow?
    func keyView() -> DCMView? { CTController?.originalView() }
    var views: [DCMView] { [CTController, PETCTController, PETController].flatMap { $0?.planes ?? [] } }
    func export() -> NSDictionary? { exportDICOMFileInt(true, view: PETController?.xReslicedView()) }

<THE EXPORT OF THE PET-CT>
}

// Every case runs: a failure is counted under what it says before its case.
var failures: [String: (count: Int, first: String)] = [:]
func check(_ condition: Bool, _ what: String) {
    if condition { return }
    let name = what.components(separatedBy: ": ").first ?? what
    failures[name] = ((failures[name]?.count ?? 0) + 1, failures[name]?.first ?? what)
}
check(UserDefaults.standard === controlled, "the controlled defaults stand for the application's")

let keys = ["ANNOTATIONS", "CLUTBARS"]
let launchArguments = controlled.volatileDomain(forName: UserDefaults.argumentDomain)
controlled.set(4096, forKey: "MAXWindowSize")
check(stored()["MAXWindowSize"] != nil, "the stored domain of the test is read back")

var cases = 0
MainActor.assumeIsolated {
for viewerName in ["orthogonal MPR", "orthogonal PET-CT"] {
// The two values stored by the user, or only the factory's; a level given at launch as well.
for (kept, launched) in [(true, false), (false, false), (true, true), (false, true)] {
    for (level, bars) in [(annotBase, barHide), (annotFull, barBoth), (annotNone, barOrigin), (annotGraphics, barHide)] {
    for allViews in [false, true] { for result in Outcome.allCases {
        if kept {
            controlled.set(level, forKey: "ANNOTATIONS"); controlled.set(bars, forKey: "CLUTBARS")
        } else {
            for key in keys { controlled.removeObject(forKey: key) }
            controlled.register(defaults: ["ANNOTATIONS": "\(level)", "CLUTBARS": "\(bars)"])
        }
        controlled.set(allViews, forKey: ReconstructionPreferences.exportIncludesAllViews.name)
        var arguments = launchArguments
        if launched { arguments["ANNOTATIONS"] = "\(annotFull)" }
        controlled.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let shown = Int32(launched ? annotFull : level)
        DCMView.setDefaults()
        before = stored()
        let what = "\(viewerName), \(result.rawValue), all views \(allViews), stored \(kept), level given at launch \(launched), level \(level), bars \(bars)"
        check(keys.allSatisfy { (before[$0] != nil) == kept }, "the case is set up: " + what)
        outcome = result; seen = []; alerts = 0

        // A viewer that is not the one exporting: its views are not the export's.
        others = [DCMView(), DCMView()]
        var views: [DCMView] = []
        var file: NSDictionary?
        var export: () -> NSDictionary? = { nil }
        if viewerName == "orthogonal MPR" {
            let viewer = OrthogonalMPRViewer()
            views = viewer.views
            export = { viewer.export() }
        } else {
            let viewer = OrthogonalMPRPETCTViewer()
            views = viewer.views
            export = { viewer.export() }
        }
        check(views.allSatisfy { $0.annotationType == shown } && CLUTBARS == Int32(bars), "the views start with the user's annotations and bars: " + what)
        for view in others { view.invalidations = 0 }

        let raised = HorosObjCException.caught { file = export() }

        check((raised != nil) == (result == .raised) && (file?["file"] as? String == "/exported.dcm") == (result == .written)
              && alerts == (result == .unwritten ? 1 : 0), "the export ends as the case says: raised \(raised != nil), file \(file != nil), alerts \(alerts): " + what)

        // While it works, the views of the export draw the graphics alone, without bars.
        check(seen.count == 1, "one capture is made: \(seen.count): " + what)
        if let seen = seen.first {
            check(seen.levels.count == (allViews ? views.count : 1) && seen.levels.allSatisfy { $0 == Int32(annotGraphics) } && seen.bars == Int32(barHide),
                  "the captured views draw the graphics only and no bars: levels \(seen.levels), bars \(seen.bars): " + what)
            // The bars are a setting of the process meanwhile; the level is the views' own, and the user's stays where it is read.
            check(seen.readBars == barHide && seen.readLevel == Int(shown),
                  "a reader of the preferences reads no bars and the user's level meanwhile: \(seen.readBars), \(seen.readLevel): " + what)
            check(seen.storedAsBefore, "nothing is stored while the capture draws: " + what)
            check(seen.others.allSatisfy { $0 == shown }, "the views of another viewer keep their annotations meanwhile: \(seen.others): " + what)
        }

        // Afterwards everything is as before, and nothing was stored.
        check(views.allSatisfy { $0.annotationType == shown } && CLUTBARS == Int32(bars),
              "the views of the export have the user's annotations and bars again: \(views.map(\.annotationType)), bars \(CLUTBARS): " + what)
        check(others.allSatisfy { $0.annotationType == shown && $0.invalidations == 0 },
              "the views of another viewer were left alone: \(others.map(\.invalidations)): " + what)
        check(controlled.integer(forKey: "ANNOTATIONS") == Int(shown) && controlled.integer(forKey: "CLUTBARS") == bars, "the preferences read as before: " + what)
        check(stored().isEqual(before), "the stored preferences are what they were: " + what
              + " -> \((stored() as? [String: Any] ?? [:]).filter { keys.contains($0.key) })")
        check((controlled.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary).isEqual(arguments),
              "what the launch gave is what it was: " + what)
        for view in views + others { view.retire() }
        cases += 1
    } } }
}
}

// The capture of the endoscopy's planes keeps the user's bars: only the level of its views changes.
for kept in [true, false] {
    if kept {
        controlled.set(annotFull, forKey: "ANNOTATIONS"); controlled.set(barBoth, forKey: "CLUTBARS")
    } else {
        for key in keys { controlled.removeObject(forKey: key) }
        controlled.register(defaults: ["ANNOTATIONS": "\(annotFull)", "CLUTBARS": "\(barBoth)"])
    }
    DCMView.setDefaults()
    before = stored()
    let planes = OrthogonalMPRController().planes, other = DCMView()
    var levels: [Int32] = [], meanwhile = NSDictionary()
    var bars: Int32 = -1
    CaptureAnnotations.during(planes + [nil], hidesBars: false) {
        levels = planes.map(\.annotationType) + [other.annotationType]
        bars = CLUTBARS
        meanwhile = stored()
    }
    let what = "the planes of the endoscopy, stored \(kept)"
    check(levels == [1, 1, 1, 3] && bars == Int32(barBoth), "the planes alone draw the graphics only, with the user's bars: \(levels), bars \(bars): " + what)
    check(planes.allSatisfy { $0.annotationType == Int32(annotFull) } && other.invalidations == 0 && CLUTBARS == Int32(barBoth),
          "the planes have the user's annotations again: " + what)
    check(meanwhile.isEqual(before) && stored().isEqual(before), "the stored preferences are what they were: " + what)
    for view in planes + [other] { view.retire() }
    cases += 1
}
}
controlled.setVolatileDomain(launchArguments, forName: UserDefaults.argumentDomain)
controlled.removePersistentDomain(forName: suite)
if !failures.isEmpty {
    for (name, failure) in failures.sorted(by: { $0.key < $1.key }) { print("FAIL (\(failure.count) of \(cases) cases): \(name); first: \(failure.first)") }
    exit(1)
}
print("PASS: \(cases) captures (DICOM exports of the orthogonal MPR and PET-CT viewers: written, nothing captured, file not written, "
      + "capture raising, one view or all; the planes of the endoscopy) leave the stored preferences and the launch's as they were, kept by the user or not, and the other viewers' "
      + "views alone, while the capture draws the graphics without bars")
'''.replace('<THE EXPORT OF THE MPR>', mpr).replace('<THE EXPORT OF THE PET-CT>', petct)

with tempfile.TemporaryDirectory(prefix='horos-orthogonal-export-preferences-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    (work / 'guards.swift').write_text(objc_exception_guards.source(log=False))
    swift = [str(work / 'main.swift'), str(work / 'guards.swift')] + ([str(capture)] if capture.is_file() else [])
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=15.0', '-c', str(ROOT / 'Horos/Sources/HorosObjCException.m'),
                    '-o', str(work / 'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(ROOT / 'Horos/Sources/HorosObjCException.h'),
                    *swift, str(work / 'HorosObjCException.o'), *isix_modules.module_flags('IsiXPreferences', work / 'modules'),
                    '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True)

# No export or capture of these windows stores the level of annotations, the colour bars or smart cropping:
# the orthogonal viewers and the endoscopy capture inside CaptureAnnotations, the web portal with a preference of the process.
STORES = re.compile(r'\.set\([^\n]*for: ViewerPreferences\.(annotations|clutBars|allowSmartCropping)\b')
texts = {'OrthogonalMPRViewer': args.mpr_source.read_text(encoding='utf-8'), 'OrthogonalMPRPETCTViewer': args.petct_source.read_text(encoding='utf-8')}
for name in ('EndoscopyMPRView', 'EndoscopyViewer', 'WebPortalConnection+Data'):
    texts[name] = source_path(name).read_text(encoding='utf-8')
for name, text in texts.items():
    stored = [line.strip() for line in text.splitlines() if STORES.search(line)]
    assert not stored, (name, stored)
    if name != 'WebPortalConnection+Data':
        assert 'CaptureAnnotations.during(' in text, name
portal = texts['WebPortalConnection+Data']
portal = portal[portal.index('func saveImageAsScreenCapture('):portal.index('func processImageAsScreenCapture(')]
assert 'TemporaryPreference(ViewerPreferences.allowSmartCropping)' in portal and portal.count('smartCropping.restore()') == 2, portal
