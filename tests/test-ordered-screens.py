#!/usr/bin/env python3
"""`-[AppController orderedScreens]` returns every screen, whatever their frames.

The method orders the screens by taking, pass after pass, the one lowest and
leftmost of those still left, and it repeated the pass until none was left. The
comparison starts from a million points, so a screen whose visible frame lies
at or beyond that, or is not a number, never passed it, and the loop never
ended: tiling, the window centre and the viewer rows all ask for the order, and
the app hung (#841). A pass that picks nothing now ends the loop and keeps the
remaining screens in the order they came in.

The method is compiled from AppController.swift with `swiftc`, with a stand-in
for NSScreen that only has a visible frame, and run under a time limit.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources

application = sources.source_text('AppController')

start = application.find('@objc func orderedScreens() -> NSArray! {')
if start < 0:
    sys.exit('FAIL: -orderedScreens is gone from AppController.swift')
method = application[start:application.index('\n    }\n', start) + len('\n    }\n')]
method = method.replace('@objc func', 'func').replace('NSScreen', 'FakeScreen')

main = r'''import AppKit

final class FakeScreen: NSObject {
    static var screens: [FakeScreen] = []
    let name: String
    let visibleFrame: NSRect
    init(_ name: String, _ frame: NSRect) { self.name = name; self.visibleFrame = frame }
}

final class Host {
%s
}

func names(_ screens: [FakeScreen]) -> [String] {
    FakeScreen.screens = screens
    return ((Host().orderedScreens() as? [FakeScreen]) ?? []).map { $0.name }
}

// The usual arrangement keeps the order the method has always given.
let left = FakeScreen("left", NSRect(x: -1920, y: 0, width: 1920, height: 1080))
let main = FakeScreen("main", NSRect(x: 0, y: 0, width: 1512, height: 944))
let right = FakeScreen("right", NSRect(x: 1512, y: 0, width: 2560, height: 1415))
precondition(names([main, right, left]) == ["left", "main", "right"], "\(names([main, right, left]))")
precondition(names([main]) == ["main"])
precondition(names([]) == [])

// A screen far away, beyond the starting point of the comparison.
let far = FakeScreen("far", NSRect(x: 2_000_000, y: 0, width: 1920, height: 1080))
let high = FakeScreen("high", NSRect(x: 0, y: 1_000_001, width: 1920, height: 1080))
precondition(names([far]) == ["far"], "\(names([far]))")
precondition(names([far, main, high]) == ["main", "far", "high"], "\(names([far, main, high]))")

// A frame that is not a number compares false with everything.
let broken = FakeScreen("broken", NSRect(x: CGFloat.nan, y: CGFloat.nan, width: 1, height: 1))
precondition(names([broken, main]) == ["main", "broken"], "\(names([broken, main]))")

print("PASS: every screen comes back once, and the method returns")
''' % method

failures = []
with tempfile.TemporaryDirectory(prefix='horos-ordered-screens-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(main)
    build = subprocess.run(['swiftc', str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stderr.strip()[-2000:])
        sys.exit('FAIL: -orderedScreens did not compile')
    try:
        run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=20)
        print((run.stdout + run.stderr).strip())
        if run.returncode:
            failures.append('-orderedScreens loses or reorders screens')
    except subprocess.TimeoutExpired:
        failures.append('-orderedScreens does not return when a screen fails the comparison')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: -orderedScreens ends with every screen')
