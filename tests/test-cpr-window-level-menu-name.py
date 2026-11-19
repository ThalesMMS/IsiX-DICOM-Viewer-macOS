#!/usr/bin/env python3
"""The Curved MPR window titles its window level menu with its own name.

A window tells the others that the presets menu of the window levels may have
changed with one notification, whose object is the name of the announcing
window's current preset; it does not say which window sent it. The Curved MPR
window kept the name it was notified as its own: a window level chosen or
dragged in any other window changed the title of its menu, while its images
stayed as they were.

It now keeps its own name, as the other reconstruction windows do, and what
only the notification told it comes straight from its views: an image view
that ends a press or a preset's hot key tells the window it is in, when that
window keeps such a name, before the notification goes out.

Checked here, on the window's own code (-createWLWWMenuItems, -UpdateWLWWMenu:
and -setCurWLWWMenu: of CPRController.swift) and the views' announcement
(announceWindowLevelPreset, of Window3DController+WindowLevel.swift, shared
with the 3D MPR window, whose test has the cases of a press), compiled with
stand-ins for the popup, the preferences and the image view:

1. a notification with another name, or with none, leaves the window's name
   and the title of its menu, and still builds the menu again from the stored
   presets;
2. a view of another window that announces changes nothing either, and the
   notification still goes out for the windows that listen;
3. a view of the window itself that announces gives the window its name, and
   the menu shows it; a view without an image names nothing;
4. in the sources, the two releases of the mouse and the window level hot key
   of the image view announce through that function, and a choice in the
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


controller = text('Horos/Sources/CPRController.swift')
start = controller.index('    @objc(createWLWWMenuItems)\n')
menu = controller[start:controller.index('    @objc(ApplyWLWW:)\n', start)]

# The function, with the protocol of the message it sends when it has one; a
# revision that had it in the window's own file is read there.
ANNOUNCE = '@MainActor func announceWindowLevelPreset('
shared = text('Horos/Sources/Window3DController+WindowLevel.swift')
holder = shared if ANNOUNCE in shared else controller
if ANNOUNCE in holder:
    KEEPER = '@objc private protocol WindowLevelNameKeeping {'
    start = holder.index(KEEPER) if KEEPER in holder else holder.index(ANNOUNCE)
    announce = holder[start:holder.index('\n}\n', holder.index(ANNOUNCE)) + len('\n}\n')]
else:
    failures.append('an image view has no way to tell its Curved MPR window the name of its window level')
    # What the views did: the notification alone.
    announce = '''@MainActor func announceWindowLevelPreset(_ name: String?, from view: DCMView) {
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
final class DCMPix { var wl: Float = 0, ww: Float = 0 }
final class DCMView {
    var curDCM: DCMPix?
    var startWL: Float = 0, startWW: Float = 0
    var controller: AnyObject?
    init(image: Bool, controller: AnyObject?) { self.curDCM = image ? DCMPix() : nil; self.controller = controller }
    func is2DViewer() -> Bool { false }
    func windowController() -> Any! { controller }
}
nonisolated(unsafe) var posted: [String?] = []
func inputPost(_ name: NSNotification.Name, object: Any?, userInfo: NSDictionary? = nil) {
    posted.append(object as? String)
    NotificationCenter.default.post(name: name, object: object, userInfo: userInfo as? [AnyHashable: Any])
}

final class CPRController: NSObject {
    let preferenceStore = Store()
    let popup = Popup()
    var curWLWWMenu: String?
    var wlwwMenuItems: NSArray?
    func wlwwPopup() -> Popup! { popup }
    @objc(ApplyWLWW:) func ApplyWLWW(_ sender: Any!) {}

MENU
}

ANNOUNCE

nonisolated(unsafe) var failed = false
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { fputs("FAIL: \(what) (line \(line))\n", stderr); failed = true }
}

@MainActor func scenario() {
let window = CPRController(), other = NSObject()
let center = NotificationCenter.default
center.addObserver(window, selector: #selector(CPRController.UpdateWLWWMenu(_:)), name: .OsirixUpdateWLWWMenu, object: nil)
func shown() -> String { "\(window.curWLWWMenu ?? "nil") / \(window.popup.title) / \(window.popup.menu?.item(at: 0)?.title ?? "nil")" }
func titles() -> [String] { (window.popup.menu?.items ?? []).map(\.title) }

// The window opens with the name of its 2D viewer and announces it.
window.curWLWWMenu = "Full dynamic"
center.post(name: .OsirixUpdateWLWWMenu, object: window.curWLWWMenu, userInfo: nil)
check(shown() == "Full dynamic / Full dynamic / Full dynamic", "the window opens with its own name: \(shown())")

// 1. Another window announces its name, or none.
center.post(name: .OsirixUpdateWLWWMenu, object: "Other", userInfo: nil)
check(shown() == "Full dynamic / Full dynamic / Full dynamic", "another window's name became this window's: \(shown())")
center.post(name: .OsirixUpdateWLWWMenu, object: nil, userInfo: nil)
check(shown() == "Full dynamic / Full dynamic / Full dynamic", "a notification without a name changed this window's: \(shown())")
// The stored presets changed: the menu is built again, under the same name.
window.preferenceStore.titles = ["Bone", "Lung"]
center.post(name: .OsirixUpdateWLWWMenu, object: "Bone", userInfo: [:])
check(shown() == "Full dynamic / Full dynamic / Full dynamic", "a change of the presets renamed this window's level: \(shown())")
check(titles().suffix(2) == ["Bone", "Lung"] && titles().count == 7, "the menu was not built again from the stored presets: \(titles())")

// 2. A view of another window, and one of no window.
posted = []
announceWindowLevelPreset("Other", from: DCMView(image: true, controller: other))
announceWindowLevelPreset("Lung", from: DCMView(image: true, controller: nil))
check(shown() == "Full dynamic / Full dynamic / Full dynamic", "a view of another window renamed this window's level: \(shown())")
check(posted == ["Other", "Lung"], "the views of the other windows no longer announce their names: \(posted)")

// 3. The window's own views.
posted = []
announceWindowLevelPreset("Other", from: DCMView(image: true, controller: window))
check(shown() == "Other / Other / Other", "a drag in a view of the window did not rename its level: \(shown())")
announceWindowLevelPreset("Bone", from: DCMView(image: true, controller: window))
check(shown() == "Bone / Bone / Bone", "a preset reached in a view of the window is not shown: \(shown())")
announceWindowLevelPreset("Lung", from: DCMView(image: false, controller: window))
check(shown() == "Bone / Bone / Bone", "a view without an image named the window's level: \(shown())")
check(posted == ["Other", "Bone", "Lung"], "the window's views no longer announce to the other windows: \(posted)")
// The message the views send, by its Objective-C name.
let setter = Selector(("setCurWLWWMenu:"))
check(window.responds(to: setter), "the window does not answer -setCurWLWWMenu:")
if window.responds(to: setter) { window.perform(setter, with: "Default WL & WW") }
center.post(name: .OsirixUpdateWLWWMenu, object: "Other", userInfo: nil)
check(shown() == "Default WL & WW / Default WL & WW / Default WL & WW", "the name the window is given is not the one its menu shows: \(shown())")

center.removeObserver(window)
}
MainActor.assumeIsolated { scenario() }
exit(failed ? 1 : 0)
'''.replace('MENU', menu).replace('ANNOUNCE', announce)

# 4. The sources: who announces, and what the window's own menu does.
mouse = text('Horos/Sources/DCMView+Mouse.swift')
releases = len(re.findall(r'announceWindowLevelPreset\(DCMView\.findWLWWPreset\(self\.windowLevelState\.level, '
                          r'self\.windowLevelState\.width, self\.curDCM\), from: self(?:, endingPress: true)?\)', mouse))
if releases != 2 or 'OsirixUpdateWLWWMenu' in mouse:
    failures.append(f'the releases of the mouse do not tell the view\'s window the name of its window level ({releases} of 2)')
hot_keys = text('Horos/Sources/DCMView+HotKeys.swift')
start = hot_keys.index('        case .windowLevelPreset(')
case = hot_keys[start:hot_keys.index('\n        case .', start + 1)]
if 'announceWindowLevelPreset(name as String, from: self)' not in case or 'OsirixUpdateWLWWMenu' in case:
    failures.append('the hot key of a window level preset does not tell the view\'s window its name')
if not re.search(r'@objc\(setCurWLWWMenu:\)\n    public dynamic func setCurWLWWMenu\(', menu):
    failures.append('the Curved MPR window does not answer -setCurWLWWMenu:')
update = menu[menu.index('func UpdateWLWWMenu('):]
update = update[:update.index('\n    }\n')]
if re.search(r'note\??\.object', update):
    failures.append('the Curved MPR window reads the name of the notification')
start = controller.index('    @objc(ApplyWLWW:)\n')
chosen = controller[start:controller.index('    // MARK: - CLUTs', start)]
if not re.search(r'self\.applyWLWW\(for: menuString\)\s+NotificationCenter\.default\.post\(name: NSNotification\.Name\.'
                 r'OsirixUpdateWLWWMenu, object: curWLWWMenu,', chosen) or \
        not re.search(r'if curWLWWMenu as NSString\? !== menuString as NSString\? \{\s+curWLWWMenu = menuString\s+\}', chosen):
    failures.append('a choice in the menu of the Curved MPR window no longer sets and announces its name')

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    sys.stderr.write('skipped: no Swift compiler (xcrun swiftc)\n')
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-cpr-wlww-name-') as directory:
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
print('PASS: the Curved MPR window keeps its own window level name when another window announces, '
      'and takes it from its own views and its own menu')
