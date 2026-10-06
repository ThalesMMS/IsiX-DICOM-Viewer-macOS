#!/usr/bin/env python3
"""Closing an orthogonal MPR, PET-CT or endoscopy viewer releases its OrthogonalMPRController.

In Objective-C the controller's view outlets and its viewer were plain ivars:
the nib set them without retaining them, and each OrthogonalMPRView retained
the controller through -setController:, which -initWithPixList:::::: sends.
When the window's views went, the controller went with them, and with it the
reslicer and its copies of the pixels. The first Swift controller kept
the views as strong properties, a cycle with the views' retain of the
controller, and retained the endoscopy viewer its nib connects as `viewer`:
nothing was released on close, some 360 MB for the orthogonal MPR of a CT and
2.7 GB after a few PET-CT openings.

The check runs: the controller's former-ivar section and its nib setters, and
the view's `_controller` and -setController:, are compiled from the sources
into stand-in classes with the same Objective-C names. For each of
OrthogonalMPR.xib, PETCT.xib and Endoscopy.xib, a nib with the controllers
and outlet connections of the real one is compiled with ibtool and loaded as
the viewer loads it; each view gets -setController: as in
-initWithPixList::::::. Then:

- every outlet must be connected, the viewer outlet to the nib's owner;
- with the owner and the nib's objects gone but the views still up, the
  controllers must live on, retained by their views, as before;
- once the views go, every controller and every view must be released, and
  the owner must have been released with its last reference.

The same probe with plain ivar-like storage is the control: it must release
everything, or the probe cannot tell.

`<git revision>` as an optional argument reads that revision, the negative
control (a revision from before the fix fails).
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8')


def braces(text, start):
    """From `start` to the brace closing the first one after it, included."""
    opening = text.index('{', start)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[start:index + 1]
    raise ValueError('unbalanced braces')


if shutil.which('xcrun') is None or subprocess.run(['xcrun', '-f', 'ibtool'], capture_output=True).returncode:
    print('skipped: needs xcrun (swiftc) and ibtool', file=sys.stderr)
    sys.exit(SKIPPED)

controller = read('Horos/Sources/OrthogonalMPRController.swift')
view = read('Horos/Sources/OrthogonalMPRView.swift')

# The controller's former ivars and the nib's setters, as they are.
section = re.search(r'\n    // MARK: - The former instance variables\n(.*?)\n    // MARK: -\n', controller, re.S)
if not section or 'setOriginalView:' not in section.group(1) or 'setViewer:' not in section.group(1):
    print('OrthogonalMPRController.swift no longer keeps its ivars and nib setters where this test expects; '
          'it needs a new look', file=sys.stderr)
    sys.exit(1)
controller_storage = section.group(1)

stored = re.search(r'\n((?:[ \t]*///[^\n]*\n)*[ \t]*private [^\n]*var _controller: [^\n]*)\n', view)
setter_at = view.find('    @objc(setController:)')
if not stored or setter_at < 0:
    print('OrthogonalMPRView.swift no longer keeps its controller as this test expects; it needs a new look',
          file=sys.stderr)
    sys.exit(1)
view_storage = stored.group(1) + '\n\n' + braces(view, setter_at)

reinit = braces(controller, controller.index('    public dynamic func initWithPixList('))
for name in ('_originalView', '_xReslicedView', '_yReslicedView'):
    if f'{name}?.setController(self)' not in reinit:
        failures.append(f'-initWithPixList:::::: no longer sends -setController: to {name}, which kept the '
                        'controller alive as long as its views')

CONTROL_CONTROLLER = '''
    private unowned(unsafe) var _originalView: OrthogonalMPRView? = nil
    private unowned(unsafe) var _xReslicedView: OrthogonalMPRView? = nil
    private unowned(unsafe) var _yReslicedView: OrthogonalMPRView? = nil
    private unowned(unsafe) var _viewer: AnyObject? = nil
    @objc(setOriginalView:) private dynamic func setOriginalViewOutlet(_ view: OrthogonalMPRView?) { _originalView = view }
    @objc(setXReslicedView:) private dynamic func setXReslicedViewOutlet(_ view: OrthogonalMPRView?) { _xReslicedView = view }
    @objc(setYReslicedView:) private dynamic func setYReslicedViewOutlet(_ view: OrthogonalMPRView?) { _yReslicedView = view }
    @objc(setViewer:) private dynamic func setViewerOutlet(_ viewer: AnyObject?) { _viewer = viewer }
'''
CONTROL_VIEW = '''
    private var _controller: OrthogonalMPRController? = nil
    @objc(setController:) public dynamic func setController(_ newController: OrthogonalMPRController!) {
        if _controller !== newController { _controller = newController }
    }
'''

PROBE = r'''
import Cocoa

final class OrthogonalReslice: NSObject {}
final class ViewerController: NSObject {}

var controllersFreed = 0, viewsFreed = 0, ownersFreed = 0

@objc(OrthogonalMPRView)
class OrthogonalMPRView: NSView {
@@VIEW@@
    deinit { viewsFreed += 1 }
}
@objc(EndoscopyMPRView) final class EndoscopyMPRView: OrthogonalMPRView {}
@objc(OrthogonalMPRPETCTView) final class OrthogonalMPRPETCTView: OrthogonalMPRView {}

@objc(OrthogonalMPRController)
class OrthogonalMPRController: NSObject {
@@CONTROLLER@@
    deinit { controllersFreed += 1 }
}
@objc(OrthogonalMPRPETCTController) final class OrthogonalMPRPETCTController: OrthogonalMPRController {}

extension OrthogonalMPRController {
    // Read while they are alive: the storage may keep them unretained.
    func probeViews() -> [OrthogonalMPRView] { [_originalView, _xReslicedView, _yReslicedView].compactMap { $0 } }
    func probeViewer() -> AnyObject? { _viewer }
}

@objc(ProbeOwner) final class ProbeOwner: NSObject {
    deinit { ownersFreed += 1 }
}

_ = NSApplication.shared
let args = CommandLine.arguments
let expectedControllers = Int(args[2])!, expectsViewer = args[3] == "1"
var problems: [String] = []
var container: NSView? = nil
var controllersAlive = 0

autoreleasepool {
    let nib = NSNib(nibData: try! Data(contentsOf: URL(fileURLWithPath: args[1])), bundle: nil)
    var owner: ProbeOwner? = ProbeOwner()
    var objects: NSArray? = nil
    guard nib.instantiate(withOwner: owner, topLevelObjects: &objects) else { problems.append("the nib did not load"); return }
    let controllers = (objects ?? []).compactMap { $0 as? OrthogonalMPRController }
    container = (objects ?? []).compactMap { $0 as? NSView }.first
    if controllers.count != expectedControllers { problems.append("\(controllers.count) controllers, not \(expectedControllers)") }
    for controller in controllers {
        let views = controller.probeViews()
        if views.count != 3 { problems.append("a controller has \(views.count) view outlets connected, not 3") }
        // What -initWithPixList:::::: does with them.
        for view in views { view.setController(controller) }
        if expectsViewer && controller.probeViewer() !== owner { problems.append("the viewer outlet is not the nib's owner") }
    }
    owner = nil
    objects = nil
}
// The viewer and the nib's objects are gone; the window's views are still up.
controllersAlive = 0
autoreleasepool {
    for view in container?.subviews ?? [] {
        if let view = view as? OrthogonalMPRView, view.controller() != nil { controllersAlive += 1 }
    }
}
autoreleasepool { container = nil }
print(controllersAlive, controllersFreed, viewsFreed, ownersFreed, problems.joined(separator: "; "))
'''

# The view keeps its controller reachable for the check above.
ACCESSOR = '\n    @objc(controller) func controller() -> OrthogonalMPRController? { _controller }\n'


def nib_source(xib_text):
    """A xib with the controllers and outlet connections of `xib_text`, its views in one container."""
    tree = ET.fromstring(xib_text)
    elements = {element.get('id'): element for element in tree.iter() if element.get('id')}
    controllers, views = [], {}
    for element in tree.iter('customObject'):
        if element.get('customClass') not in ('OrthogonalMPRController', 'OrthogonalMPRPETCTController'):
            continue
        outlets = []
        for outlet in element.iter('outlet'):
            destination = outlet.get('destination')
            if destination != '-2':
                views[destination] = elements[destination].get('customClass')
            outlets.append((outlet.get('property'), destination, outlet.get('id')))
        controllers.append((element.get('id'), element.get('customClass'), outlets))
    subviews = ''.join(f'<customView id="{identifier}" customClass="{cls}"><rect key="frame" x="0.0" y="0.0" '
                       f'width="10" height="10"/></customView>' for identifier, cls in views.items())
    objects = ''.join(
        f'<customObject id="{identifier}" customClass="{cls}"><connections>'
        + ''.join(f'<outlet property="{p}" destination="{d}" id="{i}"/>' for p, d, i in outlets)
        + '</connections></customObject>' for identifier, cls, outlets in controllers)
    xib = f'''<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.Cocoa.XIB" version="3.0" toolsVersion="22505" targetRuntime="MacOSX.Cocoa" propertyAccessControl="none">
    <dependencies><plugIn identifier="com.apple.InterfaceBuilder.CocoaPlugin" version="22505"/></dependencies>
    <objects>
        <customObject id="-2" userLabel="File's Owner" customClass="ProbeOwner"/>
        <customObject id="-1" userLabel="First Responder" customClass="FirstResponder"/>
        <customObject id="-3" userLabel="Application" customClass="NSObject"/>
        <customView id="probe-container"><rect key="frame" x="0.0" y="0.0" width="100" height="100"/>
            <subviews>{subviews}</subviews></customView>
        {objects}
    </objects>
</document>
'''
    has_viewer = any(p == 'viewer' for _, _, outlets in controllers for p, _, _ in outlets)
    return xib, len(controllers), len(views), has_viewer


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    binaries = {}
    for name, controller_part, view_part in (('control', CONTROL_CONTROLLER, CONTROL_VIEW),
                                            ('sources', controller_storage, view_storage)):
        source = tmp / f'{name}.swift'
        source.write_text(PROBE.replace('@@CONTROLLER@@', controller_part).replace('@@VIEW@@', view_part + ACCESSOR))
        binary = tmp / name
        build = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-Onone', str(source), '-o', str(binary)],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr, file=sys.stderr)
            failures.append(f'the {name} probe does not compile')
            continue
        binaries[name] = binary

    for xib_name in ('OrthogonalMPR', 'PETCT', 'Endoscopy'):
        xib, controllers, views, has_viewer = nib_source(read(f'Horos/Resources/en.lproj/{xib_name}.xib'))
        if controllers == 0 or views != 3 * controllers:
            failures.append(f'{xib_name}.xib: {controllers} controllers and {views} views; this test needs a new look')
            continue
        if (xib_name == 'Endoscopy') != has_viewer:
            failures.append(f'{xib_name}.xib: the viewer outlet is {"" if has_viewer else "not "}there; '
                            'this test needs a new look')
        (tmp / f'{xib_name}.xib').write_text(xib)
        nib = tmp / f'{xib_name}.nib'
        compiled = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(tmp / f'{xib_name}.xib')],
                                  capture_output=True, text=True)
        if compiled.returncode or not nib.exists():
            failures.append(f'ibtool did not compile the {xib_name} probe nib: {compiled.stderr.strip()}')
            continue
        for name, binary in binaries.items():
            run = subprocess.run([str(binary), str(nib), str(controllers), str(int(has_viewer))],
                                 capture_output=True, text=True, timeout=60)
            if run.returncode:
                failures.append(f'the {name} probe on {xib_name} exited with {run.returncode}: {run.stderr.strip()}')
                continue
            fields = run.stdout.strip().split(' ', 4)
            alive, freed, views_freed, owners_freed = (int(value) for value in fields[:4])
            problems = fields[4] if len(fields) > 4 else ''
            what = f'{xib_name}.xib ({name})'
            if problems:
                failures.append(f'{what}: {problems}')
            if alive != views:
                failures.append(f'{what}: with the viewer gone and the views up, {alive} of {views} views still '
                                'had their controller')
            if freed != controllers or views_freed != views:
                failures.append(f'{what}: closing released {freed} of {controllers} controllers and {views_freed} '
                                f'of {views} views: the controller and its views keep each other')
            if owners_freed != 1:
                failures.append(f'{what}: the nib\'s owner, the viewer, was not released: '
                                'the controller retains it')
            if name == 'control' and (freed, views_freed, owners_freed) != (controllers, views, 1):
                failures.append(f'{what}: the control does not release everything; the probe cannot tell')

if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print('Orthogonal MPR, PET-CT and endoscopy nibs: the views keep their controller, and closing releases the '
      'controllers, their views and the viewer')
