#!/usr/bin/env python3
"""The opacity a 16-bit CLUT gives the 3D window's volume is 0 outside its curves.

VRView's -setAdvancedCLUT:lowResolution: (VRView+AdvancedCLUT.swift) turns the
CLUT editor's curves into VTK's opacity and colour functions. VTK renders with
them, and the Metal renderer samples the same opacity function, 4096 entries
over the volume's range: `(value + offset) · valueFactor` from the series'
minimum to its maximum (VRView+VolumeHost.swift). That table is checked here,
for both engines.

The view put the function's zero segment at the series' raw minimum and
maximum, while the curves' points went in at `(offset + value) · valueFactor`.
In a CT (minimum −1050, offset 1050) the segment ended inside the curves, at
377 HU, and above the last point the opacity kept that point's value up to the
volume's maximum; in an MR (minimum 0) it ramped down from a curve's last
point to the next node. The editor draws each curve closed down to 0 at its
first and last points: outside the curves the volume is transparent, and on a
curve its opacity is the curve's.

VRView+AdvancedCLUT.swift is compiled as it is, with a stand-in view (the
members it reads) and a stand-in VTK adapter that records its calls. The calls
are applied with the rules of VTK's vtkPiecewiseFunction: AddSegment removes
the nodes within it and adds its two ends, AddPoint replaces a node at the same
value, and GetTable samples `start + i/(n − 1)·(end − start)`, linear between
nodes and the end nodes' values beyond them. With the VTK of a Debug build the
same calls are also replayed into a real vtkPiecewiseFunction, whose table must
be the same; without one that comparison is said to be skipped.

Cases: a CT (−1050...1427 HU, offset 1050, factor 1, volume rendering with a
supersampling of 2), an MR (0...1200, a projection), a range wider than the
view's 16 bits, scaled down (−3024...40000), a CT without curves and a CT with
a curve over another at the same values. Every entry is checked: on a curve,
more than one value of the volume away from its ends, the curve's opacity;
everywhere else 0. The colour function has each point's colour. Of two curves'
points at one value, the volume has the opacity and colour of the curve in
front, the first, which the editor draws on top; it had the later curve's, the
one drawn behind.

Send to back moves the first curve to the end, and the editor sends the curves
again. When the curve shares no value with the others the functions are the
same and the view skips them, rather than rendering the volume again: the
colour nodes went to the functions in the curves' order, so any reorder made
other functions. When it covers another, the volume takes the curve now in
front.

The same curves are sent again, at low resolution as windowing sends them, when
the mode changes (setMode: calls setWLWW::, and the editor sends its CLUT): the
opacity's divisor changes, so the volume must get the new functions, not keep
the ones of the other mode. So too when a 4D set's value map changes with a
wider range (recomputeValueFactorAfterRangeChange). Three cases apply their
curves first in another state and check the table of the second.

The windowing drag of the view (VRView+Mouse.swift) and setOpacity
(VRView+Transfer.swift) are read as text: the drag sends the 8-bit opacity only
without a 16-bit CLUT, as setWLWW:: does, and setOpacity, which replaces the
opacity function, forgets the 16-bit functions last applied, so the next CLUT
the editor sends is applied whatever it is.

`<git revision>` as an optional argument reads the view from that revision: the
negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import math
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
VIEW = 'Horos/Sources/VRView+AdvancedCLUT.swift'
TARGET = ['-target', 'arm64-apple-macos15.0']
ENTRIES = 4096
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(ROOT), 'show', revision + ':' + path]).decode('utf-8')
    return (ROOT / path).read_text(encoding='utf-8')


def f32(value):
    """The value as the view holds it, a Float."""
    return struct.unpack('f', struct.pack('f', value))[0]


def ramp(start):
    """The editor's new curve: rising to its last point, 0.682 high."""
    return [(start, 0.0, 0, 0, 0), (start + 190, math.sqrt(0.027), 1, 0, 0),
            (start + 392, math.sqrt(0.133), 1, 1, 0), (start + 537, math.sqrt(0.682), 1, 1, 1)]


