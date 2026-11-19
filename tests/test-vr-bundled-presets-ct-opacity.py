#!/usr/bin/env python3
"""The 16-bit CLUTs of the bundled 3D presets keep bone visible on a CT.

The 3D window's opacity is 0 outside the curves of a 16-bit CLUT, as the CLUT
editor draws them closed down to 0 at their first and last points
(AdvancedCLUTFunctions): a curve whose last point stands above 0 drops to 0
just past it. The bundled presets (Horos/Resources/3DPRESETS) were drawn when
the volume kept, or ramped down from, a curve's last height up to its maximum;
a bone curve that ends at 245 HU at 0.53 would show no bone above 245 HU. So
the curve that reaches highest, when it ends above 0, goes on to 3071 HU, the
top of a CT's 12-bit range (-1024...3071), at the height and with the colour
of its last point: an open end, which the editor leaves out of the curve's
windowing and its square, and which the volume holds up to its maximum, so
that an extended-scale CT shows metal above 3071 HU. The other curves end as
they were drawn.

Every bundled preset with a 16-bit CLUT ("advancedCLUT", 16bitClutCurves and
16bitClutColors) is decoded and checked:

- its curves ascend, with a colour per point; the one that reaches highest,
  when it ends above 0, ends at 3071 HU or beyond with the height and colour
  of the point before it repeated;
- no two curves overlap: where two curves have points at the same value the
  later one decides, and a click in the editor brings a curve to the front, so
  the volume would change with a click;
- the preset's wl and ww, which its information panel shows, are the window
  the editor gives the volume when the preset selects its first curve: that
  curve's ends, an open end left out;
- the 4096-entry opacity table the volume receives (the functions sampled
  over the volume's range, linear between nodes, as vtkPiecewiseFunction's
  GetTable and the Metal renderer sample them), in a projection, on four CTs,
  -1024...3071 HU (offset 1024), -3024...3071 HU (offset 3024) and two of
  extended scale, -1024...20000 HU and -10240...30710 HU (the second scaled
  down to the view's 32000 values, as VRView's computeValueFactor does), in
  every order of the curves: the same tables in every order; 0 more than 1 HU
  away from every curve, below the lowest one and between them; and from the
  bone threshold (the highest point of the curves below 3071 HU) up to 3071
  HU, and up to the volume's maximum after an open end, the square of that
  point's height, the preset's last height, in that point's colour.

The functions come from AdvancedCLUTFunctions.swift itself, compiled with a
small driver; the table and the colours are sampled here.

An optional argument, a git revision or a folder of presets, reads the presets
from there (the functions stay the working tree's): the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from itertools import permutations
from pathlib import Path
import json
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRESETS = 'Horos/Resources/3DPRESETS'
TARGET = ['-target', 'arm64-apple-macos15.0']
ENTRIES = 4096
TOP = 3071.0
CTS = [(-1024.0, 3071.0), (-3024.0, 3071.0), (-1024.0, 20000.0), (-10240.0, 30710.0)]
source = sys.argv[1] if len(sys.argv) > 1 else None


def presets():
    """(name, property list) of every bundled preset, from the working tree, a folder or a revision."""
    folder = ROOT / PRESETS if source is None else Path(source)
    if folder.is_dir():
        return [(path.stem, plistlib.loads(path.read_bytes())) for path in sorted(folder.glob('*.plist'))]
    listing = subprocess.check_output(['git', '-C', str(ROOT), 'ls-tree', '--name-only', source, PRESETS + '/'],
                                      text=True).splitlines()
    return [(Path(path).stem, plistlib.loads(subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{source}:{path}'])))
            for path in sorted(listing) if path.endswith('.plist')]


DRIVER = r'''
import Foundation

struct Case: Decodable {
    let name: String
    let minimum, maximum, offset, factor, divisor: Double
    let curves: [[[Double]]]
}

let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for c in cases {
    let curves = c.curves.map { $0.map { AdvancedCLUTFunctions.Point(value: $0[0], height: $0[1], red: $0[2], green: $0[3], blue: $0[4]) } }
    let functions = AdvancedCLUTFunctions(curves: curves, minimum: c.minimum, maximum: c.maximum, offset: c.offset,
                                          valueFactor: c.factor, opacityDivisor: c.divisor)
    print("case \(c.name)")
    for node in functions.opacity { print("opacity \(node.x) \(node.opacity)") }
    for node in functions.colour { print("colour \(node.x) \(node.red) \(node.green) \(node.blue)") }
}
'''


def sample(nodes, x):
    """A piecewise linear function at x, its end nodes' values beyond them."""
    if not nodes:
        return None
    if x <= nodes[0][0]:
        return nodes[0][1]
    if x >= nodes[-1][0]:
        return nodes[-1][1]
    for (x1, y1), (x2, y2) in zip(nodes, nodes[1:]):
        if x1 <= x <= x2:
            s = (x - x1) / (x2 - x1)
            return tuple((1 - s) * a + s * b for a, b in zip(y1, y2)) if isinstance(y1, tuple) else (1 - s) * y1 + s * y2
    return nodes[-1][1]


