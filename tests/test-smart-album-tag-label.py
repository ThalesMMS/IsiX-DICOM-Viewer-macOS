#!/usr/bin/env python3
"""A new smart album row's tag pop-up shows "Select a Tag...".

The cell drew noSelectionLabel in -drawInteriorWithFrame:inView:, which AppKit
no longer calls for that text: a new row's pop-up was blank. The button now
shows the label as a subview while no item is selected, and hides it once one
is. The editor's scroll view and the SQL text view had fixed light colours,
a light band in dark mode; they use the system's colours.

O2DicomPredicateEditorPopUpButton.swift is compiled as it is, with an
N2PopUpMenu double, and laid out in an offscreen window. `<git revision>` as an
optional argument reads the sources from that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text()


failures = []
for xib in ('Horos/Resources/en.lproj/SmartAlbum.xib', 'Horos/Resources/ja-JP.lproj/SmartAlbum.xib'):
    text = read(xib)
    if re.search(r'<color key="backgroundColor" white="(1|0\.91\d*)" alpha="1" colorSpace="calibratedWhite"/>', text):
        failures.append(f'{xib}: the editor or the SQL view still has a fixed light background')

main = r'''
import AppKit
final class N2PopUpMenu: NSObject {
    static func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSPopUpButton, with font: NSFont?) -> NSWindow? { nil }
}
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
let button = O2DicomPredicateEditorPopUpButton(frame: NSRect(x: 10, y: 10, width: 40, height: 20), pullsDown: false)
button.bezelStyle = .roundRect
button.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
button.noSelectionLabel = "Select a Tag..."
window.contentView!.addSubview(button)
button.sizeToFit()
func label() -> NSTextField? { button.subviews.compactMap { $0 as? NSTextField }.first }
func show() { button.needsLayout = true; button.layoutSubtreeIfNeeded(); button.viewWillDraw(); window.displayIfNeeded() }
show()
guard let field = label(), !field.isHidden, field.stringValue == "Select a Tag..." else { print("FAIL: no visible label without a selection"); exit(1) }
let needed = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width
if field.frame.width < needed { print("FAIL: the label is \(field.frame.width) pt wide, its text \(needed)"); exit(1) }
button.addItem(withTitle: "Modality")
button.selectItem(at: 0)
show()
if let field = label(), !field.isHidden { print("FAIL: the label stays over a selected item"); exit(1) }
let plain = O2DicomPredicateEditorPopUpButton(frame: NSRect(x: 10, y: 10, width: 60, height: 20), pullsDown: false)
window.contentView!.addSubview(plain)
plain.needsLayout = true; plain.layoutSubtreeIfNeeded(); plain.viewWillDraw()
if plain.subviews.contains(where: { ($0 as? NSTextField).map { !$0.isHidden } ?? false }) { print("FAIL: a pop-up without a label shows one"); exit(1) }
print("ok")
'''

with tempfile.TemporaryDirectory(prefix='horos-smart-album-label-') as tmp:
    p = Path(tmp)
    (p / 'Button.swift').write_text(read('Horos/Sources/O2DicomPredicateEditorPopUpButton.swift'))
    (p / 'main.swift').write_text(main)
    build = subprocess.run(['xcrun', 'swiftc', str(p / 'Button.swift'), str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stderr[-2000:])
        failures.append('the pop-up button does not compile')
    else:
        done = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
        for line in done.stdout.splitlines():
            if line.startswith('FAIL: '):
                failures.append(line[6:])
        if done.returncode and not any(l.startswith('FAIL: ') for l in done.stdout.splitlines()):
            failures.append(f'the harness stopped with status {done.returncode}: {done.stderr[-300:]}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: a new row\'s tag pop-up shows its label until an item is selected; the editor follows the system colours')
