#!/usr/bin/env python3
"""Exercise the production 2D wheel stepping branches.

The branches are DCMView+Scrolling.swift's, compiled as they are in a stand-in
view with IsiXImaging, whose WheelSteps make the steps, and run: ordinary,
stack (Shift) and ComPACS steps, signed large deltas, an index past the
short's range, the clamp of a huge step, and the clamp or wrap after the step.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness_defaults  # noqa: E402  - the harness's preferences stay in its own process
import isix_modules  # noqa: E402

root = Path(__file__).resolve().parents[1]
s = (root / 'Horos/Sources/DCMView+Scrolling.swift').read_text()
tools = (root / 'Horos/Sources/DCMView+Tools.swift').read_text()
wheel = s[s.index('    public override dynamic func scrollWheel(with theEvent: NSEvent) {'):]
a = wheel.index('} else if modifiers.contains(.shift) {')
b = wheel.index('\n        } else if abs(Double(deltaX)) > 0.7 {', a)
branch = 'if' + wheel[a + len('} else if'):b]
a = wheel.index('        if self.scrollThroughSeriesIfNecessary(Int32(self.horos_curImage)) {')
b = wheel.index('        self.inputShowCurrentImage()', a)
finish = wheel[a:b]
beyond = re.search(r'@inline\(__always\)\nfunc inputBeyondLast\(.*?\n\}\n', tools, re.S).group(0)

code = harness_defaults.SWIFT + r'''
import AppKit
import IsiXImaging

BEYOND
nonisolated(unsafe) var compact = false
enum PluginManager { static func isComPACS() -> Bool { compact } }
final class Pix { var stack: Int16 = 3 }
final class View {
    var horos_curImage = 0
    var horos_imageRows = 2, horos_imageColumns = 2
    var curDCM: Pix? = Pix()
    var dcmPixList: [Int] = []
    var inc = 0
    func scrollThroughSeriesIfNecessary(_ i: Int32) -> Bool { false }
    func step(_ deltaY: Float, reverse reverseScrollWheel: Float, modifiers: NSEvent.ModifierFlags) {
        var inc = 0
BRANCH
        self.inc = inc
    }
    func finish() {
        let dcmPixList = self.dcmPixList
FINISH
    }
}
func check(_ condition: Bool, _ what: String, line: Int = #line) {
    if !condition { FileHandle.standardError.write("FAIL line \(line): \(what)\n".data(using: .utf8)!); exit(1) }
}
let v = View()
for shift in [false, true] { for rev: Float in [-1, 1] {
    let modifiers: NSEvent.ModifierFlags = shift ? .shift : []
    for d in -30...30 where d != 0 {
        v.horos_curImage = 100
        var change = rev * Float(d) / 2.5
        if shift { change = change >= 0 ? max(1, change.rounded(.up)) : min(-1, change.rounded(.down)) }
        else { change = change > 0 ? max(1, change) : min(-1, change) }
        let expected = Int((shift ? 3 : 4) * change)
        v.step(Float(d), reverse: rev, modifiers: modifiers)
        check(v.horos_curImage == 100 + expected && v.inc == expected, "shift \(shift) reverse \(rev) delta \(d)")
    }
    v.horos_curImage = 100; v.step(rev * 1e12, reverse: rev, modifiers: modifiers)
    check(v.horos_curImage == Int(Int32.max) && v.inc > 0, "large forward")
    v.horos_curImage = 100; v.step(-rev * 1e12, reverse: rev, modifiers: modifiers)
    check(v.horos_curImage < 0 && v.inc < 0, "large backward")
    v.horos_curImage = Int(Int16.max); v.step(rev * 5, reverse: rev, modifiers: modifiers)
    check(v.horos_curImage == Int(Int16.max) + (shift ? 6 : 8) && v.inc == (shift ? 6 : 8), "past the short's limit")
} }
// Exercise the production clamp/wrap after the safe step.
v.horos_imageRows = 1; v.horos_imageColumns = 1
v.dcmPixList = Array(0..<16)
for loop in [false, true] {
    UserDefaults.standard.set(loop, forKey: "loopScrollWheel")
    v.horos_curImage = 7; v.step(Float.greatestFiniteMagnitude, reverse: 1, modifiers: []); v.finish()
    check(v.horos_curImage == (loop ? 0 : 15), "past the last image, loop \(loop)")
    v.horos_curImage = 7; v.step(-Float.greatestFiniteMagnitude, reverse: 1, modifiers: []); v.finish()
    check(v.horos_curImage == (loop ? 15 : 0), "before the first image, loop \(loop)")
}
v.horos_imageRows = 2; v.horos_imageColumns = 2
compact = true; v.horos_curImage = 100
v.step(1e12, reverse: 1, modifiers: [])
check(v.horos_curImage == 104 && v.inc == 4, "ComPACS steps one row of images")
print("PASS: ordinary/stack/ComPACS stepping, signed large deltas and stepping past the short's range")
'''.replace('BEYOND', beyond).replace('BRANCH', branch).replace('FINISH', finish)

with tempfile.TemporaryDirectory(prefix='horos-wheel-index-') as d:
    p = Path(d)
    (p / 'main.swift').write_text(code)
    flags = isix_modules.module_flags('IsiXImaging', p / 'module')
    subprocess.run(['xcrun', 'swiftc', *flags, str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