def narrow(middle, low=0.3, high=0.9, end=0.5):
    """A narrow curve whose ends both stand above 0."""
    return [(middle - 30, low, 0.2, 0.4, 0.6), (middle, high, 0.9, 0.1, 0.1), (middle + 30, end, 0.5, 0.5, 0.5)]


def peak(middle):
    """A narrow curve closed at 0 at both ends."""
    return [(middle - 20, 0.0, 0, 0, 1), (middle, 0.8, 0, 1, 0), (middle + 20, 0.0, 1, 0, 0)]


def covered(middle):
    """Two curves at the same values, each in colours of its own: the one in
    front, the first, higher than the one behind it."""
    return [[(middle - 100, 0.0, 1, 0, 0), (middle, 0.9, 1, 0.5, 0), (middle + 100, 0.0, 1, 1, 0)],
            [(middle - 100, 0.0, 0, 0, 1), (middle, 0.4, 0, 0.5, 1), (middle + 100, 0.0, 0, 1, 1)]]


CASES = [
    # name, minimum, maximum, offset, value factor, rendering mode, supersampling, curves, and the state
    # (minimum, maximum, offset, value factor, mode) the same curves were applied in first, or None
    ('CT', -1050.0, 1427.0, 1050.0, 1.0, 0, 2.0, [ramp(-400), peak(300), narrow(600)], None),
    ('MR', 0.0, 1200.0, 0.0, 1.0, 1, 2.0, [ramp(100), narrow(900)], None),
    ('wide', -3024.0, 40000.0, 3024.0, f32(32000.0 / 43024.0), 0, 1.0, [ramp(-400), narrow(2000), peak(30000)], None),
    ('empty', -1050.0, 1427.0, 1050.0, 1.0, 0, 2.0, [], None),
    ('CT projection after volume rendering', -1050.0, 1427.0, 1050.0, 1.0, 1, 2.0, [ramp(-400), narrow(600)],
     (-1050.0, 1427.0, 1050.0, 1.0, 0)),
    ('MR volume rendering after a projection', 0.0, 1200.0, 0.0, 1.0, 0, 2.0, [ramp(100), narrow(900)],
     (0.0, 1200.0, 0.0, 1.0, 1)),
    ('4D set widened', -2000.0, 40000.0, 2000.0, f32(32000.0 / 42000.0), 0, 2.0, [ramp(-400), narrow(600)],
     (-1050.0, 1427.0, 1050.0, 1.0, 0)),
    ('CT, a curve over another', -1050.0, 1427.0, 1050.0, 1.0, 0, 2.0, covered(200), None),
]

# Curves applied in a CT, then sent again in the other order, as Send to back
# leaves them: whether the volume must take them again.
REORDERS = [
    ('reordered without a value in common', [ramp(-400), peak(300), narrow(600)], False),
    ('reordered, a curve over another', covered(200), True),
]

STAND_INS = r'''
import AppKit
import IsiXVolumeRendering

/// What the view reads of its controller.
final class VRController: NSObject {
    var minimum: Float = 0, maximum: Float = 0
    func windowWillClose() -> Bool { false }
    func minimumValue() -> Float { minimum }
    func maximumValue() -> Float { maximum }
}

/// The VTK adapter's transfer-function calls, as lines.
final class IsiXVTKVolumeView: NSObject {
    var calls: [String] = []
    func removeAllOpacityPoints() { calls.append("clear-opacity") }
    func removeAllColourPoints() { calls.append("clear-colour") }
    func addOpacitySegment(from x1: Double, value v1: Double, to x2: Double, value v2: Double) {
        calls.append("segment \(x1) \(v1) \(x2) \(v2)")
    }
    func addOpacityPoint(at x: Double, value: Double) { calls.append("point \(x) \(value)") }
    func addColourPoint(at x: Double, red: Double, green: Double, blue: Double) {
        calls.append("colour \(x) \(red) \(green) \(blue)")
    }
    func setVolumeMinimumImageSampleDistance(_ distance: Float) {}
    func setBlendingMinimumImageSampleDistance(_ distance: Float) {}
}

/// The members of the view the advanced CLUT reads and writes; the record of
/// what was applied both as it is now and as the revision before held it.
class VRView: NSView {
    var horos_controller: VRController?
    let recorder = IsiXVTKVolumeView()
    var horos_vtk: IsiXVTKVolumeView { recorder }
    var horos_advancedCLUT = false
    var horos_appliedCLUT: AdvancedCLUTFunctions?
    var horos_appliedCurves: [AnyHashable: Any]?
    var horos_appliedResolution = false
    var horos_OFFSET16: Float = 0
    var horos_valueFactor: Float = 1
    var horos_superSampling: Float = 1
    var horos_LOD: Float = 1
    var lowResLODFactor: Float = 1
    var renderingMode = 0
}
'''


