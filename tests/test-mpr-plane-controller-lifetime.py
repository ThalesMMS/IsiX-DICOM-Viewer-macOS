#!/usr/bin/env python3
"""A plane of the 3D MPR or of the curved MPR never reaches its released controller.

MPRController and CPRController release themselves when their window closes:
their -windowWillClose: closes and releases the hidden VRController that
reslices the volume, then autoreleases the controller. The window and its
three planes (MPRDCMView, CPRMPRDCMView) can outlive both: closing the viewers
from the Database item of the 2D viewer's toolbar, with two 3D MPR open,
crashed in the Core Animation flush that drew a plane of a closed MPR, in
-[MPRDCMView roiColor:] reading the colour of an axis from the controller that
the plane kept unretained and never forgot (objc_retain of a freed object).

The check runs: the planes' references to their controller, to the hidden
VRView and (curved MPR) to their delegate are compiled as the sources declare
them, with what the sources run on them: the assignment from the window's
controller, -setVRView:viewID:, the controller's colours read for the lines,
the start of -subDraw:, the hidden VRView messaged by -checkForFrame, the
planes' detaching and the lines of the controller's -windowWillClose: that
detach them. A stand-in controller owns a window with three planes and a hidden
VRController, and releases both and itself as the real one does when the
window closes. Under NSZombieEnabled, once the autorelease pool is drained:

- the controller must be gone, its planes having let go of it while it closed;
- a plane drawn then must not reach it, nor draw its colours;
- a plane resized then must not reach the hidden VRView, gone with its
  VRController.

A control compiles the planes with the former unretained references and no
detaching: it must crash, or the probe cannot tell. `<git revision>` as an
optional argument reads the sources of that revision, the negative control.

A curved-MPR plane draws through its window's CPRRenderLifecycle, which refuses
every draw once the window starts closing, so that the teardown does not
re-enter drawRect. Letting go of the controller must not lift that gate: the
planes' -drawRect:, the lines of -setDCMPixList: that take the controller and
the lifecycle, and the lifecycle and detaching lines of -[CPRController
windowWillClose:], in their order, are compiled with CPRRenderLifecycle.swift.
The planes drawn while the window is open paint; drawn after each of those
lines, and once the controller is released, they paint nothing.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(name):
    path = f'Horos/Sources/{name}.swift'
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'],
                                       stderr=subprocess.DEVNULL).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


def bare(text):
    """The text without its // comments, so that what they recall is not taken for code."""
    return '\n'.join(re.sub(r'//.*', '', line) for line in text.split('\n'))


def body(text, signature):
    """What the braces after the first match of `signature` hold, without them; None if absent."""
    match = re.search(signature, text)
    if not match:
        return None
    opening = text.index('{', match.end())
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening + 1:index]
    return None


def declaration(text, name):
    """The line that declares the stored property `name`, or None."""
    match = re.search(rf'^[ \t]*(?:private[ \t]+)?(?:(?:weak|unowned(?:\(unsafe\))?)[ \t]+)?var[ \t]+{re.escape(name)}[ \t]*:[^\n]*$',
                      text, re.M)
    return match.group(0).strip() if match else None


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

STAND_INS = {'MPRController': 'Controller', 'CPRController': 'Controller',
             'HorosMPRVRViewMessages': 'VRViewMessages', 'CPRViewDelegate': 'PlaneDelegate'}


def stand_in(code):
    for name, replacement in STAND_INS.items():
        code = re.sub(rf'\b{name}\b', replacement, code)
    return code


