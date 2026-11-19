#!/usr/bin/env python3
"""Saved shading presets come within the shading panel's ranges, and stay
stored as the user saved them until the user edits them.

The shading panel's sliders give, and its number fields accept, the ambient
and diffuse coefficients from 0 to 1, the specular one from 0 to 4 and the
specular power from 0 to 50. A preset saved while the fields had no limits can
hold a value beyond them (a power of 60 typed in the field). Applied as it
was, it made the text beside the Shading check box wider than the widest its
field is measured for, and once the user edited its field in the panel, the
field refused the value and kept the focus (Tab) until it was corrected. A
saved 3D state can hold such a value too.

1. ShadingArrayController, the presets' array controller of VR.xib, MPR.xib
   and Endoscopy.xib, is compiled as it is with IsiXPreferences and a stand-in
   of the process's preferences kept in memory (the probe writes nothing to
   the user's preferences). Given saved presets with values outside the ranges
   in each kind a property list holds them (a real, an integer, text) beside
   one within them, -prepareContent gives the table each value outside its
   range as the nearer end, in the kind it was stored in, and everything else
   (the name, values within, keys it does not know) as stored.
2. Released with nothing edited, the controller stores the list exactly as it
   was saved: the user's list changes only when the user edits it. After an
   edit of one preset (a value set as the field's binding sets it) and a
   preset added with "+", the edited preset is stored as the table holds it,
   the added one as added, and the others as they were saved.
3. ShadingPreset.ranges are the sliders' ranges in every copy of VR.xib,
   Endoscopy.xib and MPR.xib.
4. A 3D preset's preview (-applyPresetToPreview:...) applies its shading
   preset within the ranges, as the window applies it through the controller.
5. A saved 3D state's shading comes within the ranges as a preset's does:
   the statement of -[VRView set3DStateDictionary:] that applies ShadingValues
   and the readers of the saved values, cut from VRView+State.swift (the view
   of the VR, the endoscopy and the 3D MPR), are compiled with the controller
   into a stand-in view. A state beyond the ranges gives the nearer ends; one
   within them gives its own values.

`<git revision>` as an optional argument reads ShadingArrayController.swift,
VRController+Presets.swift and VRView+State.swift from that revision: the
negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

import isix_modules

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
CONTROLLER = 'Horos/Sources/ShadingArrayController.swift'
PREVIEW = 'Horos/Sources/VRController+Presets.swift'
STATE = 'Horos/Sources/VRView+State.swift'
NIB_LANGUAGES = ['en', 'pt-BR', 'de', 'fr', 'ja-JP', 'ko', 'zh-Hans', 'ru', 'hi', 'ar']
RANGES = {'ambient': (0.0, 1.0), 'diffuse': (0.0, 1.0), 'specular': (0.0, 4.0), 'specularPower': (0.0, 50.0)}
failures = []


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


# What the user saved: values typed beyond the ranges as reals (what the
# panel's fields wrote), as integers, as text (the form of the factory
# presets), a key the presets do not know, and a preset within the ranges.
SAVED = [
    {'name': 'Typed', 'ambient': 1.5, 'diffuse': -0.25, 'specular': 6.5, 'specularPower': 60.0, 'kept': 'yes'},
    {'name': 'Whole', 'ambient': 2, 'diffuse': 1, 'specular': 9, 'specularPower': 80},
    {'name': 'Text', 'ambient': '0.15', 'diffuse': '1.4', 'specular': '0.3', 'specularPower': '75'},
    {'name': 'Default', 'ambient': '0.15', 'diffuse': '0.9', 'specular': '0.3', 'specularPower': '15'},
]
SHOWN = [
    {'name': 'Typed', 'ambient': 1.0, 'diffuse': 0.0, 'specular': 4.0, 'specularPower': 50.0, 'kept': 'yes'},
    {'name': 'Whole', 'ambient': 1, 'diffuse': 1, 'specular': 4, 'specularPower': 50},
    {'name': 'Text', 'ambient': '0.15', 'diffuse': '1', 'specular': '0.3', 'specularPower': '50'},
    SAVED[3],
]
EDITED = [
    SAVED[0],
    {'name': 'Whole', 'ambient': 1, 'diffuse': 1, 'specular': 4, 'specularPower': 30},
    SAVED[2],
    SAVED[3],
    {'name': 'Preset 5', 'ambient': 1.0, 'diffuse': 0.0, 'specular': 4.0, 'specularPower': 50.0},
]
# The first table: Typed's ambient 0.5 (its other values as the panel shows
# them, the preset being edited) and a preset added after Whole, with Whole's
# values. The second: Text's diffuse 0.7, and Default removed.
TWO_TABLES = [
    {'name': 'Typed', 'ambient': 0.5, 'diffuse': 0.0, 'specular': 4.0, 'specularPower': 50.0, 'kept': 'yes'},
    SAVED[1],
    {'name': 'Text', 'ambient': '0.15', 'diffuse': '0.7', 'specular': '0.3', 'specularPower': '50'},
    {'name': 'Preset 5', 'ambient': 1, 'diffuse': 1, 'specular': 4, 'specularPower': 50},
]
# A saved 3D state's ShadingValues (ambient, diffuse, specular, power) and what the view applies.
STATES = [([1.5, -0.25, 6.5, 60.0], [1.0, 0.0, 4.0, 50.0]), ([0.25, 0.5, 0.75, 10.0], [0.25, 0.5, 0.75, 10.0])]

STAND_IN = '''import Foundation
import IsiXPreferences

/// The process's graph, for the preferences only, kept in memory.
final class ProcessGraph: Sendable {
    static let process = ProcessGraph()
    let preferences = MemoryPreferences()
}

struct PreferencesSource: Sendable {
    let processGraph: ProcessGraph
    static let process = PreferencesSource(processGraph: ProcessGraph.process)
}
'''

# The view, as far as a saved state's shading reaches it: the statement and the
# readers as VRView+State.swift has them.
STATE_VIEW = '''import Foundation
import IsiXPreferences

@@READERS@@

final class StateView {
    var shading: [Float] = []
    func setShadingValues(_ a: Float, _ d: Float, _ s: Float, _ p: Float) { shading = [a, d, s, p] }
    func set3DStateDictionary(_ dict: [AnyHashable: Any]) {
@@SHADING@@
    }
}
'''

DRIVER = '''import AppKit
import IsiXPreferences

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
func load(_ name: String) -> Any {
    try! PropertyListSerialization.propertyList(from: Data(contentsOf: folder.appendingPathComponent(name)), format: nil)
}
func save(_ object: Any, _ name: String) {
    try! PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        .write(to: folder.appendingPathComponent(name))
}

let preferences = PreferencesSource.process.processGraph.preferences
preferences.set(load("saved.plist"), forKey: "shadingsPresets")
save(ShadingPreset.ranges.map { ["key": $0.key, "low": Double($0.range.lowerBound), "high": Double($0.range.upperBound)] },
     "ranges.plist")

// The panel opened and closed with nothing edited.
weak var first: ShadingArrayController?
autoreleasepool {
    let controller = ShadingArrayController(content: nil)
    first = controller
    controller.prepareContent()
    save(controller.content ?? [], "shown.plist")
}
save(["released": first == nil, "stored": preferences.object(forKey: "shadingsPresets") ?? []], "unedited.plist")

// The specular power of the second preset set in its field, as the binding
// sets it, then "+" with the first preset selected.
weak var second: ShadingArrayController?
autoreleasepool {
    let controller = ShadingArrayController(content: nil)
    second = controller
    controller.prepareContent()
    (controller.arrangedObjects as! [NSMutableDictionary])[1].setValue(NSNumber(value: 30), forKey: "specularPower")
    controller.setSelectionIndex(0)
    controller.addObject(NSMutableDictionary())
}
save(["released": second == nil, "stored": preferences.object(forKey: "shadingsPresets") ?? []], "edited.plist")

// Two tables read from the same list, as two 3D windows open at once: one
// changes the first preset, adds one and closes; the other changes the third,
// removes the last of those it read, and closes after it.
preferences.set(load("saved.plist"), forKey: "shadingsPresets")
weak var third: ShadingArrayController?
autoreleasepool {
    let late = ShadingArrayController(content: nil)
    third = late
    late.prepareContent()
    autoreleasepool {
        let early = ShadingArrayController(content: nil)
        early.prepareContent()
        (early.arrangedObjects as! [NSMutableDictionary])[0].setValue(NSNumber(value: 0.5), forKey: "ambient")
        early.setSelectionIndex(1)
        early.addObject(NSMutableDictionary())
    }
    (late.arrangedObjects as! [NSMutableDictionary])[2].setValue("0.7", forKey: "diffuse")
    late.remove(atArrangedObjectIndex: 3)
}
save(["released": third == nil, "stored": preferences.object(forKey: "shadingsPresets") ?? []], "two-tables.plist")

// Saved 3D states, each read by a new view.
save((load("states.plist") as! [Any]).map { values in
    let view = StateView()
    view.set3DStateDictionary(["ShadingValues": values])
    return view.shading.map { Double($0) }
}, "state-shading.plist")
'''


def same(found, expected):
    """Equal values of the same kinds: a real is not an integer, nor text a number."""
    if isinstance(expected, dict):
        return isinstance(found, dict) and found.keys() == expected.keys() and all(same(found[k], v) for k, v in expected.items())
    if isinstance(expected, list):
        return isinstance(found, list) and len(found) == len(expected) and all(map(same, found, expected))
    return type(found) is type(expected) and found == expected


def compare(found, expected, what):
    if not same(found, expected):
        failures.append(f'{what}:\n    found    {found}\n    expected {expected}')


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

# 1, 2 and 5. The controller and the saved state's statement, compiled as they are.
state = read(STATE)
shading_statement = re.search(r'\n(            if let tempArray = savedArray\(dict\["ShadingValues"\]\) \{\n.*?\n            \})\n',
                              state, re.S)
readers = re.search(r'\n(/// `\[x floatValue\]`.*?)\nextension VRView \{', state, re.S)
if not (shading_statement and readers):
    print(f'FAIL: the parts of {STATE} this probe compiles moved; the test needs a new look')
    sys.exit(1)
with tempfile.TemporaryDirectory(prefix='horos-shading-presets-') as tmp:
    tmp = Path(tmp)
    (tmp / 'ShadingArrayController.swift').write_text(read(CONTROLLER), encoding='utf-8')
    (tmp / 'StandIn.swift').write_text(STAND_IN, encoding='utf-8')
    (tmp / 'StateView.swift').write_text(STATE_VIEW.replace('@@READERS@@', readers.group(1))
                                         .replace('@@SHADING@@', shading_statement.group(1)), encoding='utf-8')
    (tmp / 'main.swift').write_text(DRIVER, encoding='utf-8')
    target = ['-target', 'arm64-apple-macos15.0']
    flags = isix_modules.module_flags('IsiXPreferences', tmp / 'modules', target)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Harness', *target, *flags,
                            str(tmp / 'ShadingArrayController.swift'), str(tmp / 'StandIn.swift'), str(tmp / 'StateView.swift'),
                            str(tmp / 'main.swift'), '-o', str(tmp / 'probe')], capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(build.stdout + build.stderr, file=sys.stderr)
        print(f'FAIL: {CONTROLLER} or the parts of {STATE} ({revision or "working tree"}) do not compile in the harness')
        sys.exit(1)
    (tmp / 'saved.plist').write_bytes(plistlib.dumps(SAVED))
    (tmp / 'states.plist').write_bytes(plistlib.dumps([saved for saved, _ in STATES]))
    run = subprocess.run([str(tmp / 'probe'), str(tmp)], capture_output=True, text=True, timeout=120)
    if run.returncode:
        print(run.stdout + run.stderr, file=sys.stderr)
        print('FAIL: the probe stopped')
        sys.exit(1)
    shown = plistlib.loads((tmp / 'shown.plist').read_bytes())
    unedited = plistlib.loads((tmp / 'unedited.plist').read_bytes())
    edited = plistlib.loads((tmp / 'edited.plist').read_bytes())
    ranges = plistlib.loads((tmp / 'ranges.plist').read_bytes())
    state_shading = plistlib.loads((tmp / 'state-shading.plist').read_bytes())
    two_tables = plistlib.loads((tmp / 'two-tables.plist').read_bytes()) if (tmp / 'two-tables.plist').exists() else None

compare(shown, SHOWN, 'the panel shows each value outside its range as the nearer end, in its own kind')
for preset in shown:
    for key, (low, high) in RANGES.items():
        value = preset.get(key)
        number = float(value) if isinstance(value, (int, float, str)) else 0.0
        if not low <= number <= high:
            failures.append(f'the panel shows {preset.get("name")} {key} {value!r}, outside {low} to {high}')
if not unedited['released'] or not edited['released']:
    failures.append('the probe did not release its controllers, so their deinit did not run')
compare(unedited['stored'], SAVED, 'nothing edited: the user\'s list is stored as it was saved')
compare(edited['stored'], EDITED, 'one preset edited and one added: those as the table holds them, the others as saved')

# Two tables open at once: what each did is in the list, whichever closes last.
if not two_tables or not two_tables['released']:
    failures.append('the probe of two tables did not run to its end')
else:
    compare(two_tables['stored'], TWO_TABLES, 'two tables open at once: the changes, the addition and the removal of both')

# 3. The ranges are the sliders'.
compare({entry['key']: (entry['low'], entry['high']) for entry in ranges}, RANGES, 'ShadingPreset.ranges')
for language in NIB_LANGUAGES:
    for name in ('VR', 'Endoscopy', 'MPR'):
        text = (root / f'Horos/Resources/{language}.lproj/{name}.xib').read_text(encoding='utf-8')
        for key, (low, high) in RANGES.items():
            bound = r'<binding [^>]*name="value" keyPath="selection\.%s"' % key
            sliders = [s for s in re.findall(r'<slider [^>]*>.*?</slider>', text, re.S) if re.search(bound, s)]
            if len(sliders) != 1:
                failures.append(f'{language} {name}.xib {key}: {len(sliders)} sliders')
                continue
            cell = re.search(r'<sliderCell [^>]*>', sliders[0]).group(0)
            minimum = re.search(r'minValue="([-\d.]+)"', cell)
            maximum = re.search(r'maxValue="([-\d.]+)"', cell)
            found = (float(minimum.group(1)) if minimum else 0.0, float(maximum.group(1)) if maximum else 1.0)
            if found != (low, high):
                failures.append(f'{language} {name}.xib {key}: the slider gives {found}, ShadingPreset.ranges {(low, high)}')

# 4. The preview of a 3D preset.
preview = read(PREVIEW)
if not re.search(r'let shading = presets\.(?:first|last)\(where: \{ \$0\.name == shadingName \}\)\?\.withinRanges\b', preview):
    failures.append(f'{PREVIEW}: a 3D preset\'s preview applies its shading preset as saved, not within the ranges')
# Of two presets of one name the window selects the first of its table (the
# loop that applies a 3D preset stops at it): the preview shows that one too.
if not re.search(r'where \(dict\.value\(forKey: "name"\) as\? String\) == shadingName \{\s*'
                 r'shadingsPresetsController\?\.setSelectedObjects\(\[dict\]\)\s*break', preview):
    failures.append(f'{PREVIEW}: the window no longer selects the first shading preset of a 3D preset\'s name; the test needs a new look')
if 'presets.first(where: { $0.name == shadingName })' not in preview:
    failures.append(f'{PREVIEW}: of two shading presets of one name the preview shows the last and the window selects the first')

# 5. A saved 3D state.
compare(state_shading, [applied for _, applied in STATES],
        f'{STATE}: a saved 3D state\'s shading comes within the ranges, one within them as saved')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: saved shading presets come within the sliders\' ranges and stay stored as saved until edited '
      f'({revision or "working tree"})')
