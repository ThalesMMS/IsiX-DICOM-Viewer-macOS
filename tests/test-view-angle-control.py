#!/usr/bin/env python3
"""The camera's view angle can be set in Volume Rendering and in the 3D Endoscopy.

ViewAngleControl.swift is compiled as it is and driven against a stand-in view:
- it shows the view's angle and is inactive while the view says the angle
  cannot be set (parallel projection);
- the slider and the field set the view's angle, a typed value inside 10° to
  120°, and the control follows the view when the view announces a change;
- the projection's toolbar view is wrapped once, so every item shows the same
  pair; the Endoscopy's item is inserted once into a toolbar that remembers its
  items, and not again once removed.

The wiring is read from the sources: VRView keeps the angle a user, a saved
state or the Endoscopy chose through the camera resets that put VTK's 30° back
(vtkRenderer::ResetCamera), fits the volume again for that angle when it
resets, saves and restores the angle with the projection, announces every
change, and a Fly Thru camera carries its interpolated angle to the view; the
Perspective item of Volume Rendering and the Endoscopy toolbar show the
control; the text is in the twelve catalogs.
"""
import harness_defaults
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
failures = []


def source(path):
    return (root / path).read_bytes().decode('latin1')


def body(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}\n', start)]


# The class (VRView.swift) and what its subclasses reach (VRView+Subclasses.swift).
vr = source('Horos/Sources/VRView.swift') + source('Horos/Sources/VRView+Subclasses.swift')
# The projection, the angle, the standard views and the camera objects are
# Swift (VRView+Camera.swift), an extension of VRView; its methods end at the
# first line that closes them at the extension's indentation.
swift = (root / 'Horos/Sources/VRView+Camera.swift').read_text(encoding='utf-8')


def swift_body(signature, text=None):
    text = swift if text is None else text
    start = text.index(signature)
    return text[start:text.index('\n    }\n', start)]


# The camera reset and the saved 3D state are Swift too (VRView+State.swift).
state = (root / 'Horos/Sources/VRView+State.swift').read_text(encoding='utf-8')


# The camera is the VTK adapter's (IsiXVTKVolumeView): the view sets it through
# the adapter, which resets it.
vr_camera = source('Horos/Sources/Adapters/VTK/IsiXVTKVolumeCamera.mm')
projection = swift_body('    private func applyProjectionMode(_ mode: Int32) {')
if 'horos_chosenViewAngle = 0' not in projection or 'ViewAngleControl.didChangeNotification' not in projection:
    failures.append('a projection mode must start at its own angle and say so')
for case, angle in (('case 0:', '30'), ('case 2:', '60'), ('case 1:', '30')):
    if not re.search(re.escape(case) + r'\s*vtk\.cameraParallelProjection = (false|true)\s*vtk\.cameraViewAngle = ' + angle + r'\s', projection):
        failures.append(f'the starting angle of {case} changed')
if 'set { applyProjectionMode(newValue) }' not in swift_body('    @objc dynamic var projectionMode: Int32 {'):
    failures.append('setting projectionMode no longer applies the mode')
setter = swift_body('    private func applyViewAngle(_ angle: Double) {')
for needle in ('if !viewAngleAdjustable || !angle.isFinite { return }',
               'min(max(angle, ViewAngleControl.minimumAngle), ViewAngleControl.maximumAngle)',
               'horos_chosenViewAngle = angle', 'vtk.cameraViewAngle = angle',
               'ViewAngleControl.didChangeNotification'):
    if needle not in setter:
        failures.append(f'setViewAngle: lost: {needle}')
if 'set { applyViewAngle(newValue) }' not in swift_body('    @objc dynamic var viewAngle: Double {'):
    failures.append('setting viewAngle no longer applies the angle')
if 'return horos_vtk.hasCamera && horos_projectionMode != 1' not in swift_body('    @objc var viewAngleAdjustable: Bool {'):
    failures.append('the angle must be inactive in parallel projection')
