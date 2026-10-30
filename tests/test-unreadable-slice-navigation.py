#!/usr/bin/env python3
"""An unreadable slice is shown as such, and navigation moves on from it.

The host viewer's answer to a frame that cannot be decoded: `CheckLoadIn`
allocates an empty frame, marks the pix `notAbleToLoadImage`, records a reason
(`missingPixelsReason`) and `DCMView` draws that reason over the empty frame.
The index the operator asked for is the index shown, so the previous image is
never presented as the failed slice; `setIndex:` neither refuses nor skips an
unreadable pix, so the next step goes on from the failed request, past it and
back; and a later successful decode has no reason to draw.

Source level, on the real methods, plus the reason texts compiled from
`MissingPixelsReason.swift`.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text, class_text

root = Path(__file__).resolve().parents[1]
pix = class_text('DCMPix')
# DCMView is Swift: -setIndex: is in DCMView+ImageList.swift.
view = source_text('DCMView+ImageList')
# -drawOrientation:, which draws the reason, is Swift.
orientation = source_text('DCMView+WindowLevel+Coordinates')
failures = []


def method(source, signature, terminator='\n}\n'):
    start = source.find(signature)
    if start < 0:
        return ''
    return source[start:source.find(terminator, start) + len(terminator)]


# The body of -CheckLoadIn.
check = pix[pix.find('    final func loadIfNeeded() {\n'):pix.find('    final func isDICOMFile(')]
if 'horos_notAbleToLoadImage = true' not in check or 'reasonForUnreadableFrame' not in check:
    failures.append('CheckLoadIn no longer marks an unreadable frame with a reason')
if 'if let image = horos_fImage { memset(image, 0, horos_width * horos_height * 4) }' not in check:
    failures.append('an unreadable frame must be empty, not a gradient or the previous pixels')

set_index = method(view, '    @objc(setIndex:)\n', '\n    }\n')
if not set_index:
    failures.append('DCMView setIndex: is gone')
else:
    if 'notAbleToLoadImage' in set_index or 'missingPixelsReason' in set_index:
        failures.append('setIndex: must not skip or refuse an unreadable pix; the index asked for is the index shown')
    if ('self.horos_curImage = SeriesDisplay.clampedIndex(index, count: dcmPixList.count)' not in set_index
            or 'self.curDCM = (dcmPixList.object(at: Int(self.horos_curImage)) as! DCMPix)' not in set_index):
        failures.append('setIndex: no longer shows the pix at the requested index')

if ('private let kMissingPixelsReasonGetter = #selector(getter: DCMPix.missingPixelsReason)' not in orientation
        or 'if ((objcProperty(self.curDCM, kMissingPixelsReasonGetter) as! NSString?)?.length ?? 0) != 0 {' not in orientation
        or 'self.drawNSStringGL(objcProperty(self.curDCM, kMissingPixelsReasonGetter) as! NSString? as String?' not in orientation):
    failures.append('DCMView does not draw the missing-pixels reason over the frame')

DRIVER = r'''
import Foundation
func expect(_ ok: Bool, _ reason: String) { if !ok { print("FAIL: " + reason); exit(1) } }
let unreadable = MissingPixelsReason.reasonForUnreadableFrame()
expect(!unreadable.isEmpty, "an unreadable frame has a reason")
expect(unreadable.lowercased().contains("read") || unreadable.lowercased().contains("decod"), "the reason says the frame could not be read: \(unreadable)")
expect(!MissingPixelsReason.reasonForAbsentPixelData().isEmpty, "absent pixel data has a reason")
print("ok: unreadable slices are shown as such and never as the previous image")
'''
if not failures:
    with tempfile.TemporaryDirectory() as tmp:
        driver = Path(tmp) / 'main.swift'
        driver.write_text(DRIVER)
        binary = Path(tmp) / 'driver'
        build = subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/MissingPixelsReason.swift'), str(driver), '-o', str(binary)],
                               capture_output=True, text=True)
        if build.returncode != 0:
            failures.append('driver did not compile:\n' + build.stderr[-2000:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append((run.stdout + run.stderr).strip())
            else:
                print(run.stdout.strip())

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
