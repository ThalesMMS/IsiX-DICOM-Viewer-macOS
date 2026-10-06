#!/usr/bin/env python3
"""The Path Assistant's simplification slider simplifies the path on mouse up
and rebuilds it once per move, not once per node.

With a centerline of about 200 nodes, moving the slider held the main thread
for 29 s (100 to 80 %) and 70 s (0 to 100 %): the slider sent its action at
each value it went through, and each node it removed or restored rebuilt the
CPRCurvedPath from its nodes, measuring the path up to every node, and showed
it in the seven views. CPRCurvedPath.withPathRebuiltOnce(_:) lets the steps
change the nodes only and rebuilds the path once at the end.

CPRCurvedPath is compiled as it is, with Nitrogen's N3BezierPath and
HorosObjCException, and driven by the steps of -[CPRController removeNode]
and -undoLastNodeRemoval (cheapest node out, last removal back) on a path of
200 nodes, once rebuilding at each step as before and once inside
withPathRebuiltOnce(_:):
- the path is not rebuilt inside the block;
- after it, the nodes, the Bezier path, the nodes' relative positions and the
  transverse sections are those of the step-by-step path, for 200 to 160
  nodes, back to 200 and down to 3;
- an exception raised inside the block goes on, with the path rebuilt from
  the nodes left, and the next edit rebuilds at once.
The time of each way is printed, for information; nothing is asserted on it.

-costFunction:, the steps without the views (-removeCheapestNode and
-restoreLastRemovedNode) are then taken from CPRController.swift as they are
and run on CPRCurvedPath, keeping one cost per node, each the cost of its node:
- a removed node that is on the last node when it comes back is refused by
  -insertPatientNode:atIndex:, and its cost does not come back either, down to
  3 nodes and back;
- a removed node that comes back past the end of a path edited since (nodes
  deleted, costs recomputed) is appended, and its cost with it;
- the removals older than a refused node come back where they were, in order,
  not one node further, past the last node.

-restartSimplificationIfNodesChanged(since:) and -updateCurvedPathCost, which
-setCurvedPath: runs with the nodes it replaces, are taken from
CPRController.swift as they are too: after the slider has removed nodes,
a node inserted, added, deleted or moved by hand, as the views do, leaves one
cost per node, each its node's, no removal to undo and the slider at its
maximum, and the slider then goes down to 3 nodes and back without raising;
a change that leaves the nodes as they were (the transverse section) keeps
the history, and the slider brings back the path it had.

-forgetCenterlineIfNodesChange(to:) and -onSliderEnabled are taken from
CPRController.swift as they are too, and run as -CPRViewDidUpdateCurvedPath:
runs them before -setCurvedPath:, so that a node edited by hand leaves no
centerline and the slider disabled; the transverse section, its spacing or
the angle moved keep the centerline and the slider enabled, where any update
of the path disabled the slider.

CPRController.swift, CPRStretchedView.swift and CPR.xib are read for the rest:
- -setCurvedPath: hands the nodes it replaces to
  -restartSimplificationIfNodesChanged(since:);
- -CPRViewDidUpdateCurvedPath: and -CPRViewDidEditCurvedPath: hand the view's
  path to -forgetCenterlineIfNodesChange(to:) before -setCurvedPath:, and
  clear the centerline nowhere else;
- the stretched view's mouse up ends the edit before it asks for the costs,
  and a node deleted during a drag is sent as an update at once, before the
  costs, not left for the mouse up;
- -onSliderMove: runs the simplification inside withPathRebuiltOnce(_:) with
  the steps that do not show the path, and shows it once;
- the slider sends its action on mouse up, not at each value it goes through;
- the window is titled "Curved MPR", not "MPR" as the MPR window.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  (swiftc leaves folders in TMPDIR)
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def source(path):
    if revision:
        try:
            return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'],
                                           stderr=subprocess.DEVNULL)
        except subprocess.CalledProcessError:
            return b''
    full = root / path
    return full.read_bytes() if full.exists() else b''


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


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(SKIPPED)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


# CPRCurvedPath makes the transverse sections' requests (CPRGeneratorRequest.swift).
# CurvedMPRPath.swift has the cheapest node of -removeCheapestNode.
SWIFT_SOURCES = [
    'Horos/Sources/CPRCurvedPath.swift',
    'Horos/Sources/CPRGeneratorRequest.swift',
    'Horos/Sources/CurvedMPRPath.swift',
]
HEADERS = [
    'Horos/Sources/CPRCurvedPath.h',
    'Horos/Sources/CPRVolumeData.h',
    'Horos/Sources/CPRProjectionOperation.h',
    'Horos/Sources/HorosObjCException.h',
    'Nitrogen/Sources/N3Geometry.h',
    'Nitrogen/Sources/N3BezierCore.h',
    'Nitrogen/Sources/N3BezierCoreAdditions.h',
    'Nitrogen/Sources/N3BezierPath.h',
]
# (source, extra clang flags): Nitrogen is manual retain/release, as in the app.
OBJC_SOURCES = [
    ('Nitrogen/Sources/N3Geometry.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierCore.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierCoreAdditions.m', ['-fno-objc-arc']),
    ('Nitrogen/Sources/N3BezierPath.m', ['-fno-objc-arc']),
    ('Horos/Sources/HorosObjCException.m', ['-fobjc-exceptions']),
    ('Horos/Sources/CPRCurvedPath+CAPI.m', ['-DHOROS_BRIDGING_HEADER=1']),
]

BRIDGING = r'''
#define HOROS_BRIDGING_HEADER 1
#import <Cocoa/Cocoa.h>
#import "HorosObjCException.h"
#import "N3Geometry.h"
#import "N3BezierPath.h"
#import "CPRVolumeData.h"
#import "CPRProjectionOperation.h"
#import "CPRCurvedPath.h"
'''

# The requests name their operation classes; no operation runs here.
OPERATION_STUBS = r'''
import Foundation
final class CPRStraightenedOperation: NSObject {}
final class CPRStretchedOperation: NSObject {}
final class CPRObliqueSliceOperation: NSObject {}
'''

DRIVER = r'''
import Cocoa

var wrong: [String] = []
func expect(_ ok: Bool, _ message: String) {
    if !ok { wrong.append(message) }
}

/// A centerline of `count` nodes about 0.5 mm apart, winding in 3D.
func makePath(_ count: Int) -> CPRCurvedPath {
    let path = CPRCurvedPath()
    for i in 0..<count {
        let t = CGFloat(i) * 0.05
        path.addPatientNode(N3VectorMake(30 * cos(t), 30 * sin(t), CGFloat(i) * 0.5 + 3 * sin(3 * t)))
    }
    return path
}

/// The steps of -[CPRController removeNode] and -undoLastNodeRemoval, on the
/// path alone: the cheapest node out, the last removal back.
final class Simplifier {
    let path: CPRCurvedPath
    var costs: [Float] = []
    var history: [Int] = []
    var removed: [N3Vector] = []

    init(_ path: CPRCurvedPath) {
        self.path = path
        costs = (0..<path.nodes.count).map { cost($0) }
    }

    func node(_ i: Int) -> N3Vector { return (path.nodes[i] as! NSValue).n3VectorValue() }

    func cost(_ i: Int) -> Float {
        if i == 0 || i == path.nodes.count - 1 { return Float.greatestFiniteMagnitude }
        let next = node(i + 1), cur = node(i), prev = node(i - 1)
        let toNext = (cur.x - next.x) * (cur.x - next.x) + (cur.y - next.y) * (cur.y - next.y) + (cur.z - next.z) * (cur.z - next.z)
        let toPrev = (cur.x - prev.x) * (cur.x - prev.x) + (cur.y - prev.y) * (cur.y - prev.y) + (cur.z - prev.z) * (cur.z - prev.z)
        return Float(toNext + toPrev)
    }

    func remove() {
        let count = costs.count
        guard count > 3 else { return }
        var index: Int? = nil
        var least = Float.greatestFiniteMagnitude
        for (i, value) in costs.enumerated() where least > value { index = i; least = value }
        guard let index else { return }
        let gone = node(index)
        path.removeNode(at: index)
        costs.remove(at: index)
        history.append(index)
        removed.append(gone)
        if index > 0 { costs[index - 1] = cost(index - 1) }
        if index < count - 1 { costs[index] = cost(index) }
    }

    func restore() {
        guard let index = history.popLast() else { return }
        path.insertPatientNode(removed.removeLast(), at: UInt(index))
        costs.insert(cost(index), at: index)
        if index > 0 { costs[index - 1] = cost(index - 1) }
        if index < costs.count - 1 { costs[index + 1] = cost(index + 1) }
    }

    func simplify(to target: Int) {
        while true {
            let count = path.nodes.count
            if count == target { return }
            if target < count { remove() } else { restore() }
            if path.nodes.count == count { return }
        }
    }
}

func same(_ a: CPRCurvedPath, _ b: CPRCurvedPath, _ what: String) {
    expect(a.nodes.isEqual(to: b.nodes as! [Any]), "\(what): the nodes differ")
    expect(a.bezierPath?.isEqual(to: b.bezierPath) ?? false, "\(what): the Bezier paths differ")
    expect(a.nodeRelativePositions?.isEqual(to: (b.nodeRelativePositions ?? []) as! [Any]) ?? false,
           "\(what): the nodes' relative positions differ")
    expect(a.hasSameTransverseSections(as: b), "\(what): the transverse sections differ")
}

func seconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
}

let original = makePath(200)
expect(original.nodes.count == 200, "the path has \(original.nodes.count) nodes, not 200")
let stepwise = Simplifier(original.copy() as! CPRCurvedPath)
let batched = Simplifier(original.copy() as! CPRCurvedPath)

var timings: [String] = []
for (target, what) in [(160, "200 to 160 nodes"), (200, "back to 200 nodes"), (3, "down to 3 nodes")] {
    let before = seconds { stepwise.simplify(to: target) }
    let bezierBefore = batched.path.bezierPath
    var rebuiltInside = false
    let after = seconds {
        batched.path.withPathRebuiltOnce {
            batched.simplify(to: target)
            rebuiltInside = batched.path.bezierPath !== bezierBefore
        }
    }
    expect(stepwise.path.nodes.count == target, "\(what): \(stepwise.path.nodes.count) nodes step by step")
    expect(!rebuiltInside, "\(what): the path was rebuilt inside withPathRebuiltOnce")
    expect(batched.path.bezierPath !== bezierBefore, "\(what): the path was not rebuilt after withPathRebuiltOnce")
    same(batched.path, stepwise.path, what)
    timings.append(String(format: "%@: %.3f s rebuilt at each step, %.3f s rebuilt once", what, before, after))
}

// An exception inside the block goes on, with the path rebuilt from the nodes left.
let raising = original.copy() as! CPRCurvedPath
let reference = original.copy() as! CPRCurvedPath
reference.removeNode(at: 1)
var caught: NSException? = nil
do {
    try HorosObjCException.perform {
        raising.withPathRebuiltOnce {
            raising.removeNode(at: 1)
            raising.removeNode(at: 10_000)
        }
    }
} catch {
    caught = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
}
expect(caught?.name == .rangeException, "the exception inside the block did not go on: \(String(describing: caught))")
same(raising, reference, "after an exception")
let bezierAfterException = raising.bezierPath
raising.removeNode(at: 1)
expect(raising.bezierPath !== bezierAfterException, "an edit after an exception is not rebuilt at once")

// The controller's own steps keep one cost per node, each its node's.
/// What -addObject: of CPRController.swift does.
private func addObject(_ array: NSMutableArray?, _ object: Any?) {
    _ = array?.perform(#selector(NSMutableArray.add(_:)), with: object)
}

/// What debugAssert of CPRController.swift does, built without DEBUG.
private func debugAssert(_ condition: @autoclosure () -> Bool) {}

/// The simplification slider, as the steps set it.
final class SliderStandIn {
    var doubleValue: Double = 40
    var maxValue: Double = 100
}

/// The controller's methods call their class by name.
typealias CPRController = ControllerSteps

/// The CPRController state the steps read, with its methods as they are.
final class ControllerSteps: NSObject {
    var _curvedPath: CPRCurvedPath?
    /// The Path Assistant's centerline, as it leaves it.
    var centerline: NSMutableArray? = NSMutableArray(array: [1, 2, 3, 4, 5])
    var curvedPath: CPRCurvedPath? { return _curvedPath }
    var nodeRemovalCost: NSMutableArray? = NSMutableArray()
    var delHistory: NSMutableArray? = NSMutableArray()
    var delNodes: NSMutableArray? = NSMutableArray()
    var pathSimplificationSlider: SliderStandIn? = SliderStandIn()

    init(_ path: CPRCurvedPath) {
        _curvedPath = path
        super.init()
        updateCosts()
    }

    /// What the views' OsirixUpdateCurvedPathCost runs.
    func updateCosts() { updateCurvedPathCost() }

    /// The part of -setCurvedPath: that edits the path: the controller keeps
    /// a copy of the view's path, and hands on the nodes it replaces.
    func setCurvedPath(_ path: CPRCurvedPath) {
        let previousNodes = _curvedPath?.nodes
        _curvedPath = path.copy() as? CPRCurvedPath
        restartSimplificationIfNodesChanged(since: previousNodes)
    }

    /// What -CPRViewDidUpdateCurvedPath: does with a view's path.
    func viewDidUpdate(_ path: CPRCurvedPath) {
        forgetCenterlineIfNodesChange(to: path)
        setCurvedPath(path)
    }

    var sliderEnabled: Bool { return onSliderEnabled() }

    func updateCurvedPathCost()
%(updateCurvedPathCost)s

    static func sameNodes(_ nodes: NSArray?, _ otherNodes: NSArray?) -> Bool
%(sameNodes)s

    func forgetCenterlineIfNodesChange(to newCurvedPath: CPRCurvedPath?)
%(forgetCenterlineIfNodesChange)s

    func onSliderEnabled() -> Bool
%(onSliderEnabled)s

    func restartSimplificationIfNodesChanged(since previousNodes: NSArray?)
%(restartSimplificationIfNodesChanged)s

    func costFunction(_ index: UInt) -> Float
%(costFunction)s

    func removeCheapestNode() -> Bool
%(removeCheapestNode)s

    func restoreLastRemovedNode() -> Bool
%(restoreLastRemovedNode)s
}

/// Runs `body`, then whether it raised and whether there is one cost per node,
/// each its node's; false once something is wrong.
func aligned(_ steps: ControllerSteps, _ what: String, _ body: () -> Void) -> Bool {
    var raised: NSException? = nil
    do {
        try HorosObjCException.perform { body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    if let raised {
        expect(false, "\(what): raised \(raised.name.rawValue): \(raised.reason ?? "")")
        return false
    }
    let nodes = steps._curvedPath?.nodes.count ?? 0
    let costs = steps.nodeRemovalCost?.count ?? 0
    if nodes != costs {
        expect(false, "\(what): \(costs) costs for \(nodes) nodes")
        return false
    }
    for i in 0..<nodes where (steps.nodeRemovalCost?[i] as? NSNumber)?.floatValue != steps.costFunction(UInt(i)) {
        expect(false, "\(what): the cost at \(i) is not its node's")
        return false
    }
    return true
}

func v(_ x: CGFloat, _ y: CGFloat) -> N3Vector { return N3VectorMake(x, y, 0) }
/// Node 5 is the cheapest: 0.1 mm from nodes 4 and 6, far from the others.
let cheapestAtFive = [v(0, 0), v(10, 0), v(20, 0), v(30, 0), v(40, 0), v(40.1, 0), v(40.2, 0), v(50, 10), v(40, 20)]

func controllerPath(_ nodes: [N3Vector]) -> CPRCurvedPath {
    let path = CPRCurvedPath()
    for node in nodes { path.addPatientNode(node) }
    expect(path.nodes.count == nodes.count, "the controller's path has \(path.nodes.count) nodes, not \(nodes.count)")
    return path
}

// The path ends on node 5: once removed, node 5 comes back on the last node.
refused: do {
    let steps = ControllerSteps(controllerPath(cheapestAtFive + [v(40.1, 0)]))
    guard aligned(steps, "on the last node: the first removal", { _ = steps.removeCheapestNode() }) else { break refused }
    expect(steps.delHistory == [5], "on the last node: node \(String(describing: steps.delHistory)) went, not node 5")
    var restored = true
    guard aligned(steps, "on the last node: node 5 refused", { restored = steps.restoreLastRemovedNode() }) else { break refused }
    expect(steps._curvedPath?.nodes.count == 9, "on the last node: node 5 came back")
    expect(!restored, "on the last node: a refused node is said to have come back")
    var count = steps._curvedPath?.nodes.count ?? 0
    while count > 3 {
        guard aligned(steps, "on the last node: down to \(count - 1) nodes", { _ = steps.removeCheapestNode() }) else { break refused }
        count = steps._curvedPath?.nodes.count ?? 0
    }
    while (steps.delHistory?.count ?? 0) > 0 {
        guard aligned(steps, "on the last node: back from \(count) nodes", { _ = steps.restoreLastRemovedNode() }) else { break refused }
        count = steps._curvedPath?.nodes.count ?? 0
    }
    expect(count == 9, "on the last node: back to \(count) nodes, not 9")
}

// Node 5 comes back to a path of 4 nodes, edited since, and goes at its end.
appended: do {
    let steps = ControllerSteps(controllerPath(cheapestAtFive + [v(30, 30)]))
    guard aligned(steps, "past the end: the first removal", { _ = steps.removeCheapestNode() }) else { break appended }
    while (steps._curvedPath?.nodes.count ?? 0) > 4 {
        steps._curvedPath?.removeNode(at: 1)
    }
    steps.updateCosts()
    var restored = false
    guard aligned(steps, "past the end: node 5 back", { restored = steps.restoreLastRemovedNode() }) else { break appended }
    expect(restored, "past the end: node 5 is said not to have come back")
    let last = (steps._curvedPath?.nodes.lastObject as? NSValue)?.n3VectorValue() ?? N3Vector()
    expect(steps._curvedPath?.nodes.count == 5 && N3VectorEqualToVector(last, v(40.1, 0)),
           "past the end: node 5 is not at the end of 5 nodes")
}

// Node 5 goes first, then node 2, which is on the last node: node 2 is refused
// on the way back, and node 5 comes back between nodes 4 and 6, not one node
// further, past the last node.
refusedFirst: do {
    let nodes = [v(0, 0), v(10, 0), v(10.5, 0), v(11, 0), v(30, 0), v(30.1, 0), v(30.2, 0), v(40, 10), v(10.5, 0)]
    let steps = ControllerSteps(controllerPath(nodes))
    guard aligned(steps, "before a refused node: node 5 out", { _ = steps.removeCheapestNode() }),
          aligned(steps, "before a refused node: node 2 out", { _ = steps.removeCheapestNode() }) else { break refusedFirst }
    expect(steps.delHistory == [5, 2], "before a refused node: \(String(describing: steps.delHistory)) went, not 5 then 2")
    while (steps.delHistory?.count ?? 0) > 0 {
        guard aligned(steps, "before a refused node: back", { _ = steps.restoreLastRemovedNode() }) else { break refusedFirst }
    }
    var expected = nodes
    expected.remove(at: 2)
    let back = (steps._curvedPath?.nodes as? [NSValue])?.map { $0.n3VectorValue() } ?? []
    expect(back.count == expected.count && zip(back, expected).allSatisfy { N3VectorEqualToVector($0, $1) },
           "before a refused node: the nodes came back as \(back.map { "(\($0.x), \($0.y))" }), not in their order without node 2")
}

/// A path of `count` nodes the slider can simplify, winding in 3D.
func slidPath(_ count: Int) -> ControllerSteps {
    let steps = ControllerSteps(makePath(count))
    for _ in 0..<(count / 3) {
        guard aligned(steps, "the slider down", { _ = steps.removeCheapestNode() }) else { break }
    }
    return steps
}

// A node edited by hand after the slider has removed nodes: what the
// views do to their copy of the path, which -setCurvedPath: takes.
let byHand: [(String, (CPRCurvedPath) -> Void)] = [
    ("a node inserted", { _ = $0.insertNode(atRelativePosition: 0.37) }),
    ("a node added", { $0.addPatientNode(N3VectorMake(-40, 5, 20)) }),
    ("a node deleted", { $0.removeNode(at: 4) }),
    ("a node moved", { $0.moveNode(at: 4, to: N3VectorMake(12, -7, 3)) }),
]
edits: for (what, edit) in byHand {
    let steps = slidPath(24)
    let view = steps._curvedPath!.copy() as! CPRCurvedPath
    let before = view.nodes.count
    edit(view)
    expect(!view.nodes.isEqual(to: steps._curvedPath!.nodes as! [Any]), "\(what): the view's path did not change")
    expect(steps.sliderEnabled, "\(what): the slider is disabled before the edit")
    guard aligned(steps, "\(what)", { steps.viewDidUpdate(view) }) else { continue edits }
    expect(steps.centerline?.count == 0, "\(what): the centerline is still there")
    expect(!steps.sliderEnabled, "\(what): the slider is still enabled")
    expect(steps._curvedPath?.nodes.count != before || what == "a node moved", "\(what): \(before) nodes still")
    expect(steps.delHistory?.count == 0 && steps.delNodes?.count == 0,
           "\(what): \(steps.delHistory?.count ?? 0) removals left to undo")
    expect(steps.pathSimplificationSlider?.doubleValue == steps.pathSimplificationSlider?.maxValue,
           "\(what): the slider is not at its maximum")
    while (steps._curvedPath?.nodes.count ?? 0) > 3 {
        let count = steps._curvedPath?.nodes.count ?? 0
        guard aligned(steps, "\(what): down from \(count) nodes", { _ = steps.removeCheapestNode() }) else { continue edits }
        if steps._curvedPath?.nodes.count == count { break }
    }
    while (steps.delHistory?.count ?? 0) > 0 {
        guard aligned(steps, "\(what): back", { _ = steps.restoreLastRemovedNode() }) else { continue edits }
    }
    expect(steps._curvedPath?.nodes.isEqual(to: view.nodes as! [Any]) ?? false,
           "\(what): the slider did not bring back the path edited by hand")
}

// The transverse section, its spacing or the angle moved: the nodes are the
// same, the centerline stays, the slider stays enabled and brings back the
// path it had.
let notTheNodes: [(String, (CPRCurvedPath) -> Void)] = [
    ("the transverse section moved", { $0.transverseSectionPosition = 0.3 }),
    ("the transverse sections' spacing changed", { $0.transverseSectionSpacing = 7 }),
    ("the angle changed", { $0.angle = 0.4 }),
]
kept: for (what, edit) in notTheNodes {
    let steps = slidPath(24)
    let history = steps.delHistory?.copy() as? NSArray
    let view = steps._curvedPath!.copy() as! CPRCurvedPath
    edit(view)
    guard aligned(steps, what, { steps.viewDidUpdate(view) }) else { continue kept }
    expect(steps.delHistory?.isEqual(to: (history ?? []) as! [Any]) ?? false,
           "\(what): the removals to undo changed")
    expect(steps.pathSimplificationSlider?.doubleValue == 40, "\(what): the slider moved")
    expect(steps.centerline?.count == 5, "\(what): the centerline went")
    expect(steps.sliderEnabled, "\(what): the slider is disabled")
    while (steps.delHistory?.count ?? 0) > 0 {
        guard aligned(steps, "\(what): back", { _ = steps.restoreLastRemovedNode() }) else { continue kept }
    }
    expect(steps._curvedPath?.nodes.isEqual(to: makePath(24).nodes as! [Any]) ?? false,
           "\(what): the slider did not bring back the path it had")
}

for line in timings { print("time: " + line) }
if !wrong.isEmpty {
    for line in wrong { print("FAIL: " + line) }
    exit(1)
}
'''


def run(command, **kwargs):
    return subprocess.run(command, check=True, capture_output=True, **kwargs)


controller = code(source('Horos/Sources/CPRController.swift').decode('utf-8'))
check(bool(controller), 'no CPRController.swift')
STEPS = {}
for name, signature in [('costFunction', 'public dynamic func costFunction('),
                        ('removeCheapestNode', 'private func removeCheapestNode('),
                        ('restoreLastRemovedNode', 'private func restoreLastRemovedNode('),
                        ('updateCurvedPathCost', 'public dynamic func updateCurvedPathCost('),
                        ('restartSimplificationIfNodesChanged', 'private func restartSimplificationIfNodesChanged('),
                        ('sameNodes', 'private static func sameNodes('),
                        ('forgetCenterlineIfNodesChange', 'private func forgetCenterlineIfNodesChange('),
                        ('onSliderEnabled', 'private dynamic func onSliderEnabled(')]:
    STEPS[name] = block(controller, signature)
    check(bool(STEPS[name]), f'CPRController.swift: no {signature.strip("(")}')
# Formerly, -setCurvedPath: left the costs and the history as they were,
# and -CPRViewDidUpdateCurvedPath: cleared the centerline at every
# update, and compared no nodes.
FORMER = {
    'restartSimplificationIfNodesChanged': '{ }',
    'sameNodes': '{ return (nodes ?? NSArray()).isEqual(to: (otherNodes ?? NSArray()) as! [Any]) }',
    'forgetCenterlineIfNodesChange': '{ centerline?.removeAllObjects() }',
}

with tempfile.TemporaryDirectory(prefix='horos-cpr-simplification-') as tmp:
    tmp = Path(tmp)
    for path in HEADERS + [path for path, _ in OBJC_SOURCES] + SWIFT_SOURCES:
        (tmp / Path(path).name).write_bytes(source(path))
    (tmp / 'harness.h').write_text(BRIDGING)
    driver = DRIVER
    for name, body in STEPS.items():
        driver = driver.replace(f'%({name})s', body or FORMER.get(name, '{ fatalError() }'))
    (tmp / 'main.swift').write_text(driver)
    (tmp / 'OperationStubs.swift').write_text(OPERATION_STUBS)
    objects = []
    try:
        for path, flags in OBJC_SOURCES:
            name = Path(path).name
            obj = tmp / (Path(path).stem + '.o')
            # The app's prefix header brings Cocoa into every source.
            run(['xcrun', 'clang', '-x', 'objective-c', '-include', 'Cocoa/Cocoa.h', '-g', '-iquote', str(tmp),
                 *flags, '-c', str(tmp / name), '-o', str(obj)])
            objects.append(str(obj))
        # Without DEBUG, as in Release: an index out of range raises rather than traps.
        run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-suppress-warnings', '-Onone',
             '-import-objc-header', str(tmp / 'harness.h'), '-Xcc', '-iquote', '-Xcc', str(tmp),
             *[str(tmp / Path(path).name) for path in SWIFT_SOURCES], str(tmp / 'OperationStubs.swift'),
             str(tmp / 'main.swift'), *objects,
             '-framework', 'Cocoa', '-framework', 'Accelerate', '-o', str(tmp / 'harness')])
    except subprocess.CalledProcessError as e:
        failures.append('the harness did not build: ' + (e.stderr or b'').decode(errors='replace')[-2000:])
    else:
        try:
            result = subprocess.run([str(tmp / 'harness')], capture_output=True, text=True, timeout=600)
            for line in result.stdout.splitlines():
                if line.startswith('time: '):
                    print(line)
                elif line.startswith('FAIL: '):
                    failures.append(line[len('FAIL: '):])
            if result.returncode != 0 and not any(line.startswith('FAIL: ') for line in result.stdout.splitlines()):
                failures.append('the harness failed: ' + (result.stderr or result.stdout)[-800:])
        except subprocess.TimeoutExpired:
            failures.append('the harness timed out')

slider = block(controller, 'func onSliderMove(')
check('withPathRebuiltOnce(' in slider, '-onSliderMove: rebuilds the path at each node')
check('self.removeNode()' not in slider and 'self.undoLastNodeRemoval()' not in slider,
      '-onSliderMove: shows the path in the views at each node')
check(slider.count('showCurvedPathInViews()') == 1, '-onSliderMove: does not show the path once')

setter = block(controller, 'private func setCurvedPathValue(')
kept_nodes = setter.find('let previousNodes = _curvedPath?.nodes')
replaced = setter.find('_curvedPath = newCurvedPath?.copy() as? CPRCurvedPath')
restarted = setter.find('self.restartSimplificationIfNodesChanged(since: previousNodes)')
check(0 <= kept_nodes < replaced < restarted,
      '-setCurvedPath: does not restart the simplification when the nodes it replaces change')
check('self.curvedPath =' not in slider and '.setCurvedPath' not in slider,
      '-onSliderMove: sets the path, which would restart the simplification')

for name, signature in [('-CPRViewDidUpdateCurvedPath:', 'public dynamic func cprViewDidUpdateCurvedPath('),
                        ('-CPRViewDidEditCurvedPath:', 'public dynamic func cprViewDidEditCurvedPath(')]:
    body = block(controller, signature)
    forget = body.find('self.forgetCenterlineIfNodesChange(to: curvedPathOf(CPRMPRDCMView))')
    setting = body.find('self.curvedPath = curvedPathOf(CPRMPRDCMView)')
    check(0 <= forget < setting,
          f'{name} does not hand the view\'s path to -forgetCenterlineIfNodesChange(to:) before -setCurvedPath:')
    check('centerline' not in body, f'{name} clears the centerline whether or not the nodes changed')
    check('pathSimplificationSlider' not in body, f'{name} moves the slider whether or not the nodes changed')

stretched = code(source('Horos/Sources/CPRStretchedView.swift').decode('utf-8'))
check(bool(stretched), 'no CPRStretchedView.swift')
up = block(stretched, 'override dynamic func mouseUp(with event: NSEvent)')
dragging = block(up, 'if _isDraggingNode {')
ended = dragging.find('self._sendDidEditCurvedPath()')
costs = dragging.find('OsirixUpdateCurvedPathCost')
check(0 <= ended < costs, 'the stretched view asks for the costs before it ends the edit of the dragged node')
key_down = block(stretched, 'override dynamic func keyDown(with theEvent: NSEvent)')
deleting = block(key_down, 'if (Int(c) == NSDeleteCharacter')
removed = deleting.find('_curvedPath?.removeNode(at: _draggedNode)')
updated = deleting.find('self._sendDidUpdateCurvedPath()')
costs = deleting.find('OsirixUpdateCurvedPathCost')
check(0 <= removed < updated < costs,
      'the stretched view does not send a node deleted during a drag before it asks for the costs')

initialize = block(controller, 'private func initialize(')
check('self.window?.title = NSLocalizedString("Curved MPR", comment: "")' in initialize,
      'the Curved MPR window is not titled "Curved MPR"')

for xib in ['Horos/Resources/en.lproj/CPR.xib', 'Horos/Resources/ja-JP.lproj/CPR.xib']:
    text = source(xib).decode('utf-8')
    cell = re.search(r'<slider [^>]*id="1570">.*?<sliderCell [^>]*/>', text, re.S)
    check(cell is not None, f'{xib}: no simplification slider')
    if cell:
        check('continuous="YES"' not in cell.group(0),
              f'{xib}: the simplification slider sends its action at each value, not on mouse up')
    check('<window title="MPR"' not in text, f'{xib}: the Curved MPR window is titled "MPR"')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the simplification slider rebuilds the path once, on mouse up, with the same result, '
      'and keeps one cost per node when a node cannot come back or comes back past the end, '
      'the older removals in their places; a node edited by hand leaves one cost per node and '
      'no removal to undo; only a node edited by hand disables the slider; the stretched view sends '
      'its edits before it asks for the costs; the Curved MPR window says so')
