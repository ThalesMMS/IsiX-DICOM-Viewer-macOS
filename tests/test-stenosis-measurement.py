#!/usr/bin/env python3
"""Curved MPR Stenosis tool: the lumen and the NASCET degree on synthetic vessels.

Compiles StenosisMeasurement.swift and measures straight synthetic tubes in
patient space, with a half-maximum edge of 0.4 mm as CT gives:

- a tube that narrows from a 3 mm to a 1.5 mm radius and widens back gives
  75 % by area and 50 % by diameter, within one point, with the minimum at
  the narrowing and a distal reference;
- a calcified plaque (1300 HU) touching the narrowed lumen stays out of its
  area;
- a neighbouring vessel touching the lumen stays out of its outline;
- a centerline beside the lumen, in soft tissue, measures nothing there.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

from sources import source_text

measurement = source_text('StenosisMeasurement')

driver = r'''
import Foundation
import simd

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}
func near(_ value: Double, _ expected: Double, _ tolerance: Double) -> Bool { abs(value - expected) <= tolerance }

/// A lumen of radius r at (cx, cy) with an edge that falls from `value` to 0
/// over 0.4 mm, half of it at r.
func disc(_ p: SIMD3<Double>, cx: Double, cy: Double, r: Double, value: Double) -> Double {
    let rho = ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
    return value * min(max(0.5 - (rho - r) / 0.4, 0), 1)
}
/// The narrowing: 3 mm, down to 1.5 mm between z = 20 and 25, back up by 30.
func radius(_ z: Double) -> Double {
    switch z {
    case ..<15: return 3
    case ..<20: return 3 - 1.5 * (z - 15) / 5
    case ..<25: return 1.5
    case ..<30: return 1.5 + 1.5 * (z - 25) / 5
    default: return 3
    }
}
let length = 50.0
func frame(_ t: Double) -> Stenosis.Frame {
    Stenosis.Frame(point: SIMD3(0, 0, t * length), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
}
let settings = Stenosis.Settings()

// 1. The narrowing alone.
func tube(_ p: SIMD3<Double>) -> Float { Float(disc(p, cx: 0, cy: 0, r: radius(p.z), value: 400)) }
let sections = Stenosis.sections(from: 0, to: 1, length: length, settings: settings, frame: frame, sample: tube)
check(sections.count == 101, "a section every 0.5 mm: \(sections.count)")
let reference = Stenosis.defaultReference(stretch: length)
check(reference == 40...50, "default reference: the distal quarter, at most 10 mm: \(reference)")
if let r = Stenosis.result(of: sections, reference: reference) {
    print(String(format: "narrowing: A_min %.2f at %.1f mm, A_ref %.2f, NASCET area %.1f %%, D_min %.2f, D_ref %.2f, NASCET diameter %.1f %%, D_eq %.2f",
                 r.minimumArea, r.minimumPosition, r.referenceArea, r.nascetByArea, r.minimumDiameter, r.referenceDiameter, r.nascetByDiameter, r.equivalentDiameter))
    check(near(r.nascetByArea, 75, 1), "NASCET by area \(r.nascetByArea)")
    check(near(r.nascetByDiameter, 50, 1), "NASCET by diameter \(r.nascetByDiameter)")
    check((20...25).contains(r.minimumPosition), "minimum in the narrowing: \(r.minimumPosition)")
    check(near(r.referenceArea, .pi * 9, .pi * 9 * 0.03), "reference area \(r.referenceArea)")
    check(near(r.equivalentDiameter, 3, 0.1), "equivalent diameter \(r.equivalentDiameter)")
    check(r.meanArea < r.referenceArea && r.meanArea > r.minimumArea, "mean area between")
} else { check(false, "no result for the narrowing") }

// 2. A calcified plaque touching the narrowed lumen.
func plaque(_ p: SIMD3<Double>) -> Float {
    let lumen = disc(p, cx: 0, cy: 0, r: radius(p.z), value: 400)
    let calcium = (15...30).contains(p.z) ? disc(p, cx: radius(p.z) + 1.0, cy: 0, r: 1.0, value: 1300) : 0
    return Float(max(lumen, calcium))
}
let narrowed = Stenosis.section(at: 0.45, position: 0, frame: frame(0.45), settings: settings, sample: plaque)
print(String(format: "plaque: area %.2f mm2 (lumen %.2f)", narrowed.area, Double.pi * 2.25))
check(near(narrowed.area, .pi * 2.25, .pi * 2.25 * 0.06), "the plaque stays out of the area: \(narrowed.area)")

// 3. A neighbouring vessel of 4 mm touching a 3 mm lumen.
func neighbour(_ p: SIMD3<Double>) -> Float {
    Float(max(disc(p, cx: 0, cy: 0, r: 3, value: 400), disc(p, cx: 7, cy: 0, r: 4, value: 350)))
}
let beside = Stenosis.section(at: 0.1, position: 0, frame: frame(0.1), settings: settings, sample: neighbour)
let farthest = beside.contour.map { simd_length(SIMD2($0.x, $0.y)) }.max() ?? 0
print(String(format: "neighbour: area %.2f mm2 (lumen %.2f), outline reaches %.2f mm", beside.area, Double.pi * 9, farthest))
check(near(beside.area, .pi * 9, .pi * 9 * 0.04), "the neighbour stays out of the area: \(beside.area)")
check(farthest < 3.4, "the neighbour stays out of the outline: \(farthest)")

// A centerline that runs beside the lumen, in soft tissue (60 HU), measures
// nothing there, rather than a blob of tissue.
func beside(_ p: SIMD3<Double>) -> Float { Float(max(disc(p, cx: 4, cy: 0, r: 2.5, value: 400), 60)) }
let off = Stenosis.section(at: 0.5, position: 0, frame: frame(0.5), settings: settings, sample: beside)
check(!off.isValid, "no lumen measured in soft tissue: \(off.area)")

// A section without contrast has no lumen and no result.
let empty = Stenosis.section(at: 0.5, position: 0, frame: frame(0.5), settings: settings) { _ in 0 }
check(!empty.isValid, "no lumen without contrast")
check(Stenosis.result(of: [empty], reference: 0...1) == nil, "no result without a valid section")

if failures > 0 { exit(1) }
print("PASS: 75 % by area and 50 % by diameter; plaque and neighbour left out")
'''

with tempfile.TemporaryDirectory(prefix='horos-stenosis-') as directory:
    work = Path(directory)
    (work / 'StenosisMeasurement.swift').write_text(measurement)
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                            str(work / 'StenosisMeasurement.swift'), str(work / 'main.swift'), '-o', str(work / 'test')],
                           capture_output=True, text=True, timeout=300)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=120)
    print(run.stdout.strip())
    failed = run.returncode != 0

# The tool's place in the curved MPR window: a toolbar button beside the Path
# Assistant, not a ToolMode; the strip under the reformation views; the
# stretched and straightened views hand it their drags and conversions.
controller = source_text('CPRController')
cpr_view = source_text('CPRView')
checks = [
    ('NSToolbarItem.Identifier("tbPathAssistant"), NSToolbarItem.Identifier("tbStenosis")' in controller, 'default toolbar puts Stenosis after the Path Assistant'),
    ('toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("tbStenosis"), at: index)' in controller, 'saved toolbars get the item once'),
    ('stenosisTool?.curvedPathDidChange()' in controller, 'a path edit reaches the tool'),
    ('stenosisTool?.setActive(false)' in controller, 'closing the window turns the tool off'),
    ('@objc public var stenosisStrip: NSView?' in cpr_view and 'rest.size.height -= stripHeight' in cpr_view, 'the strip takes the bottom of the CPR view'),
    ('currentTool' not in source_text('StenosisTool') and 'setCurrentTool' not in source_text('StenosisTool'), 'the tool does not change the shared ToolMode'),
]
for name in ('CPRStretchedView', 'CPRStraightenedView'):
    text = source_text(name)
    checks.append((all(f'stenosisTool?.{call}(event, in: self) == true' in text for call in ('handleMouseDown', 'handleMouseDragged', 'handleMouseUp')), f'{name} hands its drags to the tool'))
    checks.append((f'extension {name}: StenosisPathView' in text, f'{name} converts positions for the tool'))
    checks.append(('stenosisTool?.viewDidDraw(self)' in text, f'{name} redraws the overlay'))
checks.append(('stenosisViewPoint(forPatientVector' in source_text('CPRTransverseView'), 'the transverse view projects the outline'))
for ok, what in checks:
    if not ok:
        print('FAIL:', what); failed = True
sys.exit(1 if failed else 0)
