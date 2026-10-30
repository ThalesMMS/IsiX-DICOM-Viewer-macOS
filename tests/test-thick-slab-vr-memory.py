#!/usr/bin/env python3
"""The 2D viewer's volume-rendering slab changes thickness without touching memory it does not own.

ThickSlabVR composes the slab on the CPU when -[DCMPix computeThickSlab] asks:
for measurements, the 8-bit representation and exports; on screen, Metal
composes it. The issue reported heap corruption while the slab's
thickness was dragged. ThickSlabVR is Swift now, its composite
IsiXVolumeRendering's ThickSlabComposer (bit for bit ThickSlabVR.mm's:
tests/test-thick-slab-equivalence.py). This builds the composer with Address
Sanitizer and drives it as DCMPix drives ThickSlabVR - setImageData once with
100 slices, then, for each image, setImageSource with the slices the slab
covers, setWLWW and renderSlab - over thicknesses that grow and shrink, at the
first, a middle and the last image, in both stack directions and both slice
orders (modes 4 and 5), on 3, 4 and the machine's workers. Address Sanitizer
stops the probe at the first read or write out of bounds. The composite of a
uniform slab is checked against the opacity it is built from.

Before d0f111c60 the threads' ranges were not multiples of four and read and
wrote up to three pixels past the end of the buffers.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the tools it runs
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

code = r'''
import Foundation

let width = 67, height = 45, count = 100, frame = width * height
let volume = UnsafeMutablePointer<Float>.allocate(capacity: frame * count)
for i in 0..<(frame * count) { volume[i] = Float((i * 37) % 2000) - 1000 }
// What ThickSlabVR's -setOpacity: with no points gives: 0 at 0, 1 at 255, straight between.
let ramp = (0..<256).map { Float(Double($0) / 255) }
let thicknesses = [2, 3, 5, 9, 14, 20, 27, 35, 44, 60, 80, 99, 100, 70, 40, 12, 3, 2, 50, 2]
let positions = [0, 1, 50, 98, 99]
var renders = 0
for workers in [3, 4, ProcessInfo.processInfo.processorCount] {
    for flip in [false, true] {
        let slab = ThickSlabComposer()
        slab.threadCount = workers
        slab.setImageData(width, height, 100, 0.7, 0.7, 1.5, flip)
        slab.setCLUT(nil, nil, nil)
        slab.setOpacityTable(ramp)
        for stack in thicknesses {
            for pixPos in positions {
                for direction in 0..<2 {
                    // -[DCMPix computeThickSlab], modes 4 and 5.
                    let fImage = volume + pixPos * frame
                    if direction != 0 {
                        let stacksize = pixPos - stack < 0 ? pixPos + 1 : stack + 1
                        slab.setImageSource(fImage - (stacksize - 1) * frame, stacksize)
                    } else {
                        let stacksize = pixPos + stack < count ? stack : count - pixPos
                        slab.setImageSource(fImage, stacksize)
                    }
                    slab.setWLWW(0, 2000)
                    let rgba = slab.renderSlab()!
                    for i in 0..<frame { precondition(rgba[4 * i] == 255) }
                    free(rgba)
                    renders += 1
                }
            }
        }
    }
}
// A uniform slab: every slice at the top of the window, whose opacity is 1,
// composes to the colour of that value at full weight.
let uniform = UnsafeMutablePointer<Float>.allocate(capacity: frame * count)
uniform.initialize(repeating: 1000, count: frame * count)
let slab = ThickSlabComposer()
slab.setImageData(width, height, 100, 1, 1, 1, true)
slab.setCLUT(nil, nil, nil)
slab.setOpacityTable(ramp)
slab.setImageSource(uniform, 7)
slab.setWLWW(0, 2000)
let rgba = slab.renderSlab()!
for i in 0..<frame { for c in 1..<4 { precondition(abs(Int(rgba[4 * i + c]) - 255) <= 1) } }
free(rgba)
print("PASS: \(renders) volume-rendering slabs, thickness 2 to 100 growing and shrinking, at the edges and the middle, both directions and slice orders, on 3, 4 and all workers, clean under Address Sanitizer; a uniform slab composes to its colour")
'''
with tempfile.TemporaryDirectory(prefix='horos-thick-slab-vr-') as directory:
    p = Path(directory)
    (p / 'main.swift').write_text(code)
    module = sorted(str(path) for path in (root / 'Modules/IsiXVolumeRendering/Sources').glob('*.swift'))
    # The modules it depends on (IsiXLogging, which its log goes through).
    below = [flag for name in isix_modules.dependencies('IsiXVolumeRendering')
             for flag in isix_modules.module_flags(name, p / 'modules')]
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'ThickSlabMemory', '-Onone', *below,
                            '-sanitize=address', *module, str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print('FAIL: the composer does not build with the probe:\n' + build.stderr[-3000:])
        sys.exit(1)
    run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=600,
                         env={**os.environ, 'ASAN_OPTIONS': 'detect_leaks=0'})
    print(run.stdout.strip())
    if run.returncode:
        print('FAIL: the probe stopped with %d:\n%s' % (run.returncode, run.stderr[-3000:]))
        sys.exit(1)
