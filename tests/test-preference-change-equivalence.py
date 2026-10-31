#!/usr/bin/env python3
"""A change of the preferences is answered as before it left AppController.

The check that runs half a second after a preference is written compared the
preferences with those of the previous check and answered: the series lists,
the viewers redrawn, refreshed or read again, the measurements' lengths and the
labels' size, the database list and its columns, the PET fusion's colour table,
the notice that the servers need a restart, the listener's host-name title, and
the first entry of the compression lists and the supplementary burn folder put
back. It moved from -[AppController runPreferencesUpdateCheck:] to
IsiXPreferences' PreferenceChange, which finds the marks, and
PreferenceChangeResponder, which answers them.

This compiles both over the same stand-ins (viewers, their windows and image
views, the screens, the browser, the listener, the window arranger, the
notification centre, the alerts, the drawing and import settings and the
preferences) and drives them over the same changes: every watched key, COPYSETTINGS
and keys nobody watches, alone, for every pair of values of its domain, and
thousands of random changes of several keys at once over the factory settings.
The reference is the Swift method of AppController.swift at REFERENCE, the
revision before the move; the other side is PreferenceChangeResponder.swift of
the tree, over the IsiXPreferences module of the tree. What each does, in
order, and every preference it writes must be identical.

The domains are the values the keys are stored as: a switch as a Boolean, a
number or its text ("0", "1", "YES", "NO"); a number as a number or its text,
with a fraction only where the key has one; text as text, or a number where an
earlier version stored one. Two kinds of value are left out because the
reference answered them wrongly, the way the comments of the check describe:
the text "2" or "y" of a switch, which the previous reading took for on and the
current one for off, and the text of a number with a fraction for a key read as
an integer (3 before, 0 after). Both made every check see a change where there
was none. The alert about the web server on systems older than Mac OS X 10.6 is
never shown: every supported system is later.

    python3 tests/test-preference-change-equivalence.py [--reference REV] [--dump DIR]
"""
import argparse
import difflib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = '71700d54fc6f5a72aa8f9cac0c8b8ae067139168'
RESPONDER = ROOT / 'Horos/Sources/PreferenceChangeResponder.swift'
ROI_LABELS = ROOT / 'Horos/Sources/ROILabelPresentation.swift'

parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
parser.add_argument('--reference', default=REFERENCE)
parser.add_argument('--dump', type=Path, help='write the records of both programs to this folder')
args = parser.parse_args()

try:
    reference = subprocess.run(['git', 'show', f'{args.reference}:Horos/Sources/AppController.swift'], cwd=ROOT,
                               capture_output=True, text=True, check=True).stdout
except subprocess.CalledProcessError:
    print(f'SKIP: the reference revision {args.reference} is not in this clone')
    sys.exit(2)

signature = '@objc(runPreferencesUpdateCheck:) public func runPreferencesUpdateCheck(_ timer: Timer!) {'
start = reference.find(signature)
if start < 0:
    sys.exit(f'FAIL: runPreferencesUpdateCheck is not in AppController.swift at {args.reference}')
end = reference.index('\n    }\n', start) + len('\n    }\n')
old = reference[start:end].replace(signature, 'func runPreferencesUpdateCheck(_ timer: Timer!) {')
objc_start = reference.index('fileprivate enum ObjC {')
objc = reference[objc_start:reference.index('\n}\n', objc_start) + 3]

# What both texts name and the harness stands in for.
SHARED = ((r'NotificationCenter\.default\.post\(', 'FakeCenter.post('), (r'NSApp\.keyWindow', 'FakeApp.keyWindow'),
          (r'NSScreen\.screens', 'FakeScreen.screens'), (r'\bHorosAlertPanel\b', 'FakeAlert'), (r'\bNSLog\(', 'recordLog('))
for before, after in SHARED + ((r'UserDefaults\.standard', 'FakeDefaults.standard'), (r'\bNSWindow\b', 'FakeWindow'),
                               (r'BrowserController\.currentBrowser\(\)', 'FakeBrowser.current'),
                               (r'AppController\.shared\(\)\?\.', 'Host.shared.'), (r'\bAppController\.', 'Host.')):
    old = re.sub(before, after, old)
responder = RESPONDER.read_text(encoding='utf-8')
for before, after in SHARED + ((r'\bUserDefaults\b(?!\.didChangeNotification)', 'FakeDefaults'),):
    responder = re.sub(before, after, responder)
