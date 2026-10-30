#!/usr/bin/env python3
"""Exercise the production viewer allocation sizing block before malloc.

The sizing is IsiXImaging's ViewerMemory.plan and loadBlock
(ViewerOpening/ViewerOpeningRules.swift), which the viewer opening
(ViewerSeriesLoader.swift) runs before allocating each volume; an image that
cannot be sized safely ends the opening with one alert.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
loader = (root / 'Horos/Sources/ViewerSeriesLoader.swift').read_text()
unsafe = loader[loader.index('case .failure(.unsafeDimensions):'):]
unsafe = unsafe[:unsafe.index('stop = true')]
assert 'The selected image dimensions cannot be loaded safely.' in unsafe and unsafe.count('HorosAlertPanel.run') == 1, \
    'the opening no longer refuses unsafe dimensions with an alert'
code = r'''
import Foundation
func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL: " + message); exit(1) } }
func image(_ w: Int64, _ h: Int64, _ f: Int64) -> MemoryImage { MemoryImage(width: w, height: h, frames: f, series: 1) }
/// The block of one list, as the opening sizes it, or nil when it refuses.
func size(_ images: [MemoryImage]) -> UInt? {
    let result = ViewerMemory.plan(imageCounts: [images.count], image: { images[$1] }, visit: { _ in }, allocate: { _ in true }, purge: {})
    guard case .success(let plan) = result else { return nil }
    return plan.blocks[0]
}
check(size([image(32, 32, 1), image(32, 32, 1)]) == 2 * 256 * 256, "small images count as 256 x 256")
check(size([image(512, 512, 16)]) == 512 * 512 * 16, "multi-frame")
check(size([image(65536, 65536, 1)]) == 65536 * 65536, "wide")
check(size([image(16, 8192, 1)]) == 16 * 8192, "thin")
check(size([image(Int64.max, Int64.max, 1)]) == nil, "overflowing size")
check(size([image(512, 512, Int64.max)]) == nil, "overflowing frames")
check(size([image(0, 512, 1)]) == nil, "zero width")
check(size([image(-1, 512, 1)]) == nil, "negative width")
check(ViewerMemory.loadBlock(pixels: 512 * 512, padded: 513 * 513, total: UInt.max) == nil, "overflowing total")
print("PASS: viewer sizing preserves small-image fallback and rejects invalid/overflowing allocations")
'''
with tempfile.TemporaryDirectory(prefix='horos-viewer-size-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-sanitize=undefined', str(root / 'Modules/IsiXImaging/Sources/ViewerOpening/ViewerOpeningRules.swift'),
                    str(p / 'main.swift'), '-o', str(p / 'test')], check=True, timeout=300)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
