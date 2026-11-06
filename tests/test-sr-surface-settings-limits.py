#!/usr/bin/env python3
"""The surface settings reach VTK with a resolution it can resample by and an RGB colour.

-[SRController renderSurfaces] and -renderFusionSurfaces hand the settings
sheet's values to the surface view, which builds the surfaces through the VTK
adapter. Two values broke that:

- a resolution of 0: vtkImageResample asserts on a magnification factor of 0;
- a colour whose components cannot be read: the fused surfaces asked the
  colour for its red, green and blue as it was, and NSColor raises an
  exception for a grey, CMYK, named (catalog) or pattern colour; a missing
  colour gave no colour at all.

What the sheet can give, checked in the ten localized SR.xib: the only control
bound to `resolution` is a slider from 0.1 to 1, so 0 does not come from the
sheet; the colours are colour wells, which never give nil but give whatever the
colour panel picked, grey, CMYK and named colours included, so the fused
surfaces' exception does.

The two methods and the colour conversion are compiled here from
SRController.swift, as they are, into a stand-in controller whose view records
what it was asked to build, with SurfaceResolution from IsiXVolumeRendering.
Every resolution reaches the view between 0.1 and 1 (0, a negative number and
NaN included), every colour as RGB between 0 and 1, without an exception. The
same methods of the revision before the fix, compiled the same way, hand 0 to
the view and end on the exception for a grey colour on the fused surfaces.
"""
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ElementTree
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = 'Horos/Sources/SRController.swift'
MARKER = 'static func surfaceRGB'

failures = []


def check(condition, what):
    print('%s: %s' % ('PASS' if condition else 'FAIL', what))
    if not condition:
        failures.append(what)


# What the sheet can give.
nibs = sorted(ROOT.glob('Horos/Resources/*.lproj/SR.xib'))
check(len(nibs) == 10, 'ten localized SR.xib (%d)' % len(nibs))
for nib in nibs:
    tree = ElementTree.parse(nib)
    parents = {child: parent for parent in tree.iter() for child in parent}
    bound = {}
    for binding in tree.iter('binding'):
        if binding.get('name') == 'value' and binding.get('keyPath') in ('resolution', 'firstColor', 'secondColor'):
            control = parents[parents[binding]]
            bound.setdefault(binding.get('keyPath'), []).append(control)
    sliders = bound.get('resolution', [])
    cell = sliders[0].find('sliderCell') if len(sliders) == 1 else None
    check(len(sliders) == 1 and sliders[0].tag == 'slider' and cell is not None
          and abs(float(cell.get('minValue')) - 0.1) < 1e-9 and float(cell.get('maxValue')) == 1,
          '%s: the resolution is a slider from 0.1 to 1, its only control' % nib.parent.name)
    check([c.tag for c in bound.get('firstColor', []) + bound.get('secondColor', [])] == ['colorWell', 'colorWell'],
          '%s: each colour is a colour well' % nib.parent.name)


def method(text, signature):
    """The source of the member whose declaration starts with `signature`, attributes dropped."""
    start = text.index(signature)
    line_start = text.rindex('\n', 0, start) + 1
    brace = text.index('{', start)
    depth = 0
    for index in range(brace, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            body = text[line_start:index + 1]
            return re.sub(r'@objc(\([^)]*\))?\s*', '', body)
    raise LookupError(signature)


HARNESS = r'''
import AppKit
import IsiXVolumeRendering

final class WaitRendering {
    init(_ message: String) {}
    func start() {}
    func end() {}
    func close() {}
}

final class View {
    var built: [(fusion: Bool, actor: Int, resolution: Float, rgb: [Float])] = []
    func changeActorBuildsGeometry(_ actor: Int, _ resolution: Float, _ isocontour: Float, _ useDecimate: Bool,
                                   _ decimateVal: Float, _ useSmooth: Bool, _ smoothVal: Int) -> Bool { true }
    func surfaceBuildSeconds(_ actor: Int) -> TimeInterval { 0 }
    func changeActor(_ actor: Int, _ resolution: Float, _ transparency: Float, _ r: Float, _ g: Float, _ b: Float,
                     _ isocontour: Float, _ useDecimate: Bool, _ decimateVal: Float, _ useSmooth: Bool, _ smoothVal: Int) {
        built.append((false, actor, resolution, [r, g, b]))
    }
    func BchangeActor(_ actor: Int, _ resolution: Float, _ transparency: Float, _ r: Float, _ g: Float, _ b: Float,
                      _ isocontour: Float, _ useDecimate: Bool, _ decimateVal: Float, _ useSmooth: Bool, _ smoothVal: Int) {
        built.append((true, actor, resolution, [r, g, b]))
    }
    func deleteActor(_ actor: Int) {}
    func BdeleteActor(_ actor: Int) {}
}

final class Controller {
    var srView: View? = View()
    var firstSurface: Float = 300, secondSurface: Float = -500
    var resolution: Float = 0.5
    var firstTransparency: Float = 1, secondTransparency: Float = 1
    var decimate: Float = 0.5
    var smooth: Int32 = 20
    var firstColor: NSColor?, secondColor: NSColor?
    var shouldDecimate = true, shouldSmooth = true, useFirstSurface = true, useSecondSurface = true

METHODS
}

let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in true })
let colours: [(String, NSColor?)] = [
    ("none", nil),
    ("calibrated-RGB", NSColor(calibratedRed: 1, green: 0.592, blue: 0.608, alpha: 1)),
    ("calibrated-grey", NSColor(calibratedWhite: 0.5, alpha: 1)),
    ("generic-grey", NSColor(genericGamma22White: 0.25, alpha: 1)),
    ("CMYK", NSColor(deviceCyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0, alpha: 1)),
    ("named", NSColor.systemPink),
    ("pattern", pattern),
]
let only = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
for resolution: Float in [0, -1, .nan, 3, 0.1, 0.5, 1] {
    for (name, colour) in colours where only == nil || only == name {
        for fusion in [false, true] {
            let controller = Controller()
            controller.resolution = resolution
            controller.firstColor = colour
            controller.secondColor = colour
            if fusion { controller.renderFusionSurfaces() } else { controller.renderSurfaces() }
            for surface in controller.srView!.built {
                print("\(fusion ? "fusion" : "main") \(resolution) \(name) \(surface.actor) \(surface.resolution) "
                      + surface.rgb.map { String($0) }.joined(separator: " "))
            }
        }
    }
}
print("done")
'''


def build(controller_text, folder, label):
    methods = '\n'.join(method(controller_text, signature)
                        for signature in (MARKER, 'func renderSurfaces()', 'func renderFusionSurfaces()')
                        if signature in controller_text)
    source = folder / ('%s.swift' % label)
    source.write_text(HARNESS.replace('METHODS', methods))
    flags = isix_modules.module_flags('IsiXVolumeRendering', folder / 'modules')
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(source), *flags, '-o', str(folder / label)],
                           capture_output=True, text=True, timeout=600)
    if built.returncode:
        print('FAIL: the %s methods do not compile in the stand-in:\n%s' % (label, built.stderr[-4000:]))
        raise SystemExit(1)
    return folder / label


