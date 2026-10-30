#!/usr/bin/env python3
"""After a deletion, the slice's ROI created last is selected.

Deleting the selected ROIs with the Delete key (-[DCMView keyDown:]) or Cut
(-[DCMView cut:]) leaves selected the first ROI of the slice's list that is
neither hidden, locked nor unselectable, so that the next Delete removes it.
The list runs from the front to the back and a new ROI is brought to the
front, so the first is the newest, and the list keeps that order through a
save and a reopening. -[ViewerController bringToFrontROI:], called on every
new ROI, is checked to still insert at the start. Nothing is selected while another ROI is still selected or
being edited, and nothing when ROISelectPreviousAfterDelete is off.

The production -selectSuccessorOfDeletedROIs (DCMView+ROIEditing.swift) and
HorosROIDeletionSuccessor run here against a stand-in ROI with the properties
they read. The switch is registered on and bound once in every localization of
the Viewer pane.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
KEY = 'ROISelectPreviousAfterDelete'
swift = (root / 'Horos/Sources/DCMView+ROIEditing.swift').read_text()


def swift_method(selector):
    start = swift.index(f'    @objc({selector})\n')
    return swift[start:swift.index('\n    }\n', start) + 7]


method = swift_method('selectSuccessorOfDeletedROIs')

code = r"""
import Cocoa
let ROI_sleep = 0, ROI_drawing = 1, ROI_selected = 2, ROI_selectedModify = 3
extension NSNotification.Name { static let OsirixROISelected = NSNotification.Name("OsirixROISelectedNotification") }
final class ROI: NSObject {
    @objc dynamic var hidden = false, locked = false, selectable = true
    @objc(ROImode) dynamic var roImode = 0
}
final class DCMView: NSObject {
    var horos_curRoiList: NSMutableArray? = NSMutableArray()
METHOD
}
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { print("FAIL line \(line): " + what); exit(1) } }
func roi() -> ROI { ROI() }

let d = UserDefaults.standard
d.setVolatileDomain(["KEY": true], forName: UserDefaults.argumentDomain)
var notified: AnyObject?
NotificationCenter.default.addObserver(forName: .OsirixROISelected, object: nil, queue: nil) { notified = $0.object as AnyObject? }

// Created a, b, c: each new ROI went to the front, so the list is c, b, a.
let a = roi(), b = roi(), c = roi()
let v = DCMView()
v.horos_curRoiList = NSMutableArray(array: [c, b, a])
v.selectSuccessorOfDeletedROIs()
check(c.roImode == ROI_selected && notified === c && b.roImode == ROI_sleep && a.roImode == ROI_sleep, "the newest first")

// Delete again: the previous one, down to the first created.
v.horos_curRoiList?.remove(c); notified = nil
v.selectSuccessorOfDeletedROIs()
check(b.roImode == ROI_selected && notified === b, "then the previous one")
v.horos_curRoiList?.remove(b)
v.selectSuccessorOfDeletedROIs()
check(a.roImode == ROI_selected && notified === a, "down to the first")
v.horos_curRoiList?.remove(a); notified = nil
v.selectSuccessorOfDeletedROIs()
check(notified == nil, "nothing left")

// Hidden, locked and unselectable ROIs are skipped.
let hidden = roi(), locked = roi(), fixed = roi(), open = roi()
hidden.hidden = true; locked.locked = true; fixed.selectable = false
v.horos_curRoiList = NSMutableArray(array: [hidden, locked, fixed, open])
v.selectSuccessorOfDeletedROIs()
check(open.roImode == ROI_selected && locked.roImode == ROI_sleep && hidden.roImode == ROI_sleep && fixed.roImode == ROI_sleep, "skipped")

// A ROI still selected or being edited keeps the selection as it is.
let older = roi(), edited = roi()
edited.roImode = ROI_selectedModify; notified = nil
v.horos_curRoiList = NSMutableArray(array: [edited, older])
v.selectSuccessorOfDeletedROIs()
check(older.roImode == ROI_sleep && notified == nil, "selection kept")

