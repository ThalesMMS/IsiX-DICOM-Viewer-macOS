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


vr = source('Horos/Sources/VRView.mm')
projection = body(vr, '- (void) setProjectionMode: (int) mode')
if 'chosenViewAngle = 0;' not in projection or 'HorosViewAngleControl.didChangeNotification' not in projection:
    failures.append('a projection mode must start at its own angle and say so')
for case, angle in (('case 0:', '30'), ('case 2:', '60'), ('case 1:', '30')):
    if not re.search(re.escape(case) + r'\s*aCamera->SetParallelProjection\( (false|true)\);\s*aCamera->SetViewAngle\( ' + angle + r'\);', projection):
        failures.append(f'the starting angle of {case} changed')
setter = body(vr, '- (void) setViewAngle: (double) angle')
for needle in ('if( ![self viewAngleAdjustable] || !std::isfinite( angle)) return;',
               'MIN( MAX( angle, HorosViewAngleControl.minimumAngle), HorosViewAngleControl.maximumAngle)',
               'chosenViewAngle = angle;', 'aCamera->SetViewAngle( angle);',
               'HorosViewAngleControl.didChangeNotification'):
    if needle not in setter:
        failures.append(f'setViewAngle: lost: {needle}')
if 'return aCamera != nil && projectionMode != 1;' not in body(vr, '- (BOOL) viewAngleAdjustable'):
    failures.append('the angle must be inactive in parallel projection')
reset = body(vr, '- (void) horosResetCameraFitting:(BOOL) fit')
for needle in ('aRenderer->ResetCamera();', 'aCamera->SetViewAngle( chosenViewAngle);',
               'aCamera->Dolly( sin( vtkMath::RadiansFromDegrees( chosenViewAngle / 2)) / sin( vtkMath::RadiansFromDegrees( defaultAngle / 2)));',
               'HorosViewAngleControl.didChangeNotification'):
    if needle not in reset:
        failures.append(f'the camera reset lost: {needle}')
if vr.count('aRenderer->ResetCamera();') != 2:
    failures.append('a camera reset outside the view\'s own setup must keep the chosen angle')
for signature in ('- (IBAction) resetImage:(id) sender', '-(void) axView:(id) sender', '-(void) saView:(id) sender',
                  '-(void) saViewOpposite:(id) sender', '-(void) coView:(id) sender'):
    if 'horosResetCameraFitting:' not in body(vr, signature):
        failures.append(f'{signature} does not keep the chosen angle')
restore = body(vr, '-(void) set3DStateDictionary:(NSDictionary*) dict')
if restore.find('[self setViewAngle: [[dict objectForKey:@"ViewAngle"] doubleValue]];') < restore.find('[self setProjectionMode: [[dict objectForKey:@"Projection"] intValue]];'):
    failures.append('a saved angle must be restored after its projection mode')
if 'forKey:@"ViewAngle"];' not in body(vr, '-(NSMutableDictionary*) get3DStateDictionary'):
    failures.append('the angle is not saved with the 3D state')
camera = body(vr, '- (void) setCamera: (Camera*) cam')
if 'aCamera->SetViewAngle(viewAngle);' not in camera or 'HorosViewAngleControl.didChangeNotification' not in camera:
    failures.append('a Fly Thru camera does not bring its angle to the view')
flythru = source('Horos/Sources/FlyThru.swift')
if 'stepViewAngle.add(FlyThru.scalar(cam.viewAngle))' not in flythru or 'c.viewAngle = view' not in flythru:
    failures.append('the Fly Thru path does not interpolate the angle')
header = source('Horos/Sources/VRView.h')
if '@property (nonatomic) double viewAngle;' not in header or '@property (nonatomic, readonly) BOOL viewAngleAdjustable;' not in header:
    failures.append('VRView.h does not declare the angle')

controller = source('Horos/Sources/VRController.mm')
item = controller[controller.index('if ([itemIdent isEqualToString: PerspectiveToolbarItemIdentifier])'):]
item = item[:item.index('else if')]
if '[HorosViewAngleControl wrapping: perspectiveView host: view]' not in item:
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