PROBE = r'''
import AppKit

var closed = false
var opaqueColours = 0

func roiColor4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    if closed && a != 0 { opaqueColours += 1 }
}

@objc protocol VRViewMessages: NSObjectProtocol {
    func prepareFullDepthCapture()
    func setHostBackingScale(_ scale: CGFloat)
}

@objc protocol PlaneDelegate: NSObjectProtocol {}

final class HiddenVRView: NSView, VRViewMessages {
    func prepareFullDepthCapture() {}
    func setHostBackingScale(_ scale: CGFloat) {}
}

/// The hidden VRController: it owns its view.
final class HiddenVRController: NSObject {
    let view = HiddenVRView(frame: NSMakeRect(0, 0, 10, 10))
}

final class Controller: NSWindowController, NSWindowDelegate, PlaneDelegate {
    @objc dynamic var colorAxis1: NSColor? = .red
    @objc dynamic var colorAxis2: NSColor? = .green
    @objc dynamic var colorAxis3: NSColor? = .blue
    @objc dynamic var mprView1: PlaneView!
    @objc dynamic var mprView2: PlaneView!
    @objc dynamic var mprView3: PlaneView!
    /// Made and retained by the initializer, released by -windowWillClose:.
    unowned(unsafe) var hiddenVRController: HiddenVRController? = nil

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === window else { return }
        // The hidden VRController is closed and released: it goes with the pool.
        if let hidden = hiddenVRController { _ = Unmanaged.passUnretained(hidden).autorelease() }
@@DETACH_CALLS@@
        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }
}

final class PlaneView: NSView {
    var viewID: Int32 = 0
    var stringID: String? = nil
    var exportsAllViewsPreference = true
    var pendingScrollEvents: [NSEvent] = []
    var backingScaleFactor: CGFloat { window?.backingScaleFactor ?? 0 }
    func windowController() -> NSWindowController? { window?.windowController }

@@DECLARATIONS@@

    var controllerForProbe: Controller? { windowControllerIvar }

    func attach() {
@@ATTACH@@
    }

    func setVRView(_ v: (NSView & VRViewMessages)!, viewID i: Int32) {
@@SET_VR_VIEW@@
    }

@@DETACH_METHOD@@

    func roiColor(axis: Int) {
@@ROI_COLOR@@
    }

    /// The start of -subDraw:, then the colours of the two lines of view 1,
    /// the first thing it reads of the controller.
    func subDraw(_ r: NSRect) {
@@SUBDRAW_START@@
        roiColor(axis: 2)
        roiColor(axis: 3)
    }

    func checkForFrame() {
@@CHECK_FOR_FRAME@@
    }
}

let scenario = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "draw"
var plane: PlaneView!
var keptWindow: NSWindow!          // the window outlives its controller
weak var released: Controller?
var detachedOnClose = false

_ = NSApplication.shared
autoreleasepool {
    let window = NSWindow(contentRect: NSMakeRect(-10000, -10000, 300, 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let controller = Controller(window: window)
    _ = Unmanaged.passRetained(controller)   // handed over by its creator, given back by -windowWillClose:
    window.delegate = controller
    let hidden = HiddenVRController()
    _ = Unmanaged.passRetained(hidden)
    controller.hiddenVRController = hidden
    var planes: [PlaneView] = []
    for index in 1...3 {
        let view = PlaneView(frame: NSMakeRect(0, 0, 100, 100))
        window.contentView?.addSubview(view)
        view.attach()
        view.setVRView(hidden.view, viewID: Int32(index))
        planes.append(view)
    }
    controller.mprView1 = planes[0]
    controller.mprView2 = planes[1]
    controller.mprView3 = planes[2]
    plane = planes[0]
    keptWindow = window
    released = controller
    if plane.controllerForProbe !== controller { print("not-attached") }
    window.close()
    detachedOnClose = plane.controllerForProbe == nil
}

closed = true
print("released=\(released == nil ? 1 : 0) detached=\(detachedOnClose ? 1 : 0)")
fflush(stdout)
if scenario == "draw" {
    plane.subDraw(NSMakeRect(0, 0, 100, 100))
} else {
    plane.checkForFrame()
}
print("survived opaque=\(opaqueColours)")
'''

