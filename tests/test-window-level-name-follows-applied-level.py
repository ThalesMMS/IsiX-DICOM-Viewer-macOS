#!/usr/bin/env python3
"""A window level's name follows the level a 3D window applies.

A window that shows the name of its window level in the title of its presets
menu keeps that name apart from the level. Three places set the level and
left a name that no longer said it:

- The 2D orthogonal reformation window shows the images of its 2D viewer and
  shares their level with it: every level it applies goes to the 2D viewer
  too. The name did not go: after a preset chosen in the orthogonal window,
  or a drag in one of its views, the 2D viewer's menu kept the name of a
  level that was no longer on its image.
- The same window opened under «Other» whatever the level its 2D viewer was
  on, although it opens on that viewer's images at that viewer's level.
- The sheet that sets the level and width of a 3D window by hand applied
  them and left the name of the preset chosen before.

Checked here on the windows' own code, compiled with stand-ins for the 2D
viewer, the views, the popup, the preferences and the sheet's fields:

1. the orthogonal window opens under the name of its 2D viewer, and under
   «Other» when that viewer has none or there is no viewer;
2. a preset, «Default WL & WW» or «Full dynamic» chosen in its menu gives the
   2D viewer the level and the name; «Other», which applies no level, names
   the window alone;
3. a view of the window that ends a press which changed its level, or a
   preset's hot key in it, names the level in both windows; a press that left
   the level names neither;
4. OK in the Set WL/WW sheet with another level or width names the level
   «Other» and tells the menus; OK with the values the sheet opened with,
   however they are written, Cancel, and a window that keeps no name leave
   the name;
5. in the sources: the orthogonal window's views still give their level to
   the 2D viewer, the launcher still opens the window at the 2D viewer's
   level, the 2D viewer titles its menu with the name it is given, and the
   volume rendering window, whose nib has the sheet, titles its menu with
   the name it keeps.

`<git revision>` as an optional argument reads the sources from that
revision: that is the negative control.

Exit 2 when there is no Swift compiler.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def text(relative):
    if revision is None:
        return (root / relative).read_text(encoding='utf-8')
    return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                   stderr=subprocess.DEVNULL).decode('utf-8')


def between(source, start_marker, end_marker):
    start = source.index(start_marker)
    return source[start:source.index(end_marker, start)]


viewer = text('Horos/Sources/OrthogonalMPRViewer.swift')
# The window's level, its menu and the name it keeps.
menu = between(viewer, '    @objc(setWLWW::)\n', '    @objc(OpacityChanged:)\n')
# What the initializer does for the menu: the name, the observer, the announcement.
opening = between(viewer, '        // WL/WW Menu', '        // Opacity Menu')

shared = text('Horos/Sources/Window3DController+WindowLevel.swift')
sheet = between(shared, '    @objc(endSetWLWW:)\n', '    /// Closes the sheet that names a preset')
helper = re.search(r'    fileprivate final func announceWindowLevelName\(\) \{\n.*?\n    \}\n', shared, re.S)
sheet += helper.group(0) if helper else ''
announce = shared[shared.index('@objc private protocol WindowLevelNameKeeping {'):]
announce = announce[:announce.index('\n}\n', announce.index('@MainActor func announceWindowLevelPreset(')) + len('\n}\n')]

program = r'''
import AppKit

extension NSNotification.Name { static let OsirixUpdateWLWWMenu = NSNotification.Name("UpdateWLWWMenu") }

// Stand-ins: the stored presets, the popup of the toolbar, an image and its view.
struct Preset { var level: Double, width: Double }
final class Store { var presets: [(String, Preset)] = [("CT - Abdomen", Preset(level: 40, width: 350)), ("CT - Bone", Preset(level: 300, width: 1500))] }
enum ImagePresetPreferences { case windowLevelPresets }
enum ReconstructionPreferences {
    static func windowLevelMenuTitles(in store: Store) -> [String] { store.presets.enumerated().map { "\($0.offset + 1) - \($0.element.0)" } }
    static func preset(_ name: String!, of kind: ImagePresetPreferences, in store: Store) -> Preset? { store.presets.first { $0.0 == name }?.1 }
}
enum WindowLevel {
    static func presetName(fromMenuTitle title: String) -> String? { title.range(of: " - ").map { String(title[$0.upperBound...]) } }
}
func titleOf(_ sender: Any?) -> String? { (sender as? NSMenuItem)?.title }
final class Popup { var menu: NSMenu? = NSMenu() }
final class DCMPix {
    var wl: Float, ww: Float
    var savedWL: Float = 50, savedWW: Float = 500
    init(_ wl: Float, _ ww: Float) { self.wl = wl; self.ww = ww }
}
final class DCMView {
    var curDCM: DCMPix! = DCMPix(300, 1500)
    var startWL: Float = 300, startWW: Float = 1500
    var controller: AnyObject?
    init(controller: AnyObject?) { self.controller = controller }
    func is2DViewer() -> Bool { false }
    func windowController() -> Any! { controller }
    /// The level a drag leaves on the image.
    func dragged(to wl: Float, _ ww: Float) -> DCMView { curDCM?.wl = wl; curDCM?.ww = ww; return self }
}
nonisolated(unsafe) var posted: [String?] = []
func inputPost(_ name: NSNotification.Name, object: Any?, userInfo: NSDictionary? = nil) {
    NotificationCenter.default.post(name: name, object: object, userInfo: userInfo as? [AnyHashable: Any])
}

/// The 2D viewer: the level of its image, and the name its menu is titled with.
final class ViewerController: NSObject {
    var level: [Float] = [300, 1500]
    var name: String?
    var title = ""
    init(name: String?) { self.name = name; self.title = name ?? "" }
    func setWL(_ wl: Float, ww: Float) { level = [wl, ww] }
    @objc(setCurWLWWMenu:) func setCurWLWWMenu(_ s: String!) { name = s; title = s ?? "" }
    @objc(curWLWWMenu) func curWLWWMenu() -> String! { name }
}
/// The object of the nib that owns the three views: a level it is given goes to the 2D viewer.
final class Controller {
    weak var viewer2D: ViewerController?
    func setWLWW(_ wl: Float, _ ww: Float) { viewer2D?.setWL(wl, ww: ww) }
    func setCurWLWWMenu(_ name: String!) {}
}

// The fields and the sheet of Set WL/WW.
final class Field { var stringValue = ""; func selectText(_ sender: Any?) {} }
final class Sheet { var ended: [Int] = []; func orderOutAndEndSheet(returnCode: NSApplication.ModalResponse) { ended.append(returnCode.rawValue) } }
enum ViewerSender { static func tag(_ sender: Any?) -> Int { (sender as? NSNumber)?.intValue ?? 0 } }
@MainActor enum Window3DWindowLevelSheet {
    static var savedLevel: Float = 0
    static var savedWidth: Float = 0
}

@MainActor class Window3DController: NSObject {
    var window: NSWindow? { nil }
    var currentWLWWMenu: String?
    let wlsetOutlet: Field? = Field(), wwsetOutlet: Field? = Field()
    let setWLWWWindowOutlet: Sheet? = Sheet()
    var applied: [[Float]] = []
    @objc(setWLWW::) dynamic func setWLWW(_ wl: Float, _ ww: Float) { applied.append([wl, ww]) }
}
extension Window3DController {
SHEET
}

final class OrthogonalMPRViewer: Window3DController {
    let preferenceStore = Store()
    let popup = Popup()
    let controller: Controller? = Controller()
    var viewerIvar: ViewerController?
    var curWLWWMenuIvar: String? {
        get { currentWLWWMenu }
        set { currentWLWWMenu = newValue }
    }
    func wlwwPopup() -> Popup! { popup }
    func copyMenusOfOlderSDK() {}

    /// The part of the initializer that names the level and builds the menu.
    init(_ vC: ViewerController!) {
        super.init()
        viewerIvar = vC
        controller?.viewer2D = vC
        let nc = NotificationCenter.default
OPENING
    }

MENU
}

/// A window with the sheet: it titles its menu with the name it keeps, when the menus are told.
final class SheetWindow: Window3DController {
    var title = ""
    @objc func menusTold(_ note: Notification) { title = currentWLWWMenu ?? "" }
}

ANNOUNCE

nonisolated(unsafe) var failed = false
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { fputs("FAIL: \(what) (line \(line))\n", stderr); failed = true }
}

@MainActor func scenario() {
let center = NotificationCenter.default
let listener = center.addObserver(forName: .OsirixUpdateWLWWMenu, object: nil, queue: nil) { posted.append($0.object as? String) }
func shown(_ window: OrthogonalMPRViewer) -> String { "\(window.curWLWWMenuIvar ?? "nil") / \(window.popup.menu?.item(at: 0)?.title ?? "nil")" }
func shown(_ viewer: ViewerController) -> String { "\(viewer.name ?? "nil") / \(viewer.title) at \(viewer.level)" }

// 1. The window opens under the name of its 2D viewer.
let viewer2D = ViewerController(name: "CT - Bone")
posted = []
let window = OrthogonalMPRViewer(viewer2D)
check(shown(window) == "CT - Bone / CT - Bone", "the window does not open under the name of its 2D viewer: \(shown(window))")
check(posted == ["CT - Bone"], "the window does not announce the name it opens under: \(posted)")
check(shown(viewer2D) == "CT - Bone / CT - Bone at [300.0, 1500.0]", "opening the window changed its 2D viewer: \(shown(viewer2D))")
let unnamed = OrthogonalMPRViewer(ViewerController(name: nil)), alone = OrthogonalMPRViewer(nil)
check(shown(unnamed) == "Other / Other", "a 2D viewer without a name does not leave «Other»: \(shown(unnamed))")
check(shown(alone) == "Other / Other", "a window without a 2D viewer does not open under «Other»: \(shown(alone))")
center.removeObserver(unnamed)
center.removeObserver(alone)

// 2. A choice in the window's menu.
func choose(_ title: String) { _ = window.perform(Selector(("ApplyWLWW:")), with: NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
posted = []
choose("1 - CT - Abdomen")
check(shown(window) == "CT - Abdomen / CT - Abdomen", "a preset chosen in the window is not its name: \(shown(window))")
check(shown(viewer2D) == "CT - Abdomen / CT - Abdomen at [40.0, 350.0]", "the 2D viewer got the level of the preset without its name: \(shown(viewer2D))")
check(posted == ["CT - Abdomen"], "the choice is not announced once, by its name: \(posted)")
choose("Other")
check(shown(window) == "Other / Other", "«Other» chosen in the window is not its name: \(shown(window))")
check(shown(viewer2D) == "CT - Abdomen / CT - Abdomen at [40.0, 350.0]", "«Other», which applies no level, renamed the 2D viewer's: \(shown(viewer2D))")
choose("Full dynamic")
check(shown(viewer2D) == "Full dynamic / Full dynamic at [0.0, 0.0]", "the 2D viewer got the full dynamic without its name: \(shown(viewer2D))")
choose("Default WL & WW")
check(shown(window) == "Default WL & WW / Default WL & WW" && viewer2D.name == "Default WL & WW" && viewer2D.title == "Default WL & WW",
      "the 2D viewer got the default level without its name: \(shown(window)), \(shown(viewer2D))")

// 3. The window's views, through the function they announce by.
choose("2 - CT - Bone")
check(shown(viewer2D) == "CT - Bone / CT - Bone at [300.0, 1500.0]", "the 2D viewer is not back on the preset: \(shown(viewer2D))")
// A press that scrolled or zoomed.
announceWindowLevelPreset("Other", from: DCMView(controller: window), endingPress: true)
check(shown(window) == "CT - Bone / CT - Bone" && viewer2D.name == "CT - Bone", "a press that left the level renamed it: \(shown(window)), \(shown(viewer2D))")
announceWindowLevelPreset("Other", from: DCMView(controller: window).dragged(to: 320, 1500), endingPress: true)
check(shown(window) == "Other / Other", "a drag of the level in a view of the window did not rename it: \(shown(window))")
check(viewer2D.name == "Other" && viewer2D.title == "Other", "a drag of the level in a view of the window left the 2D viewer the name of another level: \(shown(viewer2D))")
announceWindowLevelPreset("CT - Abdomen", from: DCMView(controller: window))
check(shown(window) == "CT - Abdomen / CT - Abdomen" && viewer2D.name == "CT - Abdomen" && viewer2D.title == "CT - Abdomen",
      "a preset's hot key in a view of the window does not name the level in both windows: \(shown(window)), \(shown(viewer2D))")
center.removeObserver(window)

// 4. The Set WL/WW sheet.
let sheetWindow = SheetWindow()
center.addObserver(sheetWindow, selector: #selector(SheetWindow.menusTold(_:)), name: .OsirixUpdateWLWWMenu, object: nil)
func sheet(_ window: Window3DController, opened: [Float], fields: [String], tag: Int) {
    Window3DWindowLevelSheet.savedLevel = opened[0]
    Window3DWindowLevelSheet.savedWidth = opened[1]
    window.wlsetOutlet?.stringValue = fields[0]
    window.wwsetOutlet?.stringValue = fields[1]
    window.applied = []
    posted = []
    _ = window.perform(Selector(("endSetWLWW:")), with: NSNumber(value: tag))
}
sheetWindow.currentWLWWMenu = "CT - Bone"
sheetWindow.title = "CT - Bone"
sheet(sheetWindow, opened: [300, 1500], fields: ["300", "1500"], tag: 1)
check(sheetWindow.currentWLWWMenu == "CT - Bone" && sheetWindow.applied == [[300, 1500]], "OK with the level the sheet opened with renamed it: \(sheetWindow.currentWLWWMenu ?? "nil"), \(sheetWindow.applied)")
sheet(sheetWindow, opened: [300, 1500], fields: [" 300.0", "1500,00"], tag: 1)
check(sheetWindow.currentWLWWMenu == "CT - Bone", "OK with the same level written another way renamed it: \(sheetWindow.currentWLWWMenu ?? "nil")")
sheet(sheetWindow, opened: [713.4567, 1105.25], fields: ["713.4567", "1105.25"], tag: 1)
check(sheetWindow.currentWLWWMenu == "CT - Bone", "OK with the fractional level the sheet printed renamed it: \(sheetWindow.currentWLWWMenu ?? "nil")")
sheet(sheetWindow, opened: [300, 1500], fields: ["40", "350"], tag: 0)
check(sheetWindow.currentWLWWMenu == "CT - Bone" && sheetWindow.title == "CT - Bone" && sheetWindow.applied == [[300, 1500]],
      "Cancel does not leave the level and the name the sheet opened with: \(sheetWindow.currentWLWWMenu ?? "nil"), \(sheetWindow.applied)")
sheet(sheetWindow, opened: [300, 1500], fields: ["40", "1500"], tag: 1)
check(sheetWindow.applied == [[40, 1500]], "OK does not apply the fields: \(sheetWindow.applied)")
check(sheetWindow.currentWLWWMenu == "Other" && sheetWindow.title == "Other", "OK with another level left the name of the level before: \(sheetWindow.currentWLWWMenu ?? "nil") / \(sheetWindow.title)")
check(posted == ["Other"], "the menus are not told once that the level is «Other»: \(posted)")
sheetWindow.currentWLWWMenu = "CT - Bone"
sheet(sheetWindow, opened: [300, 1500], fields: ["300", "1499.5"], tag: 1)
check(sheetWindow.currentWLWWMenu == "Other" && sheetWindow.title == "Other", "OK with another width left the name of the level before: \(sheetWindow.currentWLWWMenu ?? "nil") / \(sheetWindow.title)")
// A window that keeps no name.
let nameless = SheetWindow()
sheet(nameless, opened: [300, 1500], fields: ["40", "350"], tag: 1)
check(nameless.currentWLWWMenu == nil && posted.isEmpty && nameless.applied == [[40, 350]], "a window that keeps no name was given one: \(nameless.currentWLWWMenu ?? "nil"), \(posted)")
check(sheetWindow.setWLWWWindowOutlet?.ended == [1, 1, 1, 0, 1, 1], "the sheet does not end with the tag of its button: \(sheetWindow.setWLWWWindowOutlet?.ended ?? [])")

center.removeObserver(sheetWindow)
center.removeObserver(listener)
}
MainActor.assumeIsolated { scenario() }
exit(failed ? 1 : 0)
'''.replace('SHEET', sheet).replace('OPENING', opening).replace('MENU', menu).replace('ANNOUNCE', announce)

# 5. The sources the scenarios stand on.
orthogonal_controller = text('Horos/Sources/OrthogonalMPRController.swift')
pushed = between(orthogonal_controller, '    @objc(setWLWW::)\n', '    @objc(setCurWLWWMenu:)\n')
if 'viewerController?.setWL(iwl, ww: iww)' not in pushed:
    failures.append('the views of the orthogonal window no longer give their level to the 2D viewer')
if 'controller?.setWLWW(iwl, iww)' not in between(menu, 'func setWLWW(', '\n    }\n'):
    failures.append('the orthogonal window no longer applies its level through the object that gives it to the 2D viewer')
launcher = text('Horos/Sources/ThreeDViewerLauncher.swift')
opened = between(launcher, '    func orthogonalMPRWindow() -> OrthogonalMPRViewer? {', '\n    }\n')
if not re.search(r'let swl = viewer\.horos_imageView\?\.curWL \?\? 0\n(?:.*\n)*?\s+made\?\.setWLWW\(swl, sww\)', opened):
    failures.append('the orthogonal window is no longer opened at the level of its 2D viewer, whose name it opens under')
viewer2d = text('Horos/Sources/ViewerController+WindowLevel.swift')
named = between(viewer2d, '    @objc(setCurWLWWMenu:)\n', '\n    }\n')
if 'horos_curWLWWMenu = s' not in named or 'horos_wlwwPopup?.setTitle(horos_curWLWWMenu ?? "")' not in named:
    failures.append('the 2D viewer no longer titles its menu with the name it is given')
volume = text('Horos/Sources/VRController+ColourTables.swift')
titled = between(volume, '    @objc(UpdateWLWWMenu:)\n', '\n    }\n')
if 'menu.item(at: 0)?.title = horos_curWLWWMenu ?? ""' not in titled or re.search(r'note\??\.object', titled):
    failures.append('the volume rendering window does not title its window level menu with the name it keeps')
if 'override func setWLWW(_ wl: Float, _ ww: Float)' not in volume or 'override func getWLWW(' not in volume:
    failures.append('the volume rendering window no longer sets and reads the level the sheet works on')

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    sys.stderr.write('skipped: no Swift compiler (xcrun swiftc)\n')
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-wlww-name-follows-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(program, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-o', str(folder / 'names'),
                            str(folder / 'main.swift'), str(root / 'Horos/Sources/WindowLevelText.swift')],
                           capture_output=True, text=True)
    if built.returncode != 0:
        failures.append("the windows' code does not compile with its stand-ins:\n" + built.stderr[-4000:])
    else:
        ran = subprocess.run([str(folder / 'names')], capture_output=True, text=True)
        if ran.returncode != 0:
            failures.append(f"the windows' names (exit {ran.returncode}):\n" + ran.stderr[-4000:].strip())

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print('PASS: the orthogonal window opens under the name of its 2D viewer and gives it the name of every level it applies, '
      'and the Set WL/WW sheet of a 3D window names another level «Other»')
