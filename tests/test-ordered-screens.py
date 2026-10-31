"""The tiling's order of the screens returns every screen, whatever their frames.

The order (`ViewerTilingLayout.orderedScreens(visibleFrames:)` in IsiXImaging,
formerly -[AppController orderedScreens]) takes, pass after pass, the screen
lowest and leftmost of those still left, and it repeated the pass until none
was left. The comparison starts from a million points, so a screen whose
visible frame lies at or beyond that, or is not a number, never passed it, and
the loop never ended: tiling, the window centre and the viewer rows all ask for
the order, and the app hung. A pass that picks nothing now ends the loop and
keeps the remaining screens in the order they came in.

ViewerTilingLayout.swift is compiled with `swiftc` beside a driver that gives
it visible frames, and run under a time limit.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
LAYOUT = ROOT / 'Modules/IsiXImaging/Sources/ViewerWorkspace/ViewerTilingLayout.swift'
if 'static func orderedScreens(visibleFrames:' not in LAYOUT.read_text():
    sys.exit('FAIL: the order of the screens is gone from ViewerTilingLayout.swift')

main = r'''import AppKit

struct FakeScreen { let name: String; let visibleFrame: NSRect; init(_ name: String, _ frame: NSRect) { self.name = name; self.visibleFrame = frame } }

func names(_ screens: [FakeScreen]) -> [String] {
    ViewerTilingLayout.orderedScreens(visibleFrames: screens.map { $0.visibleFrame }).map { screens[$0].name }
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
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-ordered-screens-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(main)
    build = subprocess.run(['xcrun', 'swiftc', str(p / 'main.swift'), str(LAYOUT), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stderr.strip()[-2000:])
        sys.exit('FAIL: the order of the screens did not compile')
    try:
        run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=20)
        print((run.stdout + run.stderr).strip())
        if run.returncode:
            failures.append('the order of the screens loses or reorders screens')
    except subprocess.TimeoutExpired:
        failures.append('the order of the screens does not end when a screen fails the comparison')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the order of the screens ends with every screen')
