#!/usr/bin/env python3
"""Exercise the production allocation-failure retry branch without allocating images.

The retry is IsiXImaging's ViewerMemory.plan (ViewerOpening/ViewerOpeningRules.swift),
which the viewer opening (ViewerSeriesLoader.swift) runs with real allocations:
here the allocations fail until a chosen pass, and the selection kept, the
sampling and the end of the retries are checked; the opening shows the
"Not enough memory" alert once when the retries end.
"""
from pathlib import Path
import subprocess, sys, tempfile
root = Path(__file__).resolve().parents[1]
rules = root / 'Modules/IsiXImaging/Sources/ViewerOpening/ViewerOpeningRules.swift'
loader = (root / 'Horos/Sources/ViewerSeriesLoader.swift').read_text()
failure = loader[loader.index('case .failure(.notEnoughMemory):'):]
failure = failure[:failure.index('stop = true')]
assert 'Not enough memory to open the selected images.' in failure and failure.count('HorosAlertPanel.run') == 1, \
    'the opening no longer says once that there is not enough memory'
code = r'''
import Foundation
func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL: " + message); exit(1) } }
let image = MemoryImage(width: 512, height: 512, frames: 1, series: 1)
// Allocations fail until `pass`; the passes and what each kept.
func plan(_ counts: [Int], succeedingAtPass pass: Int, image: MemoryImage = image) -> (Result<ViewerMemoryPlan, ViewerMemoryFailure>, Int) {
    var passes = 1
    let result = ViewerMemory.plan(imageCounts: counts, image: { _, _ in image }, visit: { _ in }, allocate: { _ in passes >= pass },
                                   purge: {}, passEnded: { passes += 1 })
    return (result, passes - 1)
}
let expected: [(Int, [[Int]], [Int])] = [(1, [[0, 1, 2, 3, 4], [0], []], [0, 1, 2]), (2, [[0, 2, 4], [0]], [0, 1]),
                                         (3, [[0, 4], [0]], [0, 1]), (4, [[0], [0]], [0, 1])]
for (pass, images, lists) in expected {
    let (result, passes) = plan([5, 1, 0], succeedingAtPass: pass)
    guard case .success(let kept) = result else { check(false, "pass \(pass) did not open"); exit(1) }
    check(kept.imageIndices == images && kept.listIndices == lists && kept.subSampling == 1 << (pass - 1) && passes == pass,
          "pass \(pass): \(kept)")
}
// Every list down to one image: the retries end.
let (ended, passes) = plan([5, 1, 0], succeedingAtPass: 99)
check(ended == .failure(.notEnoughMemory) && passes == 4, "the retries do not end: \(passes)")
// One multi-frame file cannot be thinned by dropping files.
let (multiFrame, multiPasses) = plan([1], succeedingAtPass: 99, image: MemoryImage(width: 512, height: 512, frames: 4096, series: 1))
check(multiFrame == .failure(.notEnoughMemory) && multiPasses == 1, "a multi-frame file was thinned")
// The sampling cannot overflow, and an empty selection has nothing to drop.
check(!ViewerMemory.canHalve(imageCounts: [2], subSampling: Int.max), "sampling overflow")
check(!ViewerMemory.canHalve(imageCounts: [0], subSampling: 1), "an empty selection was thinned")
print("PASS: retries strictly shrink selections and terminate for singleton, multiframe, empty and overflow cases")
'''
with tempfile.TemporaryDirectory(prefix='horos-subsampling-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', str(rules), str(p / 'main.swift'), '-o', str(p / 'test')], check=True, timeout=300)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
