#!/usr/bin/env python3
"""A VRView never reaches its released VRController, nor draws its volume.

A VRController releases itself when its window closes: -windowWillClose:
autoreleases it. The window and its VRView can outlive it, and so can the
presets panel with its nine previews; AppKit still displays them. The view
keeps its controller unretained, in a stored field that plugins of the former
SDK read at its offset, so the field cannot be weak: a frame asked of the view
after the controller was released read the gantry tilt's mark from the freed
controller and crashed in objc_retain. The volume the view rendered was the
controller's too.

The check runs: the view's references and the code that reads them are
compiled as the sources declare them (the controller's field, what the view
does when its controller is released, what lets a frame be drawn, the start of
-drawRect: of the view and of the preset preview, the gantry tilt's mark read
before each frame) with the lines of the controller's deinit that tell its
views. A stand-in controller owns a window with a view and a preview, and
releases itself as the real one does when the window closes. Under
NSZombieEnabled:

- a view drawn while the window is open draws a frame and reads the mark;
- drawn while the window closes, the controller still alive, it draws none;
- once the controller is released the view names it no more, and drawn then
  it draws no frame and reaches nothing of the controller.

A control compiles the same code without what the controller's deinit tells
its views: it must crash, or the probe cannot tell. `<git revision>` as an
optional argument reads the sources of that revision.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
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
    match = re.search(rf'^[ \t]*(?:final[ \t]+)?(?:(?:weak|unowned(?:\(unsafe\))?)[ \t]+)?var[ \t]+{re.escape(name)}\b[^\n]*$',
                      text, re.M)
    return match.group(0).strip() if match else None


def indent(code, spaces=8):
    return '\n'.join((' ' * spaces + line.strip()) if line.strip() else '' for line in code.strip('\n').split('\n'))


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

PROBE = r'''
import AppKit

final class Viewer: NSObject {}

enum GantryTiltPolicy {
    static func correctedDegrees(of viewer: Viewer?) -> NSNumber? { viewer == nil ? nil : NSNumber(value: 12.5) }
    static func overlayText(degrees: Float) -> String { "tilt \(degrees)" }
}

/// The controller: it owns its view and its previews, and its 2D viewer.
final class VRController: NSWindowController, NSWindowDelegate {
    var vrView: VRView?
    var presetPreview1: VRPresetPreview?, presetPreview2: VRPresetPreview?, presetPreview3: VRPresetPreview?
    var presetPreview4: VRPresetPreview?, presetPreview5: VRPresetPreview?, presetPreview6: VRPresetPreview?
    var presetPreview7: VRPresetPreview?, presetPreview8: VRPresetPreview?, presetPreview9: VRPresetPreview?
    var selectedPresetPreview: VRPresetPreview?
    var horosVolumeReadAgain = false
    private let viewer = Viewer()
    private var willClose = false
    func viewer2D() -> Viewer! { viewer }
    func windowWillClose() -> Bool { willClose }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === window else { return }
        willClose = true
        closingFrames = drawAll()
        // The reference the controller's creator handed over to its window.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    deinit {
@@RELEASE@@
    }
}

class VRView: NSView {
    var frames = 0
    var marks = 0
    var minimumStep = 0

@@DECLARATIONS@@

    var namesController: Bool { horos_controller != nil }
    func setController(_ aController: VRController!) { horos_controller = aController }

@@RELEASED_METHOD@@

    var horosCanDrawFrame: Bool {
@@CAN_DRAW@@
    }

    func tiltMarkText() -> String? {
@@TILT_MARK@@
    }

    /// The start of -drawRect:, then the frame: the mark is read before it.
    override func draw(_ aRect: NSRect) {
@@DRAW_START@@
        if tiltMarkText() != nil { marks += 1 }
        frames += 1
    }
}

final class VRPresetPreview: VRView {
    var noNeedsDisplay = false
    var mapperUses = 0
    unowned(unsafe) var presetControllerOfSDK: VRController?

@@PREVIEW_RELEASED_METHOD@@

    /// The start of the preview's -drawRect:, then the main view's mapper.
    override func draw(_ dirtyRect: NSRect) {
@@PREVIEW_DRAW_START@@
        mapperUses += 1
        super.draw(dirtyRect)
    }
}

var view: VRView!
var preview: VRPresetPreview!
var keptWindow: NSWindow!          // the window outlives its controller
var keptPanel: NSWindow!           // and so does the presets panel
weak var released: VRController?
var closingFrames = -1

func drawAll() -> Int {
    let before = view.frames + preview.frames + preview.mapperUses
    view.draw(view.bounds)
    preview.draw(preview.bounds)
    return view.frames + preview.frames + preview.mapperUses - before
}

_ = NSApplication.shared
var openFrames = 0, openMarks = 0
autoreleasepool {
    let window = NSWindow(contentRect: NSMakeRect(-10000, -10000, 300, 300),
                          styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let panel = NSPanel(contentRect: NSMakeRect(-10000, -10000, 300, 300),
                        styleMask: [.titled], backing: .buffered, defer: true)
    panel.isReleasedWhenClosed = false
    let controller = VRController(window: window)
    _ = Unmanaged.passRetained(controller)   // handed over by its creator, given back by -windowWillClose:
    window.delegate = controller
    view = VRView(frame: NSMakeRect(0, 0, 100, 100))
    window.contentView?.addSubview(view)
    view.setController(controller)
    controller.vrView = view
    preview = VRPresetPreview(frame: NSMakeRect(0, 0, 50, 50))
    panel.contentView?.addSubview(preview)
    preview.setController(controller)
    preview.presetControllerOfSDK = controller
    controller.presetPreview4 = preview
    controller.selectedPresetPreview = preview
    keptWindow = window
    keptPanel = panel
    released = controller
    openFrames = drawAll()
    openMarks = view.marks
    window.close()
}

print("open=\(openFrames) marks=\(openMarks) closing=\(closingFrames) released=\(released == nil ? 1 : 0)")
fflush(stdout)
let named = (view.namesController ? 1 : 0) + (preview.namesController ? 1 : 0)
print("named=\(named)")
fflush(stdout)
print("late=\(drawAll()) sdk=\(preview.presetControllerOfSDK == nil ? 0 : 1)")
'''


def probe_source(parts):
    source = PROBE
    for key, value in parts.items():
        source = source.replace(f'@@{key}@@', value)
    return source


def run_probe(name, source, tmp):
    """(returncode, stdout, stderr), or None if it does not compile."""
    directory = Path(tmp) / name
    directory.mkdir()
    (directory / 'main.swift').write_text(source)
    binary = directory / 'probe'
    build = subprocess.run(['xcrun', 'swiftc', '-Onone', '-swift-version', '5', '-suppress-warnings',
                            str(directory / 'main.swift'), '-o', str(binary)],
                           capture_output=True, text=True, timeout=600)
    if build.returncode:
        print(f'--- {name} does not compile:', file=sys.stderr)
        print('\n'.join(build.stderr.strip().split('\n')[-15:]), file=sys.stderr)
        return None
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60,
                         env=dict(os.environ, NSZombieEnabled='YES'))
    return run.returncode, run.stdout, run.stderr


def crash(result):
    code, _, stderr = result
    zombie = 'deallocated instance' in stderr
    return f'exit {code}' + (', message sent to a deallocated instance' if zombie else '')


def before(text, marker):
    """What `text` runs before `marker`; None if the marker is absent."""
    position = (text or '').find(marker)
    return text[:position] if position >= 0 else None


view = bare(read('VRView'))
render = bare(read('VRView+Render'))
volume = bare(read('VRView+Volume'))
preview = bare(read('VRPresetPreview'))
controller = bare(read('VRController'))

field = declaration(view, 'horos_controller')
flag = declaration(view, 'horos_controllerReleased')
released_method = body(view, r'func horosControllerWasReleased\(\)')
can_draw = body(view, r'var horosCanDrawFrame: Bool')
tilt_mark = body(volume, r'func tiltMarkText\(\) -> String\?')
draw_start = before(body(render, r'override func draw\(_ aRect: NSRect\)'), 'if VRView.horos_drawLock == nil')
preview_released = body(preview, r'override func horosControllerWasReleased\(\)')
preview_draw_start = before(body(preview, r'override func draw\(_ dirtyRect: NSRect\)'), 'noNeedsDisplay = true')
deinit = body(controller, r'isolated deinit') or ''
release_lines = [match.group(0) for match in re.finditer(
    r'^[ \t]*vrView\?\.horosControllerWasReleased\(\)[ \t]*$'
    r'|^[ \t]*for (\w+) in \[[^\]]*\] \{\s*\1\?\.horosControllerWasReleased\(\)\s*\}', deinit, re.M)]

for what, found in [('the controller field of VRView', field), ('tiltMarkText() of VRView', tilt_mark),
                    ('-drawRect: of VRView before it takes the draw lock', draw_start is not None or None),
                    ('-drawRect: of VRPresetPreview', preview_draw_start is not None or None)]:
    if not found:
        failures.append(f'{what} is no longer as this test expects; it needs a new look')
if tilt_mark and 'horos_controller' not in tilt_mark:
    failures.append('tiltMarkText() no longer reads the controller; this test needs a new look')
if released_method is None or flag is None:
    failures.append('VRView cannot be told that its controller was released')
if can_draw is None or 'horosCanDrawFrame' not in (draw_start or ''):
    failures.append('-[VRView drawRect:] draws without asking whether its controller and volume are still there')
if 'horosCanDrawFrame' not in (preview_draw_start or ''):
    failures.append('-[VRPresetPreview drawRect:] uses the main view\'s mapper without asking whether it is still there')
previews = {f'presetPreview{index}' for index in range(1, 10)} | {'selectedPresetPreview'}
tells_views = any('vrView' in line for line in release_lines) \
    and any(previews <= set(re.findall(r'\w+', line)) for line in release_lines)
if not tells_views:
    failures.append('the deinit of VRController does not tell its view and its ten previews that it is released')

if not failures or (field and tilt_mark and draw_start is not None and preview_draw_start is not None):
    actual = {
        'DECLARATIONS': indent('\n'.join(line for line in [field, flag] if line), 4),
        'RELEASED_METHOD': ('    func horosControllerWasReleased() {\n' + indent(released_method) + '\n    }')
        if released_method is not None else '    func horosControllerWasReleased() {}',
        'CAN_DRAW': indent(can_draw) if can_draw is not None else '        true',
        'TILT_MARK': indent(tilt_mark),
        'DRAW_START': indent(draw_start),
        'PREVIEW_RELEASED_METHOD': ('    override func horosControllerWasReleased() {\n' + indent(preview_released) + '\n    }')
        if preview_released is not None else '',
        'PREVIEW_DRAW_START': indent(preview_draw_start),
        'RELEASE': indent('\n'.join(release_lines)),
    }
    with tempfile.TemporaryDirectory() as tmp:
        control = run_probe('control', probe_source(dict(actual, RELEASE='')), tmp)
        if control is None:
            failures.append('the control probe does not compile')
        elif control[0] == 0 or 'released=1' not in control[1]:
            failures.append('the control, a controller that tells its views nothing, did not crash after it was '
                            f'released ({crash(control)}): the probe cannot tell')
        result = run_probe('actual', probe_source(actual), tmp)
        if result is None:
            failures.append('the probe does not compile with the sources\' declarations and code')
        else:
            code, stdout, _ = result
            values = {key: int(value) for key, value in re.findall(r'(\w+)=(-?\d+)', stdout)}
            if values.get('open') != 3 or values.get('marks') != 1:
                failures.append('the view and the preview did not draw their frames and the mark while the window '
                                f'was open ({stdout.strip() or crash(result)}): the probe cannot tell')
            elif values.get('released') != 1:
                failures.append('closing the window did not release the stand-in of VRController: something keeps it')
            elif code != 0 or 'late' not in values:
                failures.append(f'a VRView asked for a frame after its controller was released reached it ({crash(result)})')
            else:
                if values.get('closing') != 0:
                    failures.append(f'the views drew {values.get("closing")} frames while their window closed')
                if values.get('named') != 0:
                    failures.append('a view still names its controller once the controller was released')
                if values.get('late') != 0:
                    failures.append(f'the views drew {values["late"]} frames of the volume after their controller was released')
                if values.get('sdk') != 0:
                    failures.append('a preview still names its presets controller once the controller was released')

if failures:
    print('\n'.join(sorted(set(failures), key=failures.index)), file=sys.stderr)
    sys.exit(1)
print('VRView and the preset previews: told by their controller as it is released, they name it no more; asked for '
      'a frame while the window closes or after the controller is released, they draw none and reach nothing of it')
