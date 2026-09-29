#!/usr/bin/env python3
"""Execute the real modifier handler: typing Shift must not replace the field editor.

The handler is BrowserController's flagsChanged(with:), in
BrowserController+Toolbar.swift since #831. The test extracts it verbatim and
compiles it with swiftc inside a stand-in BrowserController.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

s = source_text('BrowserController+Toolbar')
a = s.index('    override func flagsChanged(with event: NSEvent?)')
method = s[a:s.index('    @objc(setupToolbar)', a)]
identifiers = set(re.findall(r'\b\w+ToolbarItemIdentifier\b', method))
constants = '\n'.join(f'let {name} = "{name}"' for name in sorted(identifiers))
code = r'''
import AppKit
CONSTANTS
extension NSImage {
    static func toolbarImageNamed(_ name: String) -> NSImage? { return nil }
}
final class Outline {
    var editedRow = 0
}
final class BrowserController: NSResponder {
    var horos_databaseOutline: Outline?
    var horos_toolbar: NSToolbar?
    var horos_previousFlags: UInt = 0
    var horos_refreshDeferredWhileEditing = false
    var changes = 0
    func outlineViewSelectionDidChange(_ notification: Notification?) { changes += 1 }
    @objc func viewerDICOMKeyImages(_ sender: Any?) {}
    @objc func viewerDICOMROIsImages(_ sender: Any?) {}
    @objc func viewerKeyImagesAndROIsImages(_ sender: Any?) {}
    @objc func exportROIAndKeyImagesAsDICOMSeries(_ sender: Any?) {}
METHOD
}
func event(_ flags: NSEvent.ModifierFlags) -> NSEvent {
    return NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                            timestamp: 0, windowNumber: 0, context: nil, characters: "",
                            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56)!
}
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}
let b = BrowserController()
let outline = Outline()
b.horos_databaseOutline = outline
b.horos_toolbar = NSToolbar(identifier: "probe")
outline.editedRow = 0
var e = event(.shift)
b.flagsChanged(with: e)
check(b.changes == 0, "Modifier key stole the active comment editor")
check(b.horos_refreshDeferredWhileEditing, "Selection refresh must be deferred")
check(b.horos_previousFlags == e.modifierFlags.rawValue, "Toolbar modifier state must stay current")
outline.editedRow = -1
e = event([])
b.flagsChanged(with: e)
check(b.changes == 1, "Normal modifier selection refresh must still run")
b.flagsChanged(with: e)
check(b.changes == 1, "Unchanged modifiers must not refresh")
print("PASS: modifier selection refresh deferred during editing and retained outside it")
'''.replace('CONSTANTS', constants).replace('METHOD', method)
with tempfile.TemporaryDirectory(prefix='horos-comment-modifiers-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
