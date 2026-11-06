#!/usr/bin/env python3
"""A name-only brush label hangs from inside the organ's largest piece.

The label of a brush ROI was anchored at the lower right corner of the
texture's bounding box, with its leader line to the box's centre; for a curved
or split organ both fall outside it. HorosBrushLabelAnchor is compiled and run
on small textures: a blob gets its centroid, a C shape the piece pixel nearest
to its centroid, two pieces the larger one, an empty texture nothing.

The ROI's source is checked for the rest: a name-only ROI (-textNameOnly, archived from
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import class_text  # noqa: E402

roi = class_text('ROI')
if '@objc public dynamic var textNameOnly: Bool' not in roi:
    failures.append('ROI has no textNameOnly property')
# The archive format is IsiXROI's: ROI hands its fields over and takes them back.
archive = (root / 'Modules/IsiXROI/Sources/ROIArchiveCoder.swift').read_text()
if 'public static let currentVersion = 16' not in archive \
        or 'if version >= 16 {\n            record.textNameOnly = reader.number()?.boolValue ?? false' not in archive \
        or 'coder.encode(NSNumber(value: record.textNameOnly))' not in archive \
        or '_textNameOnly = record.textNameOnly' not in roi or 'record.textNameOnly = _textNameOnly' not in roi:
    failures.append('textNameOnly is not archived in ROI version 16')
if 'c._textNameOnly = _textNameOnly' not in roi:
    failures.append('a copy loses textNameOnly')
brush = roi[roi.index('func labelBrush()'):]
brush = brush[:brush.index('\n    func ', 1)]
if 'let tPt = _textNameOnly ? textureLabelPoint() : lowerRightPoint()' not in brush:
    failures.append('a name-only brush label is not anchored inside the organ')
textual = roi[roi.index('public func drawTextualData()'):]
textual = textual[:textual.index('\n    @objc', 1)]
if '_textNameOnly ? textureLabelPoint()' not in textual:
    failures.append('the leader line of a name-only brush does not point inside the organ')
if brush.index('if _textNameOnly {') > brush.index('computeStatistics'):
    failures.append('a name-only brush still computes its statistics')
if 'if ROI.settings.textNameOnly || _textNameOnly { return full }' not in roi:
    failures.append('a name-only ROI still hides statistics by the primary-measurement rule instead of showing its name')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: name-only brush labels hang from inside the largest piece, without statistics, and survive archiving')