reset = swift_body('    func horosResetCameraFitting(_ fit: Bool) {', state) + \
    body(vr_camera, '- (void)resetCameraKeepingViewAngle:(double)chosenViewAngle keep:(BOOL)keep fit:(BOOL)fit')
for needle in ('horos_vtk.resetCameraKeepingViewAngle(chosenViewAngle, keep: chosenViewAngle > 0 && horos_projectionMode != 1, fit: fit)',
               'aRenderer->ResetCamera();', 'aCamera->SetViewAngle( chosenViewAngle);',
               'aCamera->Dolly( sin( vtkMath::RadiansFromDegrees( chosenViewAngle / 2)) / sin( vtkMath::RadiansFromDegrees( defaultAngle / 2)));',
               'ViewAngleControl.didChangeNotification'):
    if needle not in reset:
        failures.append(f'the camera reset lost: {needle}')
# The view's own setup and the preset previews' (VRView+Subclasses.swift)
# reset their camera inside the adapter as they make it; any other reset of the
# view keeps the chosen angle.
if 'resetCamera(' in vr or 'resetCameraKeepingViewAngle' in vr or 'resetCamera(' in swift \
        or 'resetCameraKeepingViewAngle' in swift or 'resetCamera(' in state \
        or state.count('resetCameraKeepingViewAngle(') != 1:
    failures.append('a camera reset outside the view\'s own setup must keep the chosen angle')
if 'horosResetCameraFitting(true)' not in swift_body('    func resetImage(_ sender: Any?) {', state):
    failures.append('- (IBAction) resetImage:(id) sender does not keep the chosen angle')
if 'horosResetCameraFitting(false)' not in swift_body('    private func standardView(position: [Double], viewUp: [Double], dolly: Double?) {'):
    failures.append('the standard views do not keep the chosen angle')
for view in ('axView', 'saView', 'saViewOpposite', 'coView'):
    if 'standardView(position:' not in swift_body(f'    func {view}(_ sender: Any?) {{'):
        failures.append(f'-{view}: does not keep the chosen angle')
restore = swift_body('    func set3DStateDictionary(_ dict: [AnyHashable: Any]?) {', state)
if restore.find('viewAngle = (angle as? NSNumber)?.doubleValue ?? 0') < restore.find('projectionMode = (projection as? NSNumber)?.int32Value ?? 0'):
    failures.append('a saved angle must be restored after its projection mode')
if 'forKey: "ViewAngle" as NSString' not in swift_body('    func get3DStateDictionary() -> NSMutableDictionary? {', state):
    failures.append('the angle is not saved with the 3D state')
camera = swift_body('    func setCamera(_ cam: Camera!) {')
if 'vtk.cameraViewAngle = viewAngle' not in camera or 'ViewAngleControl.didChangeNotification' not in camera:
    failures.append('a Fly Thru camera does not bring its angle to the view')
flythru = source('Horos/Sources/FlyThru.swift')
if 'stepViewAngle.add(FlyThru.scalar(cam.viewAngle))' not in flythru or 'c.viewAngle = view' not in flythru:
    failures.append('the Fly Thru path does not interpolate the angle')
# The properties are declared, for the Objective-C, by the generated interface
# that VRView.h imports: @objc properties of the camera block, the angle
# settable, its availability read-only.
header = source('Horos/Sources/VRView.h')
if '#import "Horos-Swift.h"' not in header or not re.search(r'@objc dynamic var viewAngle: Double \{\n\s+get \{', swift) \
        or not re.search(r'@objc var viewAngleAdjustable: Bool \{\n(?!\s+(get|set) \{)', swift):
    failures.append('VRView.h does not declare the angle')

# VRController is Swift; its toolbar items are in VRController+Toolbar.swift.
controller = source('Horos/Sources/VRController+Toolbar.swift')
item = controller[controller.index('        case Self.perspectiveItem:'):]
item = item[:item.index('        case Self.', 10)]
if 'ViewAngleControl.wrapping($0, host: vrView' not in item or 'view: projection' not in item:
    failures.append('the Perspective item does not show the angle')
