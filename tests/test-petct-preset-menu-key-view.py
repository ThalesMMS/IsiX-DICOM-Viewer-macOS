#!/usr/bin/env python3
"""The orthogonal PET-CT window titles its colour and opacity menus with its key sub-view's names.

A window tells the others that a presets menu may have changed with one
notification for each menu, whose object is the name of the announcing
window's current preset; it does not say which window sent it. The orthogonal
PET-CT window has nine sub-views, each with the name of its colour table and
of its opacity table, and titled the two popups with the name notified: a
colour table or an opacity table chosen in any other window changed the
titles, while its images stayed as they were.

The window now titles the two popups with the names its key sub-view keeps,
and with the names last chosen in it when no sub-view is the key one. A
sub-view that becomes the first responder tells the window itself, with the
view: the notifications it posts before do not say who announced, and the
window's first responder may not be that view yet.

Checked here, on the window's code (-UpdateCLUTMenu:, -UpdateOpacityMenu: and
the titling they share, of OrthogonalMPRPETCTViewer.swift), compiled with
stand-ins for the popups, the preferences and the sub-views:

1. without a key sub-view, the popups show the names last chosen in the
   window, whatever another window announces;
2. with a key sub-view, the popups show its names: another window's
   announcement, or one without a name, changes neither; a change of the
   stored tables builds both menus again, under the same names;
3. a sub-view that becomes the key one and tells the window gives the popups
   its names before the window's first responder is that view, and they stay
   once it is;
4. a table applied to the key sub-view and announced, as a choice in the
   popup and the hot key of an opacity table do, is the title;
5. in the sources, the two menus do not read the name notified; the sub-view
   tells the window after it became the first responder, and still posts its
   three notifications; a choice in a popup still applies to the controllers
   of the key sub-view, titles the popup and announces.

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


viewer = text('Horos/Sources/OrthogonalMPRPETCTViewer.swift')
start = viewer.index('    public override dynamic func updateCLUTMenu(_ note: Notification!) {\n')
colour = viewer[start:viewer.index('    @IBAction public override dynamic func addCLUT(', start)]
colour = colour.replace('public override dynamic func updateCLUTMenu', '@objc public dynamic func updateCLUTMenu')
start = viewer.index('    @objc(UpdateOpacityMenu:)\n')
opacity = viewer[start:viewer.index('    @objc(transferFunction)\n', start)]

TITLING = 'func showPresetNames(of view: OrthogonalMPRView?'
if TITLING in colour:
    told = ''
else:
    failures.append('a sub-view has no way to tell the window to title its popups with its names')
    # What a sub-view could do: nothing but its notifications.
    told = '    func showPresetNames(of view: OrthogonalMPRView?) {}\n'

program = r'''
import AppKit

extension NSNotification.Name {
    static let OsirixUpdateCLUTMenu = NSNotification.Name("UpdateCLUTMenu")
    static let OsirixUpdateOpacityMenu = NSNotification.Name("UpdateOpacityMenu")
}
// Stand-ins: the stored tables, the popups of the toolbar and a sub-view.
final class Store { var names: [String: [String]] = [:] }
enum ImagePresetPreferences { static let colourTables = "CLUT", opacityTables = "OPACITY" }
enum ReconstructionPreferences { static func menuNames(_ presets: String, in store: Store) -> [String] { store.names[presets] ?? [] } }
final class Popup { var menu: NSMenu? = NSMenu() }
final class OrthogonalMPRView {
    var colourTable: String?, opacityTable: String?
    init(_ colourTable: String?, _ opacityTable: String?) { self.colourTable = colourTable; self.opacityTable = opacityTable }
    func curCLUTMenu() -> String! { colourTable }
    func curOpacityMenu() -> String! { opacityTable }
}

final class OrthogonalMPRPETCTViewer: NSObject {
    let preferenceStore = Store()
    let colourPopup = Popup(), opacityTablePopup = Popup()
    var curCLUTMenuIvar: String? = "No CLUT"
    var curOpacityMenuIvar: String? = "Linear Table"
    /// The window's first responder, when it is a sub-view.
    var keyOrthogonalView: OrthogonalMPRView?
    func clutPopup() -> Popup! { colourPopup }
    func opacityPopup() -> Popup! { opacityTablePopup }
    func copyMenusOfOlderSDK() {}
    @objc func applyCLUT(_ sender: Any!) {}
    @objc func applyOpacity(_ sender: Any!) {}
    func observe() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateCLUTMenu(_:)), name: .OsirixUpdateCLUTMenu, object: nil)
        center.addObserver(self, selector: #selector(UpdateOpacityMenu(_:)), name: .OsirixUpdateOpacityMenu, object: nil)
    }

<<COLOUR>>
<<OPACITY>>
<<TOLD>>}

nonisolated(unsafe) var failed = false
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { fputs("FAIL: \(what) (line \(line))\n", stderr); failed = true }
}

@MainActor func scenario() {
let window = OrthogonalMPRPETCTViewer()
let center = NotificationCenter.default
window.observe()
func shown() -> String { "\(window.colourPopup.menu?.item(at: 0)?.title ?? "nil") / \(window.opacityTablePopup.menu?.item(at: 0)?.title ?? "nil")" }
func announce(_ colourTable: String?, _ opacityTable: String?, presetsChanged: Bool = false) {
    center.post(name: .OsirixUpdateCLUTMenu, object: colourTable, userInfo: presetsChanged ? [:] : nil)
    center.post(name: .OsirixUpdateOpacityMenu, object: opacityTable, userInfo: presetsChanged ? [:] : nil)
}

// 1. The window opens, and announces the names it starts with; no sub-view is the key one yet.
announce(window.curCLUTMenuIvar, window.curOpacityMenuIvar)
check(shown() == "No CLUT / Linear Table", "the window opens under its own names: \(shown())")
announce("Hot Iron", "Logarithmic Table")
check(shown() == "No CLUT / Linear Table", "another window's names became this window's, without a key sub-view: \(shown())")

// 2. A sub-view of the CT is the key one.
let ct = OrthogonalMPRView("No CLUT", "Linear Table"), pet = OrthogonalMPRView("PET", "Exponential Table")
window.keyOrthogonalView = ct
announce("Hot Iron", "Logarithmic Table")
check(shown() == "No CLUT / Linear Table", "another window's names became this window's: \(shown())")
announce(nil, nil)
check(shown() == "No CLUT / Linear Table", "a notification without a name changed the titles: \(shown())")
// The stored tables changed: both menus are built again, under the same names.
window.preferenceStore.names = ["CLUT": ["Hot Iron", "PET"], "OPACITY": ["Exponential Table"]]
announce("Hot Iron", "Exponential Table", presetsChanged: true)
check(shown() == "No CLUT / Linear Table", "a change of the stored tables renamed the popups: \(shown())")
check((window.colourPopup.menu?.items ?? []).map(\.title).suffix(2) == ["Hot Iron", "PET"],
      "the colour tables menu was not built again: \((window.colourPopup.menu?.items ?? []).map(\.title))")
check((window.opacityTablePopup.menu?.items ?? []).map(\.title).last == "Exponential Table",
      "the opacity tables menu was not built again: \((window.opacityTablePopup.menu?.items ?? []).map(\.title))")

// 3. A sub-view of the PET becomes the key one: it posts its names, then tells
// the window, whose first responder is still the CT's.
announce(pet.curCLUTMenu(), pet.curOpacityMenu())
window.showPresetNames(of: pet)
check(shown() == "PET / Exponential Table", "the sub-view that becomes the key one does not title the popups: \(shown())")
window.keyOrthogonalView = pet
announce("Hot Iron", "Logarithmic Table")
check(shown() == "PET / Exponential Table", "another window's names replaced the key sub-view's: \(shown())")

// 4. A table applied to the key sub-view, then announced with its name.
pet.colourTable = "Hot Iron"
announce("Hot Iron", pet.curOpacityMenu())
check(shown() == "Hot Iron / Exponential Table", "the colour table applied to the key sub-view is not the title: \(shown())")
pet.opacityTable = "Linear Table"
announce(pet.curCLUTMenu(), "Linear Table")
check(shown() == "Hot Iron / Linear Table", "the opacity table applied to the key sub-view is not the title: \(shown())")
// Back to the CT's sub-view, which kept its own.
window.showPresetNames(of: ct)
window.keyOrthogonalView = ct
check(shown() == "No CLUT / Linear Table", "the sub-view of the CT lost its names: \(shown())")

center.removeObserver(window)
}
MainActor.assumeIsolated { scenario() }
exit(failed ? 1 : 0)
'''.replace('<<COLOUR>>', colour).replace('<<OPACITY>>', opacity).replace('<<TOLD>>', told)

# 5. The sources.
for name, body in (('colour tables', colour[:colour.index('\n    }\n')]), ('opacity tables', opacity)):
    if re.search(r'note\??\.object', body):
        failures.append(f'the menu of the {name} of the PET-CT window reads the name notified')
view = text('Horos/Sources/OrthogonalMPRPETCTView.swift')
start = view.index('    public override dynamic func becomeFirstResponder() -> Bool {\n')
became = view[start:view.index('\n    }\n', start)]
posts = re.findall(r'\.post\(name: NSNotification\.Name\.OsirixUpdate(CLUT|WLWW|Opacity)Menu, object: self\.cur\1Menu\(\),', became)
if sorted(posts) != ['CLUT', 'Opacity', 'WLWW']:
    failures.append(f'the sub-view that becomes the first responder no longer posts its three names: {posts}')
if not re.search(r'let became = super\.becomeFirstResponder\(\)\s+if became \{ \(self\.window\?\.windowController as\? '
                 r'OrthogonalMPRPETCTViewer\)\?\.showPresetNames\(of: self\) \}\s+return became', became):
    failures.append('the sub-view that became the first responder does not tell its window to title the popups with its names')
start = viewer.index('    public override dynamic func applyCLUTString(_ str: String!) {\n')
chosen = viewer[start:viewer.index('\n    }\n', start)]
if not all(piece in chosen for piece in (
        'CTController?.applyCLUTString(str)', 'PETController?.applyCLUTString(str)',
        'NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCLUTMenu, object: curCLUTMenuIvar, userInfo: nil)',
        'self.clutPopup()?.menu?.item(at: 0)?.title = str')):
    failures.append('a colour table chosen in the popup no longer applies to the key sub-view, titles the popup and announces')
start = viewer.index('    public override dynamic func applyOpacityString(_ str: String!) {\n')
chosen = viewer[start:viewer.index('    public override dynamic func applyOpacity(_ sender: Any!) {\n', start)]
if chosen.count('self.opacityPopup()?.menu?.item(at: 0)?.title = str') != 2 or \
        chosen.count('OsirixUpdateOpacityMenu, object: curOpacityMenuIvar, userInfo: nil)') != 2 or \
        not all(piece in chosen for piece in ('CTController?.applyOpacityString(str)', 'PETController?.applyOpacityString(str)')):
    failures.append('an opacity table chosen in the popup no longer applies to the key sub-view, titles the popup and announces')

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    sys.stderr.write('skipped: no Swift compiler (xcrun swiftc)\n')
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-petct-preset-names-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(program, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-o', str(folder / 'menus'),
                            str(folder / 'main.swift')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append("the window's menus do not compile with their stand-ins:\n" + built.stderr[-3000:])
    else:
        ran = subprocess.run([str(folder / 'menus')], capture_output=True, text=True)
        if ran.returncode != 0:
            failures.append(f"the window's menus (exit {ran.returncode}):\n" + ran.stderr[-3000:].strip())

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print('PASS: the orthogonal PET-CT window titles its colour and opacity popups with the names of its key sub-view, '
      'whatever another window announces, and a change of the stored tables still builds the menus again')
