#!/usr/bin/env python3
"""The table pop-ups of the PET pane show the whole name of each table.

The pop-up of the opacity table and the two of the colour tables were 83
points wide in every copy of the pane's nib, and the pane's code fills them
with the names of the tables: "Linear Table" read "Linear…", "Logarithmic
Table" read "Logari…", and a colour table such as "VR Muscles-Bones" was cut
too. The pane has room beside each pop-up, to the trailing edge of its box.

Checked here, for the Base nib and its nine copies compiled from source with
ibtool: the pop-up the pane's OpacityTableMenu outlet names, filled with
"Linear Table" and the opacity tables of the factory defaults, and the pop-ups
its DefaultCLUTMenu and CLUTBlendingMenu outlets name, filled with the colour
tables of the factory defaults, are each as wide as the widest item needs and
end inside the view they are in; and the same measure takes the width they had
before for too narrow.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
pane = root / 'Preference Panes/OSIPETPreferencePane'
copies = sorted(pane.glob('*.lproj/OSIPETPreferencePanePref.xib')) + sorted((root / 'Horos/Resources').glob('*.lproj/OSIPETPreferencePanePref.xib'))
assert len(copies) == 10, f'expected the Base nib and nine copies, found {len(copies)}'

# The names the pane lists: its own first item and the tables the application installs.
presets = (root / 'Modules/IsiXPreferences/Sources/DefaultPreferences+ImagePresets.swift').read_text()
factory = presets[presets.index('static func factoryOpacityTables()'):]
factory = factory[:factory.index('\n    }\n')]
names = ['Linear Table'] + re.findall(r'^\s*"([^"]+)": OpacityTablePreset\(', factory, re.M)
assert 'Logarithmic Inverse Table' in names and len(names) >= 3, names
colours = presets[presets.index('static func factoryColourTables()') if 'static func factoryColourTables()' in presets else 0:]
colour_names = re.findall(r'tables\["([^"]+)"\] = ColourTablePreset\(', colours)
listed = re.search(r'for name in \[((?:\s*"[^"]+",?)+)\s*\]', colours)
colour_names += re.findall(r'"([^"]+)"', listed.group(1)) if listed else []
assert 'VR Muscles-Bones' in colour_names and 'B/W Inverse' in colour_names, colour_names

DRIVER = r'''
import AppKit
let app = NSApplication.shared
final class Owner: NSObject {
    @objc var OpacityTableMenu: NSPopUpButton?
    @objc var DefaultCLUTMenu: NSPopUpButton?
    @objc var CLUTBlendingMenu: NSPopUpButton?
    override func value(forUndefinedKey key: String) -> Any? { nil }
    override func setValue(_ value: Any?, forUndefinedKey key: String) {}
}
struct Input: Decodable { let nibs: [String]; let names: [String]; let colours: [String] }
let input = try! JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var failures: [String] = []
MainActor.assumeIsolated {
    for path in input.nibs {
        let owner = Owner()
        var objects: NSArray?
        NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: path)), bundle: nil).instantiate(withOwner: owner, topLevelObjects: &objects)
        let copy = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        for (outlet, connected, names) in [("OpacityTableMenu", owner.OpacityTableMenu, input.names),
                                           ("DefaultCLUTMenu", owner.DefaultCLUTMenu, input.colours),
                                           ("CLUTBlendingMenu", owner.CLUTBlendingMenu, input.colours)] {
            guard let popUp = connected, let parent = popUp.superview else {
                failures.append("\(copy): the nib connects no pop-up to \(outlet)")
                continue
            }
            popUp.removeAllItems()
            popUp.addItems(withTitles: names)
            var widest: CGFloat = 0
            for name in names {
                popUp.selectItem(withTitle: name)
                widest = max(widest, ceil(popUp.cell!.cellSize.width))
            }
            if widest > popUp.frame.width + 0.5 {
                failures.append("\(copy): \(outlet) has \(Int(popUp.frame.width)) points, its widest table name needs \(Int(widest))")
            }
            if popUp.frame.maxX > parent.bounds.width + 0.5 { failures.append("\(copy): \(outlet) leaves its view") }
            if widest <= 83 { failures.append("\(copy): the measure takes the former 83 points of \(outlet) for enough") }
        }
        _ = objects
    }
}
for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-pet-popup-') as name:
    directory = Path(name)
    nibs = []
    for xib in copies:
        nib = directory / f'{xib.parent.name.replace(".lproj", "")}.nib'
        subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), '--flatten', 'YES', str(xib)], check=True,
                       stdout=subprocess.DEVNULL, timeout=300)
        nibs.append(str(nib))
    (directory / 'input.json').write_text(json.dumps({'nibs': nibs, 'names': names, 'colours': colour_names}))
    (directory / 'main.swift').write_text(DRIVER)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', str(directory / 'main.swift'),
                            '-o', str(directory / 'check')], timeout=600)
    if build.returncode:
        print('FAIL: the driver does not build')
        raise SystemExit(1)
    result = subprocess.run([str(directory / 'check'), str(directory / 'input.json')], capture_output=True, text=True, timeout=300)
    sys.stdout.write(result.stdout)
    if result.returncode == 0:
        print(f'PASS: {len(copies)} copies of the pane, {len(names)} opacity tables and {len(colour_names)} colour tables')
    raise SystemExit(result.returncode)
