#!/usr/bin/env python3
"""Every action of VR.xib, the volume rendering window, has an implementation.

VR.xib had the QuickTime VR export sheet that SR.xib had: its OK and Cancel
sent -endQuicktimeVRSettings: to the volume view, which no class implements,
so the sheet, once open, could not be closed. Only -[VRView
exportQuicktime3DVR:] opened it, and nothing sent that action: no nib, menu or
code. The sheet, the view's three outlets to it (export3DVRWindow, VRFrames,
VRquality) and the action are gone from the ten localized VR.xib and from
VRView.

For each of the ten localized VR.xib, every <action selector target> is
resolved to the class of its target - the File's Owner (VRController), a
custom view or object (VRView, VRPresetPreview, the CLUT editors), an AppKit
object, or the first responder - and looked up in the app's sources and in
AppKit, as tests/xib_actions.py explains. The ten nibs have the same actions.

The same lookup over the English VR.xib of the revision before the sheet was
taken out must find -endQuicktimeVRSettings: missing, so the check sees the
defect it guards against. No outlet of the nibs names the sheet's outlets, and
VRView no longer declares them nor the action that opened it.
"""
import re
import sys
import tempfile
import xml.etree.ElementTree as ElementTree
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
from xib_actions import missing_actions, nib_actions  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
SHEET_OUTLETS = ('export3DVRWindow', 'VRFrames', 'VRquality')
failures = []


def check(condition, what):
    print('%s: %s' % ('PASS' if condition else 'FAIL', what))
    if not condition:
        failures.append(what)


def outlets(text):
    return sorted(outlet.get('property') for outlet in ElementTree.fromstring(text).iter('outlet'))


with tempfile.TemporaryDirectory(prefix='isix-vr-xib-actions-') as name:
    folder = Path(name)
    nibs = sorted(ROOT.glob('Horos/Resources/*.lproj/VR.xib'))
    check(len(nibs) == 10, 'ten localized VR.xib (%d)' % len(nibs))
    english_text = (ROOT / 'Horos/Resources/en.lproj/VR.xib').read_text(encoding='utf-8')
    english = nib_actions(english_text)
    for nib in nibs:
        text = nib.read_text(encoding='utf-8')
        actions = nib_actions(text)
        missing = missing_actions(actions, folder)
        check(not missing and actions, '%s: its %d actions (%d selectors) are all implemented%s'
              % (nib.parent.name, len(actions), len({s for s, _ in actions}),
                 '' if not missing else ': missing %s' % missing))
        check(sorted(actions) == sorted(english), '%s: the same actions as the English VR.xib' % nib.parent.name)
        check(not set(SHEET_OUTLETS) & set(outlets(text)), '%s: no outlet to the QuickTime VR sheet' % nib.parent.name)
    check(('setDefaultTool:', 'VRController') in english and ('endQuicktimeSettings:', 'VRView') in english
          and any(cls == 'FirstResponder' for _, cls in english),
          'the lookup reaches the controller, the view and the first responder')
    check(not any(selector == 'endQuicktimeVRSettings:' for selector, _ in english),
          'no action sends -endQuicktimeVRSettings:')

    view = '\n'.join(path.read_text(encoding='utf-8') for path in SOURCES.glob('VRView*.swift'))
    for outlet in SHEET_OUTLETS:
        check(not re.search(r'\bvar\s+%s\b' % outlet, view), 'VRView no longer declares the outlet %s' % outlet)
    check('exportQuicktime3DVR' not in view, 'VRView no longer has -exportQuicktime3DVR:, which opened the sheet')

    path = 'Horos/Resources/en.lproj/VR.xib'
    if b'endQuicktimeVRSettings:' in history_reference.show('HEAD', path):
        reference = 'HEAD'
    else:
        reference = history_reference.before_text_removed(path, 'endQuicktimeVRSettings:')
    if reference is None:
        print('note: the history does not reach the VR.xib with the QuickTime VR sheet; not compared')
    else:
        former = missing_actions(nib_actions(history_reference.show(reference, path).decode('utf-8')), folder)
        check(former == [('endQuicktimeVRSettings:', 'VRView')],
              'the English VR.xib of %s sends -endQuicktimeVRSettings:, which nothing implements (%s)'
              % (reference[:9], former))

if failures:
    print('%d failure(s)' % len(failures))
    raise SystemExit(1)
print('PASS: every action of the ten VR.xib has an implementation, and the QuickTime VR sheet is gone')