def swift_literal(curves):
    return '[' + ', '.join('[' + ', '.join('[' + ', '.join(repr(float(v)) for v in point) + ']' for point in curve) + ']'
                           for curve in curves) + ']'


def swift_main():
    lines = ['import AppKit', '', 'var curves: [[[Double]]]']
    for name, minimum, maximum, offset, factor, mode, supersampling, curves, before in CASES:
        first = 'nil' if before is None else '(' + ', '.join(repr(v) for v in before) + ')'
        lines += [f'curves = {swift_literal(curves)}',
                  f'apply("{name}", minimum: {minimum!r}, maximum: {maximum!r}, offset: {offset!r}, factor: {factor!r}, '
                  f'mode: {mode}, superSampling: {supersampling!r}, curves: curves, before: {first})']
    for name, curves, _ in REORDERS:
        lines += [f'reorder("{name}", curves: {swift_literal(curves)}, sent: {swift_literal(curves[1:] + curves[:1])})']
    return '\n'.join(lines) + r'''

/// The curves as the editor holds them: NSValue points, a calibrated RGB colour each.
func editorCLUT(_ curves: [[[Double]]]) -> NSMutableDictionary {
    let points = NSMutableArray(), colours = NSMutableArray()
    for curve in curves {
        points.add(NSMutableArray(array: curve.map { NSValue(point: NSPoint(x: $0[0], y: $0[1])) }))
        colours.add(NSMutableArray(array: curve.map { NSColor(calibratedRed: $0[2], green: $0[3], blue: $0[4], alpha: 1) }))
    }
    return NSMutableDictionary(dictionary: ["curves": points, "colors": colours])
}

/// The curves applied in a CT in volume rendering, then the first sent to the
/// back, at full resolution as Send to back sends them: the calls of the second.
@MainActor func reorder(_ name: String, curves: [[[Double]]], sent: [[[Double]]]) {
    let controller = VRController()
    controller.minimum = -1050
    controller.maximum = 1427
    let view = VRView(frame: .zero)
    view.horos_controller = controller
    view.horos_superSampling = 2
    view.horos_OFFSET16 = 1050
    view.setAdvancedCLUT(editorCLUT(curves), lowResolution: false)
    view.recorder.calls.removeAll()
    view.setAdvancedCLUT(editorCLUT(sent), lowResolution: false)
    print("reorder \(name)")
    for call in view.horos_vtk.calls { print(call) }
}

@MainActor func apply(_ name: String, minimum: Float, maximum: Float, offset: Float, factor: Float, mode: Int,
                      superSampling: Float, curves: [[[Double]]],
                      before: (Float, Float, Float, Float, Int)?) {
    let controller = VRController()
    let view = VRView(frame: .zero)
    view.horos_controller = controller
    view.horos_superSampling = superSampling
    func state(_ minimum: Float, _ maximum: Float, _ offset: Float, _ factor: Float, _ mode: Int) {
        controller.minimum = minimum
        controller.maximum = maximum
        view.horos_OFFSET16 = offset
        view.horos_valueFactor = factor
        view.renderingMode = mode
    }
    let clut = editorCLUT(curves)
    if let before {
        // Applied first in another state, then sent again as windowing sends it.
        state(before.0, before.1, before.2, before.3, before.4)
        view.setAdvancedCLUT(clut, lowResolution: false)
        state(minimum, maximum, offset, factor, mode)
        view.setAdvancedCLUT(clut, lowResolution: true)
    } else {
        state(minimum, maximum, offset, factor, mode)
        view.setAdvancedCLUT(clut, lowResolution: false)
    }
    print("case \(name)")
    for call in view.horos_vtk.calls { print(call) }
}
'''