def factor(minimum, maximum):
    """The view's value factor: a range wider than its 32000 values is scaled down to them."""
    return 32000.0 / (maximum - minimum) if maximum - minimum > 32000 else 1.0


def open_end(curve):
    """Whether the curve's last point is an open end: at 3071 HU or beyond, at the height of the point before it."""
    return len(curve) > 2 and curve[-1]['x'] >= TOP and curve[-1]['y'] == curve[-2]['y']


def windowed(curve):
    """The points the editor windows: all but an open end."""
    return curve[:-1] if open_end(curve) else curve


def check_curves(name, preset, curves, colours, failures):
    """The curves as written; answers whether the tables can be checked."""
    if len(curves) != len(colours) or any(len(c) != len(k) or not c for c, k in zip(curves, colours)):
        failures.append(f'{name}: a curve without points, or a colour per point missing')
        return False
    for index, curve in enumerate(curves):
        values = [p['x'] for p in curve]
        if values != sorted(values):
            failures.append(f'{name}: curve {index} is not in ascending order')
            return False
    highest = max(range(len(curves)), key=lambda i: curves[i][-1]['x'])
    curve, colour = curves[highest], colours[highest]
    last = curve[-1]
    if last['y'] > 0 and last['x'] < TOP:
        failures.append(f'{name}: curve {highest}, the highest, ends at {last["x"]:.1f} HU, {last["y"]:.3f} high, below {TOP:g} HU')
    elif last['y'] > 0 and (len(curve) < 3 or curve[-2]['y'] != last['y'] or colour[-2] != colour[-1]):
        failures.append(f'{name}: curve {highest}, the highest, goes on to {last["x"]:g} HU with another height or colour '
                        f'than its last point at {curve[-2]["x"]:.1f} HU')
    spans = sorted((c[0]['x'], c[-1]['x'], i) for i, c in enumerate(curves))
    for (_, end, a), (start, _, b) in zip(spans, spans[1:]):
        if start <= end:
            failures.append(f'{name}: curves {a} and {b} overlap from {start:.1f} to {end:.1f} HU')
    first = windowed(curves[0])
    wl, ww = (first[-1]['x'] + first[0]['x']) / 2, first[-1]['x'] - first[0]['x']
    if abs(preset.get('wl', float('nan')) - wl) > 0.01 or abs(preset.get('ww', float('nan')) - ww) > 0.01:
        failures.append(f'{name}: wl {preset.get("wl")} and ww {preset.get("ww")}, which its information panel shows, '
                        f'are not the window of its first curve, {wl:.2f} and {ww:.2f}')
    return True


def tables(minimum, maximum, recorded):
    """The opacity and colour tables the volume samples, an entry per value."""
    offset, scale = -minimum, factor(minimum, maximum)
    opacity = [(x, y) for x, y in recorded['opacity']]
    colour = {}
    for x, r, g, b in recorded['colour']:  # of two at the same value, the later one
        colour[x] = (r, g, b)
    colour = sorted(colour.items())
    start, end = (offset + minimum) * scale, (offset + maximum) * scale
    values = [start + (i / (ENTRIES - 1)) * (end - start) for i in range(ENTRIES)]
    return [(x / scale - offset, sample(opacity, x), sample(colour, x)) for x in values]


