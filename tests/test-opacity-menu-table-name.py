#!/usr/bin/env python3
"""The opacity menu is told the name of an opacity table, never another name or none.

A window tells the others that a presets menu may have changed with one
notification for each menu, whose object is the name of the current preset of
that menu. A window that titles its menu with the name it is told - the
orthogonal PET-CT window does for the opacity menu - shows whatever name comes.

Two senders told the opacity menu something else:

- the 2D viewer, after deleting a stored opacity table, sent the name of its
  colour table;
- the hot key of the first opacity preset, the linear table, sent no name when
  no table was stored, and raised NSRangeException before sending anything
  when one was: it read the name at index -1 of the list of stored tables.

Checked here:

1. every notification of a presets menu the 2D viewer announces
   (ViewerColourTables.swift, ViewerWindowLevel.swift) carries the name the
   viewer keeps for that menu;
2. the hot key's case of -[DCMView actionForHotKey:], extracted from
   DCMView+HotKeys.swift and compiled with stand-ins for the preferences, the
   window controller and the order of the names, applies and announces
   «Linear Table» for the first preset, with and without stored tables, and
   the stored table of each further preset; a preset past the stored tables
   applies and announces nothing. The choice of the table is the one of
   IsiXImaging (HotKeyMap.swift), compiled with it.

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


# 1. The viewer's announcements.
KEPT = {'CLUT': 'horos_curCLUTMenu', 'WLWW': 'horos_curWLWWMenu', 'Opacity': 'horos_curOpacityMenu',
        'Convolution': 'horos_curConvMenu'}
ANNOUNCE = re.compile(r'menus\.announce\(\.OsirixUpdate(CLUT|WLWW|Opacity|Convolution)Menu,\s*current: ([^,]+),')
count = {}
for relative in ('Horos/Sources/ViewerColourTables.swift', 'Horos/Sources/ViewerWindowLevel.swift'):
    source = text(relative)
    for match in ANNOUNCE.finditer(source):
        menu, value = match.group(1), match.group(2).strip()
        count[menu] = count.get(menu, 0) + 1
        if value != 'viewer.' + KEPT[menu]:
            line = source.count('\n', 0, match.start()) + 1
            failures.append(f'{relative}:{line}: the {menu} menu is told `{value}`, which is not the name of its preset')
if any(count.get(menu, 0) < 4 for menu in KEPT):
    sys.exit(f'FAIL: the announcements of the presets menus were not found: {count}')

# 2. The hot key of an opacity preset.
hot_keys = text('Horos/Sources/DCMView+HotKeys.swift')
start = hot_keys.index('        case .opacityPreset(let preset):\n')
case = hot_keys[start + len('        case .opacityPreset(let preset):\n'):hot_keys.index('        case .windowLevelPreset(', start)]
key_map = text('Modules/IsiXImaging/Sources/ViewInput/HotKeyMap.swift')
start = key_map.index('    /// What an opacity preset hot key applies.')
choice = key_map[start:key_map.index('\n    }\n', key_map.index('func opacityChoice(', start)) + len('\n    }\n')]

program = r'''
import Foundation

// Stand-ins for the preferences: the stored opacity tables, read through a typed key.
struct PropertyListValue {}
struct TypedKey<Value> {}
struct Key { func reading<Value>(as type: Value.Type) -> TypedKey<Value> { TypedKey() } }
enum ImagePresetPreferences { static let opacityTables = Key() }
nonisolated(unsafe) var storedTables: [String: PropertyListValue]?
struct Preferences { subscript(key: TypedKey<[String: PropertyListValue]?>) -> [String: PropertyListValue]? { storedTables } }
struct Process { let preferences = Preferences() }
enum PreferencesSource { static let process = Process() }
// The order of the menus: by name, whatever the case.
enum ViewerPresetMenus {
    static func sortedNames(_ names: [String]) -> [String] { names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending } }
}
// The choice of the table, as IsiXImaging makes it.
enum ViewerKeyCommand {
CHOICE
}
extension Notification.Name { static let OsirixUpdateOpacityMenu = Notification.Name("UpdateOpacityMenu") }
// The window controller: what it is asked to apply.
final class Controller {
    var applied: [String?] = []
    func inputApplyOpacityString(_ name: NSString?) { applied.append(name as String?) }
}

func hotKey(preset: Int, controller: Controller?) {
    repeat {
CASE
    } while false
}

var failed = false
func check(_ condition: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
    if !condition() { fputs("FAIL: \(what) (line \(line))\n", stderr); failed = true }
}

nonisolated(unsafe) var told: [String?] = []
let observer = NotificationCenter.default.addObserver(forName: .OsirixUpdateOpacityMenu, object: nil, queue: nil) { note in
    told.append(note.object as? String)
}
func press(_ preset: Int, stored: [String]?) -> (applied: [String?], told: [String?]) {
    storedTables = stored.map { names in Dictionary(uniqueKeysWithValues: names.map { ($0, PropertyListValue()) }) }
    told = []
    let controller = Controller()
    hotKey(preset: preset, controller: controller)
    return (controller.applied, told)
}

let linear = NSLocalizedString("Linear Table", comment: "")
for stored in [nil, [], ["beta", "Alpha"]] as [[String]?] {
    let first = press(1, stored: stored)
    check(first.applied == [linear], "the first preset applies the linear table with \(stored?.count ?? -1) stored: \(first.applied)")
    check(first.told == [linear], "the first preset tells the menus the linear table's name with \(stored?.count ?? -1) stored: \(first.told)")
}
let second = press(2, stored: ["beta", "Alpha"]), third = press(3, stored: ["beta", "Alpha"])
check(second.applied == ["Alpha"] && second.told == ["Alpha"], "the second preset is the first stored table by name: \(second)")
check(third.applied == ["beta"] && third.told == ["beta"], "the third preset is the second stored table by name: \(third)")
for (preset, stored) in [(4, ["beta", "Alpha"]), (2, []), (2, nil)] as [(Int, [String]?)] {
    let past = press(preset, stored: stored)
    check(past.applied.isEmpty && past.told.isEmpty, "preset \(preset) past \(stored?.count ?? -1) stored tables does nothing: \(past)")
}
NotificationCenter.default.removeObserver(observer)
exit(failed ? 1 : 0)
'''.replace('CHOICE', choice).replace('CASE', case)

if shutil.which('xcrun') is None or subprocess.run(['xcrun', '--find', 'swiftc'], capture_output=True).returncode != 0:
    sys.stderr.write('skipped: no Swift compiler (xcrun swiftc)\n')
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-opacity-menu-name-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(program, encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', '-o', str(folder / 'hotkey'),
                            str(folder / 'main.swift')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append("the hot key's case does not compile with its stand-ins:\n" + built.stderr[-3000:])
    else:
        ran = subprocess.run([str(folder / 'hotkey')], capture_output=True, text=True)
        if ran.returncode != 0:
            failures.append(f"the hot key's case (exit {ran.returncode}):\n" + ran.stderr[-3000:].strip())

# The hot key sends the table's name to the window's controller by selector:
# the one it names has to be the one the controllers answer.
sent = re.search(r'@objc\(([^)]+)\) func inputApplyOpacityString\(', text('Horos/Sources/DCMView+Tools.swift'))
answered = re.search(r'@objc\(([^)]+)\) func applyOpacityString\(', text('Horos/Sources/OSIWindowController.swift'))
if not sent or not answered:
    failures.append('the message of the opacity hot key or the method of the window controllers that answers it was not found')
elif sent.group(1) != answered.group(1):
    failures.append(f'the opacity hot key sends {sent.group(1)} and the window controllers answer {answered.group(1)}')

if failures:
    sys.exit('FAIL:\n' + '\n'.join(failures))
print(f'PASS: the opacity menu is told the name of an opacity table: {sum(count.values())} announcements of the viewer, '
      'and the hot key of each opacity preset, the linear table included')
