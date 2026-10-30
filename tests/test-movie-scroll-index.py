#!/usr/bin/env python3
"""Validate bounded temporal wheel navigation from the production helper.

The helper is IsiXImaging's WheelSteps.movieIndex, which the scroll wheel of
DCMView (DCMView+Scrolling.swift) asks for the movie index of an
Option-Shift scroll.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
scrolling = (root / 'Horos/Sources/DCMView+Scrolling.swift').read_text()
assert 'let next = WheelSteps.movieIndex(current: Int(wc?.inputCurMovieIndex() ?? 0),' in scrolling, \
    'the 4D scroll no longer asks WheelSteps for the movie index'

code = r'''
import Foundation
import IsiXImaging

func check(_ condition: Bool, _ what: String, line: Int = #line) {
    if !condition { FileHandle.standardError.write("FAIL line \(line): \(what)\n".data(using: .utf8)!); exit(1) }
}
func movie(_ i: Int, _ count: Int, _ delta: Double) -> Int { WheelSteps.movieIndex(current: i, count: count, delta: delta) }
check(movie(0, 4, -0.1) == 1, "small backward")
check(movie(0, 4, 0.1) == 3, "small forward")
check(movie(3, 4, -2.5) == 0, "wrap")
check(movie(0, 4, 5) == 2, "two back")
for count in 2...100 { for i in 0..<count { for d in -30...30 where d != 0 {
    var step = Double(d) / -2.5
    step = step >= 0 ? step.rounded(.up) : step.rounded(.down)
    let expected = ((i + Int(step)) % count + count) % count
    check(movie(i, count, Double(d)) == expected, "count \(count) index \(i) delta \(d)")
} } }
// Repeated float subtraction makes no progress at this magnitude.
let oldChange = Float.greatestFiniteMagnitude / 2.5
check(oldChange - 4 == oldChange, "float subtraction at FLT_MAX")
for count in 2...100 {
    let pos = movie(1, count, -Double(Float.greatestFiniteMagnitude))
    let neg = movie(1, count, Double(Float.greatestFiniteMagnitude))
    check(pos >= 0 && pos < count && neg >= 0 && neg < count, "large finite events, count \(count)")
}
check(movie(2, 4, .nan) == 2, "NaN")
check(movie(2, 4, .infinity) == 2, "infinity")
check(movie(2, 4, 0) == 2, "no delta")
check(movie(2, 0, 1) == 2, "no movie")
print("PASS: temporal wrap, signed deltas, large finite events and invalid input")
'''

with tempfile.TemporaryDirectory(prefix='horos-movie-scroll-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    flags = isix_modules.module_flags('IsiXImaging', p / 'module')
    subprocess.run(['xcrun', 'swiftc', *flags, str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