REPLAY = r'''
// The calls replayed into VTK's own functions; "table from to count" prints
// the opacity function's GetTable.
#include <vtkColorTransferFunction.h>
#include <vtkPiecewiseFunction.h>
#include <cstdio>
#include <cstring>
#include <vector>
int main() {
    vtkPiecewiseFunction *opacity = vtkPiecewiseFunction::New();
    vtkColorTransferFunction *colour = vtkColorTransferFunction::New();
    char line[1024];
    double a, b, c, d;
    int count;
    while (fgets(line, sizeof line, stdin)) {
        if (!strncmp(line, "clear-opacity", 13)) opacity->RemoveAllPoints();
        else if (!strncmp(line, "clear-colour", 12)) colour->RemoveAllPoints();
        else if (sscanf(line, "segment %lf %lf %lf %lf", &a, &b, &c, &d) == 4) opacity->AddSegment(a, b, c, d);
        else if (sscanf(line, "point %lf %lf", &a, &b) == 2) opacity->AddPoint(a, b);
        else if (sscanf(line, "colour %lf %lf %lf %lf", &a, &b, &c, &d) == 4) colour->AddRGBPoint(a, b, c, d);
        else if (sscanf(line, "table %lf %lf %d", &a, &b, &count) == 3) {
            std::vector<double> table(count);
            opacity->GetTable(a, b, count, table.data());
            for (double value : table) printf("%.17g\n", value);
        }
    }
    opacity->Delete();
    colour->Delete();
    return 0;
}
'''


def piecewise(calls):
    """The opacity nodes and colour nodes the calls leave, by VTK's rules."""
    opacity, colour = [], {}
    for call in calls:
        word, *numbers = call.split()
        values = [float(v) for v in numbers]
        if word == 'clear-opacity':
            opacity = []
        elif word == 'clear-colour':
            colour = {}
        elif word == 'segment':
            x1, y1, x2, y2 = values
            opacity = [n for n in opacity if not (x1 <= n[0] <= x2)]
            for x, y in ((x1, y1), (x2, y2)):
                opacity = [n for n in opacity if n[0] != x] + [(x, y)]
        elif word == 'point':
            x, y = values
            opacity = [n for n in opacity if n[0] != x] + [(x, y)]
        elif word == 'colour':
            colour[values[0]] = tuple(values[1:])
    return sorted(opacity), colour


def table(nodes, start, end, size):
    """vtkPiecewiseFunction::GetTable, clamping on, linear segments."""
    out = []
    for i in range(size):
        x = start + (i / (size - 1)) * (end - start)
        upper = next((k for k, n in enumerate(nodes) if n[0] > x), len(nodes))
        if not nodes:
            out.append(0.0)
        elif upper == len(nodes):
            out.append(nodes[-1][1])
        elif upper == 0:
            out.append(nodes[0][1])
        else:
            (x1, y1), (x2, y2) = nodes[upper - 1], nodes[upper]
            s = (x - x1) / (x2 - x1)
            out.append((1 - s) * y1 + s * y2)
    return out


def drawn(curves, value, divisor):
    """The opacity of the curves at a value of the series, as the editor draws
    them: linear between a curve's points, 0 outside every curve."""
    for curve in curves:
        if curve[0][0] <= value <= curve[-1][0]:
            for (xa, ha, *_), (xb, hb, *_) in zip(curve, curve[1:]):
                if xa <= value <= xb:
                    ya, yb = ha * ha / divisor, hb * hb / divisor
                    return ya + (value - xa) / (xb - xa) * (yb - ya)
    return 0.0


