#!/usr/bin/env python3
"""A viewer never keeps a fused or registered viewer that was freed.

A 2D viewer keeps the viewer of its fused series, and its registered one,
without retaining them, as the plugin SDK has those instance variables kept,
and reading the fused one retains it. The fusion was ended only by the close
notification of the fused viewer. A viewer whose window closed observes
nothing any more and lives until the run loop releases it, which it does
after the viewers closed after it: closing the fused viewer next left the
first one pointing at freed memory, read when it was freed in its turn, and
the application stopped in the retain. A viewer freed without its window
closing, and a fusion whose ending was turned away because another one ran,
left the same.

The check runs. Compiled as they stand: the manual retain-release storage
(ViewerControllerStorage.swift), the register's account of the viewers alive
(ViewerRegistry.swift, "The viewers alive"), the fusion's part for a viewer
that goes (ViewerFusion.swift, "A viewer that goes"), and the lines of the
viewer's freeing and of its window's closing that call them. The viewers and
their views are doubles with the same fields. The fields are examined by
their addresses, so a wrong result is a failed check and not a read of freed
memory:

- two fused viewers closed one after the other and freed in the reverse
  order, as an autorelease pool frees them;
- the fused viewer freed without its window closing, the other on screen,
  which ends its fusion as it does when told of a close;
- a fusion whose ending is turned away;
- a registered viewer freed;
- a fused viewer the register never knew, written from outside and freed;
- the fusion of two other viewers, which stays.

The negative control is run too: the same probe with the freeing and the
closing as they were (the fusion ended by the viewer's own call alone) must
find the field pointing at a freed viewer.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)


def section(text, mark, name):
    """The text from `// MARK: - mark` to the next MARK."""
    start = text.find('    // MARK: - ' + mark + '\n')
    assert start >= 0, f'{name} has no section "{mark}"; this test needs a new look'
    end = text.find('\n    // MARK: - ', start + 1)
    return text[start:end if end >= 0 else len(text)]


storage = (SOURCES / 'ViewerControllerStorage.swift').read_text(encoding='utf-8')
alive = section((SOURCES / 'ViewerRegistry.swift').read_text(encoding='utf-8'), 'The viewers alive', 'ViewerRegistry.swift')
going = section((SOURCES / 'ViewerFusion.swift').read_text(encoding='utf-8'), 'A viewer that goes', 'ViewerFusion.swift')

life = (SOURCES / 'ViewerSessionGraph+ViewerLife.swift').read_text(encoding='utf-8')
freed = re.search(r'\n( *ViewerFusion\.forget\(viewer, among: registry\.aliveViewers\)\n *registry\.viewerIsBeingFreed\(viewer\)\n'
                  r' *viewer\.fusion\.endFusionOfFreedViewer\(\)\n)', life)
assert freed, 'the freeing of a viewer no longer has the others forget it before it ends its own fusion'
assert life.index(freed.group(1)) < life.index('NotificationCenter.default.removeObserver(viewer)', life.index('func tearDown(')), \
    'the freeing of a viewer ends its fusion after it stopped observing'
assert 'viewer.activateBlending(nil)' not in life[life.index('func tearDown('):], \
    'the freeing of a viewer reads its fused viewer without asking whether it is alive'

window = (SOURCES / 'ViewerSessionGraph+WindowLife.swift').read_text(encoding='utf-8')
closed = re.search(r'NotificationCenter\.default\.post\(name: NSNotification\.Name\.OsirixCloseViewer, object: viewer, userInfo: nil\)\n'
                   r'(?:\s*//[^\n]*\n)*( *ViewerFusion\.forget\(viewer, among: registry\.aliveViewers\)\n)', window)
assert closed, 'the closing of a viewer window no longer has the other viewers forget it after the notification'

graph = (SOURCES / 'ViewerSessionGraph.swift').read_text(encoding='utf-8')
assert 'processGraph.viewerRegistry.viewerWasMade(viewer)' in graph, 'the graph of a viewer no longer says the viewer was made'

DOUBLES = r'''
import Foundation
import Synchronization

nonisolated(unsafe) var failures: Int32 = 0
nonisolated(unsafe) var danglingReads: Int32 = 0
func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    }
}

nonisolated final class ViewerRegistry: Sendable {
    struct State: Sendable { var alive: [UInt] = [] }
    let state = Mutex(State())
ALIVE
}

@MainActor final class DoubleView {
    var blending: DoubleView?
    var fusedFactor: Float = -1
    func activateBlending(_ bC: ViewerController?, blendingFactor: Float) { if bC == nil { blending = nil }; fusedFactor = blendingFactor }
}
@MainActor final class DoubleControl { var isEnabled = true; var floatValue: Float = 128 }

@MainActor final class ViewerController: NSObject {
    nonisolated(unsafe) var _blendingController = ManuallyRetained<ViewerController>()
    var _registeredViewer = ManuallyRetained<ViewerController>()
    var horos_windowWillClose = false
    var horos_imageView: DoubleView? = DoubleView()
    var horos_seriesView: DoubleView? = DoubleView()
    var horos_blendingSlider: DoubleControl? = DoubleControl()
    var horos_blendingPercentage: DoubleControl? = DoubleControl()
    let registry: ViewerRegistry
    let name: String
    /// Whether the viewer has a graph, which says it was made and runs its freeing.
    let known: Bool
    /// -ActivateBlending: runs elsewhere: this viewer's is turned away.
    var turnsAway = false
    /// How many fusions -ActivateBlending: ended.
    var ended = 0

    init(_ name: String, registry: ViewerRegistry, known: Bool = true) {
        self.name = name
        self.registry = registry
        self.known = known
        super.init()
        if known { registry.viewerWasMade(self) }
    }

    /// The fused viewer, read as the viewer reads it: it is retained. A
    /// field that points at no viewer alive is counted and not read.
    var horos_blending: ViewerController? {
        if _blendingController.address != 0 && !registry.isAlive(address: _blendingController.address) {
            danglingReads += 1
            return nil
        }
        return _blendingController.wrappedValue
    }
    func horos_assignBlendingController(_ value: ViewerController?) { _blendingController.assign(value) }
    func horos_assignRegisteredViewer(_ value: ViewerController?) { _registeredViewer.assign(value) }
    var fusion: ViewerFusion { ViewerFusion(viewer: self, registry: registry) }
    func activateBlending(_ bC: ViewerController?) { fusion.activateBlending(bC) }

    /// Fused as -ActivateBlending: leaves it.
    func fuse(with other: ViewerController) {
        horos_assignBlendingController(other)
        horos_imageView?.blending = other.horos_imageView
    }

    /// The closing of the window, to the lines after the notification.
    func closeWindow(observers: [ViewerController]) {
        let viewer = self
        viewer.horos_windowWillClose = true
        // The viewers that still observe are told.
        for other in observers where other !== viewer && !other.horos_windowWillClose {
            if other.horos_blending === viewer { other.activateBlending(nil) }
        }
        if !former {
CLOSED
        }
    }

    isolated deinit {
        let viewer = self
        if !known {
            // No graph, no freeing of the viewer's own.
        } else if former {
            // The register's account is the probe's own means in the control.
            registry.viewerIsBeingFreed(viewer)
            viewer.activateBlending(nil)
        } else {
FREED
        }
    }
}

@MainActor final class ViewerFusion {
    let viewer: ViewerController
    let registry: ViewerRegistry
    init(viewer: ViewerController, registry: ViewerRegistry) { self.viewer = viewer; self.registry = registry }

    /// The reads and the store of -ActivateBlending:, without what it shows.
    func activateBlending(_ bC: ViewerController?) {
        if viewer.turnsAway { return }
        if viewer.horos_blending === bC { return }
        viewer.horos_assignBlendingController(bC)
        if bC == nil {
            viewer.ended += 1
            viewer.horos_imageView?.blending = nil
        }
    }

GOING
}
'''

MAIN = r'''
import Foundation

nonisolated(unsafe) let former = CommandLine.arguments.contains("former")

@MainActor func address(_ viewer: ViewerController) -> UInt { UInt(bitPattern: Unmanaged.passUnretained(viewer).toOpaque()) }

@MainActor func run() {
    // The storage answers by address and forms no reference.
    do {
        let registry = ViewerRegistry()
        let a = ViewerController("a", registry: registry), b = ViewerController("b", registry: registry)
        check(a._blendingController.address == 0 && !a._blendingController.holds(b), "an empty field has an address")
        let before = CFGetRetainCount(b)
        a.horos_assignBlendingController(b)
        check(a._blendingController.address == address(b) && a._blendingController.holds(b) && !a._blendingController.holds(a),
              "a field stored without retaining does not answer by its object's address")
        check(CFGetRetainCount(b) == before, "asking a field's address retained its object")
        a.horos_assignBlendingController(nil)
        check(registry.isAlive(address: address(a)) && !registry.isAlive(address: 0), "a viewer made is not alive, or address 0 is")
        check(registry.aliveViewers.count == 2 && registry.aliveViewers.first === a, "the viewers alive are not the viewers made")
    }

    // Two fused viewers closed one after the other, freed in the reverse order.
    do {
        let registry = ViewerRegistry()
        var a: ViewerController? = ViewerController("a", registry: registry), b: ViewerController? = ViewerController("b", registry: registry)
        a!.fuse(with: b!)
        a!.closeWindow(observers: [a!, b!])
        b!.closeWindow(observers: [b!])
        check(a!._blendingController.address == 0, "a closed viewer still keeps the fused viewer closed after it")
        check(a!.ended == 0, "a closed viewer ended its fusion as one on screen does")
        check(a!.horos_imageView?.blending == nil && a!.horos_blendingSlider?.isEnabled == false, "a closed viewer still draws the fused series")
        b = nil
        check(!former || a!._blendingController.address != 0, "the control: the former freeing left nothing to find")
        check(former || !registry.isAlive(address: a!._blendingController.address) == (a!._blendingController.address == 0), "a freed viewer is alive")
        a = nil
        check(registry.aliveViewers.isEmpty, "freed viewers are still alive")
    }

    // The fused viewer freed without its window closing; the other is on screen.
    do {
        let registry = ViewerRegistry()
        let a = ViewerController("a", registry: registry)
        var b: ViewerController? = ViewerController("b", registry: registry)
        a.fuse(with: b!)
        b = nil
        check(a._blendingController.address == 0, "a viewer on screen keeps a fused viewer that was freed")
        check(a.ended == 1, "a viewer on screen did not end its fusion with a freed viewer as it ends one with a closed viewer")
    }

    // The ending of the fusion is turned away.
    do {
        let registry = ViewerRegistry()
        let a = ViewerController("a", registry: registry)
        var b: ViewerController? = ViewerController("b", registry: registry)
        a.fuse(with: b!)
        a.turnsAway = true
        b!.closeWindow(observers: [a, b!])
        check(a._blendingController.address == 0 && a.horos_imageView?.blending == nil, "a fusion whose ending was turned away keeps the closed viewer")
        b = nil
    }

    // A registered viewer freed.
    do {
        let registry = ViewerRegistry()
        let a = ViewerController("a", registry: registry)
        var b: ViewerController? = ViewerController("b", registry: registry)
        a.horos_assignRegisteredViewer(b)
        b = nil
        check(a._registeredViewer.address == 0, "a viewer keeps a registered viewer that was freed")
    }

    // A fused viewer the register never knew, freed: the field is not read.
    if !former {
        let registry = ViewerRegistry()
        var a: ViewerController? = ViewerController("a", registry: registry)
        var b: ViewerController? = ViewerController("b", registry: registry, known: false)
        a!.horos_assignBlendingController(b)
        b = nil
        a = nil
    }

    // The fusion of two other viewers stays.
    do {
        let registry = ViewerRegistry()
        let a = ViewerController("a", registry: registry), b = ViewerController("b", registry: registry)
        var c: ViewerController? = ViewerController("c", registry: registry)
        a.fuse(with: b)
        a.horos_assignRegisteredViewer(b)
        c!.closeWindow(observers: [a, b, c!])
        c = nil
        check(a._blendingController.holds(b) && a._registeredViewer.holds(b) && a.ended == 0, "another viewer's going ended a fusion")
        a.horos_assignBlendingController(nil)
        a.horos_assignRegisteredViewer(nil)
    }

    check(danglingReads == 0, "a freed viewer was read \(danglingReads) time(s)")
}

MainActor.assumeIsolated { run() }
exit(failures == 0 ? 0 : 1)
'''


def indented(text, spaces):
    lines = [line.strip() for line in text.strip('\n').split('\n')]
    return '\n'.join(' ' * spaces + line for line in lines)


doubles = (DOUBLES.replace('ALIVE', alive).replace('GOING', going)
           .replace('CLOSED', indented(closed.group(1), 12)).replace('FREED', indented(freed.group(1), 12)))

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    (tmp / 'Doubles.swift').write_text(doubles, encoding='utf-8')
    (tmp / 'ViewerControllerStorage.swift').write_text(storage, encoding='utf-8')
    (tmp / 'main.swift').write_text(MAIN, encoding='utf-8')
    binary = tmp / 'probe'
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Probe',
                            str(tmp / 'Doubles.swift'), str(tmp / 'ViewerControllerStorage.swift'), str(tmp / 'main.swift'),
                            '-o', str(binary)], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr, file=sys.stderr)
        print('FAIL: the probe does not compile', file=sys.stderr)
        sys.exit(1)
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    sys.stderr.write(run.stderr)
    if run.returncode:
        print('FAIL: a viewer kept, or read, a viewer that was freed', file=sys.stderr)
        sys.exit(1)
    control = subprocess.run([str(binary), 'former'], capture_output=True, text=True, timeout=60)
    if control.returncode != 1 or 'still keeps the fused viewer closed after it' not in control.stderr \
            or 'a freed viewer was read' not in control.stderr:
        sys.stderr.write(control.stderr)
        print(f'FAIL: the control found nothing in the former freeing (status {control.returncode})', file=sys.stderr)
        sys.exit(1)

print('PASS: no viewer keeps a fused or registered viewer that closed or was freed, in any order; '
      'the former freeing read a freed viewer')
