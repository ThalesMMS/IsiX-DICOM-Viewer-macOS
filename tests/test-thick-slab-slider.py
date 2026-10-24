#!/usr/bin/env python3
"""Exercise MPR slider mapping and its Cocoa-bindings boundary without rendering."""
import private_tmpdir  # noqa: F401
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
controller = (root / 'Horos/Sources/MPRController.swift').read_text()
proxy_start = controller.index('    private var thickSlabSliderScale:')
proxy_end = controller.index('    @objc(getClippingRangeThicknessInMm)', proxy_start)
proxy = controller[proxy_start:proxy_end]

driver = r'''
import Foundation
func check(_ ok: Bool, _ message: String) {
    if !ok { fatalError(message) }
}
func near(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-9) {
    check(abs(a - b) <= tolerance * max(1, abs(b)), "\(message): \(a) != \(b)")
}
for bounds in [(0.01, 100.0), (0.137, 100.0), (1.0, 200.0), (2.0, 2.1)] {
    for logarithmic in [false, true] {
        let scale = ThickSlabSliderScale(minimum: bounds.0, maximum: bounds.1, logarithmic: logarithmic)
        check(scale.thickness(at: 0) == bounds.0, "minimum endpoint")
        check(scale.thickness(at: 1) == bounds.1, "maximum endpoint")
        near(scale.thickness(at: 0.5), logarithmic ? sqrt(bounds.0 * bounds.1) : (bounds.0 + bounds.1) / 2, "midpoint")
        for p in stride(from: 0.0, through: 1.0, by: 0.01) {
            near(scale.position(for: scale.thickness(at: p)), p, "position roundtrip")
            let mm = bounds.0 + (bounds.1 - bounds.0) * p
            near(scale.thickness(at: scale.position(for: mm)), mm, "millimeter roundtrip")
        }
        check(scale.thickness(at: -1) == bounds.0 && scale.thickness(at: 2) == bounds.1, "position clamps")
        check(scale.position(for: -1) == 0 && scale.position(for: .infinity) == 1, "millimeter clamps")
        check(scale.thickness(at: .nan) == bounds.0 && scale.position(for: .nan) == 0, "NaN stays finite")
    }
}
let zero = ThickSlabSliderScale(minimum: 0, maximum: 100, logarithmic: true)
near(zero.thickness(at: 0.5), 50, "zero lower bound falls back to linear")
for bounds in [(0.0, 0.0), (3.0, 2.0), (Double.nan, Double.infinity)] {
    let scale = ThickSlabSliderScale(minimum: bounds.0, maximum: bounds.1, logarithmic: true)
    check(scale.thickness(at: 0.5).isFinite && scale.position(for: 1) == 0, "uninitialized or invalid bounds")
}

// Compile the production proxy with a millimeter storage double in place of
// VRView. This exercises KVC, KVO, and the float boundary used by the renderer.
final class ControllerDouble: NSObject {
    var dcmIntervalMin: Float = 0.01
    var dcmIntervalMax: Float = 100
    var millimeters: Float = 10
    var writes = 0
    func getClippingRangeThicknessInMm() -> Float { millimeters }
    func setClippingRangeThicknessInMm(_ value: Float) { millimeters = value; writes += 1 }
    func refresh() { refreshThickSlabSliderPosition() }
PROXY
}
let defaults = UserDefaults.standard
let key = ThickSlabSliderScale.defaultsKey
let original = defaults.object(forKey: key)
defer {
    if let original { defaults.set(original, forKey: key) }
    else { defaults.removeObject(forKey: key) }
}
defaults.removeObject(forKey: key)
check(!defaults.bool(forKey: key), "unset preference is linear")
let host = ControllerDouble()
var updates = 0
let observation = host.observe(\.thickSlabSliderPosition, options: [.new]) { _, _ in updates += 1 }
let linearPosition = host.thickSlabSliderPosition
defaults.set(true, forKey: key)
host.refresh()
check(host.millimeters == 10 && host.writes == 0 && updates == 1, "changing scale only refreshes the knob")
check(host.thickSlabSliderPosition > linearPosition, "logarithmic knob position")
host.setValue(0.5, forKey: "thickSlabSliderPosition")
near(Double(host.millimeters), sqrt(Double(host.dcmIntervalMin) * Double(host.dcmIntervalMax)), "KVC writes mm", tolerance: 1e-6)
defaults.set(false, forKey: key)
let mm = host.millimeters
host.refresh()
check(host.millimeters == mm && host.writes == 1, "returning to linear preserves mm")
host.setValue(0.5, forKey: "thickSlabSliderPosition")
near(Double(host.millimeters), (Double(host.dcmIntervalMin) + Double(host.dcmIntervalMax)) / 2, "linear KVC midpoint", tolerance: 1e-6)
observation.invalidate()
print("PASS: mapping, midpoint, endpoints, roundtrips, clamping, KVC and scale changes preserving mm")
'''.replace('PROXY', proxy)

with tempfile.TemporaryDirectory(prefix='horos-thick-slab-slider-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    binary = folder / 'check'
    subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/ThickSlabSliderScale.swift'),
                    str(folder / 'main.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

nibs = list((root / 'Horos/Resources').glob('*.lproj/MPR.xib'))
assert nibs, 'MPR windows exist'
for path in nibs:
    document = ET.parse(path)
    slider = document.find('.//slider[@id="663"]')
    assert slider is not None, path
    bindings = slider.findall('./connections/binding')
    assert [(b.get('name'), b.get('keyPath')) for b in bindings] == [
        ('value', 'selection.thickSlabSliderPosition')], path
    cell = slider.find('sliderCell')
    assert float(cell.get('minValue', '0')) == 0 and float(cell.get('maxValue')) == 1, path
    assert document.find('.//textField/connections/binding[@keyPath="selection.clippingRangeThicknessInMm"]') is not None, path
    assert any(s.text == 'thickSlabSliderPosition' for s in document.findall('.//objectController/declaredKeys/string')), path

assert 'addObserver(self, forKeyPath: "values." + ThickSlabSliderScale.defaultsKey' in controller
assert 'removeObserver(self, forKeyPath: "values." + ThickSlabSliderScale.defaultsKey' in controller
assert 'if keyPath == "values." + ThickSlabSliderScale.defaultsKey {\n                self.refreshThickSlabSliderPosition()\n            }' in controller
for begin, end in [('var dcmIntervalMin:', 'var dcmIntervalMax:'),
                   ('var dcmIntervalMax:', 'var dcmmN:'),
                   ('private func setClippingRangeThicknessValue(', 'private func setClippingRangeModeValue(')]:
    section = controller[controller.index(begin):controller.index(end)]
    assert 'refreshThickSlabSliderPosition()' in section, begin
print(f'PASS: {len(nibs)} localized MPR slider bindings, millimeter fields and refresh wiring')
