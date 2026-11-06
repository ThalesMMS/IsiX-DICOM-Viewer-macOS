#!/usr/bin/env python3
"""The viewers' tiling chooses the same frames as before it left AppController.

The choice of the grid when the viewers' windows are tiled (the order by row
and by centre, the rows and columns from the number of viewers, screens, the
screen's shape, the hanging protocol and the tiling menus, the grouping by
study, the order by study date, the window added beside the others and the
stretching of the last row) moved from -[AppController
tileWindows:windows:display2DViewerToolbar:displayThumbnailsList:] to
ViewerTilingLayout in IsiXImaging; ViewerWindowArranger moves the windows to
the frames it chooses.

This compiles both over the same synthetic scenarios and compares what they
produce: the reference is the Swift method of AppController.swift at REFERENCE
(the revision before the move), with its helpers (-displayViewers:...,
-currentRowForViewer:, -windowCenter:, -orderedScreens, the messages to an id),
over stand-ins of the screens, windows, viewers and defaults; the other side is
ViewerTilingLayout.swift of the tree, driven the way the arranger drives it.
Each scenario tiles twice (a viewer fewer, then one more, hidden), for 1 to 16
viewers, on one landscape screen, one portrait screen and two screens, without
and with a hanging protocol, with the Rows and Columns menus, a hanging
protocol's dictionary, the studies kept on their screen, the order by study
date off and reversed, no stretching and the 2D viewer's toolbar panel. The
frames each window is moved to, in order, the preference written, the key
window, the series lists rebuilt and the grid kept for the next tiling must be
identical.

    python3 tests/test-viewer-tiling-layout-equivalence.py [--reference REV] [--dump DIR]
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

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = '4b75f5b1f26e5a173cccbe5d6a5c2b5eaf3544ec'
LAYOUT = 'Modules/IsiXImaging/Sources/ViewerWorkspace/ViewerTilingLayout.swift'

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


def method(source, signature):
    start = source.find(signature)
    if start < 0:
        sys.exit(f'FAIL: {signature.strip()!r} is not in AppController.swift at {args.reference}')
    # Back to the start of the line, attributes included.
    start = source.rfind('\n', 0, start) + 1
    end = source.index('\n    }\n', start) + len('\n    }\n')
    return source[start:end]


objc_start = reference.index('fileprivate enum ObjC {')
objc = reference[objc_start:reference.index('\n}\n', objc_start) + 3]
methods = [method(reference, signature) for signature in (
    'private func idSendBool(', 'private func idSendInteger(', 'private func idSendVoid(', 'private func idSendObject(',
    'private func idSendSetWindowFrame(', 'private func idSendCompare(', 'private func idIsEqualToString(',
    'private func idStudyInstanceUID(', 'func displayViewers(_ viewers: NSArray!', '@objc func orderedScreens() -> NSArray! {',
    'func currentRowForViewer(', 'func windowCenter(', 'public func tileWindows(_ sender: Any!, windows viewersList',
)]
old = '\n'.join(methods)
old = re.sub(r'@objc\([^)]*\)\s*', '', old)
old = re.sub(r'@objc\s+', '', old)
old = re.sub(r'\bpublic\s+', '', old)
for before, after in ((r'\bNSWindowController\b', 'FakeController'), (r'\bViewerController\b', 'FakeController'),
                      (r'\bNSWindow\b', 'FakeWindow'), (r'\bNSScreen\b', 'FakeScreen'),
                      (r'UserDefaults\.standard', 'FakeDefaults.standard'),
                      (r'AppController\.shared\(\)\?\.', 'Host.shared.'), (r'\bAppController\.', 'Host.'),
                      (r'WindowLayoutManager\.shared\(\)', 'FakeLayoutManager.current'),
                      (r'\b(?:DCMView|ToolbarPanelController|OSIWindowController)\.', 'Stub.')):
    old = re.sub(before, after, old)

SCENARIOS = r'''
import AppKit

/// A screen: its frame, visible frame, and the areas the tiling fills with and
/// without the floating panels.
struct ScenarioScreen { let frame: CGRect; let visible: CGRect; let grid: CGRect; let plain: CGRect }

final class ScenarioViewer {
    let name: String
    var frame: CGRect
    var visible: Bool
    let key: Bool
    var screen: Int?
    let study: String?
    let date: Date?
    init(name: String, frame: CGRect, visible: Bool, key: Bool, screen: Int?, study: String?, date: Date?) {
        self.name = name; self.frame = frame; self.visible = visible; self.key = key; self.screen = screen; self.study = study; self.date = date
    }
}

struct ScenarioStep { let count: Int; let hiddenLast: Bool; let sender: [String: Int]? }

struct Scenario {
    let name: String
    let screens: [ScenarioScreen]
    let viewers: [ScenarioViewer]
    let steps: [ScenarioStep]
    let defaults: [String: Bool]
    let protocolRows: Int32, protocolColumns: Int32, hasProtocol: Bool
    let toolbar: Bool
}

/// The screen whose frame holds the centre of `frame`, as AppKit gives a moved window its screen.
func screenIndex(of frame: CGRect, in screens: [ScenarioScreen]) -> Int? {
    let centre = CGPoint(x: frame.midX, y: frame.midY)
    return screens.firstIndex { $0.frame.contains(centre) }
}

func describe(_ rect: CGRect) -> String {
    String(format: "%.3f %.3f %.3f %.3f", Double(rect.origin.x), Double(rect.origin.y), Double(rect.size.width), Double(rect.size.height))
}

var records: [String] = []
func record(_ line: String) { records.append(line) }

struct Generator {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

func makeScenarios() -> [Scenario] {
    let landscape = ScenarioScreen(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visible: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                                   grid: CGRect(x: 0, y: 0, width: 1920, height: 943), plain: CGRect(x: 0, y: 0, width: 1920, height: 1055))
    let portrait = ScenarioScreen(frame: CGRect(x: 0, y: 0, width: 1080, height: 1920), visible: CGRect(x: 0, y: 0, width: 1080, height: 1895),
                                  grid: CGRect(x: 152, y: 0, width: 928, height: 1783), plain: CGRect(x: 0, y: 0, width: 1080, height: 1895))
    let right = ScenarioScreen(frame: CGRect(x: 1920, y: -200, width: 2560, height: 1440), visible: CGRect(x: 1920, y: -200, width: 2560, height: 1415),
                               grid: CGRect(x: 2072, y: -200, width: 2408, height: 1303), plain: CGRect(x: 1920, y: -200, width: 2560, height: 1415))
    let layouts: [(String, [ScenarioScreen])] = [("landscape", [landscape]), ("portrait", [portrait]), ("two", [landscape, right])]
    let modes = ["plain", "protocol", "smallProtocol", "rowsMenu", "columnsMenu", "protocolDictionary", "studies", "noDate",
                 "reversedDate", "noStretch", "toolbar", "rowsAndColumns"]
    let dates = [Date(timeIntervalSinceReferenceDate: 600_000_000), Date(timeIntervalSinceReferenceDate: 700_000_000), nil]
    var scenarios: [Scenario] = []
    var generator = Generator(state: 1692)
    for (layoutName, screens) in layouts {
        for mode in modes {
            for count in 1...16 {
                var viewers: [ScenarioViewer] = []
                for i in 0..<count {
                    let screen = generator.next(screens.count)
                    let area = screens[screen].visible
                    let width = CGFloat(400 + generator.next(400)), height = CGFloat(300 + generator.next(300))
                    let frame = CGRect(x: area.minX + CGFloat(generator.next(Int(area.width - width))),
                                       y: area.minY + CGFloat(generator.next(Int(area.height - height))), width: width, height: height)
                    let studyNumber = mode == "studies" ? generator.next(3) : (generator.next(8) == 0 ? 2 : 0)
                    let study: String? = (mode == "studies" && generator.next(9) == 0) ? nil : "1.2.840.\(studyNumber)"
                    viewers.append(ScenarioViewer(name: "v\(i)", frame: frame, visible: true, key: i == min(2, count - 1), screen: screen,
                                                  study: study, date: dates[studyNumber]))
                }
                var sender: [String: Int]? = nil
                switch mode {
                case "rowsMenu": sender = ["rows": 2]
                case "columnsMenu": sender = ["columns": 3]
                case "protocolDictionary": sender = ["Rows": 3, "Columns": 2]
                case "rowsAndColumns": sender = ["rows": 2, "columns": 2]
                default: break
                }
                var steps: [ScenarioStep] = []
                if count > 1 { steps.append(ScenarioStep(count: count - 1, hiddenLast: false, sender: sender)) }
                steps.append(ScenarioStep(count: count, hiddenLast: count > 1, sender: sender))
                let defaults = ["KeepStudiesTogetherOnSameScreen": mode == "studies",
                                "tileWindowsOrderByStudyDate": mode != "noDate",
                                "reversedTileWindowsOrderByStudyDate": mode == "reversedDate",
                                "StrechWindows": mode != "noStretch",
                                "syncPreviewList": true, "COPYSETTINGS": true, "UseDBScreenAtLast": false]
                let hasProtocol = mode == "protocol" || mode == "smallProtocol"
                scenarios.append(Scenario(name: "\(layoutName) \(mode) \(count)", screens: screens, viewers: viewers, steps: steps,
                                          defaults: defaults, protocolRows: mode == "smallProtocol" ? 4 : 2,
                                          protocolColumns: mode == "smallProtocol" ? 4 : 3, hasProtocol: hasProtocol,
                                          toolbar: mode == "toolbar"))
            }
        }
    }
    return scenarios
}
'''

REFERENCE_MAIN = r'''
import AppKit

let HorosObjCExceptionKey = "HorosObjCException"
enum HorosObjCException { static func perform(_ block: () throws -> Void) throws { try block() } }
func _N2LogExceptionImpl(_ e: NSException, _ b: Bool, _ s: String) {}
func screenFrame() -> NSRect { .zero }
var delayedTileWindows: Int32 = 1
var accumulateAnimations: ObjCBool = false
var accumulateAnimationsArray: NSMutableArray! = nil

enum Stub {
    static func setDontListenToSyncMessage(_ b: Bool) {}
    static func checkForValidToolbar() {}
    static func setDontEnterMagneticFunctions(_ b: Bool) {}
    static func setDontEnterWindowDidChangeScreen(_ b: Bool) {}
}

final class FakePanel { func setThumbnailsView(_ v: Any?, viewer: Any?) {} }
func thumbnailsListPanelAt(_ index: Int) -> FakePanel? { nil }

final class FakeDefaults {
    static let standard = FakeDefaults()
    var values: [String: Bool] = [:]
    func bool(forKey key: String) -> Bool { values[key] ?? false }
    func set(_ value: Any?, forKey key: String) {
        if key == "LastWindowsTilingRowsColumns" { record("LastWindowsTilingRowsColumns \(value ?? "nil")") }
    }
}

final class FakeLayoutManager {
    static var current: FakeLayoutManager? = nil
    var rows: Int32 = 0, columns: Int32 = 0
    var currentHangingProtocol: NSDictionary? = nil
    func windowsRows() -> Int32 { rows }
    func windowsColumns() -> Int32 { columns }
}

final class FakeScreen: NSObject {
    static var screens: [FakeScreen] = []
    let model: ScenarioScreen
    init(_ model: ScenarioScreen) { self.model = model }
    var frame: NSRect { model.frame }
    var visibleFrame: NSRect { model.visible }
}

final class FakeWindow: NSObject {
    let viewer: ScenarioViewer
    init(_ viewer: ScenarioViewer) { self.viewer = viewer }
    var frame: NSRect { viewer.frame }
    var isVisible: Bool { viewer.visible }
    var isKeyWindow: Bool { viewer.key }
    var screen: FakeScreen? { viewer.screen.map { FakeScreen.screens[$0] } }
    func makeKeyAndOrderFront(_ sender: Any?) { record("makeKey \(viewer.name)") }
}

final class FakeView { func becomeMainWindow() {} }

final class FakeStudy: NSObject {
    let viewer: ScenarioViewer
    init(_ viewer: ScenarioViewer) { self.viewer = viewer }
    @objc func date() -> AnyObject? { viewer.date.map { $0 as NSDate } }
}

final class FakeImage: NSObject {
    let viewer: ScenarioViewer
    init(_ viewer: ScenarioViewer) { self.viewer = viewer }
    override func value(forKeyPath keyPath: String) -> Any? {
        precondition(keyPath == "series.study.studyInstanceUID")
        return viewer.study.map { $0 as NSString }
    }
}

final class FakeController: NSObject {
    let model: ScenarioViewer
    let window: FakeWindow?
    init(_ model: ScenarioViewer) { self.model = model; self.window = FakeWindow(model) }
    @objc func setWindowFrame(_ frame: NSRect, showWindow: Bool, animate: Bool) {
        record("frame \(model.name) \(describe(frame))")
        model.frame = frame
        model.visible = true
        model.screen = screenIndex(of: frame, in: FakeScreen.screens.map(\.model))
    }
    @objc func currentStudy() -> AnyObject? { FakeStudy(model) }
    @objc func fileList() -> AnyObject? { NSArray(object: FakeImage(model)) }
    @objc func propagateSettings() { record("propagateSettings \(model.name)") }
    @objc func syncThumbnails() { record("syncThumbnails \(model.name)") }
    func buildMatrixPreview(_ showSelection: Bool) { record("buildMatrixPreview \(model.name) \(showSelection)") }
    func imageView() -> FakeView? { FakeView() }
    func redrawToolbar() {}
    static func frontMostDisplayed2DViewer(for screen: Any?) -> FakeController? { nil }
}

final class Host: NSObject {
    static var shared = Host()
    var lastColumns: Int32 = 0, lastRows: Int32 = 0, lastCount: Int32 = 0
    var dbWindow: FakeWindow? = nil
    var screenList: [FakeScreen] = []
    func viewerScreens() -> [Any]! { screenList }
    static var toolbar = false
    static func checkForPreferencesUpdate(_ b: Bool) {}
    static func usefullRect(for screen: FakeScreen?, showFloatingWindows: Bool) -> NSRect {
        showFloatingWindows ? (screen?.model.grid ?? .zero) : (screen?.model.plain ?? .zero)
    }
    static func usefullRect(for screen: FakeScreen?) -> NSRect { usefullRect(for: screen, showFloatingWindows: true) }

%s
}

%s

for scenario in makeScenarios() {
    record("scenario \(scenario.name)")
    FakeScreen.screens = scenario.screens.map { FakeScreen($0) }
    Host.shared = Host()
    let host = Host.shared
    host.screenList = FakeScreen.screens
    FakeDefaults.standard.values = scenario.defaults
    let manager = FakeLayoutManager()
    manager.rows = scenario.protocolRows; manager.columns = scenario.protocolColumns
    manager.currentHangingProtocol = scenario.hasProtocol ? NSDictionary() : nil
    FakeLayoutManager.current = manager
    let controllers = scenario.viewers.map { FakeController($0) }
    for step in scenario.steps {
        if step.hiddenLast { scenario.viewers[step.count - 1].visible = false }
        let list = NSMutableArray(array: Array(controllers.prefix(step.count)))
        let sender: Any? = step.sender.map { NSDictionary(dictionary: $0) }
        host.tileWindows(sender, windows: list, display2DViewerToolbar: scenario.toolbar, displayThumbnailsList: false)
        record("last \(host.lastRows) \(host.lastColumns) \(host.lastCount)")
    }
}
print(records.joined(separator: "\n"))
''' % (old, objc)

CURRENT_MAIN = r'''
import AppKit

/// What ViewerWindowArranger does with the layout, over the scenario's models.
for scenario in makeScenarios() {
    record("scenario \(scenario.name)")
    var layout = ViewerTilingLayout()
    let screens = scenario.screens
    let defaults = scenario.defaults
    for step in scenario.steps {
        if step.hiddenLast { scenario.viewers[step.count - 1].visible = false }
        let models = Array(scenario.viewers.prefix(step.count))
        let ordered = ViewerTilingLayout.orderedScreens(visibleFrames: screens.map(\.visible))
        let options = ViewerTilingLayout.Options(rows: scenario.protocolRows, columns: scenario.protocolColumns,
                                                 hasHangingProtocol: scenario.hasProtocol,
                                                 keepsStudiesOnSameScreen: defaults["KeepStudiesTogetherOnSameScreen"] ?? false,
                                                 stretchesWindows: defaults["StrechWindows"] ?? false,
                                                 ordersByStudyDate: defaults["tileWindowsOrderByStudyDate"] ?? false,
                                                 reversesStudyDateOrder: defaults["reversedTileWindowsOrderByStudyDate"] ?? false)
        let viewers = models.map { model in
            ViewerTilingLayout.Viewer(frame: model.frame, isVisible: model.visible, isKey: model.key,
                                      orderedScreenIndex: model.screen.flatMap { screen in ordered.firstIndex(of: screen) },
                                      screenVisibleOriginY: model.screen.map { screens[$0].visible.origin.y } ?? 0,
                                      tilingScreenIndex: model.screen,
                                      studyInstanceUID: options.keepsStudiesOnSameScreen ? model.study : nil,
                                      studyDate: options.ordersByStudyDate ? model.date : nil)
        }
        let tilingScreens = screens.map {
            ViewerTilingLayout.Screen(visibleFrame: $0.visible, gridRect: $0.grid, rowRect: scenario.toolbar ? $0.grid : $0.plain)
        }
        var request: ViewerTilingLayout.Request? = nil
        if let sender = step.sender {
            request = ViewerTilingLayout.Request(rows: sender["rows"].map { Int32($0) }, columns: sender["columns"].map { Int32($0) },
                                                 protocolRows: sender["Rows"].map { Int32($0) }, protocolColumns: sender["Columns"].map { Int32($0) })
        }
        let arrangement = layout.arrange(viewers, on: tilingScreens, request: request, options: options)
        for placement in arrangement.placements {
            let model = models[placement.viewer]
            record("frame \(model.name) \(describe(placement.frame))")
            model.frame = placement.frame
            model.visible = true
            model.screen = screenIndex(of: placement.frame, in: screens)
        }
        record("LastWindowsTilingRowsColumns \(layout.lastRowsColumns(viewerScreens: screens.count))")
        if !arrangement.order.isEmpty, let key = arrangement.keyViewer {
            record("makeKey \(models[key].name)")
            record("propagateSettings \(models[key].name)")
            for place in arrangement.order.reversed() where place != key {
                record("buildMatrixPreview \(models[place].name) \(arrangement.hidden.contains(place))")
            }
            record("buildMatrixPreview \(models[key].name) true")
            if defaults["syncPreviewList"] ?? false { record("syncThumbnails \(models[key].name)") }
        }
        record("last \(layout.lastRows) \(layout.lastColumns) \(layout.lastCount)")
    }
}
print(records.joined(separator: "\n"))
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-tiling-layout-') as tmp:
    folder = Path(tmp)
    results = {}
    for label, sources in (('reference', {'main.swift': REFERENCE_MAIN}),
                           ('current', {'main.swift': CURRENT_MAIN, 'ViewerTilingLayout.swift': (ROOT / LAYOUT).read_text()})):
        work = folder / label
        work.mkdir()
        (work / 'Scenarios.swift').write_text(SCENARIOS)
        for name, text in sources.items():
            (work / name).write_text(text)
        program = work / 'program'
        build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', *sorted(map(str, work.glob('*.swift'))), '-o', str(program)],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr[-4000:])
            sys.exit(f'FAIL: the {label} program does not compile')
        run = subprocess.run([str(program)], capture_output=True, text=True, timeout=300)
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
frames = sum(1 for line in expected if line.startswith('frame '))
if expected != got:
    print(f'FAIL: ViewerTilingLayout differs from AppController at {args.reference[:9]}:')
    for line in list(difflib.unified_diff(expected, got, 'reference', 'current', lineterm='', n=3))[:80]:
        print('  ' + line)
    sys.exit(1)
if frames < 1000:
    sys.exit(f'FAIL: only {frames} frames were compared; the scenarios no longer tile')
print(f'PASS: {scenarios} scenarios, {frames} window frames and {len(expected)} records identical to '
      f'AppController at {args.reference[:9]}')
