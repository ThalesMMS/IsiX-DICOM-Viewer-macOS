#!/usr/bin/env python3
"""A capture served by the web portal leaves the open 2D viewers' annotations as they were.

/imageAsScreenCapture.jpg draws the image in a view of its own and serves a
JPEG of it. Before it drew, the portal gave "graphics only" to every view of
the 2D viewers on screen, and afterwards only read the display settings again,
which do not hold a view's level of annotations: after one such request the
open viewers showed no patient name, no dates and no window values until the
preference changed or their windows were opened again.

-saveImageAsScreenCapture: is taken from WebPortalConnection+Data.swift as it
stands and compiled against the real IsiXPreferences and HorosObjCException
around controlled views, where +setCLUTBARS:ANNOTATIONS: does what DCMView's
does. For a capture that is served and one that raises, at each level of
annotations: the views of the open viewers have afterwards the level they
had, the colour bars are what they were, smart cropping is off for the capture
and for this process only, the stored preferences are untouched, and the JPEG
is written where the request reads it. The image served is drawn with the
graphics alone (the regions and the lines), whatever level of annotations the
station shows: their text names the patient.
--source takes a Swift source of the portal, to prove the regression against
an earlier one.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults
import isix_modules
import objc_exception_guards
from sources import source_path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=source_path('WebPortalConnection+Data'))
args = parser.parse_args()
text = args.source.read_text(encoding='utf-8')
begin = text.index('    @objc(saveImageAsScreenCapture:)\n')
capture = text[begin:text.index('    @objc(processImageAsScreenCapture:)', begin)]

DRIVER = harness_defaults.DOMAINS + r'''
import AppKit
import IsiXPreferences
import ObjectiveC

let annotNone = 0, annotGraphics = 1, annotBase = 2, annotFull = 3
nonisolated(unsafe) var CLUTBARS: Int32 = 0

// The application's defaults are a domain of this test only.
let suite = harnessDomainName("web-portal-capture-annotations-\(getpid())")
let controlled = UserDefaults(suiteName: suite)!
extension UserDefaults { @objc class func controlled_standardUserDefaults() -> UserDefaults { controlled } }
method_exchangeImplementations(class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!,
                               class_getClassMethod(UserDefaults.self, #selector(UserDefaults.controlled_standardUserDefaults))!)
func stored() -> NSDictionary { (controlled.persistentDomain(forName: suite) ?? [:]) as NSDictionary }
enum PreferencesSource {
    enum process { static var preferences: UserDefaults { controlled } }
}

nonisolated(unsafe) var raises = false
nonisolated(unsafe) var seenCropping: [Bool] = []
nonisolated(unsafe) var logged = 0
/// The views of the 2D viewers on screen.
nonisolated(unsafe) var displayed: [DCMView] = []

final class DCMView {
    var annotationType: Int32
    var refreshes = 0
    init() { annotationType = Int32(truncatingIfNeeded: controlled.integer(forKey: "ANNOTATIONS")) }

    /// The display preferences every view draws with: not a view's level.
    static func setDefaults() { CLUTBARS = Int32(truncatingIfNeeded: controlled[ViewerPreferences.clutBars]) }

    /// The colour bars, and the annotations of every view of the 2D viewers.
    static func setCLUTBARS(_ bars: Int32, annotations: Int32) {
        CLUTBARS = bars
        for view in displayed {
            view.annotationType = annotations
            view.refreshes += 1
        }
    }
}

/// The level of annotations each capture was asked to draw with: nil for the user's.
nonisolated(unsafe) var askedLevels: [Int32?] = []
func assumeMainActor<Value, Result>(_ value: Value, _ body: (Value) throws -> Result) rethrows -> Result { try body(value) }

final class DicomImage {
    func xidFilename() -> String { "x-image-1" }
    /// The former entry: the level of the user's preferences.
    func image(asScreenCapture frame: NSRect) -> NSImage? { screenCapture(frame, annotations: nil) }
    /// Draws in a view of its own, as the application's does, at the level asked.
    func screenCapture(_ frame: NSRect, annotations: Int32?) -> NSImage? {
        askedLevels.append(annotations)
        seenCropping.append(controlled.bool(forKey: "allowSmartCropping"))
        if raises { NSException(name: .rangeException, reason: "the capture raises", userInfo: nil).raise() }
        let image = NSImage(size: NSMakeSize(4, 4))
        image.addRepresentation(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 3,
                                                 hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!)
        return image
    }
}

enum WebPortalPageError: Error {
    case raised(NSException)
    static func exception(for error: Error) -> NSException {
        if case .raised(let exception)? = error as? WebPortalPageError { return exception }
        return NSException(name: .genericException, reason: "\(error)", userInfo: nil)
    }
}
func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ function: String) { logged += 1 }
func objcAppendingPathComponent(_ base: NSString?, _ component: String?) -> NSString? {
    guard let base, let component else { return nil }
    return base.appendingPathComponent(component) as NSString
}
func objcAppendingPathExtension(_ base: NSString?, _ ext: String?) throws -> NSString? {
    guard let base, let ext else { return nil }
    return base.appendingPathExtension(ext) as NSString?
}

let folder = NSTemporaryDirectory() + "web-portal-capture-\(getpid())"
try! FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

final class WebPortalConnection: NSObject {
    let image = DicomImage()
    class func tmpDirPath() -> String { folder }
    func objectWithXID(_ xid: NSString?) -> Any? { xid == "image" ? image : nil }

CAPTURE
}

// Every case runs: a failure is counted under what it says before its case.
var failures: [String: (count: Int, first: String)] = [:]
func check(_ condition: Bool, _ what: String) {
    if condition { return }
    let name = what.components(separatedBy: ": ").first ?? what
    failures[name] = ((failures[name]?.count ?? 0) + 1, failures[name]?.first ?? what)
}
check(UserDefaults.standard === controlled, "the controlled defaults stand for the application's")
controlled.register(defaults: ["allowSmartCropping": "1", "ANNOTATIONS": "2", "CLUTBARS": "0",
                               "DicomImageScreenCaptureWidth": "512", "DicomImageScreenCaptureHeight": "512"])
let launchArguments = controlled.volatileDomain(forName: UserDefaults.argumentDomain)
let served = folder + "/x-image-1.jpg"

var cases = 0
for kept in [true, false] { for level in [annotBase, annotFull, annotNone, annotGraphics] { for bars in [0, 3] { for cropping in [true, false] {
    for outcome in ["served", "raising"] {
        for key in ["ANNOTATIONS", "CLUTBARS", "allowSmartCropping"] { controlled.removeObject(forKey: key) }
        if kept {
            controlled.set(level, forKey: "ANNOTATIONS"); controlled.set(bars, forKey: "CLUTBARS"); controlled.set(cropping, forKey: "allowSmartCropping")
        } else {
            controlled.register(defaults: ["ANNOTATIONS": "\(level)", "CLUTBARS": "\(bars)", "allowSmartCropping": cropping ? "1" : "0"])
        }
        DCMView.setDefaults()
        let before = stored()
        // Two viewers on screen, one of them tiled in two views.
        displayed = [DCMView(), DCMView(), DCMView()]
        raises = outcome == "raising"; seenCropping = []; logged = 0; askedLevels = []
        try? FileManager.default.removeItem(atPath: served)
        let what = "\(outcome), stored \(kept), level \(level), bars \(bars), smart cropping \(cropping)"

        let raised = HorosObjCException.caught { WebPortalConnection().saveImageAsScreenCapture("image") }

        check(raised == nil && logged == (raises ? 1 : 0) && FileManager.default.fileExists(atPath: served) == !raises,
              "the capture ends as the case says, and the request's thread is not raised to: logged \(logged): " + what)
        check(seenCropping == [false], "the capture draws with smart cropping off: \(seenCropping): " + what)
        check(askedLevels == [Int32(annotGraphics)],
              "the image served has the graphics alone, whatever the level of this station: asked \(askedLevels): " + what)
        check(displayed.allSatisfy { $0.annotationType == Int32(level) },
              "the views of the open 2D viewers have the level of annotations they had: \(displayed.map(\.annotationType)): " + what)
        check(CLUTBARS == Int32(bars), "the colour bars are what they were: \(CLUTBARS): " + what)
        check(controlled.bool(forKey: "allowSmartCropping") == cropping && controlled.integer(forKey: "ANNOTATIONS") == level,
              "the preferences read as before: " + what)
        check(stored().isEqual(before), "the stored preferences are what they were: " + what)
        check((controlled.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary).isEqual(launchArguments),
              "what the launch gave is what it was: " + what)
        cases += 1
    }
} } } }
// A request for what is not an image captures nothing.
displayed = [DCMView()]
seenCropping = []
WebPortalConnection().saveImageAsScreenCapture("series")
check(seenCropping.isEmpty && displayed[0].refreshes == 0, "an XID that is not an image is left alone")

controlled.setVolatileDomain(launchArguments, forName: UserDefaults.argumentDomain)
controlled.removePersistentDomain(forName: suite)
try? FileManager.default.removeItem(atPath: folder)
if !failures.isEmpty {
    for (name, failure) in failures.sorted(by: { $0.key < $1.key }) { print("FAIL (\(failure.count) of \(cases) cases): \(name); first: \(failure.first)") }
    exit(1)
}
print("PASS: \(cases) captures of the web portal (served, raising) leave the views of the open 2D viewers with their level of annotations, "
      + "the colour bars and the stored preferences as they were, and draw with smart cropping off")
'''.replace('CAPTURE', capture)

with tempfile.TemporaryDirectory(prefix='horos-web-portal-capture-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    (work / 'guards.swift').write_text(objc_exception_guards.source(log=False))
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=15.0', '-c', str(ROOT / 'Horos/Sources/HorosObjCException.m'),
                    '-o', str(work / 'HorosObjCException.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-import-objc-header', str(ROOT / 'Horos/Sources/HorosObjCException.h'),
                    str(work / 'main.swift'), str(work / 'guards.swift'), str(work / 'HorosObjCException.o'),
                    *isix_modules.module_flags('IsiXPreferences', work / 'modules'), '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True)

# The capture itself: the level asked is given to the view of the capture before it draws, and the
# selector the former SDK had keeps the level of the user's preferences.
image = (ROOT / 'Horos/Sources/DicomImage.swift').read_text(encoding='utf-8')
start = image.index('    @MainActor func screenCapture(_ frame: NSRect, annotations: Int32?) -> NSImage? {')
body = image[start:image.index('\n    }\n', start)]
if not (0 < body.find('if let annotations { view?.annotationType = annotations }') < body.find('view?.draw(frame)')):
    raise SystemExit('FAIL: the capture does not give its view the level asked before it draws')
if 'image.screenCapture(frame, annotations: nil)' not in image:
    raise SystemExit('FAIL: -imageAsScreenCapture: no longer draws at the level of the preferences')

