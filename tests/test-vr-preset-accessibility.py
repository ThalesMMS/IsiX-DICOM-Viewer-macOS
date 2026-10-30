#!/usr/bin/env python3
"""Exercise production thumbnail accessibility methods with controlled selection.

VRPresetPreview and VRController are Swift: the preview's accessibility
methods and -setSelectedState:, and the controller's -setSelectedPresetPreview:,
are compiled as they are into stand-ins of the two classes.
"""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
s = (root/'Horos/Sources/VRPresetPreview.swift').read_text()
a = s.index('    public override func isAccessibilityElement()')
b = s.index('    @objc(setSelected)\n', a)
c = (root/'Horos/Sources/VRController+Presets.swift').read_text()
a2 = c.index('    @objc(setSelectedPresetPreview:)')
b2 = c.index('    @objc(selectGroupWithName:)', a2)
code = r'''
import AppKit

final class Controller: NSObject {
    var selectedPresetPreview: VRPresetPreview?
    var updates = 0
CONTROLLER
    func updatePresetInfoPanel() { updates += 1 }
}

final class VRPresetPreview: NSView {
    var isEmptyPreview = false, isSelectedPreview = false
    var selectionView: NSView?
    var presetController: Controller?
METHODS
    func setSelected() { presetController?.setSelectedPresetPreview(self) }
}

let c = Controller()
let a = VRPresetPreview(), b = VRPresetPreview(), empty = VRPresetPreview()
a.presetController = c; b.presetController = c; empty.presetController = c; empty.isEmptyPreview = true
a.setAccessibilityLabel("Bone + Skin"); b.setAccessibilityLabel("Black & White")
precondition(a.isAccessibilityElement() && !empty.isAccessibilityElement())
precondition(a.accessibilityRole() == .radioButton)
precondition(a.accessibilityLabel() == "Bone + Skin")
precondition((a.accessibilityValue() as? NSNumber)?.boolValue == false)
precondition(a.accessibilityPerformPress()); precondition(c.selectedPresetPreview === a && (a.accessibilityValue() as? NSNumber)?.boolValue == true)
precondition(b.accessibilityPerformPress())
precondition(c.selectedPresetPreview === b && (b.accessibilityValue() as? NSNumber)?.boolValue == true && (a.accessibilityValue() as? NSNumber)?.boolValue == false)
precondition(!empty.accessibilityPerformPress()); precondition(c.selectedPresetPreview === b && c.updates == 2)
precondition(a.accessibilityPerformPress())
precondition((b.accessibilityValue() as? NSNumber)?.boolValue == false && (a.accessibilityValue() as? NSNumber)?.boolValue == true)
print("PASS: named radio role, selection switching and empty-slot rejection")
'''.replace('METHODS', s[a:b]).replace('CONTROLLER', c[a2:b2])
with tempfile.TemporaryDirectory(prefix='horos-preset-ax-') as d:
    p = Path(d)
    (p/'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(p/'main.swift'), '-o', str(p/'test')],
                   check=True)
    subprocess.run([str(p/'test')], check=True, timeout=60)
