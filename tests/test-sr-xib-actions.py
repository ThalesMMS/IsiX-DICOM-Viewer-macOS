#!/usr/bin/env python3
"""Every action of SR.xib, the surface rendering window, has an implementation.

A nib action whose target does not implement it does nothing, or worse: the
QuickTime VR sheet's OK and Cancel sent -endQuicktimeVRSettings: to the surface
view, which no class implements, so the sheet, once open, could not be closed.
Only the contextual menu, which was never built, opened it; the sheet, its
outlets and the menu are gone.

For each of the ten localized SR.xib, every <action selector target> is
resolved to the class of its target - the File's Owner (SRController), a
custom view (SRView) or an AppKit object (a window, a control) - and looked up
in the app's sources and in AppKit, as tests/xib_actions.py explains.

The same lookup over the English SR.xib of the revision before the sheet was
taken out must find -endQuicktimeVRSettings: missing, so the check sees the
defect it guards against.

-[SRController setDefaultTool:] and -setOrientation: read what their sender
chose through chosenTag(of:), compiled here from SRController.swift: the
selected cell of a matrix (the tools and orientation matrices of SR.xib) or a
menu item's own tag, which used to be read as a cell and gave nothing.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
from xib_actions import block, missing_actions, nib_actions  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
failures = []


def check(condition, what):
    print('%s: %s' % ('PASS' if condition else 'FAIL', what))
    if not condition:
        failures.append(what)


with tempfile.TemporaryDirectory(prefix='isix-sr-xib-actions-') as name:
    folder = Path(name)
    nibs = sorted(ROOT.glob('Horos/Resources/*.lproj/SR.xib'))
    check(len(nibs) == 10, 'ten localized SR.xib (%d)' % len(nibs))
    english = nib_actions((ROOT / 'Horos/Resources/en.lproj/SR.xib').read_text(encoding='utf-8'))
    for nib in nibs:
        actions = nib_actions(nib.read_text(encoding='utf-8'))
        missing = missing_actions(actions, folder)
        check(not missing and actions, '%s: its %d actions (%d selectors) are all implemented%s'
              % (nib.parent.name, len(actions), len({s for s, _ in actions}),
                 '' if not missing else ': missing %s' % missing))
        check(sorted(actions) == sorted(english),
              '%s: the same actions as the English SR.xib' % nib.parent.name)
    check(('setDefaultTool:', 'SRController') in english and ('setOrientation:', 'SRController') in english
          and ('ApplySettings:', 'SRController') in english and ('endQuicktimeSettings:', 'SRView') in english,
          'the lookup reaches the controller and the view')
    check(not any(selector == 'endQuicktimeVRSettings:' for selector, _ in english),
          'no action sends -endQuicktimeVRSettings:')

    path = 'Horos/Resources/en.lproj/SR.xib'
    if b'endQuicktimeVRSettings:' in history_reference.show('HEAD', path):
        reference = 'HEAD'
    else:
        reference = history_reference.before_text_removed(path, 'endQuicktimeVRSettings:')
    if reference is None:
        print('note: the history does not reach the SR.xib with the QuickTime VR sheet; not compared')
    else:
        former = missing_actions(nib_actions(history_reference.show(reference, path).decode('utf-8')), folder)
        check(former == [('endQuicktimeVRSettings:', 'SRView')],
              'the English SR.xib of %s sends -endQuicktimeVRSettings:, which nothing implements (%s)'
              % (reference[:9], former))

    # The tag a sender chose.
    controller = (SOURCES / 'SRController.swift').read_text(encoding='utf-8')
    start = controller.index('    static func chosenTag(of sender: Any?) -> Int? {')
    function = controller[start:controller.index('{', start)] + block(controller, start)
    (folder / 'tag.swift').write_text('import AppKit\nenum SR {\n' + function + '\n}\n' + r'''
let matrix = NSMatrix(frame: .zero, mode: .radioModeMatrix, prototype: NSButtonCell(), numberOfRows: 1, numberOfColumns: 4)
for (index, cell) in matrix.cells.enumerated() { cell.tag = index }
matrix.selectCell(atRow: 0, column: 3)
let item = NSMenuItem(title: "Control Model", action: nil, keyEquivalent: "")
item.tag = 7
let button = NSButton(frame: .zero)
button.tag = 2
print(SR.chosenTag(of: matrix).map(String.init) ?? "nil", SR.chosenTag(of: item).map(String.init) ?? "nil",
      SR.chosenTag(of: nil).map(String.init) ?? "nil", SR.chosenTag(of: "text").map(String.init) ?? "nil",
      SR.chosenTag(of: button).map(String.init) ?? "nil")
''')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(folder / 'tag.swift'), '-o', str(folder / 'tag')],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        check(False, 'chosenTag(of:) compiles: %s' % built.stderr[-2000:])
    else:
        answer = subprocess.run([str(folder / 'tag')], capture_output=True, text=True, timeout=60).stdout.split()
        check(answer[:4] == ['3', '7', 'nil', 'nil'],
              'the tools and orientation actions read a matrix\'s selected cell and a menu item\'s tag (%s)' % answer)

if failures:
    print('%d failure(s)' % len(failures))
    raise SystemExit(1)
print('PASS: every action of the ten SR.xib has an implementation, and a menu item chooses a tool or orientation')
