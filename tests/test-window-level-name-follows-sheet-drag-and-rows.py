#!/usr/bin/env python3
"""A window level's name follows the level a sheet, a drag or a row applies.

A window that shows the name of its window level in the title of its presets
menu keeps that name apart from the level. Four places set a level, or seemed
to, and left a name that no longer said it:

- The "Set WL/WW" sheet of the 2D viewer applied its fields and left the name
  of the level before.
- A drag of the window level tool in the volume rendering window changed the
  level under a name that only the menu, a hot key or the sheet could change.
- The PET-CT orthogonal window gives the level of its CT row to the 2D viewer
  of the CT and the level of its PET row to the 2D viewer of the PET, without
  the name, kept no name a drag or a hot key in its views left, and opened
  under «Other» whatever its viewer showed.
- The 2D viewer does not give its level to the orthogonal window opened from
  it: that window shows copies of the viewer's images, each with a level of
  its own, so a preset or a drag in the viewer leaves the orthogonal window
  its level, and its name with it. Nothing takes a name back from the viewer.

Checked here on the windows' own code, compiled with stand-ins for the 2D
viewers, the views, the popup, the preferences and the sheet's fields:

1. OK in the viewer's sheet names the level its fields left, a preset's or
   «Other»; Cancel restores the level and leaves the name;
2. a step of a drag that changes the level of the volume rendering names it
   «Other» and tells the menus once for the drag; a window already on «Other»
   and a window that keeps no name are told nothing, and in the sources only
   the drag of the window level tool, on a step that changed the level, asks
   for it;
3. the PET-CT window opens under the name of the viewer it is opened from; a
   preset chosen with the CT row key names the CT's viewer, with the PET row
   key the PET's viewer, with the fused row key neither; «Other» names the
   window alone; a press or a hot key in a view names the window and the
   viewer of its row; each viewer is named once, and naming it asks nothing
   back of the window;
4. in the sources: the orthogonal window keeps copies of its viewer's images
   and takes a level only from an image of its own list, the 2D viewer only
   titles its menu when it is given a name, the PET-CT window gives each
   row's level to that row's 2D viewer, and its launcher opens the rows at
   the levels of the two viewers.

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


# 1. The end of the 2D viewer's sheet.
viewer_level = text('Horos/Sources/ViewerWindowLevel.swift')
sheet = between(viewer_level, '    func endSetWindowSheet(_ sender: Any?) {\n', '\n    }\n') + '\n    }\n'

# 2. What a 3D window does when a drag changed its level, with what it tells the menus by.
shared = text('Horos/Sources/Window3DController+WindowLevel.swift')
dragged = re.search(r'    fileprivate final func announceWindowLevelName\(\) \{\n.*?\n    \}\n', shared, re.S).group(0)
named_by_drag = re.search(r'    final func nameDraggedWindowLevel\(\) \{\n.*?\n    \}\n', shared, re.S)
if named_by_drag:
    dragged += named_by_drag.group(0)
else:
    failures.append('a 3D window has nothing to name the level a drag left')
    dragged += '    final func nameDraggedWindowLevel() {}\n'

# 3. The PET-CT window: the name it opens under, its menu and the name its views give it.
fused = text('Horos/Sources/OrthogonalMPRPETCTViewer.swift')
fused_opening = between(fused, '        // WL/WW Menu', '        // Opacity Menu')
fused_menu = between(fused, '    @objc(applyWLWWForString:)\n', '    @objc(OpacityChanged:)\n')

program = r'''
import AppKit

extension NSNotification.Name { static let OsirixUpdateWLWWMenu = NSNotification.Name("UpdateWLWWMenu") }

// Stand-ins: the stored presets, the popup of the toolbar, an image and its view.
struct Preset { var level: Double, width: Double }
final class Store { var presets: [(String, Preset)] = [("CT - Abdomen", Preset(level: 40, width: 350)), ("CT - Bone", Preset(level: 300, width: 1500))] }
enum ImagePresetPreferences { case windowLevelPresets }
enum ReconstructionPreferences {
    static func preset(_ name: String!, of kind: ImagePresetPreferences, in store: Store) -> Preset? { store.presets.first { $0.0 == name }?.1 }
}
enum WindowLevel {
    static func presetName(fromMenuTitle title: String) -> String? { title.range(of: " - ").map { String(title[$0.upperBound...]) } }
}
func titleOf(_ sender: Any?) -> String? { (sender as? NSMenuItem)?.title }
final class Popup { var menu: NSMenu? = NSMenu() }
final class DCMPix {
    var wl: Float = 300, ww: Float = 1500
    var savedWL: Float = 50, savedWW: Float = 500
}
/// A row of the PET-CT window: the object of the nib that owns its three views.
final class RowController: NSObject {
    var views: [DCMView] = []
    func containsView(_ view: DCMView?) -> Bool { views.contains { $0 === view } }
}
final class DCMView {
    var curDCM: DCMPix! = DCMPix()
    var curWL: Float { curDCM.wl }
    var curWW: Float { curDCM.ww }
    weak var row: RowController?
    init(row: RowController? = nil) { self.row = row; row?.views.append(self) }
    func controller() -> RowController? { row }
    func setWLWW(_ wl: Float, _ ww: Float) { curDCM.wl = wl; curDCM.ww = ww }
    /// The name the presets have for a level: here the stored presets, by their values.
    static func findWLWWPreset(_ wl: Float, _ ww: Float, _ pix: DCMPix?) -> String! {
        Store().presets.first { Float($0.1.level) == wl && Float($0.1.width) == ww }?.0 ?? "Other"
    }
}

// The fields and the sheet of Set WL/WW.
final class Field { var stringValue = ""; func selectText(_ sender: Any?) {} }
final class Sheet { var ended: [Int] = []; func orderOutAndEndSheet(returnCode: NSApplication.ModalResponse) { ended.append(returnCode.rawValue) } }
enum ViewerSender { static func tag(_ sender: Any?) -> Int { (sender as? NSNumber)?.intValue ?? 0 } }

/// A 2D viewer: its view, the name its menu is titled with and how many times it was given one.
final class ViewerController: NSObject {
    let horos_imageView: DCMView? = DCMView()
    let horos_wlset: Field? = Field(), horos_wwset: Field? = Field()
    let horos_setWLWWWindow: Sheet? = Sheet()
    var name: String?
    var named = 0
    init(name: String?) { self.name = name }
    var level: [Float] { [horos_imageView!.curWL, horos_imageView!.curWW] }
    func setWL(_ wl: Float, ww: Float) { horos_imageView?.setWLWW(wl, ww) }
    @objc(setCurWLWWMenu:) func setCurWLWWMenu(_ s: String!) { name = s; named += 1 }
    @objc(curWLWWMenu) func curWLWWMenu() -> String! { name }
}

@MainActor final class ViewerWindowLevel {
    let viewer: ViewerController
    static var windowBeforeSetWLWW: (level: Float, width: Float) = (0, 0)
    init(_ viewer: ViewerController) { self.viewer = viewer }
SHEET
}

@MainActor class Window3DController: NSObject {
    var currentWLWWMenu: String?
    var title = ""
    @objc func menusTold(_ note: Notification) { title = currentWLWWMenu ?? "" }
}
extension Window3DController {
DRAGGED
}

final class OrthogonalMPRPETCTViewer: NSObject {
    let preferenceStore = Store()
    let popup = Popup()
    let CTController: RowController! = RowController(), PETController: RowController! = RowController(), PETCTController: RowController! = RowController()
    var viewerIvar: ViewerController?
    var blendingViewerController: ViewerController?
    var curWLWWMenuIvar: String?
    var key: DCMView?
    func keyView() -> DCMView! { key }
    var keyOrthogonalView: DCMView? { key }
    func wlwwPopup() -> Popup! { popup }
    /// As the window's own: the row's level goes to the 2D viewer of that row, the fused row's to none.
    func setWLWW(_ wl: Float, _ ww: Float, _ sender: Any!) {
        if sender as AnyObject? === CTController { viewerIvar?.setWL(wl, ww: ww) }
        else if sender as AnyObject? === PETController { blendingViewerController?.setWL(wl, ww: ww) }
    }
    @objc(UpdateWLWWMenu:) func UpdateWLWWMenu(_ note: Notification!) { popup.menu?.item(at: 0)?.title = curWLWWMenuIvar ?? "" }

    /// The part of the initializer that names the level and builds the menu.
    init(_ vC: ViewerController!, _ bC: ViewerController!) {
        super.init()
        viewerIvar = vC
        blendingViewerController = bC
        popup.menu?.addItem(withTitle: "", action: nil, keyEquivalent: "")
        let nc = NotificationCenter.default
FUSED_OPENING
    }

FUSED_MENU
}

nonisolated(unsafe) var posted: [String?] = []
nonisolated(unsafe) var failed = false
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { fputs("FAIL: \(what) (line \(line))\n", stderr); failed = true }
}

@MainActor func scenario() {
let center = NotificationCenter.default
let listener = center.addObserver(forName: .OsirixUpdateWLWWMenu, object: nil, queue: nil) { posted.append($0.object as? String) }

// 1. The sheet of the 2D viewer.
let viewer2D = ViewerController(name: "CT - Bone")
let level2D = ViewerWindowLevel(viewer2D)
func sheet(fields: [String], tag: Int) {
    ViewerWindowLevel.windowBeforeSetWLWW = (viewer2D.level[0], viewer2D.level[1])
    viewer2D.horos_wlset?.stringValue = fields[0]
    viewer2D.horos_wwset?.stringValue = fields[1]
    level2D.endSetWindowSheet(NSNumber(value: tag))
}
func shown(_ viewer: ViewerController) -> String { "\(viewer.name ?? "nil") at \(viewer.level)" }
sheet(fields: ["40", "350"], tag: 1)
check(shown(viewer2D) == "CT - Abdomen at [40.0, 350.0]", "OK on the level of a preset does not name it: \(shown(viewer2D))")
sheet(fields: ["123", "456"], tag: 1)
check(shown(viewer2D) == "Other at [123.0, 456.0]", "OK on a level of no preset does not name it «Other»: \(shown(viewer2D))")
sheet(fields: ["300", "1500"], tag: 1)
check(shown(viewer2D) == "CT - Bone at [300.0, 1500.0]", "OK does not name the level of another preset: \(shown(viewer2D))")
sheet(fields: ["40", "350"], tag: 0)
check(shown(viewer2D) == "CT - Bone at [300.0, 1500.0]", "Cancel does not leave the level and the name the sheet opened with: \(shown(viewer2D))")
check(viewer2D.horos_setWLWWWindow?.ended == [1, 1, 1, 0], "the sheet does not end with the tag of its button: \(viewer2D.horos_setWLWWWindow?.ended ?? [])")

// 2. A drag of the level in a 3D window that looks for no preset.
let volume = Window3DController()
center.addObserver(volume, selector: #selector(Window3DController.menusTold(_:)), name: .OsirixUpdateWLWWMenu, object: nil)
volume.currentWLWWMenu = "CT - Abdomen"
volume.title = "CT - Abdomen"
posted = []
volume.nameDraggedWindowLevel()
check(volume.currentWLWWMenu == "Other" && volume.title == "Other", "a drag that changed the level left the name of the level before: \(volume.currentWLWWMenu ?? "nil") / \(volume.title)")
volume.nameDraggedWindowLevel()
volume.nameDraggedWindowLevel()
check(posted == ["Other"], "the menus are not told once for the drag that the level is «Other»: \(posted)")
let nameless = Window3DController()
posted = []
nameless.nameDraggedWindowLevel()
check(nameless.currentWLWWMenu == nil && posted.isEmpty, "a window that keeps no name was given one by a drag: \(nameless.currentWLWWMenu ?? "nil"), \(posted)")
center.removeObserver(volume)

// 3. The PET-CT window.
let viewerCT = ViewerController(name: "CT - Bone"), viewerPET = ViewerController(name: "PET")
viewerPET.setWL(5, ww: 10)
posted = []
let window = OrthogonalMPRPETCTViewer(viewerCT, viewerPET)
func shown(_ window: OrthogonalMPRPETCTViewer) -> String { "\(window.curWLWWMenuIvar ?? "nil") / \(window.popup.menu?.item(at: 0)?.title ?? "nil")" }
check(shown(window) == "CT - Bone / CT - Bone", "the window does not open under the name of the viewer it is opened from: \(shown(window))")
check(posted == ["CT - Bone"], "the window does not announce the name it opens under: \(posted)")
check(viewerCT.named == 0 && viewerPET.named == 0, "opening the window named its viewers: \(viewerCT.named), \(viewerPET.named)")
let unnamed = OrthogonalMPRPETCTViewer(ViewerController(name: nil), viewerPET), alone = OrthogonalMPRPETCTViewer(nil, nil)
check(shown(unnamed) == "Other / Other" && shown(alone) == "Other / Other", "a window whose viewer has no name does not open under «Other»: \(shown(unnamed)), \(shown(alone))")
center.removeObserver(unnamed)
center.removeObserver(alone)

let viewCT = DCMView(row: window.CTController), viewPET = DCMView(row: window.PETController), viewFused = DCMView(row: window.PETCTController)
func choose(_ title: String, key: DCMView) {
    window.key = key
    _ = window.perform(Selector(("ApplyWLWW:")), with: NSMenuItem(title: title, action: nil, keyEquivalent: ""))
}
func names() -> String { "\(shown(window)); CT \(shown(viewerCT)) x\(viewerCT.named); PET \(shown(viewerPET)) x\(viewerPET.named)" }
posted = []
choose("1 - CT - Abdomen", key: viewCT)
check(names() == "CT - Abdomen / CT - Abdomen; CT CT - Abdomen at [40.0, 350.0] x1; PET PET at [5.0, 10.0] x0",
      "a preset chosen with the CT row key does not name the viewer of the CT, once, and it alone: \(names())")
check(posted == ["CT - Abdomen"], "the choice is not announced once, by its name: \(posted)")
choose("Full dynamic", key: viewPET)
check(names() == "Full dynamic / Full dynamic; CT CT - Abdomen at [40.0, 350.0] x1; PET Full dynamic at [0.0, 0.0] x1",
      "a choice with the PET row key does not name the viewer of the PET, once, and it alone: \(names())")
choose("2 - CT - Bone", key: viewFused)
check(names() == "CT - Bone / CT - Bone; CT CT - Abdomen at [40.0, 350.0] x1; PET Full dynamic at [0.0, 0.0] x1",
      "a choice with the fused row key, which sets no level, named a viewer: \(names())")
choose("Other", key: viewCT)
check(names() == "Other / Other; CT CT - Abdomen at [40.0, 350.0] x1; PET Full dynamic at [0.0, 0.0] x1",
      "«Other», which applies no level, named a viewer: \(names())")
choose("Default WL & WW", key: viewCT)
check(names() == "Default WL & WW / Default WL & WW; CT Default WL & WW at [50.0, 500.0] x2; PET Full dynamic at [0.0, 0.0] x1",
      "the default level of the CT row went to its viewer without its name: \(names())")

// A press or a hot key in a view: the view tells its window by this message, when it answers it.
func viewNames(_ name: String, key: DCMView) {
    window.key = key
    if window.responds(to: Selector(("setCurWLWWMenu:"))) { _ = window.perform(Selector(("setCurWLWWMenu:")), with: name) }
}
viewNames("Other", key: viewPET)
check(window.curWLWWMenuIvar == "Other" && viewerPET.name == "Other" && viewerPET.named == 2 && viewerCT.named == 2,
      "a press in a view of the PET row does not name the window and the viewer of the PET alone: \(names())")
viewNames("CT - Bone", key: viewCT)
check(window.curWLWWMenuIvar == "CT - Bone" && viewerCT.name == "CT - Bone" && viewerCT.named == 3 && viewerPET.named == 2,
      "a hot key in a view of the CT row does not name the window and the viewer of the CT alone: \(names())")
viewNames("Other", key: viewFused)
check(window.curWLWWMenuIvar == "Other" && viewerCT.named == 3 && viewerPET.named == 2, "a name from the fused row went to a viewer: \(names())")
center.removeObserver(window)
center.removeObserver(listener)
}
MainActor.assumeIsolated { scenario() }
exit(failed ? 1 : 0)
'''.replace('SHEET', sheet).replace('DRAGGED', dragged).replace('FUSED_OPENING', fused_opening).replace('FUSED_MENU', fused_menu)

# 2, in the sources: only a step of the window level drag that changed the level asks for the name.
volume_mouse = text('Horos/Sources/VRView+Mouse.swift')
drag_step = between(volume_mouse, '            case .tWL:\n', '                // As setWLWW:')
asked = 'if wl != horos_wl || ww != horos_ww { horos_controller?.nameDraggedWindowLevel() }\n                horos_wl = wl\n'
if asked not in drag_step:
    failures.append('a step of the window level drag in the volume rendering view that changes the level does not have the window name it')
if volume_mouse.count('nameDraggedWindowLevel') != (1 if asked in drag_step else 0):
    failures.append('the volume rendering view has its window name the level outside the drag of the window level tool')
if not re.search(r'public class VRController: Window3DController\b', text('Horos/Sources/VRController.swift')):
    failures.append('the volume rendering window is no longer a 3D window, whose name the drag changes')

# 4. The sources the scenarios and the absence of a way back stand on.
orthogonal_controller = text('Horos/Sources/OrthogonalMPRController.swift')
if '_originalDCMPixList?.add((p as! NSObject).copy())' not in between(orthogonal_controller, '    @objc(setPixList:::)\n', '\n    }\n'):
    failures.append("the orthogonal window no longer shows copies of its viewer's images: a level of the viewer may reach it, and its name must then")
taken = between(orthogonal_controller, '    @objc(changeWLWW:)\n', '    @objc(setWLWW::)\n')
if 'if let otherPix, _originalDCMPixList?.contains(otherPix) == true {' not in taken:
    failures.append('the orthogonal window no longer takes a level only from an image of its own list')
if re.search(r'func isEqual\(|override var hash\b', text('Horos/Sources/DCMPix.swift')):
    failures.append('an image now compares equal to another: the copies of the orthogonal window may answer for the images of the viewer')
viewer2d = text('Horos/Sources/ViewerController+WindowLevel.swift')
named = between(viewer2d, '    @objc(setCurWLWWMenu:)\n', '\n    }\n')
if 'horos_wlwwPopup?.setTitle(horos_curWLWWMenu ?? "")' not in named or re.search(r'post\(|announce|perform|setWL', named):
    failures.append('the 2D viewer does more than title its menu when it is given a name: a name may come back to the window that gave it')
pushed = between(fused, '    @objc(setWLWW:::)\n', '    @objc(UpdateWLWWMenu:)\n')
if not re.search(r'if objIsEqual\(sender, CTController\) \{\n\s+viewerIvar\?\.setWL\(iwl, ww: iww\)\n', pushed) \
        or not re.search(r'\} else if objIsEqual\(sender, PETController\) \{\n\s+blendingViewerController\?\.setWL\(iwl, ww: iww\)\n', pushed) \
        or 'PETCTController)' in pushed:
    failures.append("the PET-CT window no longer gives the level of the CT row to the CT's viewer and of the PET row to the PET's, and of the fused row to none")
launcher = text('Horos/Sources/ThreeDViewerLauncher.swift')
opened = between(launcher, '    func orthogonalPETCTWindow() -> OrthogonalMPRPETCTViewer? {', '\n    }\n')
if not re.search(r'viewer\.horos_imageView\?\.getWLWW\(&wl, &ww\)\n\s+made\?\.CTController\?\.setWLWW\(wl, ww\)\n'
                 r'\s+blending\.imageView\(\)\?\.getWLWW\(&wl, &ww\)\n\s+made\?\.PETController\?\.setWLWW\(wl, ww\)', opened):
    failures.append('the rows of the PET-CT window are no longer opened at the levels of the two viewers')

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    sys.stderr.write('skipped: no Swift compiler (xcrun swiftc)\n')
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-wlww-name-sheet-drag-rows-') as directory:
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
print("PASS: the 2D viewer's sheet names the level it leaves, a drag of the level in the volume rendering names it «Other», "
      'the PET-CT window names the level of each row in the 2D viewer of that row, and no name comes back from a 2D viewer')
