#!/usr/bin/env python3
"""Deleting the colour or opacity table a viewer has applied leaves it on a table that exists.

A stored colour table or opacity table is deleted from the 2D viewer's menu,
with Shift. When the table deleted was the one the viewer had applied, the
viewer kept its colours, or its opacity, and its name: the title of the menu
was a table no menu listed any more and nothing could apply again, and that
name was what the viewer announced to the other windows.

The viewer now goes to the table every menu has, «No CLUT» for the colours
and the linear table for the opacity, and announces that name with the
changed list. A viewer with another table applied keeps it.

Checked here on the two deletions of ViewerColourTables.swift, compiled with
stand-ins for the stored tables, the menus' cache and the viewer (which
applies a table as the viewer does: «No CLUT», the linear table or a stored
one, the name kept and announced):

1. deleting the applied table removes it from the stored ones, applies the
   fixed table once, and the last announcement carries its name and says the
   list changed;
2. deleting another table applies nothing, keeps the viewer's name and
   announces it with the changed list;
3. a viewer without a name applies nothing;
4. no announcement carries the name of the deleted table.

`<git revision>` as an optional argument reads the source from that revision:
that is the negative control.

Exit 2 when there is no Swift compiler.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
relative = 'Horos/Sources/ViewerColourTables.swift'
if revision is None:
    source = (root / relative).read_text(encoding='utf-8')
else:
    source = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}'],
                                     stderr=subprocess.DEVNULL).decode('utf-8')


def function(signature):
    start = source.index(signature)
    return source[start:source.index('\n    }\n', start) + len('\n    }\n')]


deletions = function('    func deleteColourTable(_ name: String, in viewer: ViewerController) {\n') + '\n' + \
    function('    func deleteOpacityTable(_ name: String, in viewer: ViewerController) {\n')

program = r'''
import Foundation

extension Notification.Name {
    static let OsirixUpdateCLUTMenu = Notification.Name("UpdateCLUTMenu")
    static let OsirixUpdateOpacityMenu = Notification.Name("UpdateOpacityMenu")
}
func viewerIsEqualToString(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

// Stand-ins: the stored tables of the preferences, by name.
final class Preferences {
    var colour: [String] = ["Hot", "PET"]
    var opacity: [String] = ["Bone", "Smooth"]
}
struct Tables {
    var names: [String]
    let store: ([String]) -> Void
    mutating func set(_ preset: Bool?, named name: String) { names.removeAll { $0 == name } }
    func write(to preferences: Preferences) { store(names) }
}
// The menus' cache: what the windows are told.
struct Told: Equatable { let menu: Notification.Name, current: String?, presetsChanged: Bool }
final class Menus {
    var told: [Told] = []
    func announce(_ menu: Notification.Name, current: String?, presetsChanged: Bool) {
        told.append(Told(menu: menu, current: current, presetsChanged: presetsChanged))
    }
}
// The viewer: a table is applied when it is the fixed one or a stored one,
// and then its name is kept and announced.
final class ViewerController {
    let preferences: Preferences, menus: Menus
    var horos_curCLUTMenu: String?, horos_curOpacityMenu: String?
    var applied: [String] = []
    init(_ preferences: Preferences, _ menus: Menus) { self.preferences = preferences; self.menus = menus }
    func applyCLUTString(_ name: String!) {
        guard let name, name == NSLocalizedString("No CLUT", comment: "") || preferences.colour.contains(name) else { return }
        applied.append("colour: " + name)
        horos_curCLUTMenu = name
        menus.announce(.OsirixUpdateCLUTMenu, current: horos_curCLUTMenu, presetsChanged: false)
    }
    func applyOpacityString(_ name: String!) {
        guard let name, name == NSLocalizedString("Linear Table", comment: "") || preferences.opacity.contains(name) else { return }
        applied.append("opacity: " + name)
        horos_curOpacityMenu = name
        menus.announce(.OsirixUpdateOpacityMenu, current: horos_curOpacityMenu, presetsChanged: false)
    }
}

final class ViewerColourTables {
    let preferences = Preferences()
    let menus = Menus()
    var colourTables: Tables { Tables(names: preferences.colour) { self.preferences.colour = $0 } }
    var opacityTables: Tables { Tables(names: preferences.opacity) { self.preferences.opacity = $0 } }

DELETIONS
}

var failed = false
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { fputs("FAIL: \(what) (line \(line))\n", stderr); failed = true }
}

let noCLUT = NSLocalizedString("No CLUT", comment: ""), linear = NSLocalizedString("Linear Table", comment: "")

/// A viewer with `colour` and `opacity` applied, after `delete` ran on it.
func after(colour: String?, opacity: String?, _ delete: (ViewerColourTables, ViewerController) -> Void)
    -> (tables: ViewerColourTables, viewer: ViewerController) {
    let tables = ViewerColourTables()
    let viewer = ViewerController(tables.preferences, tables.menus)
    viewer.horos_curCLUTMenu = colour
    viewer.horos_curOpacityMenu = opacity
    delete(tables, viewer)
    return (tables, viewer)
}

// 1. The applied table.
var run = after(colour: "Hot", opacity: "Bone") { $0.deleteColourTable("Hot", in: $1) }
check(run.tables.preferences.colour == ["PET"], "the colour table is still stored: \(run.tables.preferences.colour)")
check(run.viewer.applied == ["colour: " + noCLUT], "deleting the applied colour table applies: \(run.viewer.applied)")
check(run.viewer.horos_curCLUTMenu == noCLUT && run.viewer.horos_curOpacityMenu == "Bone",
      "the viewer is on \(run.viewer.horos_curCLUTMenu ?? "nil") and \(run.viewer.horos_curOpacityMenu ?? "nil")")
check(run.tables.menus.told.last == Told(menu: .OsirixUpdateCLUTMenu, current: noCLUT, presetsChanged: true),
      "the colour menus are told last: \(String(describing: run.tables.menus.told.last))")
check(!run.tables.menus.told.contains { $0.current == "Hot" }, "the menus are told the name of the deleted colour table")

run = after(colour: "Hot", opacity: "Bone") { $0.deleteOpacityTable("Bone", in: $1) }
check(run.tables.preferences.opacity == ["Smooth"], "the opacity table is still stored: \(run.tables.preferences.opacity)")
check(run.viewer.applied == ["opacity: " + linear], "deleting the applied opacity table applies: \(run.viewer.applied)")
check(run.viewer.horos_curOpacityMenu == linear && run.viewer.horos_curCLUTMenu == "Hot",
      "the viewer is on \(run.viewer.horos_curOpacityMenu ?? "nil") and \(run.viewer.horos_curCLUTMenu ?? "nil")")
check(run.tables.menus.told.last == Told(menu: .OsirixUpdateOpacityMenu, current: linear, presetsChanged: true),
      "the opacity menus are told last: \(String(describing: run.tables.menus.told.last))")
check(!run.tables.menus.told.contains { $0.current == "Bone" }, "the menus are told the name of the deleted opacity table")

// 2. Another table.
run = after(colour: "Hot", opacity: "Bone") { $0.deleteColourTable("PET", in: $1) }
check(run.tables.preferences.colour == ["Hot"] && run.viewer.applied.isEmpty && run.viewer.horos_curCLUTMenu == "Hot",
      "deleting another colour table: stored \(run.tables.preferences.colour), applied \(run.viewer.applied), on \(run.viewer.horos_curCLUTMenu ?? "nil")")
check(run.tables.menus.told == [Told(menu: .OsirixUpdateCLUTMenu, current: "Hot", presetsChanged: true)],
      "deleting another colour table tells: \(run.tables.menus.told)")

run = after(colour: "Hot", opacity: "Bone") { $0.deleteOpacityTable("Smooth", in: $1) }
check(run.tables.preferences.opacity == ["Bone"] && run.viewer.applied.isEmpty && run.viewer.horos_curOpacityMenu == "Bone",
      "deleting another opacity table: stored \(run.tables.preferences.opacity), applied \(run.viewer.applied), on \(run.viewer.horos_curOpacityMenu ?? "nil")")
check(run.tables.menus.told == [Told(menu: .OsirixUpdateOpacityMenu, current: "Bone", presetsChanged: true)],
      "deleting another opacity table tells: \(run.tables.menus.told)")

// The fixed tables are not stored ones: a viewer on them stays as it is.
run = after(colour: noCLUT, opacity: linear) { $0.deleteColourTable("Hot", in: $1); $0.deleteOpacityTable("Bone", in: $1) }
check(run.viewer.applied.isEmpty && run.viewer.horos_curCLUTMenu == noCLUT && run.viewer.horos_curOpacityMenu == linear,
      "a viewer on the fixed tables: applied \(run.viewer.applied)")

// 3. A viewer without a name.
run = after(colour: nil, opacity: nil) { $0.deleteColourTable("Hot", in: $1); $0.deleteOpacityTable("Bone", in: $1) }
check(run.viewer.applied.isEmpty && run.viewer.horos_curCLUTMenu == nil && run.viewer.horos_curOpacityMenu == nil,
      "a viewer without a name: applied \(run.viewer.applied)")
check(run.tables.menus.told == [Told(menu: .OsirixUpdateCLUTMenu, current: nil, presetsChanged: true),
                                Told(menu: .OsirixUpdateOpacityMenu, current: nil, presetsChanged: true)],
      "a viewer without a name tells: \(run.tables.menus.told)")
exit(failed ? 1 : 0)
'''.replace('DELETIONS', deletions)

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    sys.stderr.write('skipped: no Swift compiler (xcrun swiftc)\n')
    sys.exit(2)
failures = []
with tempfile.TemporaryDirectory(prefix='horos-delete-applied-table-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(program, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-o', str(folder / 'delete'),
                            str(folder / 'main.swift')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the deletions do not compile with their stand-ins:\n' + built.stderr[-3000:])
    else:
        ran = subprocess.run([str(folder / 'delete')], capture_output=True, text=True)
        if ran.returncode != 0:
            failures.append(f'the deletions (exit {ran.returncode}):\n' + ran.stderr[-3000:].strip())

# The names the deletions apply are the ones the viewer's own application of a
# table takes as the fixed tables.
if 'viewerIsEqualToString(name, NSLocalizedString("No CLUT", comment: ""))' not in source or \
        'AnyLanguage.says(name, "Linear Table")' not in source:
    failures.append('the viewer no longer applies «No CLUT» and the linear table by the names the deletions give')

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print('PASS: deleting the applied colour or opacity table leaves the viewer on «No CLUT» or the linear table, '
      'announced with the changed list; deleting another table changes nothing applied')
