#!/usr/bin/env python3
"""The 3D MPR window titles its window level menu with the name of its own views.

A window tells the others that the presets menu of the window levels may have
changed with one notification, whose object is the name of the announcing
window's current preset; it does not say which window sent it. The 3D MPR
window titles its menu with the name it keeps, and learnt that name only from
a choice in its own menu: after a drag of the window level or a preset's hot
key in one of its views, the menu kept the name of a level that was no longer
on screen.

An image view that ends a press or a preset's hot key announces through one
function, shared by the windows that keep such a name: it tells the view's own
window before the notification goes out, when that window answers
-setCurWLWWMenu: and is not a 2D viewer, which its views tell while the level
changes. A press tells the window only when it changed the level it started
from: a scroll or a zoom leaves the name the window has, which the level may
not find again (the default of the series, on a resliced image).

Checked here, on the window's own code (-createWLWWMenuItems, -UpdateWLWWMenu:
and -setCurWLWWMenu: of MPRController.swift) and the views' announcement
(announceWindowLevelPreset, of Window3DController+WindowLevel.swift), compiled
with stand-ins for the popup, the preferences, the image and its view:

1. a notification with another name, or with none, leaves the window's name
   and the title of its menu, and still builds the menu again from the stored
   presets;
2. a view of another window, of no window, of a window that does not answer
   the message and of a 2D viewer changes nothing in this window, the 2D viewer
   is not told, and each notification still goes out;
3. a view of the window that ends a press which changed its level gives the
   window its name, and the menu shows it; a press that left the level, and a
   view without an image, name nothing; a preset's hot key names the preset
   whatever the level the last press started from;
4. in the sources, the two releases of the mouse of the image view announce
   as the end of a press and the window level hot key as a preset, the
   function is no longer in the file of one window, and a choice in the
   window's own menu still sets the name it announces.

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


controller = text('Horos/Sources/MPRController.swift')
start = controller.index('    @objc(createWLWWMenuItems)\n')
menu = controller[start:controller.index('    @objc(ApplyWLWW:)\n', start)]

shared = text('Horos/Sources/Window3DController+WindowLevel.swift')
KEEPER = '@objc private protocol WindowLevelNameKeeping {'
ANNOUNCE = '@MainActor func announceWindowLevelPreset('
if KEEPER in shared and ANNOUNCE in shared:
    start = shared.index(KEEPER)
    announce = shared[start:shared.index('\n}\n', shared.index(ANNOUNCE)) + len('\n}\n')]
else:
    failures.append('the windows that keep the name of their window level have no shared way to be told it by their views')
    # What the views did for this window: the notification alone.
    announce = '''@MainActor func announceWindowLevelPreset(_ name: String?, from view: DCMView, endingPress: Bool = false) {
    inputPost(.OsirixUpdateWLWWMenu, object: name)
}
'''

program = r'''
import AppKit

extension NSNotification.Name { static let OsirixUpdateWLWWMenu = NSNotification.Name("UpdateWLWWMenu") }
// Stand-ins: the stored presets, the popup of the toolbar, an image and its view.
final class Store { var titles: [String] = [] }
enum ReconstructionPreferences { static func windowLevelMenuTitles(in store: Store) -> [String] { store.titles } }
final class Popup {
    var menu: NSMenu? = NSMenu()
    var title = ""
    func setTitle(_ title: String) { self.title = title }
}
final class DCMPix {
    var wl: Float, ww: Float
    init(_ wl: Float, _ ww: Float) { self.wl = wl; self.ww = ww }
}
final class DCMView {
    var curDCM: DCMPix!
    var startWL: Float = 40, startWW: Float = 400
    var controller: AnyObject?
    var viewer2D = false
    /// A view on an image at 40/400, where its last press started, or on none.
    init(image: Bool = true, controller: AnyObject?, viewer2D: Bool = false) {
        self.curDCM = image ? DCMPix(40, 400) : nil
        self.controller = controller
        self.viewer2D = viewer2D
    }
    func is2DViewer() -> Bool { viewer2D }
    func windowController() -> Any! { controller }
    /// The level a drag leaves on the image.
    func dragged(to wl: Float, _ ww: Float) -> DCMView { curDCM?.wl = wl; curDCM?.ww = ww; return self }
}
nonisolated(unsafe) var posted: [String?] = []
func inputPost(_ name: NSNotification.Name, object: Any?, userInfo: NSDictionary? = nil) {
    posted.append(object as? String)
    NotificationCenter.default.post(name: name, object: object, userInfo: userInfo as? [AnyHashable: Any])
}

final class MPRController: NSObject {
    let preferenceStore = Store()
    let popup = Popup()
    var curWLWWMenu: String?
    var _wlwwMenuItems: NSArray?
    var wlwwMenuItems: NSArray? {
        get { _wlwwMenuItems }
        set { _wlwwMenuItems = newValue }
    }
    func wlwwPopup() -> Popup! { popup }
    @objc(ApplyWLWW:) func ApplyWLWW(_ sender: Any!) {}

MENU
}

/// A 2D viewer, which answers the message and is told by its views elsewhere.
final class Viewer2D: NSObject {
    var told: [String?] = []
    @objc(setCurWLWWMenu:) func setCurWLWWMenu(_ name: String!) { told.append(name) }
}

ANNOUNCE

nonisolated(unsafe) var failed = false
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { fputs("FAIL: \(what) (line \(line))\n", stderr); failed = true }
}

@MainActor func scenario() {
let window = MPRController(), silent = NSObject(), viewer2D = Viewer2D()
let center = NotificationCenter.default
center.addObserver(window, selector: #selector(MPRController.UpdateWLWWMenu(_:)), name: .OsirixUpdateWLWWMenu, object: nil)
func shown() -> String { "\(window.curWLWWMenu ?? "nil") / \(window.popup.title) / \(window.popup.menu?.item(at: 0)?.title ?? "nil")" }
func titles() -> [String] { (window.popup.menu?.items ?? []).map(\.title) }

// The window opens with the name of its 2D viewer and announces it.
window.curWLWWMenu = "Default WL & WW"
center.post(name: .OsirixUpdateWLWWMenu, object: window.curWLWWMenu, userInfo: nil)
check(shown() == "Default WL & WW / Default WL & WW / Default WL & WW", "the window opens with its own name: \(shown())")

// 1. Another window announces its name, or none.
center.post(name: .OsirixUpdateWLWWMenu, object: "Other", userInfo: nil)
check(shown() == "Default WL & WW / Default WL & WW / Default WL & WW", "another window's name became this window's: \(shown())")
center.post(name: .OsirixUpdateWLWWMenu, object: nil, userInfo: nil)
check(shown() == "Default WL & WW / Default WL & WW / Default WL & WW", "a notification without a name changed this window's: \(shown())")
// The stored presets changed: the menu is built again, under the same name.
window.preferenceStore.titles = ["Bone", "Lung"]
center.post(name: .OsirixUpdateWLWWMenu, object: "Bone", userInfo: [:])
check(shown() == "Default WL & WW / Default WL & WW / Default WL & WW", "a change of the presets renamed this window's level: \(shown())")
check(titles().suffix(2) == ["Bone", "Lung"] && titles().count == 7, "the menu was not built again from the stored presets: \(titles())")

// 2. The views of other windows: one that does not answer the message, none, and a 2D viewer.
posted = []
announceWindowLevelPreset("Other", from: DCMView(controller: silent).dragged(to: 300, 1500), endingPress: true)
announceWindowLevelPreset("Lung", from: DCMView(controller: nil).dragged(to: -600, 1600), endingPress: true)
announceWindowLevelPreset("Bone", from: DCMView(controller: viewer2D, viewer2D: true).dragged(to: 300, 1500), endingPress: true)
announceWindowLevelPreset("Bone", from: DCMView(controller: viewer2D, viewer2D: true))
check(shown() == "Default WL & WW / Default WL & WW / Default WL & WW", "a view of another window renamed this window's level: \(shown())")
check(viewer2D.told.isEmpty, "the 2D viewer, which its views tell elsewhere, was told again: \(viewer2D.told)")
check(posted == ["Other", "Lung", "Bone", "Bone"], "the views of the other windows no longer announce their names: \(posted)")

// 3. The window's own views.
posted = []
// A press that scrolled or zoomed: the level is the one it started from, which
// finds no name on a resliced image.
announceWindowLevelPreset("Other", from: DCMView(controller: window), endingPress: true)
check(shown() == "Default WL & WW / Default WL & WW / Default WL & WW", "a press that left the level renamed it: \(shown())")
announceWindowLevelPreset("Other", from: DCMView(controller: window).dragged(to: 55, 400), endingPress: true)
check(shown() == "Other / Other / Other", "a drag of the level in a view of the window did not rename it: \(shown())")
announceWindowLevelPreset("Lung", from: DCMView(controller: window).dragged(to: 40, 1600), endingPress: true)
check(shown() == "Lung / Lung / Lung", "a drag of the width alone did not rename the level: \(shown())")
// A preset's hot key, to the level the last press started from.
announceWindowLevelPreset("Bone", from: DCMView(controller: window))
check(shown() == "Bone / Bone / Bone", "a preset's hot key in a view of the window is not shown: \(shown())")
announceWindowLevelPreset("Lung", from: DCMView(image: false, controller: window))
check(shown() == "Bone / Bone / Bone", "a view without an image named the window's level: \(shown())")
check(posted == ["Other", "Other", "Lung", "Bone", "Lung"], "the window's views no longer announce to the other windows: \(posted)")
// The message the views send, by its Objective-C name.
let setter = Selector(("setCurWLWWMenu:"))
check(window.responds(to: setter), "the window does not answer -setCurWLWWMenu:")
if window.responds(to: setter) { window.perform(setter, with: "Full dynamic") }
center.post(name: .OsirixUpdateWLWWMenu, object: "Other", userInfo: nil)
check(shown() == "Full dynamic / Full dynamic / Full dynamic", "the name the window is given is not the one its menu shows: \(shown())")

center.removeObserver(window)
}
MainActor.assumeIsolated { scenario() }
exit(failed ? 1 : 0)
'''.replace('MENU', menu).replace('ANNOUNCE', announce)

# 4. The sources: who announces, where the function is, and what the window's own menu does.
mouse = text('Horos/Sources/DCMView+Mouse.swift')
releases = len(re.findall(r'announceWindowLevelPreset\(DCMView\.findWLWWPreset\(self\.windowLevelState\.level, '
                          r'self\.windowLevelState\.width, self\.curDCM\), from: self, endingPress: true\)', mouse))
if releases != 2 or 'OsirixUpdateWLWWMenu' in mouse:
    failures.append(f'the releases of the mouse do not announce the level as the end of a press ({releases} of 2)')
hot_keys = text('Horos/Sources/DCMView+HotKeys.swift')
start = hot_keys.index('        case .windowLevelPreset(')
case = hot_keys[start:hot_keys.index('\n        case .', start + 1)]
if 'announceWindowLevelPreset(name as String, from: self)' not in case or 'OsirixUpdateWLWWMenu' in case:
    failures.append('the hot key of a window level preset does not tell the view\'s window its name')
# The two hot keys that are not presets of the list name what they apply too.
for label, title in (('defaultWindowLevel', 'Default WL & WW'), ('fullDynamic', 'Full dynamic')):
    start = hot_keys.index('        case .%s:' % label)
    case = hot_keys[start:hot_keys.index('\n        case .', start + 1)]
    if 'announceWindowLevelPreset(NSLocalizedString("%s", comment: ""), from: self)' % title not in case:
        failures.append('the hot key of «%s» does not tell the view\'s window its name' % title)
for relative in ('Horos/Sources/CPRController.swift', 'Horos/Sources/MPRController.swift'):
    if 'func announceWindowLevelPreset(' in text(relative):
        failures.append(f'{relative} holds the function the views of several windows announce through')
if not re.search(r'@objc\(setCurWLWWMenu:\)\n    public dynamic func setCurWLWWMenu\(', menu):
    failures.append('the 3D MPR window does not answer -setCurWLWWMenu:')
update = menu[menu.index('func UpdateWLWWMenu('):]
update = update[:update.index('\n    }\n')]
if re.search(r'note\??\.object', update) or 'setTitle(curWLWWMenu ?? "")' not in update:
    failures.append('the 3D MPR window does not title its menu with its own name')
start = controller.index('    @objc(ApplyWLWW:)\n')
chosen = controller[start:controller.index('    // MARK: - CLUTs', start)]
if not re.search(r'self\.applyWLWW\(for: menuString\)\s+NotificationCenter\.default\.post\(name: NSNotification\.Name\.'
                 r'OsirixUpdateWLWWMenu, object: curWLWWMenu,', chosen) or \
        not re.search(r'\n\s+curWLWWMenu = menuString\n', chosen):
    failures.append('a choice in the menu of the 3D MPR window no longer sets and announces its name')

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    sys.stderr.write('skipped: no Swift compiler (xcrun swiftc)\n')
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-mpr-wlww-name-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(program, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-o', str(folder / 'menu'),
                            str(folder / 'main.swift')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append("the window's menu does not compile with its stand-ins:\n" + built.stderr[-3000:])
    else:
        ran = subprocess.run([str(folder / 'menu')], capture_output=True, text=True)
        if ran.returncode != 0:
            failures.append(f"the window's menu (exit {ran.returncode}):\n" + ran.stderr[-3000:].strip())

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print('PASS: the 3D MPR window keeps its own window level name when another window announces, '
      'and takes it from its own views, after a drag of the level or a preset\'s hot key, and from its own menu')
