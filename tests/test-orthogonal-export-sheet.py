#!/usr/bin/env python3
"""The DICOM export sheet of the orthogonal MPR and PET-CT viewers counts what the export makes (#921).

Three defects of the sheet, in both viewers:

1. "Current position" filled "From" or "To" without recounting: after
   From = To = 1 the sheet still said "347 images", and the export made one.
   -setCurrentPosition: now recounts after it writes the fields.
2. The interval slider kept only the values of its tick marks. The nib gives
   it 50 marks over 1...50, and the sheet raised its maximum to 90 without
   changing the marks: a typed 3 left the slider on the mark at 2.8, and the
   count and the export stepped by 2 (1...10 gave 5 images). The sheet now
   gives it one mark a value.
   This part runs: an NSSlider is set up as each viewer's nib has it
   (read from the en and ja-JP xibs), then as the source's -exportDICOMFile:
   sets it (the lines that set dcmInterval, compiled as they are), and each
   value from 1 to 90 is handed to it as the field does (takeIntValueFrom:);
   the slider must keep it.
3. Without one of the window's views as the key view, the sheet showed
   From 1, To 0 and "1 images", and the export makes nothing. "From" is now 0
   there, as "To", and the count 0: -updateExportImageCount counts only when
   -exportSeriesLength, the length the sheet also takes its bounds from, has
   a series.

`<git revision>` as an optional argument reads that revision, the negative
control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def method(text, signature):
    """The method that `signature` starts, up to its closing brace at four spaces."""
    start = text.find(signature)
    if start < 0:
        return ''
    end = text.find('\n    }\n', start)
    return text[start:end + len('\n    }\n')]


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

VIEWERS = (('OrthogonalMPRViewer', 'OrthogonalMPR.xib'), ('OrthogonalMPRPETCTViewer', 'PETCT.xib'))

PROBE = r'''
import AppKit

let dcmInterval: NSSlider? = NSSlider()
let field = NSTextField()
dcmInterval?.minValue = @@MIN@@
dcmInterval?.maxValue = @@MAX@@
dcmInterval?.numberOfTickMarks = @@MARKS@@
dcmInterval?.allowsTickMarkValuesOnly = @@MARKS_ONLY@@
// -exportDICOMFile:
@@SHEET@@
var wrong: [String] = []
for typed in Int32(1)...Int32(90) {
    field.intValue = typed
    dcmInterval?.takeIntValueFrom(field)
    let kept = dcmInterval?.intValue ?? 0
    if kept != typed { wrong.append("\(typed)->\(kept)") }
}
print(wrong.joined(separator: " "))
'''

with tempfile.TemporaryDirectory() as tmp:
    for name, nib_name in VIEWERS:
        text = read(f'Horos/Sources/{name}.swift')
        sheet = method(text, 'public dynamic func exportDICOMFile(')
        position = method(text, 'public dynamic func setCurrentPosition(')
        recount = method(text, 'private func updateExportImageCount()')
        if not sheet or not position or not recount:
            failures.append(f'{name}: the export sheet is not where this test looks; it needs a new look')
            continue

        # 1. The current position recounts, after it writes the fields.
        fields = max(position.rfind('dcmFromTextField?.intValue ='), position.rfind('dcmToTextField?.intValue ='))
        if position.rfind('self.updateExportImageCount()') < fields:
            failures.append(f'{name}: "current position" fills From or To without recounting the images')

        # 2. The interval slider, as the nib and then the sheet set it up.
        interval_lines = '\n'.join(line.strip() for line in sheet.splitlines()
                                   if line.strip().startswith('dcmInterval?.') and '=' in line)
        for language in ('en', 'ja-JP'):
            nib = read(f'Horos/Resources/{language}.lproj/{nib_name}')
            outlet = re.search(r'<outlet property="dcmInterval" destination="([^"]+)"', nib)
            cell = re.search(r'<slider [^>]*id="%s">.*?(<sliderCell [^>]*>)' % outlet.group(1), nib, re.S) if outlet else None
            if not cell:
                failures.append(f'{language} {nib_name}: no interval slider for dcmInterval')
                continue
            attributes = dict(re.findall(r'(\w+)="([^"]*)"', cell.group(1)))
            source = (PROBE.replace('@@MIN@@', attributes.get('minValue', '0'))
                           .replace('@@MAX@@', attributes.get('maxValue', '100'))
                           .replace('@@MARKS@@', attributes.get('numberOfTickMarks', '0'))
                           .replace('@@MARKS_ONLY@@', 'true' if attributes.get('allowsTickMarkValuesOnly') == 'YES' else 'false')
                           .replace('@@SHEET@@', interval_lines))
            probe = Path(tmp) / f'{name}-{language}.swift'
            probe.write_text(source)
            binary = probe.with_suffix('')
            build = subprocess.run(['xcrun', 'swiftc', '-O', str(probe), '-o', str(binary)], capture_output=True, text=True)
            if build.returncode:
                print(build.stderr, file=sys.stderr)
                failures.append(f'{name} ({language}): the interval probe does not compile')
                continue
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            if run.returncode:
                failures.append(f'{name} ({language}): the interval probe exited with {run.returncode}')
            elif run.stdout.strip():
                wrong = run.stdout.split()
                failures.append(f'{name} ({language}): the interval slider does not keep {len(wrong)} of the values 1...90 '
                                f'typed in its field (typed->kept: {" ".join(wrong[:6])} ...)')

        # 3. Without a key view of the window: From 0 and no count.
        if 'self.exportSeriesLength() > 0 ? exportImageCount(dcmFrom, dcmTo, dcmInterval) : 0' not in recount:
            failures.append(f'{name}: without a key view of the window the sheet still counts images')
        length = method(text, 'private func exportSeriesLength()')
        if 'return 0\n' not in length or length.count('return ') != 4:
            failures.append(f'{name}: -exportSeriesLength does not give the length of each view, and 0 without one')
        if 'let first: Int32 = max > 0 ? 1 : 0' not in sheet or 'dcmFromTextField?.intValue = first' not in sheet \
                or 'dcmFromTextField?.intValue = 1' in sheet:
            failures.append(f'{name}: without a key view of the window the sheet still shows From 1 to 0')

if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print('orthogonal export sheet: the current position recounts, the interval keeps every value 1...90, '
      'and without a key view no image is promised')
