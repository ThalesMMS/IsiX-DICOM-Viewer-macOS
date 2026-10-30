#!/usr/bin/env python3
"""A trackpad pinch or rotation reaches the other viewers as it happens.

The zoom tool and the scroll-wheel zoom call -[ViewerController
propagateSettings] on every change, so viewers that share settings follow.
-magnifyWithEvent: and -rotateWithEvent: changed the zoom and the angle
without it: the other viewers followed only at the next click, whose
-mouseDown: ends in -mouseDragged:. The production gesture handlers
(DCMView+Scrolling.swift), with the messages they send the window controller
(DCMView+Tools.swift), run here against a stand-in DCMView and window
controller, in a 2D viewer and in a view that is not one (MPR, CPR), which must
not propagate.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
scrolling = (root / 'Horos/Sources/DCMView+Scrolling.swift').read_text()
tools = (root / 'Horos/Sources/DCMView+Tools.swift').read_text()


def method(selector):
    """The Swift method of `selector`, as a method of the stand-in: its gesture is a Gesture."""
    start = scrolling.index('    @objc(' + selector + ')\n')
    text = scrolling[start:scrolling.index('\n    }\n', start) + 7]
    text = text.replace('    @objc(' + selector + ')\n', '')
    return text.replace('public override dynamic func', 'func').replace('NSEvent', 'Gesture')


messages = re.search(r'@objc protocol DCMViewInputMessages \{.*?\n\}\n', tools, re.S).group(0)
messages += re.search(r'@inline\(__always\)\nfunc inputMessages\(.*?\n\}\n', tools, re.S).group(0)

code = r'''
import AppKit

typealias ROI = NSObject
typealias HorosVolumeLengthROI = NSObject
MESSAGES
final class Controller: NSObject {
    var propagations = 0, cancels = 0
    @objc func propagateSettings() { propagations += 1 }
}
final class Gesture {
    var deltaZ: CGFloat = 0
    var rotation: Float = 0
}
final class DCMView {
    var horos_scaleValue: Float = 1, horos_rotation: Float = 0
    var scaleValue: Float { get { horos_scaleValue } set { horos_scaleValue = newValue } }
    var rotation: Float { get { horos_rotation } set { horos_rotation = newValue } }
    var twoD = false, needsDisplay = false
    let controller = Controller()
    func is2DViewer() -> Bool { twoD }
    func windowController() -> Any! { controller }
    func cancelOpeningScaleToFitForInteraction() { controller.cancels += 1 }
METHODS
}
func check(_ condition: Bool, _ what: String) {
    if !condition { FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!); exit(1) }
}
let v = DCMView()
v.twoD = true
let pinch = Gesture(); pinch.deltaZ = 30
v.magnify(with: pinch)
check(abs(v.scaleValue - 1.5) < 1e-5 && v.controller.propagations == 1 && v.controller.cancels == 1, "pinch")
v.magnify(with: pinch)
check(v.controller.propagations == 2, "second pinch")

let turn = Gesture(); turn.rotation = 10
v.rotate(with: turn)
check(abs(v.rotation + 15) < 1e-5 && v.controller.propagations == 3 && v.controller.cancels == 3, "rotation")

// A view that is not a 2D viewer changes itself only.
let mpr = DCMView()
mpr.magnify(with: pinch)
mpr.rotate(with: turn)
check(abs(mpr.scaleValue - 1.5) < 1e-5 && mpr.controller.propagations == 0, "a view that is not a 2D viewer")
print("PASS: pinch and rotation propagate from a 2D viewer on every gesture event, not from other views")
'''.replace('MESSAGES', messages).replace('METHODS', method('magnifyWithEvent:') + method('rotateWithEvent:'))

with tempfile.TemporaryDirectory(prefix='horos-gesture-propagate-') as folder:
    p = Path(folder)
    (p / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(p / 'main.swift'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True, timeout=60)
