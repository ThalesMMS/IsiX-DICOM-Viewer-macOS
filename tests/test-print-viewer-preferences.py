#!/usr/bin/env python3
"""Printing the 2D viewer on paper leaves the stored preferences as they were.

To capture its pages the print turns smart cropping off, enlarges the font of
the annotations and, around the square print window, turns "always scale to
fit" off. None of the three is a choice of the user. The print once stored
them: smart cropping came back on for someone who had turned it off, a value
that was only the factory's became the user's, and an application that ended
in the middle kept the capture's values.

The sheet's opening, the capture of the pages and the windows' restoration are
taken from ViewerPrintJob (ViewerPrintJob.swift) as they stand, with its plan
and its settings, and compiled against the real IsiXPreferences around a
controlled viewer. For a print that succeeds, one whose page cannot be written
and one that is cancelled, with the window enlarged or not, the stored
preferences and what the launch gave are afterwards exactly what they were,
kept by the user or only the factory's, while the views read the capture's
values as it draws and are told of the user's font again at the end.
--source takes a Swift source of the job, to prove the regression against an
earlier one.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults
import isix_modules
from sources import source_path

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, default=source_path('ViewerPrintJob'))
args = parser.parse_args()
job = args.source.read_text(encoding='utf-8')


def between(start, end):
    begin = job.index(start)
    return job[begin:job.index(end, begin)]


plan = between('// MARK: - The plan', '// MARK: - The job')
sheet = between('    /// Opens the print sheet', '    /// Shows the number of pages')
pages = between('    // MARK: The pages', '    /// Prints the pages prepared')
windows = between("    /// Puts the viewer's window back", '    func presentPreparationFailure()')
# What follows the failure alert: the helpers of the capture, up to the spool.
failure = job.index('    func presentPreparationFailure()')
helpers = job[job.index('\n    }\n', failure) + 7:job.index('    // MARK: The spool')]

DRIVER = harness_defaults.DOMAINS + r'''
import AppKit
import IsiXPreferences
import ObjectiveC

PLAN

extension Notification.Name { static let OsirixGLFontChange = Notification.Name("controlled font change") }

// What the views would read of the preferences while the print works.
var seenCropping: [Bool] = [], seenFont: [Float] = [], toldFont: [Float] = [], seenScaleToFit: [Bool] = []

final class Screen { var visibleFrame = NSMakeRect(0, 0, 1600, 1000) }
final class Window {
    var frame = NSMakeRect(30, 40, 400, 300)
    var screen: Screen? = Screen()
    func setFrame(_ frame: NSRect, display: Bool) { self.frame = frame }
    func update() {}
    func orderOut(_ sender: Any?) {}
    func orderFront(_ sender: Any?) {}
    func makeKeyAndOrderFront(_ sender: Any?) {}
    func beginSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)?) {}
}
final class DCMPix { static func resizeIfNecessary(_ image: NSImage?, dcmPix: DCMPix?) -> NSImage? { image } }
final class DicomImage { func isKeyImage() -> NSNumber? { nil } }
final class ImageView {
    var whiteBackground = false, flippedData = false
    var curImage = 0
    var curDCM: DCMPix?
    func isScaledFit() -> Bool { true }
    func scaleToFit() {}
    func setIndex(_ index: Int) {}
    func sendSyncMessage(_ message: Int) {}
    func nsimage(_ original: Bool) -> NSImage? {
        seenCropping.append(UserDefaults.standard.bool(forKey: "allowSmartCropping"))
        seenFont.append(UserDefaults.standard.float(forKey: "FONTSIZE"))
        return NSImage(size: NSMakeSize(8, 8))
    }
}
final class SeriesView {
    var rows: Int32 = 2, columns: Int32 = 3
    func imageRows() -> Int32 { rows }
    func imageColumns() -> Int32 { columns }
}
final class Wait {
    var cancelAfter: Int?, steps = 0
    func increment(by: Int) { steps += 1 }
    func aborted() -> Bool { cancelAfter.map { steps >= $0 } ?? false }
}
enum OSIWindow {
    nonisolated(unsafe) static var free = false
    static func dontConstrainWindow() -> Bool { free }
    static func setDontConstrain(_ value: Bool) { free = value }
}
enum OSIWindowController {
    nonisolated(unsafe) static var magnetic = false, screen = false
    static func setDontEnterMagneticFunctions(_ value: Bool) { magnetic = value }
    static func setDontEnterWindowDidChangeScreen(_ value: Bool) { screen = value }
}
enum AppController {
    static func usefullRect(for screen: Screen?) -> NSRect { screen?.visibleFrame ?? NSZeroRect }
    static func resizeWindow(withAnimation window: Window?, newSize: NSRect) {
        // The window's resizing asks whether the image is to fill it.
        seenScaleToFit.append(UserDefaults.standard.bool(forKey: "AlwaysScaleToFit"))
        window?.frame = newSize
    }
}
final class ViewerRegistry {
    var displayedViewers: [ViewerController] = []
    var viewers: [ViewerController]? = []
}
final class ViewerController {
    var window: Window? = Window()
    var horos_imageView: ImageView? = ImageView()
    var horos_seriesView: SeriesView? = SeriesView()
    var horos_printLayout: NSPopUpButton?, horos_printWindow: NSWindow?
    var horos_printSettings: NSMatrix?, horos_printFormat: NSMatrix?, horos_printSelection: NSMatrix?
    var horos_printInterval: NSSlider?, horos_printFrom: NSSlider?, horos_printTo: NSSlider?
    var horos_printText: NSTextField?, horos_printToText: NSTextField?, horos_printFromText: NSTextField?, horos_printIntervalText: NSTextField?
    var horos_curMovieIndex = 0
    var horos_windowFrameToRestore = NSZeroRect
    var horos_scaleFitToRestore = false
    var index = 7, zoom: Float = 1, isMagnetic = true, matrixVisible = true
    func horos_pixList(at movie: Int) -> NSMutableArray? { [0, 1, 2] }
    func setCurrentdcmExport(_ sender: Any?) {}
    func imageIndex() -> Int { index }
    func setImageIndex(_ index: Int) { self.index = index }
    func magnetic() -> Bool { isMagnetic }
    func setMagnetic(_ value: Bool) { isMagnetic = value }
    func checkFrameSize() -> Bool { matrixVisible }
    func setMatrixVisible(_ value: Bool) { matrixVisible = value }
    func setImageRows(_ rows: Int32, columns: Int32) { horos_seriesView?.rows = rows; horos_seriesView?.columns = columns }
    func fileList() -> NSMutableArray? { nil }
    func roiList() -> NSMutableArray? { nil }
    func scaleValue() -> Float { zoom }
    func adjustSlider() {}
}

@MainActor final class ViewerPrintJob {
    private unowned let viewer: ViewerController
    private let preferences: any PreferenceStore
    private let registry = ViewerRegistry()
    var unwritablePage: Int32?

    init(viewer: ViewerController, preferences: any PreferenceStore) {
        self.viewer = viewer
        self.preferences = preferences
    }

    func updatePageCount(_ sender: Any?) {}
    func writePage(_ image: NSImage?, index: Int32) -> String? { index == unwritablePage ? nil : "page \(index)" }
    func capture(_ plan: ViewerPrintPlan, settings: ViewerPrintSettings, splash: Wait) -> (pages: [String], failed: Bool) {
        capturePages(plan, settings: settings, keyImagesOnly: false, splash: splash)
    }

SHEET
PAGES
WINDOWS
HELPERS
}

// Every case runs: a failure is counted under what it says before its case.
var failures: [String: (count: Int, first: String)] = [:]
func check(_ condition: Bool, _ what: String) {
    if condition { return }
    let name = what.components(separatedBy: ": ").first ?? what
    failures[name] = ((failures[name]?.count ?? 0) + 1, failures[name]?.first ?? what)
}

// The application's defaults are a domain of this test only.
let suite = harnessDomainName("print-viewer-preferences-\(getpid())")
let controlled = UserDefaults(suiteName: suite)!
extension UserDefaults { @objc class func controlled_standardUserDefaults() -> UserDefaults { controlled } }
method_exchangeImplementations(class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults"))!,
                               class_getClassMethod(UserDefaults.self, #selector(UserDefaults.controlled_standardUserDefaults))!)
check(UserDefaults.standard === controlled, "the controlled defaults stand for the application's")

let told = NotificationCenter.default.addObserver(forName: .OsirixGLFontChange, object: nil, queue: nil) { _ in
    toldFont.append(UserDefaults.standard.float(forKey: "FONTSIZE"))
}
let keys = ["allowSmartCropping", "FONTSIZE", "AlwaysScaleToFit"]
func stored() -> NSDictionary { (controlled.persistentDomain(forName: suite) ?? [:]) as NSDictionary }
let launchArguments = controlled.volatileDomain(forName: UserDefaults.argumentDomain)
controlled.set(true, forKey: "SquareWindowForPrinting")
controlled.set(true, forKey: "printAt100%Minimum")
controlled.set(4096, forKey: "MAXWindowSize")
check(stored()["MAXWindowSize"] != nil, "the stored domain of the test is read back")

var cases = 0
MainActor.assumeIsolated {
// The three values stored by the user, or only the factory's; a font given at launch as well.
for (kept, launched) in [(true, false), (false, false), (true, true), (false, true)] {
    for initial in [false, true] { for outcome in ["printed", "unwritable page", "cancelled"] { for zoom in [Float(1), 0.5] {
        if kept {
            controlled.set(initial, forKey: "allowSmartCropping"); controlled.set(Float(12), forKey: "FONTSIZE"); controlled.set(initial, forKey: "AlwaysScaleToFit")
        } else {
            for key in keys { controlled.removeObject(forKey: key) }
            controlled.register(defaults: ["allowSmartCropping": initial, "FONTSIZE": Float(12), "AlwaysScaleToFit": initial])
        }
        var arguments = launchArguments
        if launched { arguments["FONTSIZE"] = Float(16) }
        controlled.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let font: Float = launched ? 16 : 12
        let before = stored()
        let what = "\(outcome), zoom \(zoom), stored \(kept), font given at launch \(launched), switches \(initial)"
        check(keys.allSatisfy { (before[$0] != nil) == kept }, "the case is set up: " + what)
        seenCropping = []; seenFont = []; toldFont = []; seenScaleToFit = []

        let viewer = ViewerController()
        viewer.zoom = zoom
        let job = ViewerPrintJob(viewer: viewer, preferences: controlled)
        if outcome == "unwritable page" { job.unwritablePage = 1 }
        let splash = Wait()
        if outcome == "cancelled" { splash.cancelAfter = 2 }

        job.openSheet()
        let settings = ViewerPrintSettings(layout: "3x2", columns: 3, rows: 2, comments: nil, patientInfo: false, studyInfo: false,
                                           whiteBackground: false, format: 0, interval: 1)
        let plan = ViewerPrintPlan(selection: ViewerPrintPlan.Selection.range.rawValue, currentImage: 0, count: 3, first: 1, last: 3, step: 1)
        let (pages, failed) = job.capture(plan, settings: settings, splash: splash)
        job.restoreWindows()

        check(failed == (outcome == "unwritable page") && pages.count == (outcome == "printed" ? 3 : outcome == "cancelled" ? 2 : 1),
              "the capture ends as the case says: \(pages.count) pages, failed \(failed): " + what)
        check(viewer.index == 7 && viewer.isMagnetic && viewer.matrixVisible && viewer.horos_seriesView?.rows == 2 && viewer.horos_seriesView?.columns == 3
              && NSEqualRects(viewer.window?.frame ?? NSZeroRect, NSMakeRect(30, 40, 400, 300)) && !OSIWindow.free, "the viewer is as it was: " + what)

        // While it works, the views read the capture's values.
        check(!seenCropping.isEmpty && !seenCropping.contains(true), "smart cropping is off while a page is captured: " + what)
        // The window is the square one the sheet made of the screen's 1600 x 1000.
        let scale = zoom < 1 ? ViewerPrintPlan.windowScale(viewScale: zoom, maximumWindowSize: 4096, columns: 3, rows: 2, frame: NSMakeSize(1000, 1000)) : 1
        let pageFont = Float(ViewerPrintPlan.pageFontSize(base: font, increment: ViewerPrintPlan.fontIncrement(columns: 3), scale: scale))
        check(pageFont > font && seenFont.allSatisfy { $0 == pageFont }, "a page is captured with the page's font, \(pageFont): \(seenFont): " + what)
        check(toldFont.first == pageFont && toldFont.last == font, "the views are told of the page's font, and of the user's at the end: \(toldFont): " + what)
        check(seenScaleToFit == [false, false], "the square window and its restoration resize with scale to fit off: \(seenScaleToFit): " + what)

        // Afterwards everything reads as before, and nothing was stored.
        check(controlled.bool(forKey: "allowSmartCropping") == initial && controlled.float(forKey: "FONTSIZE") == font
              && controlled.bool(forKey: "AlwaysScaleToFit") == initial, "the preferences read as before: " + what)
        check(stored().isEqual(before), "the stored preferences are what they were: " + what
              + " -> \((stored() as? [String: Any] ?? [:]).filter { keys.contains($0.key) })")
        check((controlled.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary).isEqual(arguments),
              "what the launch gave is what it was: " + what)
        cases += 1
    } } }
}
}
NotificationCenter.default.removeObserver(told)
controlled.setVolatileDomain(launchArguments, forName: UserDefaults.argumentDomain)
controlled.removePersistentDomain(forName: suite)
if !failures.isEmpty {
    for (name, failure) in failures.sorted(by: { $0.key < $1.key }) { print("FAIL (\(failure.count) of \(cases) cases): \(name); first: \(failure.first)") }
    exit(1)
}
print("PASS: \(cases) prints of the 2D viewer (printed, a page not written, cancelled; window enlarged or not) leave the stored "
      + "preferences and the launch's as they were, kept by the user or not, while the capture reads its own values")
'''.replace('PLAN', plan).replace('SHEET', sheet).replace('PAGES', pages).replace('WINDOWS', windows).replace('HELPERS', helpers)

with tempfile.TemporaryDirectory(prefix='horos-print-preferences-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(work / 'main.swift'),
                    *isix_modules.module_flags('IsiXPreferences', work / 'modules'), '-o', str(work / 'test')], check=True)
    subprocess.run([str(work / 'test')], check=True)

# Of the preferences, the job stores the settings the next print starts from, and nothing else.
stored = [line.strip() for line in job.splitlines() if 'preferences.set(' in line or 'UserDefaults.standard.set(' in line]
assert stored == ['preferences.set(settings.propertyList, for: VolumeRenderingPreferences.previousPrintSettings)'], stored
