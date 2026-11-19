#!/usr/bin/env python3
"""Vessel Analysis and the Curved MPR's Path Assistant off the main thread.

The 2D viewer's 8th reconstruction, Vessel Analysis, is the curved MPR's
action (cprViewer:) with tag 11, as MIP is volume rendering's with tag 3: it
opens the series' Curved MPR, or turns the one open to it, with the Curved
Path tool, and the Path Assistant runs between the two points as soon as the
second one is marked. The Curved MPR opened as always does not run it on its
own. The Path Assistant (the window's button and Vessel Analysis alike) runs
the vessel tracer off the main thread, with a sheet that shows its progress
and cancels it; the former fly-through assistant traces an air-filled lumen
only, built when such a segment comes and not when the window opens.

CurvedMPRVesselTrace.swift is compiled with CurvedMPRPath.swift, the module
IsiXVolumeRendering and Nitrogen's N3 geometry, and run from the main actor:
- the trace of a vessel ends with its segment's nodes in patient space, from
  the first point to the second, and the main actor runs while it traces;
- a cancel, at once or half way, gives no path, and a trace started after
  it gives its own;
- a trace of a path edited meanwhile is given up, with no path and no
  notice, and the window may trace the new points; one that ends while an
  edit is open (a node pressed) waits for the edit's end, and is given then,
  or given up if the edit moved a node;
- an airway is traced by the former assistant;
- the volume is the data object's floats, refused when it holds fewer than
  the voxels;
- the notice: a stretch out of the lumen over 2 mm, a faint lumen, a segment
  without a path, memory short; nothing for a clean path.
CPRController.swift and ThreeDViewerLauncher.swift are read for the wiring:
the tag opens or turns the window to Vessel Analysis once the openings have
brought back the saved path, which it clears as an edit Cmd-Z undoes, with
the Curved Path tool; the usual command turns it back, each with its title;
an edit of the path gives a path held for it, or asks VesselAnalysisTrigger
and runs the assistant; the assistant starts the trace with what tells an
edited or open path, assembles the path and tells the stenosis tool; closing
the window cancels it and keeps the saved path when Vessel Analysis marked
none; no FlyAssistant is built at the window's opening. The sheet waits for
another the window shows, and a trace started after a cancel waits for it.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  (swiftc leaves folders in TMPDIR)
import isix_modules  # noqa: E402
import n3_geometry_harness  # noqa: E402

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', revision + ':' + path],
                                           stderr=subprocess.DEVNULL).decode('utf-8')
        except subprocess.CalledProcessError:
            return ''
    full = root / path
    return full.read_text(encoding='utf-8') if full.exists() else ''


def code(text):
    """Without comments, so that what they recall is not taken for a call."""
    text = '\n'.join(line.split('//')[0] for line in text.split('\n'))
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


def block(text, signature):
    at = text.find(signature)
    if at < 0:
        return ''
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening:index + 1]
    return ''


def check(condition, message):
    if not condition:
        failures.append(message)


STUBS = r'''
import Foundation

/// The CPRVolumeData the trace reads its shape from.
open class CPRVolumeData: NSObject {
    let size: (UInt, UInt, UInt), spacing: (CGFloat, CGFloat, CGFloat)
    init(size: (UInt, UInt, UInt), spacing: (CGFloat, CGFloat, CGFloat)) { self.size = size; self.spacing = spacing }
    @objc public var pixelsWide: UInt { size.0 }
    @objc public var pixelsHigh: UInt { size.1 }
    @objc public var pixelsDeep: UInt { size.2 }
    @objc public var pixelSpacingX: CGFloat { spacing.0 }
    @objc public var pixelSpacingY: CGFloat { spacing.1 }
    @objc public var pixelSpacingZ: CGFloat { spacing.2 }
}
'''

DRIVER = r'''
import AppKit
import IsiXVolumeRendering

var failures: [String] = []
@MainActor func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

/// Runs the main run loop, which serves the main actor, until `done` or the deadline.
@MainActor func spin(seconds: Double, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}

// A vessel of 1.5 mm of radius (400 HU) along z in fat (-80 HU), 0.5 mm
// voxels, with noise of +-20 HU; and an airway (-1000 HU) in soft tissue.
let (w, h, d) = (40, 40, 80)
var noise: UInt64 = 1
@MainActor func next() -> Float { noise = noise &* 6364136223846793005 &+ 1442695040888963407; return Float(noise >> 40) / Float(1 << 24) * 40 - 20 }
var vessel = [Float](repeating: 0, count: w * h * d), airway = vessel
for z in 0..<d { for y in 0..<h { for x in 0..<w {
    let r = ((Float(x) - 20) * (Float(x) - 20) + (Float(y) - 20) * (Float(y) - 20)).squareRoot() * 0.5
    vessel[(z * h + y) * w + x] = (r <= 1.5 ? 400 : -80) + next()
    airway[(z * h + y) * w + x] = r <= 2.5 ? -1000 : 40
} } }
@MainActor func volume(_ voxels: [Float]) -> VesselVolume {
    VesselVolume(copying: voxels, width: w, height: h, depth: d, spacing: SIMD3(repeating: 0.5))
}
// Patient space: a voxel at (i, j, k) lies at (i, j, k) * 0.5 + (10, -5, 3).
let patientToVolume = N3AffineTransformConcat(N3AffineTransformMakeTranslation(-10, 5, -3), N3AffineTransformMakeScale(2, 2, 2))
func patient(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> N3Vector { N3VectorMake(x * 0.5 + 10, y * 0.5 - 5, z * 0.5 + 3) }
let a = patient(20, 20, 10), b = patient(20, 20, 70)

// The trace of the vessel, from the main actor.
let trace = CurvedMPRVesselTrace()
var outcome: CurvedMPRVesselTrace.Outcome?
var ticked = false, tickedFirst = false
trace.start(nodes: [a, b], in: volume(vessel), patientToVolume: patientToVolume, window: nil) { result in
    outcome = result
    tickedFirst = ticked
}
check(trace.isRunning, "a trace is under way once started")
Task { @MainActor in ticked = true }
spin(seconds: 120) { outcome != nil }
check(outcome != nil, "the trace of the vessel gave no path")
check(tickedFirst, "the main actor did not run while the vessel was traced")
check(!trace.isRunning, "the trace is still under way after its path")
if let nodes = outcome?.segments.first ?? nil {
    check(N3VectorDistance(nodes.first!, a) < 0.01 && N3VectorDistance(nodes.last!, b) < 0.01,
          "the segment runs from \(nodes.first!) to \(nodes.last!), not from the first point to the second")
    check(nodes.allSatisfy { abs($0.x - 20) < 0.6 && abs($0.y - 5) < 0.6 }, "the segment leaves the vessel's axis")
    check(outcome?.lastSegment.count == nodes.count, "the last segment's nodes are not the centerline kept")
} else {
    check(false, "the vessel's segment has no nodes")
}

// Cancelled at once, then half way through a path of many segments: no path.
var cancelled = 0
trace.start(nodes: [a, b], in: volume(vessel), patientToVolume: patientToVolume, window: nil) { _ in cancelled += 1 }
trace.cancel()
check(!trace.isRunning, "a cancelled trace is still under way")
let many = (0..<24).map { $0 % 2 == 0 ? a : b }
trace.start(nodes: many, in: volume(vessel), patientToVolume: patientToVolume, window: nil) { _ in cancelled += 1 }
spin(seconds: 0.05)
trace.cancel()
var after: CurvedMPRVesselTrace.Outcome?
trace.start(nodes: [b, a], in: volume(vessel), patientToVolume: patientToVolume, window: nil) { after = $0 }
spin(seconds: 120) { after != nil }
spin(seconds: 0.5)
check(cancelled == 0, "a cancelled trace gave its path \(cancelled) times")
check(after != nil, "the trace started after a cancel gave no path")

// A path edited meanwhile: given up, with no path, and the window may trace its new points.
var givenUp = 0, applied = 0
trace.start(nodes: [a, b], in: volume(vessel), patientToVolume: patientToVolume, window: nil,
            delivery: .init(isCurrent: { false }, givenUp: { givenUp += 1 })) { _ in applied += 1 }
spin(seconds: 120) { givenUp > 0 }
check(givenUp == 1 && applied == 0, "a trace of a path edited meanwhile gave its path \(applied) times, given up \(givenUp) times")

// A node pressed as the trace ends: the path waits for the edit's end.
var editing = true, current = true
var held: CurvedMPRVesselTrace.Outcome?
let pressed = CurvedMPRVesselTrace.Delivery(isCurrent: { current }, isEditing: { editing }, givenUp: { givenUp += 1 })
trace.start(nodes: [a, b], in: volume(vessel), patientToVolume: patientToVolume, window: nil, delivery: pressed) { held = $0 }
spin(seconds: 120) { !trace.isRunning }
spin(seconds: 0.2)
check(held == nil, "the path was given while an edit was open")
check(trace.editEnded() && held == nil, "a path held for an edit is given while the edit is still open")
editing = false
check(trace.editEnded() && held != nil, "the path held for an edit is not given as the edit ends")
check(!trace.editEnded(), "the end of an edit gives the held path twice")
held = nil
editing = true
trace.start(nodes: [a, b], in: volume(vessel), patientToVolume: patientToVolume, window: nil, delivery: pressed) { held = $0 }
spin(seconds: 120) { !trace.isRunning }
spin(seconds: 0.2)
(current, editing) = (false, false)
let givenUpBefore = givenUp
check(trace.editEnded() && held == nil && givenUp == givenUpBefore + 1, "the path held for an edit that moved a node is not given up")

// An airway: the former assistant.
var air: CurvedMPRVesselTrace.Outcome?
trace.start(nodes: [patient(20, 20, 10), patient(20, 20, 70)], in: volume(airway), patientToVolume: patientToVolume, window: nil) { air = $0 }
spin(seconds: 120) { air != nil }
check(air.map { result in result.assisted.segments.allSatisfy { if case .formerAssistant = $0 { true } else { false } } } == true,
      "the airway was not traced by the former assistant: \(String(describing: air?.assisted.segments.first))")
check((air?.segments.first ?? nil)?.isEmpty == false, "the airway's segment has no nodes")

// The volume: the data object's floats, without a copy.
let shape = CPRVolumeData(size: (UInt(w), UInt(h), UInt(d)), spacing: (0.5, 0.5, 0.5))
let data = vessel.withUnsafeBytes { NSData(bytes: $0.baseAddress!, length: $0.count) }
let borrowed = CurvedMPRVesselTrace.volume(of: data, shapedAs: shape)
check(borrowed?.width == w && borrowed?.depth == d && borrowed?.spacing == SIMD3(repeating: 0.5), "the volume does not take the data's shape")
check(CurvedMPRVesselTrace.volume(of: NSData(bytes: [Float](repeating: 0, count: 10), length: 40), shapedAs: shape) == nil,
      "a data object shorter than the volume is taken")

// The notice.
@MainActor func traced(gap: Float, faint: Bool) -> VesselPathSegment { .traced(nodes: [SIMD3(0, 0, 0), SIMD3(1, 1, 1)], longestGap: gap, isLumenFaint: faint) }
check(CurvedMPRVesselTrace.notice(for: VesselAssistedPath(segments: [traced(gap: 1.5, faint: false)])) == nil, "a clean path is noticed")
let gap = CurvedMPRVesselTrace.notice(for: VesselAssistedPath(segments: [traced(gap: 9.84, faint: false)]))
check(gap?.title == "Check the traced path" && gap?.message.contains(String.localizedStringWithFormat("%.1f mm", 9.84)) == true,
      "an occlusion of 9.8 mm is noticed as \(String(describing: gap))")
let faint = CurvedMPRVesselTrace.notice(for: VesselAssistedPath(segments: [traced(gap: 0, faint: true)]))
check(faint?.message.contains("hardly stands out") == true, "a faint lumen is noticed as \(String(describing: faint))")
let lost = CurvedMPRVesselTrace.notice(for: VesselAssistedPath(segments: [.failed(.refused(.samePoint)), traced(gap: 0, faint: false)]))
check(lost?.title == "Can't find path" && lost?.message == "Path Assistant can not find a path from A to B.",
      "a segment without a path is noticed as \(String(describing: lost))")
let memory = CurvedMPRVesselTrace.notice(for: VesselAssistedPath(segments: [.failed(.outOfMemory)]))
check(memory?.title == "Not enough memory", "memory short is noticed as \(String(describing: memory))")

print(failures.joined(separator: "\n"))
'''

sources = {name: read('Horos/Sources/' + name) for name in ('CurvedMPRVesselTrace.swift', 'CurvedMPRPath.swift')}
if not sources['CurvedMPRVesselTrace.swift']:
    failures.append('no Horos/Sources/CurvedMPRVesselTrace.swift: the Path Assistant runs on the main thread')
elif shutil.which('xcrun') is None:
    print('skipped the trace run: needs xcrun (swiftc)', file=sys.stderr)
else:
    with tempfile.TemporaryDirectory(prefix='horos-vessel-analysis-') as tmp:
        tmp = Path(tmp)
        for name, text in sources.items():
            (tmp / name).write_text(text)
        (tmp / 'Stubs.swift').write_text(STUBS)
        (tmp / 'main.swift').write_text(DRIVER)
        target = ['-target', 'arm64-apple-macos15.0']
        try:
            n3_include, _ = n3_geometry_harness.build(tmp / 'n3', 'debug')
            (tmp / 'bridge.h').write_text('#import <Cocoa/Cocoa.h>\n#import "N3Geometry.h"\n')
            modules = isix_modules.module_flags('IsiXVolumeRendering', tmp / 'modules', target)
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos', '-Onone', *target,
                            '-import-objc-header', str(tmp / 'bridge.h'), *[f for flag in n3_include for f in ('-Xcc', flag)],
                            *modules, *map(str, [tmp / name for name in sources]), str(tmp / 'Stubs.swift'), str(tmp / 'main.swift'),
                            *n3_geometry_harness.libraries(tmp / 'n3'), '-framework', 'Cocoa', '-framework', 'QuartzCore',
                            '-framework', 'Accelerate', '-o', str(tmp / 'driver')],
                           check=True, capture_output=True, text=True, timeout=900)
        except (subprocess.CalledProcessError, RuntimeError) as error:
            failures.append('the trace driver did not build: ' + (getattr(error, 'stderr', None) or str(error))[-2500:])
        else:
            result = subprocess.run([str(tmp / 'driver')], capture_output=True, text=True, timeout=900)
            if result.returncode != 0:
                failures.append('the trace driver failed: ' + (result.stderr or result.stdout)[-1500:])
            failures += [line for line in result.stdout.split('\n') if line.strip()]

controller = code(read('Horos/Sources/CPRController.swift'))
launcher = code(read('Horos/Sources/ThreeDViewerLauncher.swift'))
assistant = code(read('Modules/IsiXVolumeRendering/Sources/VesselPathAssistant.swift'))
check(bool(controller) and bool(launcher), 'no CPRController.swift or ThreeDViewerLauncher.swift')

opened = block(launcher, 'func openCurvedMPR(')
check('asksForVesselAnalysis(sender)' in opened and opened.count('beginVesselAnalysis()') == 2
      and 'endVesselAnalysis()' in opened and 'isInVesselAnalysis != vesselAnalysis' in opened,
      'the 2D viewer does not open the Curved MPR in Vessel Analysis, turn the one open to it, or turn it back')
check(opened.count('retitle(') == 2 and 'curvedMPRTitle(vesselAnalysis:' in opened,
      'the window turned to or from Vessel Analysis keeps the title of the other mode')
check(opened.rfind('made?.beginVesselAnalysis()') > opened.rfind('made?.showWindow(owner)'),
      'Vessel Analysis begins before the openings bring back the saved path, which two new points then extend')
check('ViewerToolbarCatalog.vesselAnalysisTag' in block(launcher, 'func asksForVesselAnalysis('),
      'Vessel Analysis is not told by its tag')

begin = block(controller, 'func beginVesselAnalysis(')
check('VesselAnalysisTrigger()' in begin and 'curvedPathCreationMode = true' in begin,
      'Vessel Analysis does not select the Curved Path tool and trace on its own')
check('cprViewWillEditCurvedPath(' in begin and 'clearPath()' in begin and 'cprViewDidEditCurvedPath(' in begin,
      'Vessel Analysis does not start from two new points, the path shown one Cmd-Z away')
edited = block(controller, 'func cprViewDidEditCurvedPath(')
asks = block(controller, 'func traceIfVesselAnalysisAsks(')
check('self.traceIfVesselAnalysisAsks()' in edited and 'vesselAnalysis?.shouldTrace(nodes:' in asks
      and 'self.assistedCurvedPath(nil)' in asks, 'the second point marked does not run the Path Assistant')
check('vesselTrace.editEnded()' in asks, 'the end of an edit does not give the path held for it')
assisted = block(controller, 'func assistedCurvedPath(')
check('vesselTrace.start(' in assisted and 'CurvedMPRPathAssistant.assembledPath(' in assisted
      and 'sameNodes(' in assisted, 'the Path Assistant does not trace off the main thread, or replaces a path edited meanwhile')
check('isEditing:' in assisted and 'delegateCurveViewDebugging()' in assisted and 'givenUp:' in assisted
      and 'traceIfVesselAnalysisAsks()' in assisted,
      'the traced path lands in a view whose node is pressed, or a trace given up for new points does not trace them')
check('stenosisTool?.curvedPathDidChange()' in assisted, 'the stenosis tool is not told of the traced path')
check('createCenterline' not in controller and re.search(r'\bFlyAssistant\(', controller) is None,
      'the window still builds the former assistant or traces with it on the main thread')
closing = block(controller, 'func windowWillClose(')
check('vesselTrace.cancel()' in closing, 'closing the window does not cancel the trace')
check('vesselAnalysis == nil ||' in closing, 'Vessel Analysis closed before a path is marked replaces the saved path with none')
traced = code(sources['CurvedMPRVesselTrace.swift'])
check('await previous?.value' in traced and 'cancelledTask = task' in traced,
      'a trace started after a cancel does not wait for the cancelled one, whose distance map may still be kept')
check('window.attachedSheet == nil' in traced, 'the progress sheet queues behind another sheet of the window')
dark = assistant[assistant.find('case .failure(.darkLumen):'):]
dark = dark[:dark.find('case .failure(let error)')]
check('formerAssistant(over:' in dark and assistant.count('formerAssistant(over:') == 1,
      'the former assistant is built for another segment than an air-filled one')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: Vessel Analysis opens the Curved MPR with the Curved Path tool and traces on the second point, '
      'off the main thread and cancellable, with the former assistant for an airway only')
