#!/usr/bin/env python3
"""Which open 2D viewers say "Previous".

With studies of one patient open on different days, every study older than
the newest is marked; studies of the same day, a lone study, studies of other
patients and studies without a date are not. Patients are compared without
case, accents or width, as the viewers' study colours compare them.
HorosPreviousStudyMark itself is compiled and asked, with the label it draws.

The 2D viewer records the mark for every displayed viewer where it computes
the study colours, so opening, closing and switching a study update it, and
draws it only from the Base annotation level up, centred at the bottom; the
label is translated in every host catalog.

A check of the Viewers pane, ShowPreviousExamLabel (on by default), turns it
off: the label is drawn only while it is on, and a change redraws the open
viewers without touching their images. The check is made in code in the free
place under "Only display images of the same patient", which every localized
copy of the pane has, and its title fits there in every language.
"""
from pathlib import Path
import plistlib
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

driver = r'''
import AppKit

func check(_ condition: Bool, _ message: String) {
    if !condition { FileHandle.standardError.write(("FAIL: " + message + "\n").data(using: .utf8)!); exit(1) }
}
func day(_ text: String, _ hour: Int = 10) -> Any {
    var c = DateComponents(); c.calendar = Calendar(identifier: .gregorian)
    let p = text.split(separator: "-").map { Int($0)! }
    c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = hour
    return c.date!
}
func previous(_ patients: [String], _ dates: [Any]) -> [Int] {
    Array(PreviousStudyMark.previousIndices(patients: patients, dates: dates))
}

check(previous(["P1"], [day("2026-10-19")]) == [], "a lone study")
check(previous(["P1", "P1"], [day("2026-10-19"), day("2025-03-01")]) == [1], "the older of two")
check(previous(["P1", "P1", "P1"], [day("2024-01-01"), day("2026-10-19"), day("2025-03-01")]) == [0, 2], "all but the newest")
check(previous(["P1", "P1"], [day("2026-10-19", 8), day("2026-10-19", 20)]) == [], "two studies of the same day")
check(previous(["P1", "P2"], [day("2026-10-19"), day("2025-03-01")]) == [], "another patient's study")
check(previous(["P1", "P1", "P2", "P2"], [day("2026-10-19"), day("2025-03-01"), day("2020-01-01"), day("2021-01-01")]) == [1, 2],
      "each patient's own newest")
check(previous(["P1", "P1"], [day("2026-10-19"), NSNull()]) == [], "a study without a date")
check(previous(["", ""], [day("2026-10-19"), day("2025-03-01")]) == [], "studies without a patient")
check(previous(["0", "0"], [day("2026-10-19"), day("2025-03-01")]) == [], "the placeholder patient")
check(previous(["ROSSI^MARIO", "rossi^mário"], [day("2026-10-19"), day("2025-03-01")]) == [1], "case and accents")

MainActor.assumeIsolated {
    let a = NSObject(), b = NSObject()
    PreviousStudyMark.setPrevious(true, for: a)
    check(PreviousStudyMark.isPrevious(a) && !PreviousStudyMark.isPrevious(b) && !PreviousStudyMark.isPrevious(nil), "recorded per viewer")
    PreviousStudyMark.setPrevious(false, for: a)
    check(!PreviousStudyMark.isPrevious(a), "cleared")
    let label = PreviousStudyMark.label
    check(label.frameSize.width > 60 && label.frameSize.height >= 18, "label size \(label.frameSize)")
    check(PreviousStudyMark.label === label, "the label is made once")
}
print("ok")
'''

with tempfile.TemporaryDirectory() as folder:
    main = Path(folder) / 'main.swift'
    main.write_text(driver)
    binary = Path(folder) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(Path(folder) / 'modules'),
                    str(root / 'Horos/Sources/PreviousStudyMark.swift'), str(root / 'Horos/Sources/AnnotationOverlay.swift'),
                    str(root / 'Horos/Sources/ROICanvas.swift'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)


def fail(message):
    print('FAIL:', message)
    raise SystemExit(1)


# -computeColor is Swift (DCMView+Geometry.swift).
geometry = (root / 'Horos/Sources/DCMView+Geometry.swift').read_text()
compute = geometry[geometry.index('    private func computeStudyColours() {'):]
compute = compute[:compute.index('\n    }\n')]
if 'PreviousStudyMark.previousIndices(' not in compute or 'PreviousStudyMark.setPrevious(' not in compute:
    fail('computeColor does not record the previous exams')
if compute.index('PreviousStudyMark.previousIndices(') > compute.index('guard !studies.isEmpty else { return }'):
    fail('the mark is recorded only when there are studies to colour')
if 'computeStudyColours()' not in geometry[geometry.index('    @objc(computeColor)'):geometry.index('    private func computeStudyColours() {')]:
    fail('computeColor does not compute the study colours')

text = (root / 'Horos/Sources/DCMView+WindowLevel+Coordinates.swift').read_text()
draw = text[text.index('public dynamic func drawTextualData(_ size: NSRect, annotationsLevel'):]
draw = draw[:draw.index('@objc(drawTextualData::)')]
if 'PreviousStudyMark.isPrevious(' not in draw:
    fail('drawTextualData does not draw the mark')
if draw.index('PreviousStudyMark.isPrevious(') < draw.index('} else if annotations > annotGraphics {'):
    fail('the mark is drawn below the Base annotation level')

