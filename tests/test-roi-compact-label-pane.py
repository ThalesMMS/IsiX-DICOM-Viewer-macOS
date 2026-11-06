#!/usr/bin/env python3
"""The Viewers pane says when the compact ROI label is on.

"Show Primary Measurement Only" (ROIPRIMARYMEASUREMENTONLY) can be switched on
from the ROI menu and then forgotten: the labels lose their statistics while
the statistics checks of the Viewers pane still look chosen. The pane builds,
beside the compact check, a note that is shown only while the mode is on, and
greys out the statistics checks, keeping their choices.

The builder is read for those bindings; the note's text is looked up in every
catalog of the app and measured with AppKit, beside the compact check of the
same language, against the box of every localized copy of the pane.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
NOTE = 'On: ROI labels hide the statistics below.'
COMPACT = 'Show Primary Measurement Only'


def fail(message):
    print(f'FAIL: {message}')
    sys.exit(1)


pane = (root / 'Preference Panes/OSIViewerPreferencePane/OSIViewerPreferencePanePref.swift').read_text()
builder = pane[pane.index('private func addROIStatisticsChecks()'):]
builder = builder[:builder.index('\n    }\n')]
negated = 'options: [.valueTransformerName: NSValueTransformerName.negateBooleanTransformerName]'
for piece in ('let compactPath = "values.ROIPRIMARYMEASUREMENTONLY"', f'NSLocalizedString("{NOTE}"',
              'note.bind(.hidden, to: defaults, withKeyPath: compactPath,', 'check.bind(.enabled, to: defaults, withKeyPath: compactPath,',
              'compact.bind(.value, to: defaults, withKeyPath: compactPath', 'let noteX = compact.frame.maxX + 8'):
    if piece not in builder:
        fail(f'the compact setting is not built as expected: {piece}')
if builder.count(negated) != 2:
    fail('the note and the statistics checks do not both follow the opposite of the compact setting')
if 'note.toolTip = note.stringValue' not in builder:
    fail('a cut note has no tooltip')


def catalog(path):
    raw = path.read_bytes()
    text = raw.decode('utf-16' if raw[:2] in (b'\xff\xfe', b'\xfe\xff') else 'utf-8')
    table = {}
    for line in text.splitlines():
        if line.startswith('"') and '" = "' in line:
            key, value = line[1:].split('" = "', 1)
            table[key.replace('\\"', '"')] = value.rsplit('";', 1)[0].replace('\\"', '"')
    return table


pairs = []
for path in sorted((root / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    table = catalog(path)
    language = path.parent.name
    if NOTE not in table:
        fail(f'{language} has no text for the note')
    if language != 'en.lproj' and table[NOTE] == NOTE:
        fail(f'{language} leaves the note in English')
    pairs += [table.get(COMPACT, COMPACT), table[NOTE]]
if len(pairs) < 24:
    fail(f'{len(pairs) // 2} catalogs')

nibs = sorted(root.glob('Horos/Resources/*.lproj/OSIViewerPreferencePanePref.xib'))
nibs += sorted(root.glob('Preference Panes/OSIViewerPreferencePane/*.lproj/OSIViewerPreferencePanePref.xib'))
if len(nibs) < 10:
    fail(f'{len(nibs)} copies of the Viewers pane')
width = None
for nib in nibs:
    box = next((b for b in ET.parse(nib).getroot().iter('box')
                if any((x.get('keyPath') or '') == 'values.ROILabelBackground' for x in b.iter('binding'))), None)
    if box is None:
        fail(f'{nib.parent.name}: no box with the ROI label settings')
    box_width = float(box.find('rect').get('width'))
    width = box_width if width is None else min(width, box_width)

measure = r'''
import AppKit
let box = NSBox(frame: NSRect(x: 0, y: 0, width: CGFloat(Double(CommandLine.arguments[1])!), height: 200))
let inner = box.contentView!.bounds.width
let texts = Array(CommandLine.arguments.dropFirst(2))
var failed = false
for index in stride(from: 0, to: texts.count, by: 2) {
    let compact = NSButton(checkboxWithTitle: texts[index], target: nil, action: nil)
    compact.sizeToFit()
    let note = NSTextField(labelWithString: texts[index + 1])
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.sizeToFit()
    let right = 12 + compact.frame.width + 8 + note.frame.width
    if right > inner - 12 { print("too wide (\(right) of \(inner - 12)): \(texts[index + 1])"); failed = true }
}
exit(failed ? 1 : 0)
'''
with tempfile.TemporaryDirectory() as folder:
    source = Path(folder) / 'measure.swift'
    source.write_text(measure)
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'modules'), str(source),
                    '-o', str(Path(folder) / 'measure')], check=True)
    if subprocess.run([str(Path(folder) / 'measure'), str(width)] + pairs).returncode:
        fail('the note does not fit beside the compact check')
print('ok: the compact ROI label note shows only while the mode is on, the statistics checks grey out, and the note fits in every language')
