#!/usr/bin/env python3
"""The surface view's 3D points and their annotations take any colour the colour well gives.

The point panel of the surface window has two colour wells: the colour of the
3D points and the colour of their annotations (3D text). A colour well gives
whatever the colour panel picked, grey (the grey slider), CMYK and named
(catalog) colours included, and NSColor raises an exception ("need to first
convert colorspace") when asked for the red, green or blue of a colour that is
not RGB. Three places in SRView+Points.swift asked the colour as it was:
-IBSetSelected3DPointColor: (through -set3DPointAtIndex:Color:),
-IBSetSelected3DPointAnnotationColor: and the annotation text built by
setAnnotation(_:for3DPointAt:).

They now read the colour through SRController.surfaceRGB, the conversion the
surfaces use: generic RGB, black for a colour that does not convert. The
methods are compiled here from SRView+Points.swift and SRController.swift, as
they are, into a stand-in view whose VTK actors record the colour they get.
Every colour, for the selected point and for all points, reaches the actors
without an exception, as the RGB the surfaces get for it. The same methods of
the revision before the fix, compiled the same way, end on the exception for a
grey and a CMYK colour on each of the three paths.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
POINTS = 'Horos/Sources/SRView+Points.swift'
CONTROLLER = 'Horos/Sources/SRController.swift'
MARKER = 'SRController.surfaceRGB('

failures = []


def check(condition, what):
    print('%s: %s' % ('PASS' if condition else 'FAIL', what))
    if not condition:
        failures.append(what)


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
            return re.sub(r'@(IBAction|objc(\([^)]*\))?)\s*', '', body)
    raise LookupError(signature)


SIGNATURES = (
    'private var propagatesToAll',
    'func ibSetSelected3DPointColor(',
    'func setSelected3DPointColor(',
    'func setAll3DPointsColor(',
    'func set3DPoint(at index: UInt32, color: NSColor)',
    'func setAnnotation(_ annotation: String, for3DPointAt index: Int)',
    'func ibSetSelected3DPointAnnotationColor(',
)

HARNESS = r'''
import AppKit

struct IsiXVTKPoint { var x: Double, y: Double, z: Double }

final class IsiXVTKActor {
    var rgb: [Double] = []
    var position = IsiXVTKPoint(x: 0, y: 0, z: 0)
    static func follower(text: String) throws -> IsiXVTKActor { IsiXVTKActor() }
    func setColor(red: Double, green: Double, blue: Double) { rgb = [red, green, blue] }
    func setUniformScale(_ scale: Double) {}
}

final class Scene { func removeActor(_ actor: IsiXVTKActor) {} }

enum SRController {
SURFACE
}

final class View {
    var point3DActors = [IsiXVTKActor(), IsiXVTKActor(), IsiXVTKActor()]
    var point3DColors = [NSColor](repeating: .red, count: 3)
    var point3DTexts = [IsiXVTKActor(), IsiXVTKActor(), IsiXVTKActor()]
    var point3DTextColors = [NSColor](repeating: .white, count: 3)
    var point3DRadius: [Float] = [1, 1, 1]
    var point3DPositions = [IsiXVTKPoint](repeating: IsiXVTKPoint(x: 1, y: 2, z: 3), count: 3)
    var point3DTextSizes: [Float] = [4, 4, 4]
    var point3DPropagateToAll: NSButton? = NSButton()
    var point3DRadiusSlider: NSSlider? = nil
    var needsDisplay = false
    let scene = Scene()
    func isAny3DPointSelected() -> Bool { true }
    func selected3DPointIndex() -> UInt32 { 1 }
    func setAll3DPointsRadius(_ radius: Float) {}

METHODS
}

let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2), flipped: false) { _ in true })
let colours: [(String, NSColor)] = [
    ("calibrated-RGB", NSColor(calibratedRed: 1, green: 0.592, blue: 0.608, alpha: 1)),
    ("calibrated-grey", NSColor(calibratedWhite: 0.5, alpha: 1)),
    ("generic-grey", NSColor(genericGamma22White: 0.25, alpha: 1)),
    ("CMYK", NSColor(deviceCyan: 0.1, magenta: 0.2, yellow: 0.3, black: 0, alpha: 1)),
    ("named", NSColor.systemPink),
    ("pattern", pattern),
]
let paths = ["point", "annotation", "text"]
let onlyPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let onlyColour = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil
func show(_ values: [Double]) -> String { values.map { String(format: "%.4f", $0) }.joined(separator: " ") }
for path in paths where onlyPath == nil || onlyPath == path {
    for (name, colour) in colours where onlyColour == nil || onlyColour == name {
        for all in [false, true] {
            let view = View()
            view.point3DPropagateToAll?.state = all ? .on : .off
            let well = NSColorWell()
            well.color = colour
            switch path {
            case "point":
                view.ibSetSelected3DPointColor(well)
            case "annotation":
                view.ibSetSelected3DPointAnnotationColor(well)
            default:
                view.point3DTextColors[1] = colour
                view.setAnnotation("x: 1 mm", for3DPointAt: 1)
            }
            let actors = path == "point" ? view.point3DActors : view.point3DTexts
            let surface = SRController.surfaceRGB(colour)
            let expected = show([Double(surface.red), Double(surface.green), Double(surface.blue)])
            for (index, actor) in actors.enumerated() {
                print("\(path) \(name) \(all ? "all" : "selected") \(index) [\(show(actor.rgb))] [\(expected)]")
            }
        }
    }
}
print("done")
'''


def build(points_text, controller_text, folder, label):
    methods = '\n'.join(method(points_text, signature) for signature in SIGNATURES)
    surface = method(controller_text, 'static func surfaceRGB')
    source = folder / ('%s.swift' % label)
    source.write_text(HARNESS.replace('METHODS', methods).replace('SURFACE', surface))
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(source), '-o', str(folder / label)],
                           capture_output=True, text=True, timeout=600)
    if built.returncode:
        print('FAIL: the %s methods do not compile in the stand-in:\n%s' % (label, built.stderr[-4000:]))
        raise SystemExit(1)
    return folder / label


controller = (ROOT / CONTROLLER).read_text(encoding='utf-8')
with tempfile.TemporaryDirectory(prefix='isix-sr-points-') as name:
    folder = Path(name)
    current = build((ROOT / POINTS).read_text(encoding='utf-8'), controller, folder, 'current')
    run = subprocess.run([str(current)], capture_output=True, text=True, timeout=60)
    check(run.returncode == 0 and run.stdout.rstrip().endswith('done'),
          'every colour is applied on the three paths without an exception (exit %d)' % run.returncode)
    rows = [re.match(r'(\S+) (\S+) (\S+) (\d) \[(.*)\] \[(.*)\]$', line).groups()
            for line in run.stdout.splitlines() if line != 'done']
    check(len(rows) == 3 * 6 * 2 * 3, '%d actors recorded' % len(rows))
    # The selected point (index 1) always gets the colour; the others only when the change goes to all
    # points, except the annotation text, built for one point.
    for path, colour, scope, index, got, expected in rows:
        changed = index == '1' or (scope == 'all' and path != 'text')
        if changed:
            check(got == expected, '%s %s (%s) point %s gets the RGB the surfaces get: %s' % (path, colour, scope, index, got))
        else:
            check(got == '', '%s %s (%s) point %s is left alone' % (path, colour, scope, index))
    by_colour = {colour: expected for _, colour, _, _, _, expected in rows}
    check(by_colour.get('pattern') == '0.0000 0.0000 0.0000', 'a colour that does not convert is black')
    check(by_colour.get('calibrated-grey') == '0.5000 0.5000 0.5000', 'a grey is its grey')

    # The revision before the fix, compiled the same way.
    reference = history_reference.before_text_added(POINTS, MARKER)
    if reference is None and MARKER not in history_reference.show('HEAD', POINTS).decode('utf-8'):
        reference = 'HEAD'
    if reference is None:
        print('note: the history does not reach the revision before the fix; not compared')
    else:
        former = build(history_reference.show(reference, POINTS).decode('utf-8'), controller, folder, 'former')
        for path in ('point', 'annotation', 'text'):
            for colour in ('calibrated-grey', 'CMYK'):
                old = subprocess.run([str(former), path, colour], capture_output=True, text=True, timeout=60)
                check(old.returncode != 0 and 'need to first convert colorspace' in old.stderr,
                      'before the fix (%s) the %s colour ended on the exception for %s' % (reference[:9], path, colour))

if failures:
    print('%d failure(s)' % len(failures))
    raise SystemExit(1)
print('PASS: the 3D points and their annotations take grey, CMYK, named and pattern colours')