with tempfile.TemporaryDirectory(prefix='isix-sr-settings-') as name:
    folder = Path(name)
    current = build((ROOT / CONTROLLER).read_text(encoding='utf-8'), folder, 'current')
    run = subprocess.run([str(current)], capture_output=True, text=True, timeout=60)
    check(run.returncode == 0 and run.stdout.rstrip().endswith('done'),
          'every resolution and colour is rendered without an exception (exit %d)' % run.returncode)
    rows = [line.split() for line in run.stdout.splitlines() if line != 'done']
    check(len(rows) == 7 * 7 * 2 * 2, '%d surfaces asked for' % len(rows))
    resolutions = {(row[1], float(row[4])) for row in rows}
    expected = {'0.0': 0.1, '-1.0': 0.1, 'nan': 0.5, '3.0': 1.0, '0.1': 0.1, '0.5': 0.5, '1.0': 1.0}
    check(all(abs(value - expected[asked]) < 1e-6 for asked, value in resolutions),
          'the resolution reaches the view between 0.1 and 1: %s' % sorted(resolutions))
    rgb = {}
    for row in rows:
        values = tuple(round(float(v), 4) for v in row[5:8])
        rgb.setdefault((row[0], row[2]), set()).add(values)
    check(all(len(v) == 1 and all(0 <= c <= 1 for c in next(iter(v))) for v in rgb.values()),
          'each colour reaches the view as one RGB between 0 and 1')
    check(all(rgb[('main', name)] == rgb[('fusion', name)] for name in ('none', 'calibrated-RGB', 'calibrated-grey',
                                                                           'generic-grey', 'CMYK', 'named', 'pattern')),
          'the fused surfaces get the colour the surfaces get')
    check(rgb[('main', 'none')] == {(0.0, 0.0, 0.0)} and rgb[('main', 'pattern')] == {(0.0, 0.0, 0.0)}
          and rgb[('main', 'calibrated-grey')] == {(0.5, 0.5, 0.5)}
          and rgb[('main', 'calibrated-RGB')] == {(1.0, 0.592, 0.608)},
          'no colour or a pattern is black, a grey its grey, a calibrated RGB its own components')

    # The revision before the fix, compiled the same way.
    reference = history_reference.before_text_added(CONTROLLER, MARKER)
    if reference is None and MARKER not in history_reference.show('HEAD', CONTROLLER).decode('utf-8'):
        reference = 'HEAD'
    if reference is None:
        print('note: the history does not reach the revision before the fix; not compared')
    else:
        former = build(history_reference.show(reference, CONTROLLER).decode('utf-8'), folder, 'former')
        zero = subprocess.run([str(former), 'calibrated-RGB'], capture_output=True, text=True, timeout=60)
        check(any(line.startswith('main 0.0 calibrated-RGB 0 0.0 ') for line in zero.stdout.splitlines()),
              'before the fix (%s) a resolution of 0 reached the view' % reference[:9])
        grey = subprocess.run([str(former), 'calibrated-grey'], capture_output=True, text=True, timeout=60)
        check(grey.returncode != 0 and 'need to first convert colorspace' in grey.stderr,
              'and the fused surfaces ended on the exception for a grey colour')

if failures:
    print('%d failure(s)' % len(failures))
    raise SystemExit(1)
print('PASS: the surface settings reach VTK with a resolution between 0.1 and 1 and an RGB colour')
