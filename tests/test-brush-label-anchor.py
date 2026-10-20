#!/usr/bin/env python3
"""A name-only brush label hangs from inside the organ's largest piece.

The label of a brush ROI was anchored at the lower right corner of the
texture's bounding box, with its leader line to the box's centre; for a curved
or split organ both fall outside it. HorosBrushLabelAnchor is compiled and run
on small textures: a blob gets its centroid, a C shape the piece pixel nearest
to its centroid, two pieces the larger one, an empty texture nothing.

ROI.m is checked for the rest: a name-only ROI (-textNameOnly, archived from
ROI version 16) shows only its name, computes no statistics, and a brush's
label and leader line use that anchor.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
failures = []

DRIVER = r'''
import Foundation
func texture(_ rows: [String]) -> (UnsafeMutablePointer<UInt8>, Int, Int) {
    let w = rows[0].count, h = rows.count
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h)
    for (y, row) in rows.enumerated() { for (x, c) in row.enumerated() { p[y * w + x] = c == "#" ? 255 : 0 } }
    return (p, w, h)
}
func show(_ name: String, _ rows: [String]) {
    let (p, w, h) = texture(rows)
    if let v = BrushLabelAnchor.anchor(of: p, width: w, height: h) {
        let pt = v.pointValue
        let inside = rows[Int(pt.y - 0.5)][rows[0].index(rows[0].startIndex, offsetBy: Int(pt.x - 0.5))] == "#"
        print("\(name)\t\(pt.x),\(pt.y),\(inside ? "inside" : "outside")")
    } else { print("\(name)\tnone") }
}
show("blob", ["......", ".####.", ".####.", ".####.", "......"])
show("c", ["#####", "#....", "#....", "#....", "#####"])
show("two", ["##......", "##......", "....####", "....####", "....####"])
show("empty", ["....", "...."])
'''

with tempfile.TemporaryDirectory(prefix='horos-label-anchor-') as directory:
    work = Path(directory)
    (work / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/BrushLabelAnchor.swift'), str(work / 'main.swift'),
                            '-o', str(work / 'anchor')], capture_output=True, text=True)
    if built.returncode:
        failures.append('the anchor does not compile:\n' + built.stderr[-2000:])
    else:
        run = subprocess.run([str(work / 'anchor')], capture_output=True, text=True, timeout=60)
        results = dict(line.split('\t') for line in run.stdout.splitlines() if '\t' in line)
        expected = {
            'blob': '3.0,2.5,inside',     # centroid of the 4 x 3 block
            'two': '6.0,3.5,inside',      # the larger piece, not the 2 x 2 one
            'empty': 'none',
        }
        for key, value in expected.items():
            if results.get(key) != value:
                failures.append('%s: expected %r, got %r' % (key, value, results.get(key)))
        if not results.get('c', '').endswith(',inside'):
            failures.append('a C shape is labelled outside it: %r' % results.get('c'))

roi = (root / 'Horos/Sources/ROI.m').read_bytes().decode('latin1')
header = (root / 'Horos/Sources/ROI.h').read_bytes().decode('latin1')
if '@property BOOL textNameOnly;' not in header:
    failures.append('ROI has no textNameOnly property')
if '#define ROIVERSION 16' not in roi or 'textNameOnly = [ROIArchiveNumber' not in roi \
        or '[coder encodeObject:[NSNumber numberWithBool: textNameOnly]]' not in roi:
    failures.append('textNameOnly is not archived in ROI version 16')
if 'c->textNameOnly = textNameOnly;' not in roi:
    failures.append('a copy loses textNameOnly')
if 'NSPoint tPt = textNameOnly ? [self textureLabelPoint] : [self lowerRightPoint];' not in roi:
    failures.append('a name-only brush label is not anchored inside the organ')
if 'textNameOnly ? [self textureLabelPoint]' not in roi.split('- (void) drawTextualData')[1].split('\n- (')[0]:
    failures.append('the leader line of a name-only brush does not point inside the organ')
plain = roi[roi.index('NSPoint tPt = textNameOnly'):roi.index('#pragma mark t2DPoint')]
if plain.index('if( textNameOnly)') > plain.index('computeROI'):
    failures.append('a name-only brush still computes its statistics')
if 'if( ROITEXTNAMEONLY || textNameOnly)' not in roi:
    failures.append('a name-only ROI still hides statistics by the primary-measurement rule instead of showing its name')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: name-only brush labels hang from inside the largest piece, without statistics, and survive archiving')
