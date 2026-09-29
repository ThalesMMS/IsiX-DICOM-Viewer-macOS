#!/usr/bin/env python3
"""A viewer whose window is closing is not reused (#924).

The -windowWillClose: of an MPR, CPR, 3D or 2D orthogonal viewer autoreleases
the controller, which goes when the pool drains at the end of that pass of the
run loop. -[AppController FindViewer::] still returned it: a request for the
same viewer in that pass (-mprViewer: right after -performClose:, from the
keyboard, a plugin or AppleScript) showed its window again, the controller
was deallocated with the window on screen, and the views, whose
windowControllerIvar is unowned(unsafe), crashed in -roiColor:.

FindViewer now skips a controller that answers YES to -windowWillClose, and a
new viewer is opened. The method runs compiled with xcrun swiftc, taken from
AppController.swift into a stand-in AppController, over real windows whose
stand-in controllers have a nib name, a pixList and the -windowWillClose flag.
The sources are also read for the other half of the fix: each viewer that
FindViewer or the VR lookup of ViewerController.m can return sets the flag in
its -windowWillClose:, and the VR lookup skips a closing viewer.
`<git revision>` as an optional argument reads the sources of that revision,
the negative control.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('latin1' if not path.endswith('.swift') else 'utf-8')
    return (root / path).read_bytes().decode('latin1' if not path.endswith('.swift') else 'utf-8')


def method(source, signature, end='\n    }\n'):
    start = source.find(signature)
    if start < 0:
        return None
    return source[start:source.index(end, start) + len(end)]


# -- The lookup, compiled ------------------------------------------------------

application = read('Horos/Sources/AppController.swift')
find_viewer = method(application, '    @objc(FindViewer::) public func FindViewer(')
if find_viewer is None:
    print('FAIL: -FindViewer:: is gone from AppController.swift; this test needs a new look')
    sys.exit(1)
helpers = ''.join(method(application, '    private func %s(' % name) or '' for name in ('viewerWindowWillClose', 'idSendBool', 'idSendObject'))

main = r'''import AppKit

final class AppController: NSObject {
%s
%s
}

/// A viewer as FindViewer sees it: a nib name, a pixList and, for the classes
/// of OSIWindowController, -windowWillClose.
class Viewer: NSWindowController {
    let nib: String
    @objc let pixList: NSArray
    init(_ nib: String, _ pixList: NSArray) {
        self.nib = nib
        self.pixList = pixList
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var windowNibName: NSNib.Name? { nib }
}

final class ClosingViewer: Viewer {
    var closing = false
    @objc func windowWillClose() -> Bool { closing }
    /// What the -windowWillClose: of a 3D viewer does before its autorelease.
    func willClose() { closing = true; window?.close() }
}

_ = NSApplication.shared
let app = AppController()
let mprPix = NSArray(array: [1, 2, 3]), otherPix = NSArray(array: [1, 2, 3])

func found(_ nib: String, _ pix: NSArray) -> AnyObject? { app.FindViewer(nib, pix) as AnyObject? }

let mpr = ClosingViewer("MPR", mprPix)
mpr.showWindow(nil)
precondition(found("MPR", mprPix) === mpr, "an open viewer is not found")
precondition(found("MPR", otherPix) == nil, "a viewer is found by an equal pixList that is not its own")
precondition(found("CPR", mprPix) == nil, "a viewer is found under another nib")

// Hidden, not closing: found, as before.
let hidden = ClosingViewer("SR", mprPix)
precondition(found("SR", mprPix) === hidden, "a viewer whose window is not shown is not found")

// A controller that does not answer -windowWillClose is found, as before.
let plain = Viewer("Endoscopy", mprPix)
precondition(found("Endoscopy", mprPix) === plain, "a controller without -windowWillClose is not found")

// The MPR closes; in the same pass of the run loop it is still there, with its window.
mpr.willClose()
precondition(NSApp.windows.contains { $0.windowController === mpr }, "the closed window left NSApp.windows; the test sees nothing")
var closingFound = found("MPR", mprPix)
if closingFound === mpr {
    print("FindViewer returned the MPR viewer whose window is closing")
    exit(1)
}
precondition(closingFound == nil, "FindViewer returned another controller for a closing MPR")

// The new viewer opened in its place is the one found.
let reopened = ClosingViewer("MPR", mprPix)
reopened.showWindow(nil)
precondition(found("MPR", mprPix) === reopened, "the new MPR viewer is not the one found")
print("PASS: FindViewer skips a viewer whose window is closing")
''' % (find_viewer, helpers)

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='horos-find-viewer-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(main)
    build = subprocess.run(['xcrun', 'swiftc', str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode:
        print(build.stderr.strip()[-2000:])
        failures.append('-FindViewer:: did not compile in the stand-in')
    else:
        run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
        print((run.stdout + run.stderr).strip()[-2000:])
        if run.returncode:
            failures.append('-FindViewer:: returns a viewer whose window is closing')

# -- The flag, set by each viewer the lookups return -----------------------------

swift_viewers = ('MPRController', 'CPRController', 'OrthogonalMPRViewer', 'OrthogonalMPRPETCTViewer', 'EndoscopyViewer')
for name in swift_viewers:
    body = method(read(f'Horos/Sources/{name}.swift'), '    public override dynamic func windowWillClose(_ notification: Notification) {')
    if body is None:
        failures.append(f'-[{name} windowWillClose:] is gone; this test needs a new look')
    elif 'self.horos_windowWillClose = true' not in body:
        failures.append(f'-[{name} windowWillClose:] does not set the windowWillClose flag')

for name in ('SRController', 'VRController'):
    body = method(read(f'Horos/Sources/{name}.mm'), '- (void)windowWillClose:(NSNotification *)notification', end='\n}\n')
    if body is None:
        failures.append(f'-[{name} windowWillClose:] is gone; this test needs a new look')
    elif not re.search(r'\n\s*windowWillClose = YES;', body):
        failures.append(f'-[{name} windowWillClose:] does not set the windowWillClose flag')

# -- The VR lookup of ViewerController.m -----------------------------------------

viewer = read('Horos/Sources/ViewerController.m')
lookups = [m.start() for m in re.finditer(r'FindRelatedViewers:pixList\[0\]\]', viewer)]
if len(lookups) != 3:
    failures.append(f'{len(lookups)} VR lookups by FindRelatedViewers in ViewerController.m, not 3; this test needs a new look')
for start in lookups:
    test = re.search(r'if\( \[v\.windowNibName isEqualToString: @"VR"\][^\n]*', viewer[start:start + 400])
    if test is None:
        failures.append('a VR lookup of ViewerController.m no longer tests the nib; this test needs a new look')
    elif '[(VRController*) v windowWillClose] == NO' not in test.group(0):
        failures.append('a VR lookup of ViewerController.m reuses a viewer whose window is closing')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a viewer whose window is closing is not reused')
