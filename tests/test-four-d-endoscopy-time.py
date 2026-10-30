#!/usr/bin/env python3
"""Endoscopy opens the aligned 4D time, not pixList[0]."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def body(source, signature):
    at = 0
    while True:
        at = source.find(signature, at)
        if at < 0:
            return ''
        brace = source.find('{', at)
        semi = source.find(';', at)
        if brace >= 0 and (semi < 0 or brace < semi):
            break
        at += len(signature)
    depth, index = 0, brace
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
        index += 1
    return ''


code = r'''
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

check(FourDSeriesGuard.alignedTimeIndex(requested: 2, count: 3) == 2, "host time 2")
check(FourDSeriesGuard.alignedTimeIndex(requested: 5, count: 3) == 2, "host wrap")
check(FourDSeriesGuard.alignedTimeIndex(requested: -1, count: 3) == 2, "negative wrap")
check(FourDSeriesGuard.alignedTimeIndex(requested: 0, count: 3) == 0, "time 0 stays 0")
check(FourDSeriesGuard.alignedTimeIndex(requested: 7, count: 0) == 0, "empty series opens time 0")
print("PASS: Endoscopy open uses the same wrap as SR")
'''
with tempfile.TemporaryDirectory(prefix='horos-endo-time-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(code)
    subprocess.run([
        'xcrun', 'swiftc',
        str(root / 'Horos/Sources/FourDSeriesGuard.swift'),
        str(p / 'main.swift'), '-o', str(p / 'test')
    ], check=True)
    subprocess.run([str(p / 'test')], check=True)

viewer = (root / 'Horos/Sources/ViewerController+ThreeDViewers.swift').read_text()
open_endo = body(viewer, 'func openEndoscopyViewer() -> EndoscopyViewer!')
check(open_endo, 'openEndoscopyViewer is missing')
check('FourDSeriesGuard.alignedTimeIndex(requested:' in open_endo or 'FourDSeriesGuard.wrappedIndex(' in open_endo,
      'openEndoscopyViewer must wrap the host 4D time')
check('EndoscopyViewer(pixList: horos_pixList(at: 0)' not in open_endo,
      'openEndoscopyViewer must not pass pixList[0] to EndoscopyViewer')
check('horos_pixList(at: time)' in open_endo and 'horos_fileList(at: time)' in open_endo
      and 'horos_volumeData(at: time)' in open_endo and 'EndoscopyViewer(pixList: pix, files, volume,' in open_endo,
      'pixList, fileList and volumeData must share the wrapped time')
check('FindViewer("Endoscopy", horos_pixList(at: 0))' in open_endo,
      'FindViewer may still identify the series by pixList[0]')

endo_action = body(viewer, 'func endoscopyViewer(_ sender: Any!)')
check('refuseFourDReconstruction(withTitle:' in endo_action,
      'endoscopyViewer must keep the 4D geometry refusal')
check('Endoscopy' in endo_action,
      'endoscopyViewer must keep the Endoscopy refusal title')

open_sr = body(viewer, 'func openSRViewer() -> SRController!')
check('horos_pixList(at: time)' in open_sr and 'horos_fileList(at: time)' in open_sr
      and 'horos_volumeData(at: time)' in open_sr,
      'openSRViewer aligned time must stay')

if failures:
    for item in failures:
        print('FAIL:', item, file=sys.stderr)
    sys.exit(1)
print('PASS: Endoscopy opens one aligned 4D time')
