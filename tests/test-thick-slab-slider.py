#!/usr/bin/env python3
"""Exercise MPR bindings and the 2D slab slider's real AppKit input geometry."""
import private_tmpdir  # noqa: F401
import os
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

root = Path(__file__).resolve().parents[1]
configuration = os.environ.get('HOROS_TEST_CONFIGURATION', 'Debug')
assert configuration in ('Debug', 'Release'), configuration
controller = (root / 'Horos/Sources/MPRController.swift').read_text()
proxy_start = controller.index('    private var thickSlabSliderScale:')
proxy_end = controller.index('    @objc(getClippingRangeThicknessInMm)', proxy_start)
proxy = controller[proxy_start:proxy_end]

driver = r'''
import AppKit
func check(_ ok: Bool, _ message: String) {
    if !ok { fflush(stdout); fatalError(message) }
}
func near(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 1e-9) {
    check(abs(a - b) <= tolerance * max(1, abs(b)), "\(message): \(a) != \(b)")
}
for bounds in [(0.01, 100.0), (0.137, 100.0), (1.0, 200.0), (2.0, 2.1)] {
    for exponential in [false, true] {
        let scale = ThickSlabSliderScale(minimum: bounds.0, maximum: bounds.1, exponential: exponential)
        check(scale.thickness(at: 0) == bounds.0, "minimum endpoint")
        check(scale.thickness(at: 1) == bounds.1, "maximum endpoint")
        near(scale.thickness(at: 0.5), exponential ? sqrt(bounds.0 * bounds.1) : (bounds.0 + bounds.1) / 2, "midpoint")
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
let zero = ThickSlabSliderScale(minimum: 0, maximum: 100, exponential: true)
near(zero.thickness(at: 0.5), 50, "zero lower bound falls back to linear")
for bounds in [(0.0, 0.0), (3.0, 2.0), (Double.nan, Double.infinity)] {
    let scale = ThickSlabSliderScale(minimum: bounds.0, maximum: bounds.1, exponential: true)
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
check(host.thickSlabSliderPosition > linearPosition, "exponential knob position")
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

_ = NSApplication.shared
final class SliderProbe: HorosThickSlabSlider {
    var redraws = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if newValue { redraws += 1 }; super.needsDisplay = newValue }
    }
}
let slider = SliderProbe(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
slider.minValue = 2
slider.maxValue = 128
slider.controlSize = .mini
slider.isContinuous = true
slider.integerValue = 20
let track = slider.trackRect
func point(_ fraction: Double) -> NSPoint {
    NSPoint(x: track.minX + track.width * fraction, y: slider.bounds.midY)
}
defaults.set(false, forKey: key)
near(slider.value(at: point(0.5)), 65, "2D linear midpoint")
near(Double(slider.fraction), 18.0 / 126.0, "2D linear knob")
defaults.set(true, forKey: key)
check(slider.integerValue == 20, "2D changing scale preserves slice count")
near(slider.value(at: point(0.5)), 16, "2D exponential midpoint")
near(slider.value(at: point(0.25)), 6, "2D first quarter grows slowly")
near(slider.value(at: point(0.75)), 45, "2D last quarter accelerates")
check(slider.value(at: point(0.75)) - slider.value(at: point(0.5)) >
      slider.value(at: point(0.5)) - slider.value(at: point(0.25)), "2D increasing sensitivity")
for enabled in [false, true] {
    defaults.set(enabled, forKey: key)
    check(slider.minValue == 2 && slider.maxValue == 128, "2D same bounds in both modes")
    check(slider.value(at: point(-1)) == 2 && slider.value(at: point(2)) == 128, "2D reachable endpoints")
    for count in 2...128 {
        slider.integerValue = count
        near(slider.value(at: point(Double(slider.fraction))), Double(count), "2D programmatic value and knob roundtrip")
    }
}

final class ActionTarget: NSObject {
    var counts: [Int] = []
    @objc func changed(_ sender: NSSlider) { counts.append(sender.integerValue) }
}
let target = ActionTarget()
slider.target = target
slider.action = #selector(ActionTarget.changed(_:))
slider.isEnabled = true
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 40),
                      styleMask: [], backing: .buffered, defer: false)
window.contentView!.addSubview(slider)
func click(_ fraction: Double) {
    let location = slider.convert(point(fraction), to: nil)
    let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                               timestamp: 0, windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 0)!
    NSApp.postEvent(up, atStart: true)
    let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                                 timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                 eventNumber: 0, clickCount: 1, pressure: 1)!
    slider.mouseDown(with: down)
}
slider.integerValue = 20
defaults.set(true, forKey: key)
click(0.5)
check(target.counts == [16] && slider.integerValue == 16, "2D action receives slice count, not normalized position")
slider.removeFromSuperview()
let redraws = slider.redraws
defaults.set(false, forKey: key)
let until = Date(timeIntervalSinceNow: 0.1)
while Date() < until { RunLoop.current.run(mode: .default, before: until) }
check(slider.redraws > redraws, "2D preference change refreshes knob drawing")
check(slider.integerValue == 16 && target.counts == [16], "2D toggle never sends a projection action")
window.contentView!.addSubview(slider)
click(0.5)
check(target.counts == [16, 65], "2D linear click retains original action units")
window.orderOut(nil)
print("PASS: 2D endpoints, increasing sensitivity, knob roundtrips, native click action and scale toggle")
'''.replace('PROXY', proxy)

with tempfile.TemporaryDirectory(prefix='horos-thick-slab-slider-') as folder:
    folder = Path(folder)
    (folder / 'main.swift').write_text(driver)
    binary = folder / 'check'
    subprocess.run(['xcrun', 'swiftc', '-O' if configuration == 'Release' else '-Onone',
                    str(root / 'Horos/Sources/ThickSlabSliderScale.swift'),
                    str(root / 'Horos/Sources/HorosCellSlider.swift'),
                    str(root / 'Horos/Sources/HorosThickSlabSlider.swift'),
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

viewers = list((root / 'Horos/Resources').glob('*.lproj/Viewer.xib'))
assert viewers, '2D viewer windows exist'
for path in viewers:
    document = ET.parse(path)
    outlet = document.find('.//outlet[@property="sliderFusion"]')
    slider = document.find(f'.//slider[@id="{outlet.get("destination")}"]')
    assert slider.get('customClass') == 'HorosThickSlabSlider', path
    cell = slider.find('sliderCell')
    assert float(cell.get('minValue')) == 2 and float(cell.get('maxValue')) == 128, path
    assert slider.find('./connections/action').get('selector') == 'sliderFusionAction:', path
print(f'PASS: {len(viewers)} localized 2D sliders preserve bounds and projection action')