// Switched off, nothing is selected.
d.setVolatileDomain(["KEY": false], forName: UserDefaults.argumentDomain)
let last = roi()
v.horos_curRoiList = NSMutableArray(array: [last])
v.selectSuccessorOfDeletedROIs()
check(last.roImode == ROI_sleep && notified == nil, "switch off")
check(ROIDeletionSuccessor.preferenceKey == "KEY", "the preference key")
print("PASS: front of the list first, repeated deletions, hidden/locked/unselectable skipped, selection kept, switch off")
""".replace('METHOD', method).replace('KEY', KEY)

with tempfile.TemporaryDirectory(prefix='horos-delete-successor-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(p / 'modules'),
                    str(p / 'main.swift'), str(root / 'Horos/Sources/ROIDeletionSuccessor.swift'),
                    '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)

# Both deletion paths call it once their whole ROIs are gone, and a new ROI
# still goes to the front of its slice.
# The Delete key is Swift (DCMView+Keyboard.swift), the click that adds a ROI
# too (DCMView+Mouse.swift).
keyboard = (root / 'Horos/Sources/DCMView+Keyboard.swift').read_text()
assert 'self.deleteSelectedROIs()' in keyboard[keyboard.index('Int(c) == NSDeleteFunctionKey'):keyboard.index('Return - Enter - Space')], \
    '-keyDown:: Delete no longer deletes the selected ROIs'
text = keyboard[keyboard.index('private func deleteSelectedROIs()'):keyboard.index('@objc(keyUp:)')]
assert text.count('removed = true') >= 1, '-keyDown:: a deletion does not mark the ROI removed'
assert 'if removed {\n                    self.selectSuccessorOfDeletedROIs()' in text, '-keyDown:: no successor selected'
text = swift_method('cut:')
assert text.count('removed = true') >= 1, '-cut:: a deletion does not mark the ROI removed'
assert 'if removed {\n                self.selectSuccessorOfDeletedROIs()' in text, '-cut:: no successor selected'
mouse = (root / 'Horos/Sources/DCMView+Mouse.swift').read_text()
creation = mouse[mouse.index('self.horos_curRoiList?.add(aNewROI)'):]
assert creation.index('wc?.inputBringToFrontROI(aNewROI)') < 1200, 'a new ROI is no longer brought to the front'
editing = (root / 'Horos/Sources/ViewerController+ROI+Editing.swift').read_text()
front = editing[editing.index('func bring(toFrontROI roi: ROI!)'):]
front = front[:front.index('} else {')]
assert 'objcInsert(self.roi2CurrentSlice(), roi, 0)' in front, 'Bring to Front no longer inserts at the start of the list'

import sys  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
assert default_preferences.registered().get(KEY) == '1', 'the switch is not registered on'
panes = [root / 'Preference Panes/OSIViewerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')]
panes += [root / 'Horos/Resources' / f'{language}.lproj' for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')]
for pane in panes:
    tree = ET.parse(pane / 'OSIViewerPreferencePanePref.xib')
    assert len(tree.findall(f'.//binding[@keyPath="values.{KEY}"]')) == 1, pane.name
    box = tree.find('.//box[@id="100"]/view')
    button = box.find('.//button[@id="roi-delete-successor-control"]')
    assert button is not None and button.find('buttonCell').get('title'), pane.name
    frame = button.find('rect')
    mine = (float(frame.get('x')), float(frame.get('y')))
    for other in box.iter('button'):
        r = other.find('rect')
        if other is not button and r is not None:
            assert (float(r.get('x')), float(r.get('y'))) != mine, f'{pane.name}: overlaps {other.get("id")}'
print(f'PASS: {KEY} registered on and bound in {len(panes)} localizations; Delete and Cut select the successor')