GATE_PROBE = r'''
import AppKit

let HorosObjCExceptionKey = "HorosObjCException"
enum HorosObjCException {
    static func perform(_ body: () -> Void) throws { body() }
}

@objc protocol VRViewMessages: NSObjectProtocol {}
@objc protocol PlaneDelegate: NSObjectProtocol {}

var planes: [PlaneView] = []
var step = "open"
var paintedOpen = 0
var paintedLate: [String] = []

/// DCMView's drawRect: it paints the plane's image.
class DrawnView: NSView {
    override func draw(_ rect: NSRect) {
        if step == "open" { paintedOpen += 1 } else if !paintedLate.contains(step) { paintedLate.append(step) }
    }
}

func drawPlanes(_ when: String) {
    step = when
    for plane in planes { plane.draw(plane.bounds) }
}

final class Controller: NSWindowController, NSWindowDelegate, PlaneDelegate {
    @objc dynamic var mprView1: PlaneView!
    @objc dynamic var mprView2: PlaneView!
    @objc dynamic var mprView3: PlaneView!
    private var _renderLifecycle: CPRRenderLifecycle?
    @objc dynamic var renderLifecycle: CPRRenderLifecycle! {
        if _renderLifecycle == nil { _renderLifecycle = CPRRenderLifecycle() }
        return _renderLifecycle
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === window else { return }
@@CLOSING@@
        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }
}

final class PlaneView: DrawnView {
    var viewID: Int32 = 0
    func windowController() -> NSWindowController? { window?.windowController }

@@DECLARATIONS@@

    func attach() {
@@ATTACH@@
    }

@@DETACH_METHOD@@

    override func draw(_ rect: NSRect) {
@@DRAW@@
    }
}

weak var released: Controller?
var keptWindow: NSWindow!          // the window outlives its controller

_ = NSApplication.shared
autoreleasepool {
    let window = NSWindow(contentRect: NSMakeRect(-10000, -10000, 300, 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let controller = Controller(window: window)
    _ = Unmanaged.passRetained(controller)   // handed over by its creator, given back by -windowWillClose:
    window.delegate = controller
    _ = controller.renderLifecycle.markOpen()
    for index in 1...3 {
        let view = PlaneView(frame: NSMakeRect(0, 0, 100, 100))
        view.viewID = Int32(index)
        window.contentView?.addSubview(view)
        view.attach()
        planes.append(view)
    }
    controller.mprView1 = planes[0]
    controller.mprView2 = planes[1]
    controller.mprView3 = planes[2]
    keptWindow = window
    released = controller
    drawPlanes("open")
    window.close()
}
drawPlanes("once the controller was released")
print("released=\(released == nil ? 1 : 0) open=\(paintedOpen)")
print("late=" + paintedLate.joined(separator: "|"))
'''


def indent(code, spaces=8):
    return '\n'.join((' ' * spaces + line.strip()) if line.strip() else '' for line in code.strip('\n').split('\n'))


def probe_source(parts, template=PROBE):
    source = template
    for key, value in parts.items():
        source = source.replace(f'@@{key}@@', value)
    return source