def check_tables(name, curves, colours, minimum, maximum, table, failures):
    spans = [(c[0]['x'], max(c[-1]['x'], maximum) if open_end(c) else c[-1]['x']) for c in curves]
    reach = max(TOP, maximum) if any(open_end(c) for c in curves) else TOP
    points = [(p['x'], p['y'], tuple(k[c] for c in ('red', 'green', 'blue'))) for curve, ks in zip(curves, colours)
              for p, k in zip(curve, ks)]
    below = [p for p in points if p[0] < TOP]
    threshold = max(p[0] for p in below)
    height, tint = [(h, c) for x, h, c in below if x == threshold][-1]
    expected = height * height
    wrong, tinted = [], []
    for value, found, shade in table:
        if all(value < low - 1 or value > high + 1 for low, high in spans) and found != 0:
            wrong.append(f'{value:.0f} HU: {found:.4f}, not 0')
        elif threshold <= value <= reach:
            if abs(found - expected) > 1e-6:
                wrong.append(f'{value:.0f} HU: {found:.4f}, not {expected:.4f}')
            if shade is None or any(abs(a - b) > 1e-6 for a, b in zip(shade, tint)):
                tinted.append(f'{value:.0f} HU')
    label = f'{name} on {minimum:g}...{maximum:g} HU'
    if wrong:
        failures.append(f'{label}: {len(wrong)} of {ENTRIES} entries wrong, e.g. '
                        + '; '.join(wrong[:: max(1, len(wrong) // 5)][:5]))
    if tinted:
        failures.append(f'{label}: the colour above {threshold:.1f} HU is not that point\'s at {len(tinted)} entries, '
                        f'e.g. {tinted[0]}')
    if not wrong and not tinted:
        print(f'PASS {label}: 0 outside the curves, {expected:.3f} from {threshold:.0f} to {reach:g} HU')


bundled = [(name, p) for name, p in presets() if p.get('advancedCLUT') and p.get('16bitClutCurves')]
failures = []
if not bundled:
    failures.append(f'no preset with a 16-bit CLUT in {PRESETS}')
cases, checked = [], []
for name, p in bundled:
    curves, colours = p['16bitClutCurves'], p.get('16bitClutColors') or []
    if not check_curves(name, p, curves, colours, failures):
        continue
    orders = list(permutations(range(len(curves))))
    checked.append((name, curves, colours, orders))
    for minimum, maximum in CTS:
        for order in orders:
            cases.append({'name': f'{name} {minimum:g} {maximum:g} {order}', 'minimum': minimum, 'maximum': maximum,
                          'offset': -minimum, 'factor': factor(minimum, maximum), 'divisor': 1.0,
                          'curves': [[[q['x'], q['y'], k['red'], k['green'], k['blue']] for q, k in zip(curves[i], colours[i])]
                                     for i in order]})

sources = sorted((ROOT / 'Modules').glob('*/Sources/**/AdvancedCLUTFunctions.swift'))
if len(sources) != 1:
    print(f'FAIL: AdvancedCLUTFunctions.swift found {len(sources)} times under Modules', file=sys.stderr)
    sys.exit(1)
with tempfile.TemporaryDirectory(prefix='horos-preset-opacity-') as temp:
    folder = Path(temp)
    (folder / 'main.swift').write_text(DRIVER, encoding='utf-8')
    (folder / 'cases.json').write_text(json.dumps(cases), encoding='utf-8')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', *TARGET, str(sources[0]), str(folder / 'main.swift'),
                            '-o', str(folder / 'functions')], capture_output=True, text=True, timeout=600)
    if built.returncode != 0:
        print(built.stderr[-4000:], file=sys.stderr)
        print('FAIL: AdvancedCLUTFunctions.swift does not compile with the driver', file=sys.stderr)
        sys.exit(1)
    run = subprocess.run([str(folder / 'functions'), str(folder / 'cases.json')], capture_output=True, text=True,
                         timeout=60)
    if run.returncode != 0:
        print(run.stdout[-2000:], run.stderr[-2000:], file=sys.stderr)
        sys.exit(1)

recorded, current = {}, None
for line in run.stdout.splitlines():
    word, rest = line.split(' ', 1)
    if word == 'case':
        current = recorded.setdefault(rest, {'opacity': [], 'colour': []})
    else:
        current[word].append(tuple(float(v) for v in rest.split()))

for name, curves, colours, orders in checked:
    for minimum, maximum in CTS:
        table = tables(minimum, maximum, recorded[f'{name} {minimum:g} {maximum:g} {orders[0]}'])
        for order in orders[1:]:
            other = tables(minimum, maximum, recorded[f'{name} {minimum:g} {maximum:g} {order}'])
            changed = [a[0] for a, b in zip(table, other) if a[1:] != b[1:]]
            if changed:
                failures.append(f'{name} on {minimum:g}...{maximum:g} HU: with the curves in the order {list(order)}, '
                                f'{len(changed)} of {ENTRIES} entries differ, from {changed[0]:.0f} HU')
        check_tables(name, curves, colours, minimum, maximum, table, failures)

print(f'{len(bundled)} bundled presets with a 16-bit CLUT: ' + ', '.join(name for name, _ in bundled))
for failure in failures:
    print('FAIL: ' + failure)
sys.exit(1 if failures else 0)