if 'PreviousStudyMark.isEnabled' not in draw[:draw.index('PreviousStudyMark.isPrevious(')] or \
        draw.index('PreviousStudyMark.isEnabled') < draw.index('} else if annotations > annotGraphics {'):
    fail('the label is drawn whatever the Viewers pane says')
import sys  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
if default_preferences.registered().get('ShowPreviousExamLabel') is not True:
    fail('ShowPreviousExamLabel is not on by default')
mark = (root / 'Horos/Sources/PreviousStudyMark.swift').read_text()
if 'defaultsKey = "ShowPreviousExamLabel"' not in mark:
    fail('the mark does not read ShowPreviousExamLabel')
app = (root / 'Horos/Sources/AppController.swift').read_text()
check = app[app.index('@objc(runPreferencesUpdateCheck:)'):]
check = check[check.index('PreviousStudyMark.defaultsKey'):]
check = check[:check.index('\n                if ')]
if 'needsDisplay = true' not in check or 'refreshViewer' in check:
    fail('a change of the check does not redraw the viewers, or reloads their images')
pane = (root / 'Preference Panes/OSIViewerPreferencePane/OSIViewerPreferencePanePref.swift').read_text()
if 'addPreviousExamCheck()' not in pane[pane.index('private func finishInitOnMainActor()'):pane.index('self.mainViewDidLoad()')]:
    fail('the Viewers pane does not add the check')
builder = pane[pane.index('private func addPreviousExamCheck()'):]
builder = builder[:builder.index('\n    }\n')]
for piece in ('"values.onlyDisplayImagesOfSamePatient"', 'anchor.frame.minY - 20', 'PreviousStudyMark.defaultsKey',
              'Show \\"Previous\\" on older studies', 'intersects(place)'):
    if piece not in builder:
        fail(f'the check is not built as expected: {piece}')

import xml.etree.ElementTree as ET
nibs = sorted(root.glob('Horos/Resources/*.lproj/OSIViewerPreferencePanePref.xib'))
nibs += sorted(root.glob('Preference Panes/OSIViewerPreferencePane/*.lproj/OSIViewerPreferencePanePref.xib'))
if len(nibs) < 10:
    fail(f'{len(nibs)} copies of the Viewers pane')
width = None
for nib in nibs:
    tree = ET.parse(nib).getroot()
    box = next(b for b in tree.iter('box') if any((x.get('keyPath') or '') == 'values.onlyDisplayImagesOfSamePatient' for x in b.iter('binding')))
    views = []
    for element in box.find('view').find('subviews'):
        rect = element.find('rect'); binding = element.find('.//binding[@name="value"]')
        if rect is None:
            continue
        views.append((float(rect.get('x')), float(rect.get('y')), float(rect.get('width')), float(rect.get('height')),
                      binding.get('keyPath') if binding is not None else element.tag))
    anchor = next(v for v in views if v[4] == 'values.onlyDisplayImagesOfSamePatient')
    place = (anchor[0], anchor[1] - 20, anchor[2], anchor[3])
    taken = [v[4] for v in views if not (v[0] >= place[0] + place[2] or v[0] + v[2] <= place[0] or
                                         v[1] >= place[1] + place[3] or v[1] + v[3] <= place[1])]
    if taken:
        fail(f'{nib.parent.name}: the place of the check is taken by {taken}')
    width = anchor[2] if width is None else min(width, anchor[2])

titles = []
for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    raw = catalog.read_bytes()
    text = raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')
    found = [line for line in text.splitlines() if line.startswith('"Show \\"Previous\\" on older studies" = "')]
    if not found:
        fail(f'{catalog.parent.name} has no title for the check')
    titles.append(found[0].split('" = "', 1)[1].rsplit('";', 1)[0].replace('\\"', '"'))
measure = r'''
import AppKit
let width = CGFloat(Double(CommandLine.arguments[1])!)
for title in CommandLine.arguments.dropFirst(2) {
    let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
    if check.fittingSize.width > width { print("too wide: \(title) \(check.fittingSize.width)"); exit(1) }
}
'''
with tempfile.TemporaryDirectory() as folder:
    (Path(folder) / 'measure.swift').write_text(measure)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'modules'), str(Path(folder) / 'measure.swift'),
                    '-o', str(Path(folder) / 'measure')], check=True)
    if subprocess.run([str(Path(folder) / 'measure'), str(width)] + titles).returncode:
        fail('the title of the check does not fit its place')

for catalog in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    with open(catalog, 'rb') as handle:
        try:
            table = plistlib.load(handle)
        except Exception:
            raw = catalog.read_bytes()
            table = {}
            text = raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')
            for line in text.splitlines():
                if line.startswith('"Previous" = "'):
                    table['Previous'] = line.split('" = "', 1)[1].rsplit('";', 1)[0]
    value = table.get('Previous')
    if not value:
        fail(f'{catalog.parent.name} has no "Previous"')
    if catalog.parent.name not in ('en.lproj',) and value == 'Previous':
        fail(f'{catalog.parent.name} leaves "Previous" in English')
    if catalog.parent.name == 'it-IT.lproj' and value != 'Precedente':
        fail(f'Italian says {value!r}, not "Precedente"')
print('ok: previous exams marked by patient and day, drawn from the Base level while the Viewers pane check is on, in every catalog')