def run_probe(name, source, tmp, extra=(), scenarios=('draw', 'resize')):
    """{scenario: (returncode, stdout, stderr)}, or None if it does not compile."""
    directory = Path(tmp) / name
    directory.mkdir()
    (directory / 'main.swift').write_text(source)
    binary = directory / 'probe'
    build = subprocess.run(['xcrun', 'swiftc', '-Onone', '-swift-version', '5', '-suppress-warnings',
                            *[str(path) for path in extra], str(directory / 'main.swift'), '-o', str(binary)],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(f'--- {name} does not compile:', file=sys.stderr)
        print('\n'.join(build.stderr.strip().split('\n')[-15:]), file=sys.stderr)
        return None
    environment = dict(os.environ, NSZombieEnabled='YES')
    results = {}
    for scenario in scenarios:
        run = subprocess.run([str(binary), scenario], capture_output=True, text=True, timeout=60, env=environment)
        results[scenario] = (run.returncode, run.stdout, run.stderr)
    return results


def crash(result):
    code, _, stderr = result
    zombie = 'deallocated instance' in stderr
    return f'exit {code}' + (', message sent to a deallocated instance' if zombie else '')


PAIRS = [('MPRDCMView', 'MPRController', ['windowControllerIvar', '_vrView']),
         ('CPRMPRDCMView', 'CPRController', ['windowControllerIvar', '_vrView', '_delegate'])]
CONTROL = {'windowControllerIvar': 'private unowned(unsafe) var windowControllerIvar: Controller? = nil',
           '_vrView': 'private unowned(unsafe) var _vrView: (NSView & VRViewMessages)? = nil',
           '_delegate': 'private unowned(unsafe) var _delegate: PlaneDelegate? = nil'}

with tempfile.TemporaryDirectory() as tmp:
    for view_name, controller_name, properties in PAIRS:
        view = read(view_name)
        controller = read(controller_name)
        code = bare(view)

        declarations = {name: declaration(code, name) for name in properties}
        for name, line in declarations.items():
            if line is None:
                failures.append(f'{view_name} no longer declares {name} as this test expects; it needs a new look')
        set_pix = body(code, r'func setDCMPixList\(')
        attach = re.search(rf'windowControllerIvar = self\.windowController\(\) as\? {controller_name}\b', set_pix or '')
        set_vr = body(code, r'func setVRView\(')
        roi_color = body(code, r'func roiColor\(axis: Int\)')
        sub_draw = body(code, r'override dynamic func subDraw\(_ r: NSRect\)')
        check_for_frame = body(code, r'func checkForFrame\(\)')
        for what, found in [('-setDCMPixList: taking its controller from the window', attach), ('-setVRView:viewID:', set_vr),
                            ('roiColor(axis:)', roi_color), ('-subDraw:', sub_draw), ('-checkForFrame', check_for_frame)]:
            if not found:
                failures.append(f'{view_name} has no {what} as this test expects; it needs a new look')
        if any(line is None for line in declarations.values()) or not all([attach, set_vr, roi_color, sub_draw, check_for_frame]):
            continue
        if 'windowControllerIvar' not in roi_color:
            failures.append(f'{view_name} roiColor(axis:) no longer reads the controller; this test needs a new look')
        start = sub_draw[:sub_draw.find('self.viewport.rotation = 0')] if 'self.viewport.rotation = 0' in sub_draw else ''

        detach = body(code, r'func detachFromWindowController\(\)')
        closing = bare(body(controller, r'override dynamic func windowWillClose\(_ notification: Notification\)') or '')
        autorelease = closing.find('Unmanaged.passUnretained(self).autorelease()')
        loop = re.search(r'for (\w+) in \[mprView1, mprView2, mprView3\] \{\s*\1\?\.detachFromWindowController\(\)\s*\}', closing)
        calls = [loop.group(0)] if loop else re.findall(r'mprView[123]\??\.detachFromWindowController\(\)', closing)
        detaches = bool(calls) and autorelease >= 0 and all(closing.find(call) < autorelease for call in calls) \
            and (loop is not None or len(set(calls)) == 3)
        if detach is None:
            failures.append(f'{view_name} cannot be detached from its controller')
        if not detaches:
            failures.append(f'-[{controller_name} windowWillClose:] does not detach its three planes before it lets itself go')
        for name, line in declarations.items():
            if 'unowned' in line:
                failures.append(f'{view_name} keeps {name} unowned(unsafe): it is not forgotten when what it names is released')

        actual = {
            'DECLARATIONS': indent(stand_in('\n'.join(declarations.values())), 4),
            'ATTACH': indent(stand_in(attach.group(0))),
            'SET_VR_VIEW': indent(stand_in(set_vr)),
            'DETACH_METHOD': ('    func detachFromWindowController() {\n' + indent(stand_in(detach)) + '\n    }') if detach is not None else '',
            'DETACH_CALLS': indent(stand_in('\n'.join(calls))) if detaches and detach is not None else '',
            'ROI_COLOR': indent(stand_in(roi_color)),
            'SUBDRAW_START': indent(stand_in(start)),
            'CHECK_FOR_FRAME': indent(stand_in(check_for_frame)),
        }
        control = dict(actual, DECLARATIONS=indent('\n'.join(CONTROL[name] for name in properties), 4),
                       DETACH_METHOD='', DETACH_CALLS='', SUBDRAW_START='')

        control_results = run_probe(f'{view_name}-control', probe_source(control), tmp)
        if control_results is None:
            failures.append(f'the control probe of {view_name} does not compile')
            continue
        for scenario, result in control_results.items():
            if result[0] == 0 or 'released=1' not in result[1]:
                failures.append(f'the control of {view_name} ({scenario}), unretained references without detaching, '
                                f'did not crash after the controller was released ({crash(result)}): the probe cannot tell')
        results = run_probe(view_name, probe_source(actual), tmp)
        if results is None:
            failures.append(f'the probe of {view_name} does not compile with the sources\' declarations and code')
            continue
        what = {'draw': f'a {view_name} drawn', 'resize': f'a {view_name} resized'}
        for scenario, result in results.items():
            code, stdout, _ = result
            if 'not-attached' in stdout:
                failures.append(f'{view_name} did not take its controller from its window')
            if code != 0 or 'survived' not in stdout:
                reached = 'the controller' if scenario == 'draw' else 'the hidden VRView'
                failures.append(f'{what[scenario]} after its controller was released reached {reached} ({crash(result)})')
                continue
            if 'released=1' not in stdout:
                failures.append(f'closing the window did not release the stand-in of {controller_name}: something keeps it')
            if detaches and 'detached=1' not in stdout:
                failures.append(f'{view_name} still names its controller once -[{controller_name} windowWillClose:] detached it')
            opaque = re.search(r'opaque=(\d+)', stdout)
            if opaque and int(opaque.group(1)):
                failures.append(f'{what[scenario]} after its controller was released drew {opaque.group(1)} lines in its colours')

    # The curved MPR's draw gate: it must outlive the planes' controller.
    code = bare(read('CPRMPRDCMView'))
    closing = bare(body(read('CPRController'), r'override dynamic func windowWillClose\(_ notification: Notification\)') or '')
    lifecycles = re.findall(r'^[ \t]*(?:private[ \t]+)?var[ \t]+(\w+)[ \t]*:[ \t]*CPRRenderLifecycle\b', code, re.M)
    declarations = [declaration(code, name) for name in ['windowControllerIvar', '_vrView', '_delegate', *lifecycles]]
    held = '|'.join(['windowControllerIvar', *lifecycles])
    attach = re.findall(rf'^[ \t]*(?:self\.)?(?:{held})[ \t]*=(?!=)[^\n]*$', body(code, r'func setDCMPixList\(') or '', re.M)
    draw = body(code, r'override dynamic func draw\(_ rect: NSRect\)')
    detach = body(code, r'func detachFromWindowController\(\)')
    steps = [line.strip() for line in closing.split('\n') if 'renderLifecycle' in line or 'detachFromWindowController' in line]
    if None in declarations or not attach or draw is None or 'beginDraw' not in draw \
            or not any('beginClosing' in line for line in steps):
        failures.append('CPRMPRDCMView no longer draws, or CPRController no longer closes, through the render lifecycle '
                        'as this test expects; it needs a new look')
    else:
        gate = {
            'DECLARATIONS': indent(stand_in('\n'.join(declarations)), 4),
            'ATTACH': indent(stand_in('\n'.join(attach))),
            'DETACH_METHOD': ('    func detachFromWindowController() {\n' + indent(stand_in(detach)) + '\n    }') if detach is not None else '',
            'CLOSING': indent(stand_in('\n'.join(f'{line}\ndrawPlanes({json.dumps("after " + line)})' for line in steps))),
            'DRAW': indent(stand_in(draw)),
        }
        lifecycle_source = Path(tmp) / 'CPRRenderLifecycle.swift'
        lifecycle_source.write_text(read('CPRRenderLifecycle'))
        results = run_probe('CPRMPRDCMView-gate', probe_source(gate, GATE_PROBE), tmp,
                            extra=[lifecycle_source], scenarios=('gate',))
        if results is None:
            failures.append('the draw-gate probe of CPRMPRDCMView does not compile with the sources\' declarations and code')
        else:
            returncode, stdout, _ = results['gate']
            late = re.search(r'^late=(.*)$', stdout, re.M)
            if returncode != 0 or late is None:
                failures.append('a CPRMPRDCMView drawn while its window closed or once its controller was released '
                                f'crashed ({crash(results["gate"])})')
            elif 'released=1' not in stdout:
                failures.append('closing the window of the draw-gate probe did not release the stand-in of CPRController: '
                                'something keeps it')
            elif 'open=3' not in stdout:
                failures.append('the planes of the draw-gate probe did not paint while the window was open: the probe cannot tell')
            elif late.group(1):
                failures.append('a CPRMPRDCMView drawn ' + ', '.join(late.group(1).split('|'))
                                + ' painted: the closing of its window no longer refuses its draw')

if failures:
    print('\n'.join(sorted(set(failures), key=failures.index)), file=sys.stderr)
    sys.exit(1)
print('MPR and curved MPR planes: they let go of their controller and hidden VRView as the window closes; '
      'drawn or resized after both are released, they reach neither; the curved MPR planes paint nothing '
      'once their window starts closing')
