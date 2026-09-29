#!/usr/bin/env python3
"""Defects of the endoscopy viewer that its Swift translation kept (#864).

1. -[EndoscopyVRController initWithPix:::::] is sent again to the controller
   Endoscopy.xib made. On its failure paths (no slice interval nor thickness,
   images of different sizes, no 3D engine) it sent [self autorelease] to that
   object, which the nib and the viewer keep, and the viewer went on using it:
   an over-release. It also left the viewer's pixel list and volume in the
   controller's ivars without a retain, which -[VRController dealloc] releases.
   The initializer now gives back what it took and returns nil without a
   release, HorosEndoscopyVRControllerReinit reports the failure, the viewer's
   initializer returns nil, and -save3DState writes nothing for a controller
   without a file list.
2. -[EndoscopyMPRView bitmapImageRepForCachingDisplayInRect:] handed the raw
   RGB samples of -getRawPixels:::::: to -[NSBitmapImageRep initWithData:],
   an image file decoder, which returns nil for them, and never freed the
   buffer. A Swift double built with the method copied verbatim from
   EndoscopyMPRView.swift checks the bitmap and the buffer.
3. The WLWW3D and WLWW2D toolbar items sent setMinSize twice; the second is
   setMaxSize, as for the other items with a view.
4. -pathAssistantSetPointB: read the centerline's first point without an
   assistant (an empty centerline) and its fifth point on a path of fewer
   points: both raised.

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def block(source, signature):
    """The text of `signature` up to the brace that closes its body."""
    at = source.find(signature)
    if at < 0:
        return ''
    brace = source.find('{', at)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[at:index + 1]
    return ''


# 1. The failed initializer of the nib's VR controller.
capi = read('Horos/Sources/EndoscopyVRController+CAPI.m')
init = block(capi, '-(id) initWithPix:(NSMutableArray*) pix :(NSArray*) f :(NSData*) vData :(ViewerController*) bC :(ViewerController*) vC\n{')
check(init, 'EndoscopyVRController+CAPI.m lost -initWithPix:::::')
check('autorelease' not in init,
      '-initWithPix::::: must not release the controller Endoscopy.xib made')
returns = init.count('return nil;')
check(returns == 3, f'-initWithPix::::: has {returns} failure paths, expected 3')
check(len(re.findall(r'\[self horosAbandonInitWithPix: NO\];\s*return nil;', init)) == 2,
      'the two failures before the volume is retained must give back the file list and the unretained volume')
check(len(re.findall(r'\[self horosAbandonInitWithPix: YES\];\s*return nil;', init)) == 1,
      'the 3D engine failure must release the retained volume')
abandon = block(capi, '- (void) horosAbandonInitWithPix: (BOOL) volumeRetained\n{')
check(abandon, 'EndoscopyVRController+CAPI.m lacks -horosAbandonInitWithPix:')
for needle in ('[pixList[0] release];', '[volumeData[0] release];', 'pixList[0] = nil;',
               'volumeData[0] = nil;', '[fileList release];', 'fileList = nil;'):
    check(needle in abandon, f'-horosAbandonInitWithPix: must do {needle}')
check(abandon.find('if( volumeRetained)') < abandon.find('[pixList[0] release];') < abandon.find('pixList[0] = nil;'),
      '-horosAbandonInitWithPix: releases the volume only when it was retained')

viewer_capi = read('Horos/Sources/EndoscopyViewer+CAPI.m')
check(re.search(r'^BOOL HorosEndoscopyVRControllerReinit\(', viewer_capi, re.M)
      and 'return [controller initWithPix: pix : files : (NSData*)vData : bC : vC] != nil;' in viewer_capi,
      'HorosEndoscopyVRControllerReinit must report whether the initializer failed')
check('extern BOOL HorosEndoscopyVRControllerReinit(' in read('Horos/Sources/EndoscopyViewer.h'),
      'EndoscopyViewer.h must declare HorosEndoscopyVRControllerReinit as returning BOOL')

viewer = read('Horos/Sources/EndoscopyViewer.swift')
viewer_init = block(viewer, '    public convenience init!(pixList pix:')
reinit = re.search(r'if !HorosEndoscopyVRControllerReinit\(vrController, pix, files, vData, bC, vC\) \{(.*?)\n        \}', viewer_init, re.S)
check(reinit and 'return nil' in reinit.group(1),
      'the viewer must not open when the VR controller refused the volume')
check(reinit and viewer_init.find('return nil') < viewer_init.find('load3DState()')
      and viewer_init.find('return nil') < viewer_init.find('nc.addObserver'),
      'the viewer must give up before it loads the 3D state or observes anything')

controller = read('Horos/Sources/EndoscopyVRController.swift')
save = block(controller, '    private dynamic func save3DState() {')
check(re.search(r'guard let files = self\.fileList\(\) as NSArray\?, files\.count > 0 else \{ return \}', save)
      and save.find('guard let files') < save.find('endoscopyStatePath'),
      '-save3DState must write nothing for a controller without a file list')

# 3. The sizes of the WL/WW toolbar items.
for item in ('WLWW3DView', 'WLWW2DView'):
    check(viewer.count(f'toolbarItem?.minSize = NSMakeSize(NSWidth({item}?.frame') == 1
          and viewer.count(f'toolbarItem?.maxSize = NSMakeSize(NSWidth({item}?.frame') == 1,
          f'the toolbar item of {item} must set its minimum and its maximum size once each')

# 4. The path assistant's point B.
point_b = block(viewer, '    public dynamic func pathAssistantSetPointB(_ sender: Any!) {')
check(point_b, 'EndoscopyViewer.swift lost -pathAssistantSetPointB:')
guard = point_b.find('guard let assistant = assistant else {')
check(0 <= guard < point_b.find('createCenterline'),
      '-pathAssistantSetPointB: must not compute a path without an assistant')
check('object(at: 4)' not in point_b,
      '-pathAssistantSetPointB: must not read a fifth point the path may not have')
check(re.search(r'path\.count > 1 \{.*?path\.object\(at: 0\).*?path\.object\(at: min\(4, path\.count - 1\)\)', point_b, re.S),
      '-pathAssistantSetPointB: looks from the first point to the fifth, or the last of a shorter path')

# 2. The bitmap of the cached display, built by a double of the view.
mpr = read('Horos/Sources/EndoscopyMPRView.swift')
method = block(mpr, '    public override dynamic func bitmapImageRepForCachingDisplay(in aRect: NSRect) -> NSBitmapImageRep? {')
check(method, 'EndoscopyMPRView.swift lost -bitmapImageRepForCachingDisplayInRect:')

harness = r'''
import Cocoa

// free(), as the method calls it: the buffers it frees are counted.
var freed: [UnsafeMutableRawPointer] = []
func free(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer = pointer { freed.append(pointer) }
    Darwin.free(pointer)
}

final class Double: NSView {
    var size = (width: 0, height: 0, spp: 0, bpp: 0)
    var noPixels = false
    var handed: UnsafeMutablePointer<UInt8>?

    // -getRawPixels::::::: malloc'd samples, row after row.
    func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!, _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>! {
        if noPixels { return nil }
        width.pointee = size.width; height.pointee = size.height
        spp.pointee = size.spp; bpp.pointee = size.bpp
        let count = size.width * size.height * size.spp * size.bpp / 8
        let data = malloc(count)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count { data[i] = UInt8(truncatingIfNeeded: i * 7 + 1) }
        handed = data
        return data
    }

METHOD
}

var failures = 0
func fail(_ message: String) { failures += 1; print("FAIL: \(message)") }

for (width, height, spp) in [(5, 3, 3), (4, 2, 1)] {
    freed = []
    let view = Double(frame: NSMakeRect(0, 0, CGFloat(width), CGFloat(height)))
    view.size = (width, height, spp, 8)
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    let handed = view.handed.map { UnsafeMutableRawPointer($0) }
    if freed.count != 1 || freed.first != handed { fail("\(spp) samples: the pixel buffer is not freed once (\(freed.count))") }
    guard let rep = rep else { fail("\(spp) samples: no bitmap"); continue }
    if rep.pixelsWide != width || rep.pixelsHigh != height || rep.samplesPerPixel != spp || rep.bitsPerSample != 8 || rep.hasAlpha {
        fail("\(spp) samples: bitmap \(rep.pixelsWide)x\(rep.pixelsHigh), \(rep.samplesPerPixel) samples of \(rep.bitsPerSample) bits")
        continue
    }
    guard let pixels = rep.bitmapData else { fail("\(spp) samples: bitmap without data"); continue }
    for row in 0..<height {
        for column in 0..<(width * spp) {
            let expected = UInt8(truncatingIfNeeded: (row * width * spp + column) * 7 + 1)
            if pixels[row * rep.bytesPerRow + column] != expected {
                fail("\(spp) samples: sample \(column) of row \(row) is \(pixels[row * rep.bytesPerRow + column]), expected \(expected)")
            }
        }
    }
}

freed = []
let empty = Double(frame: NSMakeRect(0, 0, 8, 8))
empty.noPixels = true
_ = empty.bitmapImageRepForCachingDisplay(in: empty.bounds)
if !freed.isEmpty { fail("without pixels, nothing is freed") }

if failures == 0 { print("PASS: the cached display holds the view's pixels, and their buffer is freed") }
exit(failures == 0 ? 0 : 1)
'''

if method:
    with tempfile.TemporaryDirectory(prefix='horos-endoscopy-bitmap-') as tmp:
        tmp = Path(tmp)
        (tmp / 'main.swift').write_text(harness.replace('METHOD', method))
        build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(tmp / 'main.swift'), '-o', str(tmp / 'probe')],
                               capture_output=True, text=True)
        if build.returncode != 0:
            failures.append('the double of EndoscopyMPRView does not compile:\n' + build.stderr)
        else:
            run = subprocess.run([str(tmp / 'probe')], capture_output=True, text=True)
            print(run.stdout, end='')
            if run.returncode != 0:
                failures.append('the cached display of EndoscopyMPRView is not the view\'s pixels' + (': ' + run.stderr if run.stderr else ''))

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: endoscopy #864 defects are fixed')