kinds = re.search(r'static let statisticKinds = (\[[^\]]*\])', ROI_LABELS.read_text(encoding='utf-8'))
if not kinds:
    sys.exit('FAIL: ROILabelPresentation.statisticKinds is not found')

STAND_INS = r'''
import AppKit
import IsiXPreferences

var records: [String] = []
func record(_ line: String) { records.append(line) }
func recordLog(_ format: String, _ arguments: CVarArg...) { record("log \(format)") }

/// A property list as text, its tables' keys in order.
func describe(_ value: Any?) -> String {
    guard let value else { return "nil" }
    guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0) else { return "\(value)" }
    return String(decoding: data, as: UTF8.self).components(separatedBy: "\n").dropFirst(3).joined(separator: " ")
}

let HorosObjCExceptionKey = "HorosObjCException"
enum HorosObjCException { static func perform(_ block: () throws -> Void) throws { try block() } }

final class FakeDefaults: PreferenceStore, @unchecked Sendable {
    static let standard = FakeDefaults()
    var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) {
        record("set \(key) \(describe(value))")
        values[key] = (value as? NSObject)?.copy()
    }
    func isGivenAsLaunchArgument(_ key: String) -> Bool { false }
    func dictionaryRepresentation() -> [String: Any] { values }
    func bool(forKey key: String) -> Bool { Bool.reading(values[key]) }
    func integer(forKey key: String) -> Int { Int.reading(values[key]) }
    func string(forKey key: String) -> String? { Optional<String>.reading(values[key]) }
    func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
}

enum FakeCenter {
    static func post(name: Notification.Name, object: Any?) { record("post \(name.rawValue)") }
}
extension NSNotification.Name {
    static let OsirixLabelGLFontChange = NSNotification.Name("OsirixLabelGLFontChange")
}

final class FakeWindow {
    let name: String
    var isVisible: Bool
    var isMainWindow: Bool
    init(_ name: String, visible: Bool, main: Bool) { self.name = name; isVisible = visible; isMainWindow = main }
    func makeKeyAndOrderFront(_ sender: Any?) { record("\(name) makeKeyAndOrderFront") }
}
enum FakeApp { static var keyWindow: FakeWindow? = nil }

final class FakeScreen {
    static var screens: [FakeScreen] = []
    var front: ViewerController?
    init(front: ViewerController?) { self.front = front }
}

final class FakeImageView: NSView {
    var label = ""
    override var needsDisplay: Bool { didSet { record("\(label) needsDisplay") } }
}

final class ViewerController: NSObject {
    static var all: [ViewerController] = []
    let name: String
    let displayed: Bool
    let window: FakeWindow?
    let views: [FakeImageView]
    init(_ name: String, displayed: Bool, main: Bool) {
        self.name = name
        self.displayed = displayed
        window = FakeWindow(name, visible: displayed, main: main)
        views = (0..<2).map { index in
            let view = FakeImageView(frame: .zero)
            view.label = "\(name).\(index)"
            return view
        }
    }
    class func get2DViewers() -> NSMutableArray! { all.isEmpty ? nil : NSMutableArray(array: all) }
    class func getDisplayed2DViewers() -> NSMutableArray! { NSMutableArray(array: all.filter(\.displayed)) }
    class func frontMostDisplayed2DViewer(for screen: FakeScreen?) -> ViewerController! { screen?.front }
    func imageViews() -> NSArray! { NSArray(array: views) }
    func updateSeriesListMode() { record("\(name) updateSeriesListMode") }
    func setMatrixVisible(_ visible: Bool) { record("\(name) setMatrixVisible \(visible)") }
    func redrawToolbar() { record("\(name) redrawToolbar") }
    func needsDisplayUpdate() { record("\(name) needsDisplayUpdate") }
    func displayDICOMOverlays(_ sender: Any!) { record("\(name) displayDICOMOverlays") }
    func copySettingsToOthers(_ sender: Any!) { record("\(name) copySettingsToOthers") }
}

final class ViewerRegistry {
    var viewers: [ViewerController]? { ViewerController.all.isEmpty ? nil : ViewerController.all }
    var displayedViewers: [ViewerController] { ViewerController.all.filter(\.displayed) }
    func frontMostDisplayedViewer(on screen: FakeScreen?) -> ViewerController? { screen?.front }
}

final class FakeBrowser {
    static var current: FakeBrowser? = nil
    func setDBDate() { record("browser setDBDate") }
    func outlineViewRefresh() -> String! { record("browser outlineViewRefresh"); return "" }
    func refreshColumns() { record("browser refreshColumns") }
    func setNetworkLogs() { record("browser setNetworkLogs") }
}

final class ProcessGraph {
    static let process = ProcessGraph()
    let viewerRegistry = ViewerRegistry()
    var currentBrowser: FakeBrowser? { FakeBrowser.current }
    var preferences: FakeDefaults { FakeDefaults.standard }
}

final class DICOMListenerController {
    func applySettingsIfChanged() { record("listener applySettingsIfChanged") }
    func setAETitleToHostname() { record("listener setAETitleToHostname") }
    func noteAppliedSettings() { record("listener noteAppliedSettings") }
}

final class ViewerWindowArranger {
    func prepareThumbnailsListsForScreenReconfiguration() { record("arranger prepareThumbnailsLists") }
    func tileWindows(sender: Any?) { record("arranger tileWindows") }
}

enum FakeAlert {
    @discardableResult
    static func run(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        record("alert \(title)"); return 0
    }
    @discardableResult
    static func runCritical(title: String, message: String, defaultButton: String?, alternateButton: String?, otherButton: String?) -> Int {
        record("critical alert \(title)"); return 0
    }
}

enum DCMView {
    static func computePETBlendingCLUT() { record("DCMView computePETBlendingCLUT") }
    static func setDefaults() { record("DCMView setDefaults") }
}
enum DCMPix { static func checkUserDefaults(_ update: Bool) { record("DCMPix checkUserDefaults") } }
enum DicomFile { static func resetDefaults() { record("DicomFile resetDefaults") } }
enum ROI { static func loadDefaultSettings() { record("ROI loadDefaultSettings") } }

enum LengthPresentation {
    static let unitKey = ViewerPreferences.roiLengthUnit.name
    static let decimalsKey = ViewerPreferences.roiLengthDecimals.name
    static let changedNotification = "HorosLengthPresentationDidChange"
}
enum ROILabelPresentation {
    static let statisticKinds = %s
    static func defaultsKey(forStatistic kind: String) -> String {
        ViewerPreferences.roiLabelShows(statistic: kind)?.name ?? "ROILabelShow" + kind
    }
}
enum ROILabelContrast {
    static let backgroundKey = ViewerPreferences.roiLabelBackground.name
    static let backgroundOpacityKey = ViewerPreferences.roiLabelBackgroundOpacity.name
}
enum PreviousStudyMark { static let defaultsKey = ViewerPreferences.showPreviousExamLabel.name }
enum XMLRPCServerAccess { static let httpsKey = NetworkPreferences.xmlrpcServerHTTPS.name }
let OsirixCanActivateDefaultDatabaseOnlyDefaultsKey = "addNewIncomingFilesToDefaultDBOnly"

/// One change: the preferences before and after it, the viewers open, the
/// window with the focus and whether the browser is there.
struct Scenario {
    let name: String
    let previous: [String: Any]
    let current: [String: Any]
    let keyWindow: Bool
    let browser: Bool
}

struct Generator {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) %% UInt64(bound))
    }
}

let switches = ["UseFloatingThumbnailsList", "ROIPRIMARYMEASUREMENTONLY", "ShowPreviousExamLabel", "ROILabelBackground"]
    + ["Area", "WH", "Mean", "SDev", "Sum", "Median", "Min", "Max"].map { "ROILabelShow" + $0 }
let integers = ["SeriesListVisible", "DisplayDICOMOverlays", "ROITEXTNAMEONLY", "ROITEXTIFSELECTED", "httpXMLRPCServer",
                "httpXMLRPCServerPort", "httpXMLRPCServerHTTPS", "httpWebServer", "httpWebServerPort", "encryptedWebServer",
                "LISTENERCHECKINTERVAL", "addNewIncomingFilesToDefaultDBOnly", "HIDEPATIENTNAME", "SERIESORDER",
                "KeepStudiesOfSamePatientTogether", "NOINTERPOLATION", "SOFTWAREINTERPOLATION"]
let numbers = ["ROILabelBackgroundOpacity", "ROILengthUnit", "ROILengthDecimals", "LabelFONTSIZE"]
let texts = ["PET Blending CLUT", "DBDateFormat2", "DBDateOfBirthFormat2"]
let others = ["COPYSETTINGS", "UseHostNameForAETitle", "NSWindow Frame Viewer", "SupplementaryBurnPath", "BurnSupplementaryFolder"]

let switchValues: [Any?] = [nil, "0", "1", NSNumber(value: 0), NSNumber(value: 1), true, false, "YES", "NO"]
let integerValues: [Any?] = [nil, "0", "1", "2", NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: 2), true, false, "8080",
                             NSNumber(value: 8080)]
let numberValues: [Any?] = [nil, "0", "3", "0.8", NSNumber(value: 0), NSNumber(value: 3), NSNumber(value: Float(0.8)),
                            NSNumber(value: 0.5), "12", NSNumber(value: 14.5)]
let textValues: [Any?] = [nil, "PET", "Hot Iron", "", NSNumber(value: 1), "1"]
let tableValues: [Any?] = [nil, [String: Any](), ["Patient name": 120], ["Patient name": 140], "x"]
let otherValues: [Any?] = [nil, "1", NSNumber(value: 0), true, false, "", "/Users/me/Burn"]

func domain(of key: String) -> [Any?] {
    if switches.contains(key) { return switchValues }
    if integers.contains(key) { return integerValues }
    if numbers.contains(key) { return numberValues }
    if texts.contains(key) { return textValues }
    if key == "COLUMNSDATABASE" { return tableValues }
    return otherValues
}

func compressionList(_ variant: Int, quality: String) -> [Any]? {
    switch variant {
    case 0: return [["modality": "default", "compression": "3", "quality": quality], ["modality": "CT", "compression": "0", "quality": quality]]
    case 1: return [["modality": "CT", "compression": "0", "quality": quality], ["modality": "MR", "compression": "4"]]
    case 2: return [["modality": "default", "compression": NSNumber(value: 0), "quality": quality]]
    case 3: return [["modality": "XA", "compression": "5"]]
    default: return nil
    }
}

func makeScenarios() -> [Scenario] {
    let environment = PreferenceEnvironment(viewer: true, appStore: false, hostName: "reading-room.example.org", graphicsMemory: 1 << 30)
    let factory = DefaultPreferences.defaults(in: environment, store: MemoryPreferences()) as? [String: Any] ?? [:]
    var scenarios: [Scenario] = []
    func with(_ base: [String: Any], _ key: String, _ value: Any?) -> [String: Any] {
        var values = base
        values[key] = value
        return values
    }
    // Every watched key alone, and the keys nobody watches, for every pair of values.
    for key in switches + integers + numbers + texts + ["COLUMNSDATABASE"] + others {
        let values = domain(of: key)
        for (i, before) in values.enumerated() {
            for (j, after) in values.enumerated() {
                scenarios.append(Scenario(name: "\(key) \(i) \(j)", previous: with(factory, key, before), current: with(factory, key, after),
                                          keyWindow: (i + j) %% 2 == 0, browser: (i + j) %% 3 != 0))
            }
        }
    }
    // Several keys at once, over the factory settings and over earlier changes.
    var generator = Generator(state: 1693)
    let keys = switches + integers + numbers + texts + ["COLUMNSDATABASE"] + others
    for index in 0..<6000 {
        var previous = factory
        for _ in 0..<generator.next(4) {
            let key = keys[generator.next(keys.count)]
            let values = domain(of: key)
            previous[key] = values[generator.next(values.count)]
        }
        var current = previous
        for _ in 0..<(1 + generator.next(6)) {
            let key = keys[generator.next(keys.count)]
            let values = domain(of: key)
            current[key] = values[generator.next(values.count)]
        }
        if generator.next(4) == 0 {
            current["CompressionSettings"] = compressionList(generator.next(5), quality: "1")
            current["CompressionSettingsLowRes"] = compressionList(generator.next(5), quality: "0")
        }
        scenarios.append(Scenario(name: "random \(index)", previous: previous, current: current,
                                  keyWindow: generator.next(2) == 0, browser: generator.next(5) != 0))
    }
    return scenarios
}

/// The viewers of every scenario: two shown, one the main window, one hidden;
/// the first screen's front viewer is the first, the second screen has none.
func prepare(_ scenario: Scenario) {
    ViewerController.all = [ViewerController("v0", displayed: true, main: true), ViewerController("v1", displayed: true, main: false),
                            ViewerController("v2", displayed: false, main: false)]
    FakeScreen.screens = [FakeScreen(front: ViewerController.all[0]), FakeScreen(front: nil)]
    FakeApp.keyWindow = scenario.keyWindow ? FakeWindow("preferences", visible: true, main: false) : nil
    FakeBrowser.current = scenario.browser ? FakeBrowser() : nil
}
''' % (kinds.group(1),)