endoscopy = source('Horos/Sources/EndoscopyViewer.swift')
for needle in ('private let ViewAngleToolbarItemIdentifier = "ViewAngle"',
               'ViewAngleControl.reveal(item: ViewAngleToolbarItemIdentifier, in: toolbar, after: ShadingToolbarItemIdentifier,',
               'NSToolbarItem.Identifier(ViewAngleToolbarItemIdentifier),', 'ViewAngleToolbarItemIdentifier,\n',
               'if let savedAngle { vrView?.setViewAngle(savedAngle) }'):
    if needle not in endoscopy:
        failures.append(f'the Endoscopy lost: {needle.strip()}')

KEYS = ('View angle', 'Field of view of the camera, in degrees. Parallel projection has none.')
for language in ('en', 'ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans'):
    data = (root / 'Horos/Resources' / f'{language}.lproj/Localizable.strings').read_bytes()
    text = data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8')
    for key in KEYS:
        if len(re.findall(r'^"' + re.escape(key) + r'" = "[^"]+";$', text, re.M)) != 1:
            failures.append(f'{language}: "{key}" is not in the catalog once')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

DRIVER = r'''
import AppKit

extension NSNotification.Name {
    static let OsirixVRCameraDidChange = NSNotification.Name("VRCameraDidChange")
}

var failed = false
@MainActor func check(_ condition: Bool, _ what: String) {
    if !condition { FileHandle.standardError.write("FAIL: \(what)\n".data(using: .utf8)!); failed = true }
}

/// A stand-in VRView: an angle that only perspective accepts, clamped as the view clamps it.
@MainActor final class Host: NSObject {
    @objc dynamic var viewAngleAdjustable = true
    var angle = 30.0
    var writes = 0
    @objc var viewAngle: Double {
        get { angle }
        set { guard viewAngleAdjustable else { return }; angle = min(max(newValue, 10), 120); writes += 1 }
    }
    func announce() { NotificationCenter.default.post(name: Notification.Name(ViewAngleControl.didChangeNotification), object: self) }
}

final class Delegate: NSObject, NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        NSToolbarItem(itemIdentifier: id)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ["A", "Shading", "ViewAngle", "B"].map { .init($0) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ["A", "Shading", "B"].map { .init($0) } }
}

_ = NSApplication.shared
MainActor.assumeIsolated {
    let host = Host()
    let control = ViewAngleControl(host: host)
    let slider = control.subviews.compactMap { $0 as? NSSlider }.first!
    let field = control.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!

    check(slider.doubleValue == 30 && (field.objectValue as? NSNumber)?.doubleValue == 30, "the control shows the view's angle")
    check(slider.minValue == 10 && slider.maxValue == 120, "the slider covers 10° to 120°")
    check(slider.isEnabled && field.isEnabled, "the control is active in perspective")

    slider.doubleValue = 74.6
    _ = slider.sendAction(slider.action, to: slider.target)
    check(host.angle == 75, "the slider sets a whole angle: \(host.angle)")
    check((field.objectValue as? NSNumber)?.doubleValue == 75, "the field follows the slider")

    field.objectValue = NSNumber(value: 200)
    _ = field.sendAction(field.action, to: field.target)
    check(host.angle == 120, "a typed angle beyond the range is the largest: \(host.angle)")
    field.objectValue = NSNumber(value: 2)
    _ = field.sendAction(field.action, to: field.target)
    check(host.angle == 10, "a typed angle below the range is the smallest: \(host.angle)")
    check(ViewAngleControl.clamped(.nan) == nil && ViewAngleControl.clamped(.infinity) == nil, "no angle from a value that is not a number")

    host.angle = 60
    host.announce()
    check(slider.doubleValue == 60, "the control follows the view's announcement")
    host.angle = 45
    NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: host)
    check(slider.doubleValue == 45, "the control follows a camera change (a pinch narrows the angle)")
    NotificationCenter.default.post(name: Notification.Name(ViewAngleControl.didChangeNotification), object: Host())
    check(slider.doubleValue == 45, "another view's announcement is not this control's")

    host.viewAngleAdjustable = false
    host.announce()
    check(!slider.isEnabled && !field.isEnabled, "the control is inactive in parallel projection")
    let writes = host.writes
    slider.doubleValue = 90
    _ = slider.sendAction(slider.action, to: slider.target)
    check(host.angle == 45 && slider.doubleValue == 45, "parallel projection keeps no angle")
    check(host.writes == writes, "the control only asks; the view refuses")

    let projection = NSView(frame: NSRect(x: 0, y: 0, width: 93, height: 44))
    let wrapper = ViewAngleControl.wrapping(projection, host: host)
    check(ViewAngleControl.wrapping(projection, host: host) === wrapper, "one pair per projection view")
    check(projection.superview === wrapper && wrapper.subviews.count == 2, "the projection view comes first, the control after it")
    check(wrapper.frame.width >= projection.frame.width + control.frame.width, "the pair is as wide as both")

    // The projection view does not keep its pair: a pair no toolbar item
    // shows any more goes, and the projection view with it once its owner
    // lets it go. A view that kept its pair formed a cycle with it, which kept
    // the volume window's VRView alive through the projection matrix's bindings.
    weak var goneProjection: NSView?
    weak var gonePair: NSView?
    autoreleasepool {
        let unused = NSView(frame: NSRect(x: 0, y: 0, width: 93, height: 44))
        gonePair = ViewAngleControl.wrapping(unused, host: host)
        goneProjection = unused
    }
    check(gonePair == nil && goneProjection == nil, "a pair and its projection view are freed when nothing else holds them")

    let suite = "horos-view-angle-test-\(ProcessInfo.processInfo.processIdentifier)"
    UserDefaults.standard.removeObject(forKey: suite)
    let delegate = Delegate()
    let toolbar = NSToolbar(identifier: suite)
    toolbar.delegate = delegate
    toolbar.insertItem(withItemIdentifier: .init("A"), at: 0)
    toolbar.insertItem(withItemIdentifier: .init("Shading"), at: 1)
    toolbar.insertItem(withItemIdentifier: .init("B"), at: 2)
    ViewAngleControl.reveal(item: "ViewAngle", in: toolbar, after: "Shading", defaultsKey: suite)
    check(toolbar.items.map(\.itemIdentifier.rawValue) == ["A", "Shading", "ViewAngle", "B"], "the item is inserted after Shading: \(toolbar.items.map(\.itemIdentifier.rawValue))")
    toolbar.removeItem(at: 2)
    ViewAngleControl.reveal(item: "ViewAngle", in: toolbar, after: "Shading", defaultsKey: suite)
    check(!toolbar.items.contains { $0.itemIdentifier.rawValue == "ViewAngle" }, "a removed item is not inserted again")
    UserDefaults.standard.removeObject(forKey: suite)
}

if failed { exit(1) }
print("PASS: the control shows, sets, clamps and follows the view's angle, is inactive in parallel projection, and is placed once")
'''

with tempfile.TemporaryDirectory(prefix='horos-view-angle-') as folder:
    main = Path(folder) / 'main.swift'
    main.write_text(harness_defaults.SWIFT + DRIVER)
    binary = Path(folder) / 'check'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-cache-path', str(Path(folder) / 'modules'),
                            str(root / 'Horos/Sources/ViewAngleControl.swift'), str(main), '-o', str(binary)],
                           capture_output=True, text=True)
    if built.returncode:
        print(built.stderr, file=sys.stderr)
        sys.exit(1)
    ran = subprocess.run([str(binary)], capture_output=True, text=True)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        sys.exit(1)
    print(ran.stdout.strip())
print('PASS: the view keeps the chosen angle through camera resets, saves and restores it, and the Perspective and Endoscopy toolbars show it')