def check_case(case, calls, vtk_table, failures):
    name, minimum, maximum, offset, factor, mode, supersampling, curves, _ = case
    divisor = supersampling if mode == 0 else 1.0
    start, end = (offset + minimum) * factor, (offset + maximum) * factor
    opacity, colour = piecewise(calls)
    entries = table(opacity, start, end, ENTRIES)
    if vtk_table is not None:
        differing = [i for i, (a, b) in enumerate(zip(entries, vtk_table)) if abs(a - b) > 1e-12]
        if differing or len(vtk_table) != ENTRIES:
            failures.append(f'{name}: VTK\'s own table differs from its rules at {len(differing)} entries')
    unit = 1 / factor
    wrong = []
    for i, found in enumerate(entries):
        x = start + (i / (ENTRIES - 1)) * (end - start)
        value = x / factor - offset
        if any(abs(value - curve[k][0]) <= unit for curve in curves for k in (0, -1)):
            continue
        expected = drawn(curves, value, divisor)
        if abs(found - expected) > 1e-5:
            wrong.append(f'{value:.1f}: {found:.4f}, not {expected:.4f}')
    if wrong:
        failures.append(f'{name}: {len(wrong)} of {ENTRIES} entries wrong, e.g. ' + '; '.join(wrong[:: max(1, len(wrong) // 6)][:6]))
    else:
        print(f'PASS {name}: every entry 0 outside the curves and the curve\'s opacity on them')
    # Of two curves' points at one value, the colour of the curve in front, the
    # first: the editor draws it on top.
    expected = {}
    for curve in reversed(curves):
        for point in curve:
            expected[(offset + point[0]) * factor] = (point[0], point[2:])
    for x, (value, rgb) in sorted(expected.items()):
        if colour.get(x) is None or any(abs(a - b) > 1e-6 for a, b in zip(colour[x], rgb)):
            failures.append(f'{name}: the colour function lacks the colour of the point at {value}')
            break


def check_reorder(name, curves, again, calls, failures):
    """Send to back of a curve that shares no value with the others leaves the
    functions as they were, and the view skips them; of a curve over another,
    the volume takes the one now in front."""
    if not again:
        if calls:
            failures.append(f'{name}: the same functions were applied again ({len(calls)} calls to VTK)')
        else:
            print(f'PASS {name}: the volume skips the same functions')
        return
    nodes, colour = piecewise(calls)
    opacity, front = dict(nodes), curves[1]
    wrong = [p[0] for p in front if opacity.get(1050 + p[0]) != f32(p[1] * p[1] / 2)
             or any(abs(a - b) > 1e-6 for a, b in zip(colour.get(1050 + p[0], (-1, -1, -1)), p[2:]))]
    if wrong:
        failures.append(f'{name}: at {wrong} the volume has not the opacity and colour of the curve now in front')
    else:
        print(f'PASS {name}: the volume takes the curve now in front')


def block(source, start, end):
    """The text of `source` from the first `start` to the next `end` after it."""
    begin = source.find(start)
    if begin < 0:
        return None
    stop = source.find(end, begin + len(start))
    return source[begin:stop if stop >= 0 else len(source)]


def check_wiring(failures):
    """The windowing drag and setOpacity, as text (see the docstring)."""
    drag = block(read('Horos/Sources/VRView+Mouse.swift'), 'case .tWL:', 'case .t3DCut:')
    guarded = drag is not None and 'if !horos_advancedCLUT {\n                    setOpacity(horos_currentOpacityArray)' in drag
    if drag is None or drag.count('setOpacity(') != 1 or not guarded:
        failures.append('the windowing drag sends the 8-bit opacity over a 16-bit CLUT (VRView+Mouse.swift, case .tWL)')
    else:
        print('PASS windowing drag: the 8-bit opacity only without a 16-bit CLUT')
    opacity = block(read('Horos/Sources/VRView+Transfer.swift'), 'func setOpacity(', '\n    }\n')
    if opacity is None or not (0 <= opacity.find('horos_appliedCLUT = nil') < opacity.find('removeAllOpacityPoints()')):
        failures.append('setOpacity replaces the opacity function and keeps the 16-bit functions as applied '
                        '(VRView+Transfer.swift)')
    else:
        print('PASS setOpacity: the 16-bit functions are applied again after it')


def vtk_install():
    for base in (ROOT / 'build', ROOT / 'build/Build'):
        install = base / 'Intermediates.noindex/Horos.build/Debug/VTK.build/Install'
        if (install / 'wlib/libVTK.a').is_file():
            return install
    return None


with tempfile.TemporaryDirectory(prefix='horos-advanced-clut-') as temp:
    folder = Path(temp)
    (folder / 'VRView+AdvancedCLUT.swift').write_text(read(VIEW), encoding='utf-8')
    (folder / 'StandIns.swift').write_text(STAND_INS, encoding='utf-8')
    (folder / 'main.swift').write_text(swift_main(), encoding='utf-8')
    flags = isix_modules.module_flags('IsiXVolumeRendering', folder / 'modules', TARGET)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-strict-concurrency=complete', *TARGET, *flags,
                            str(folder / 'main.swift'), str(folder / 'StandIns.swift'), str(folder / 'VRView+AdvancedCLUT.swift'),
                            '-o', str(folder / 'clut')], capture_output=True, text=True)
    if built.returncode != 0:
        print(built.stderr[-4000:], file=sys.stderr)
        print('FAIL: VRView+AdvancedCLUT.swift does not compile with the stand-ins', file=sys.stderr)
        sys.exit(1)
    run = subprocess.run([str(folder / 'clut')], capture_output=True, text=True, timeout=60)
    if run.returncode != 0:
        print(run.stdout[-2000:], run.stderr[-2000:], file=sys.stderr)
        sys.exit(1)
    recorded, current = {}, None
    for line in run.stdout.splitlines():
        if line.startswith(('case ', 'reorder ')):
            current = line[5:] if line.startswith('case ') else line
            recorded[current] = []
        elif current:
            recorded[current].append(line)

    vtk_tables = {}
    install = vtk_install()
    if install is None:
        print('skipped: the replay into VTK itself needs the VTK of a Debug build; its rules were applied here')
    else:
        (folder / 'replay.cxx').write_text(REPLAY)
        compiled = subprocess.run(['xcrun', 'clang++', '-std=c++17', '-I' + str(install / 'include'), str(folder / 'replay.cxx'),
                                   str(install / 'wlib/libVTK.a'), '-lz', '-o', str(folder / 'replay')],
                                  capture_output=True, text=True)
        if compiled.returncode != 0:
            print(compiled.stderr[-4000:], file=sys.stderr)
            print('FAIL: the VTK replay does not build', file=sys.stderr)
            sys.exit(1)
        for case in CASES:
            name, minimum, maximum, offset, factor = case[:5]
            commands = recorded.get(name, []) + [f'table {(offset + minimum) * factor!r} {(offset + maximum) * factor!r} {ENTRIES}']
            replay = subprocess.run([str(folder / 'replay')], input='\n'.join(commands) + '\n', capture_output=True, text=True,
                                    timeout=60, check=True)
            vtk_tables[name] = [float(v) for v in replay.stdout.split()]
        print('VTK replay: the calls replayed into vtkPiecewiseFunction')

    failures = []
    check_wiring(failures)
    for case in CASES:
        if case[0] not in recorded:
            failures.append(f'{case[0]}: nothing recorded')
            continue
        check_case(case, recorded[case[0]], vtk_tables.get(case[0]), failures)
    for name, curves, again in REORDERS:
        if 'reorder ' + name not in recorded:
            failures.append(f'{name}: nothing recorded')
            continue
        check_reorder(name, curves, again, recorded['reorder ' + name], failures)

for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
