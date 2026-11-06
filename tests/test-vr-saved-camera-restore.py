#!/usr/bin/env python3
"""The VR window's saved camera comes back whole: position, focal point and view-up.

-[VRView get3DStateDictionary] saves the camera with the series' 3D state
(VRMIP-<mode>-<series> in the database's 3DSTATE folder) and
-[VRView set3DStateDictionary:] reads it when the window opens again. A new
view has no volume mapper yet: reading the state is what installs the engine
(engine = 2), and the engine's first installation frames the volume from the
standard anterior view (-resetImage:, -saView:), keeping only the camera's
distance. Installed after the saved camera was set, it turned the view back to
the front: the distance came back, the orientation did not.

The check runs the methods as VRView+State.swift has them, without the app:
both bodies, and the readers of the saved values, are compiled into a stand-in
VRView whose camera is a small model of VTK's (position, focal point, view-up,
clipping range; an azimuth turns the position about the view-up through the
focal point), and whose first engine installation puts the camera in front of
the volume at the same distance, as -resetImage: does.

1. A new view reads no state (the engine is installed and frames the volume),
   the camera is turned 40 degrees in azimuth and 15 in elevation, and its
   state is written to a plist file as -[VRController save3DState] writes it.
2. A second new view reads that file as -[VRController load3DState] reads it.
   Its camera must have the saved position, focal point and view-up (to the
   float precision of the file), and so the saved orientation and distance.

`<git revision>` as an optional argument reads that revision, the negative
control: before the engine was installed first, the second view came back
facing the front.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def block(source, signature):
    start = source.find(signature)
    if start < 0:
        return ''
    depth, i = 0, source.index('{', start)
    while True:
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                return source[start:i + 1]
        i += 1


view = read('Horos/Sources/VRView+State.swift')
setter = block(view, '    @objc(set3DStateDictionary:)\n    func set3DStateDictionary(')
getter = block(view, '    @objc(get3DStateDictionary)\n    func get3DStateDictionary(')
readers = re.search(r'\n(/// `\[x floatValue\]`.*?)\nextension VRView \{', view, re.S)
if not (setter and getter and readers):
    print('FAIL: the sources this probe compiles moved; the test needs a new look')
    sys.exit(1)
if shutil.which('xcrun') is None:
    print('skipped: needs xcrun', file=sys.stderr)
    sys.exit(SKIPPED)

MAIN = r'''
import Foundation

@@READERS@@

/// VTK's camera and volume, as far as the saved state reaches them.
final class StubVTK {
    var position = [0.0, -100.0, 0.0], focal = [0.0, 0.0, 0.0], viewUp = [0.0, 0.0, 1.0]
    var clipping = [1.0, 1000.0]
    var cameraViewAngle = 30.0
    var shade = 0
    let hasProperty = true, hasCamera = true, hasVolume = true
    var volumeHasMapper = false

    func setCameraPosition(_ p: UnsafePointer<Double>) { position = [p[0], p[1], p[2]] }
    func setCameraViewUp(_ p: UnsafePointer<Double>) { viewUp = [p[0], p[1], p[2]] }
    func setCameraFocalPoint(_ p: UnsafePointer<Double>) { focal = [p[0], p[1], p[2]] }
    func setCameraClippingRangeNear(_ near: Double, far: Double) { clipping = [near, far] }
    func getCameraPosition(_ p: UnsafeMutablePointer<Double>) { for i in 0..<3 { p[i] = position[i] } }
    func getCameraViewUp(_ p: UnsafeMutablePointer<Double>) { for i in 0..<3 { p[i] = viewUp[i] } }
    func getCameraFocalPoint(_ p: UnsafeMutablePointer<Double>) { for i in 0..<3 { p[i] = focal[i] } }
    func getCameraClippingRange(_ p: UnsafeMutablePointer<Double>) { p[0] = clipping[0]; p[1] = clipping[1] }

    var distance: Double {
        sqrt((0..<3).reduce(0.0) { $0 + (position[$1] - focal[$1]) * (position[$1] - focal[$1]) })
    }

    /// -resetImage: then -saView: in front of the volume, the distance kept.
    func frameFromTheFront(center: [Double]) {
        let d = distance
        focal = center
        position = [center[0], center[1] - d, center[2]]
        viewUp = [0, 0, 1]
    }

    /// vtkCamera::Azimuth: the position turns about the view-up through the focal point.
    func azimuth(_ degrees: Double) {
        rotate(about: viewUp, degrees)
    }

    /// vtkCamera::Elevation: about the cross of the direction of projection and the view-up.
    func elevation(_ degrees: Double) {
        let p = (0..<3).map { focal[$0] - position[$0] }
        let axis = [p[1] * viewUp[2] - p[2] * viewUp[1], p[2] * viewUp[0] - p[0] * viewUp[2], p[0] * viewUp[1] - p[1] * viewUp[0]]
        let n = sqrt(axis.reduce(0) { $0 + $1 * $1 })
        rotate(about: axis.map { $0 / n }, degrees)
        // OrthogonalizeViewUp
        let dir = (0..<3).map { focal[$0] - position[$0] }
        let dn = sqrt(dir.reduce(0) { $0 + $1 * $1 })
        let f = dir.map { $0 / dn }
        let dot = (0..<3).reduce(0.0) { $0 + viewUp[$1] * f[$1] }
        var up = (0..<3).map { viewUp[$0] - dot * f[$0] }
        let un = sqrt(up.reduce(0) { $0 + $1 * $1 })
        up = up.map { $0 / un }
        viewUp = up
    }

    private func rotate(about k: [Double], _ degrees: Double) {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        let v = (0..<3).map { position[$0] - focal[$0] }
        let kv = [k[1] * v[2] - k[2] * v[1], k[2] * v[0] - k[0] * v[2], k[0] * v[1] - k[1] * v[0]]
        let kd = (0..<3).reduce(0.0) { $0 + k[$1] * v[$1] }
        position = (0..<3).map { focal[$0] + v[$0] * c + kv[$0] * s + k[$0] * kd * (1 - c) }
    }
}

final class StubPix { let suvConverted = false }
enum VolumeRenderingPreferences { static let defaultShading = "defaultShading" }
struct StubPreferences { subscript(_ key: String) -> Bool { false } }
struct StubGraph { let preferences = StubPreferences() }

final class VRView: NSObject {
    let horos_vtk = StubVTK()
    let processGraph = StubGraph()
    let horos_firstObject: StubPix? = StubPix()
    var horos_firstTime = true
    var renderingMode = 0
    var horos_superSampling: Float = 2
    var horos_wl: Float = 40, horos_ww: Float = 400
    var horos_projectionMode: Int32 = 0
    var horos_clippingRangeThickness = 0.0
    var horos_clipRangeActivated = false
    var dontResetImage = false
    var shadingValues: [Float] = [0.15, 0.9, 0.3, 15]
    var viewAngleAdjustable: Bool { horos_projectionMode != 1 }

    func setShadingValues(_ a: Float, _ d: Float, _ s: Float, _ p: Float) { shadingValues = [a, d, s, p] }
    func getShadingValues(_ a: UnsafeMutablePointer<Float>, _ d: UnsafeMutablePointer<Float>,
                          _ s: UnsafeMutablePointer<Float>, _ p: UnsafeMutablePointer<Float>) {
        a.pointee = shadingValues[0]; d.pointee = shadingValues[1]; s.pointee = shadingValues[2]; p.pointee = shadingValues[3]
    }
    func setWLWW(_ wl: Float, _ ww: Float) { horos_wl = wl; horos_ww = ww }
    func getClippingRangeThickness() -> Double { horos_clippingRangeThickness / Double(horos_superSampling) }

    /// -resetImage:, as the engine's first installation, a slab switched
    /// outside a restore, and the endoscopy projection call it.
    func resetImage() { horos_vtk.frameFromTheFront(center: [0, 0, 0]) }

    /// The engine: its first installation frames the volume (-instantiateEngine:).
    var engine: Int32 = 0 {
        didSet {
            horos_vtk.volumeHasMapper = true
            if horos_firstTime { resetImage() }
        }
    }

    /// Perspective and parallel keep the camera; a slab on or the endoscopy reset it.
    var projectionMode: Int32 {
        get { horos_projectionMode }
        set {
            horos_projectionMode = newValue
            horos_vtk.cameraViewAngle = newValue == 2 ? 60 : 30
            if horos_clipRangeActivated || newValue == 2 { resetImage() }
        }
    }
    var viewAngle: Double {
        get { horos_vtk.cameraViewAngle }
        set { horos_vtk.cameraViewAngle = newValue }
    }
    var clipRangeActivated: Bool {
        get { horos_clipRangeActivated }
        set {
            clippingRangeThickness = newValue ? 2 : 0
            if !dontResetImage { resetImage() }
        }
    }
    var clippingRangeThickness: Double {
        get { horos_clippingRangeThickness }
        set {
            horos_clippingRangeThickness = newValue * Double(horos_superSampling)
            horos_clipRangeActivated = newValue != 0
        }
    }
}

extension VRView {
@@SETTER@@

@@GETTER@@
}

func line(_ name: String, _ values: [Double]) -> String {
    name + " " + values.map { String(format: "%.9g", $0) }.joined(separator: " ")
}

let file = CommandLine.arguments[1]

// 1. A new view, the camera turned, the state written.
let first = VRView()
first.set3DStateDictionary(nil)
print(line("framed", first.horos_vtk.position))
first.horos_vtk.azimuth(40)
first.horos_vtk.elevation(15)
let turned = first.horos_vtk
print(line("turnedPosition", turned.position))
print(line("turnedFocal", turned.focal))
print(line("turnedViewUp", turned.viewUp))
print(line("turnedDistance", [turned.distance]))
guard let saved = first.get3DStateDictionary(), saved.write(toFile: file, atomically: true) else {
    print("notWritten")
    exit(3)
}

// 2. Another new view, the file read.
let second = VRView()
second.set3DStateDictionary(NSDictionary(contentsOfFile: file) as? [AnyHashable: Any])
let back = second.horos_vtk
print(line("backPosition", back.position))
print(line("backFocal", back.focal))
print(line("backViewUp", back.viewUp))
print(line("backDistance", [back.distance]))
print("engineInstalled", back.volumeHasMapper)
'''

with tempfile.TemporaryDirectory() as tmp:
    t = Path(tmp)
    (t / 'main.swift').write_text(MAIN.replace('@@READERS@@', readers.group(1))
                                  .replace('@@SETTER@@', setter).replace('@@GETTER@@', getter))
    swift = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(t / 'main.swift'), '-o', 'probe'],
                           cwd=t, capture_output=True, text=True, timeout=300)
    if swift.returncode:
        print('FAIL: the probe does not build:\n' + swift.stderr[-3000:])
        sys.exit(1)
    state = t / 'VRMIP-0-probe'
    run = subprocess.run([str(t / 'probe'), str(state)], capture_output=True, text=True, timeout=60)
    if run.returncode:
        print(f'FAIL: the probe stopped with {run.returncode}: {run.stdout.strip()[-500:]} {run.stderr.strip()[-500:]}')
        sys.exit(1)
    values = {}
    for text in run.stdout.splitlines():
        name, *rest = text.split(' ')
        values[name] = rest
    print('\n'.join(run.stdout.splitlines()))

    def numbers(name):
        return [float(v) for v in values.get(name, [])]

    def close(a, b, tolerance):
        return len(a) == len(b) and all(abs(x - y) <= tolerance * max(1.0, abs(y)) for x, y in zip(a, b))

    # The file keeps floats: 1e-5 relative.
    turned_position, framed = numbers('turnedPosition'), numbers('framed')
    if close(turned_position, framed, 1e-3):
        failures.append('the probe did not turn the camera')
    for part in ('Position', 'Focal', 'ViewUp'):
        if not close(numbers('back' + part), numbers('turned' + part), 1e-5):
            failures.append(f'the camera {part.lower()} read back {values.get("back" + part)} '
                            f'is not the saved one {values.get("turned" + part)}')
    if not close(numbers('backDistance'), numbers('turnedDistance'), 1e-5):
        failures.append('the camera distance did not come back')
    if values.get('engineInstalled') != ['true']:
        failures.append('reading the state must still install the engine')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: a turned camera saved with the VR state comes back with its position, focal point and view-up')