REFERENCE_MAIN = r'''
import AppKit
import IsiXPreferences

%s

final class Host {
    static var shared = Host()
    static func hasMacOSXSnowLeopard() -> Bool { true }
    var updateTimer: Timer? = nil
    var previousDefaults: NSDictionary? = nil
    var showRestartNeeded = true
    let dicomListener = DICOMListenerController()
    let windowArranger = ViewerWindowArranger()
    func tileWindows(_ sender: Any?) { windowArranger.tileWindows(sender: sender) }

%s
}

MainActor.assumeIsolated {
    for scenario in makeScenarios() {
        prepare(scenario)
        record("scenario \(scenario.name)")
        let host = Host()
        Host.shared = host
        host.previousDefaults = scenario.previous as NSDictionary
        FakeDefaults.standard.values = scenario.current
        host.runPreferencesUpdateCheck(nil)
    }
}
print(records.joined(separator: "\n"))
''' % (objc.replace('fileprivate enum ObjC', 'enum ObjC'), old)

# start() hands the listener the settings it runs with, which the reference
# did before the check existed: what it records is left out.
CURRENT_MAIN = r'''
import AppKit
import IsiXPreferences

var printed: [String] = []
MainActor.assumeIsolated {
    for scenario in makeScenarios() {
        prepare(scenario)
        let responder = PreferenceChangeResponder(listener: DICOMListenerController(), windowArranger: ViewerWindowArranger())
        FakeDefaults.standard.values = scenario.previous
        responder.start()
        records.removeAll()
        record("scenario \(scenario.name)")
        FakeDefaults.standard.values = scenario.current
        responder.check()
        printed += records
        records.removeAll()
    }
}
print(printed.joined(separator: "\n"))
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-preference-change-') as tmp:
    folder = Path(tmp)
    flags = isix_modules.module_flags('IsiXPreferences', folder / 'modules')
    results = {}
    for label, sources in (('reference', {'main.swift': REFERENCE_MAIN}),
                           ('current', {'main.swift': CURRENT_MAIN, 'PreferenceChangeResponder.swift': responder})):
        work = folder / label
        work.mkdir()
        (work / 'StandIns.swift').write_text(STAND_INS)
        for name, text in sources.items():
            (work / name).write_text(text)
        program = work / 'program'
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', *flags,
                                *sorted(map(str, work.glob('*.swift'))), '-o', str(program)],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-6000:])
            sys.exit(f'FAIL: the {label} program does not compile')
        run = subprocess.run([str(program)], capture_output=True, text=True, timeout=600)
        if run.returncode:
            print((run.stdout + run.stderr)[-3000:])
            sys.exit(f'FAIL: the {label} program stopped ({run.returncode})')
        results[label] = run.stdout.splitlines()
    if args.dump:
        args.dump.mkdir(parents=True, exist_ok=True)
        for label, lines in results.items():
            (args.dump / f'{label}.txt').write_text('\n'.join(lines) + '\n')

expected, got = results['reference'], results['current']
scenarios = sum(1 for line in expected if line.startswith('scenario '))
answered = sum(1 for line in expected if line == 'DCMPix checkUserDefaults')
if expected != got:
    print(f'FAIL: PreferenceChangeResponder answers otherwise than AppController at {args.reference[:9]}:')
    for line in list(difflib.unified_diff(expected, got, 'reference', 'current', lineterm='', n=4))[:80]:
        print('  ' + line)
    sys.exit(1)
marks = {name: sum(1 for line in expected if line.endswith(name)) for name in (
    'needsDisplayUpdate', 'displayDICOMOverlays', 'needsDisplay', 'updateSeriesListMode', 'setMatrixVisible false',
    'browser setDBDate', 'browser refreshColumns', 'computePETBlendingCLUT', 'alert DICOM Listener', 'setAETitleToHostname',
    'post HorosLengthPresentationDidChange', 'post OsirixLabelGLFontChange', 'log *** isKindOfClass NSString',
    'arranger tileWindows')}
missing = [name for name, count in marks.items() if count == 0]
if missing or answered < 1000:
    sys.exit(f'FAIL: the scenarios no longer reach {missing or "enough checks"}')
print(f'PASS: {scenarios} changes, {answered} answered, {len(expected)} records identical to AppController at '
      f'{args.reference[:9]}; ' + ', '.join(f'{name} {count}' for name, count in marks.items()))
