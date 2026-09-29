#!/usr/bin/env python3
"""An auxiliary window whose controller is closing is not reused (#929).

The brush palette, the ROI manager, the histogram, plot, ROI info and ROI
defaults windows and the calcium scoring window autorelease their controller
in -windowWillClose:; it goes when the pool drains at the end of that pass of
the run loop. The lookups by nib name that reuse them (-brushTool:,
-roiGetManager:, -roiHistogram:, -roiGetInfo:, -roiDefaults:,
-calciumScoring:, the ROI window of a double click in DCMView, -histogram: and
-plot: of ROIWindow, -roiGetInfo: of MPR and CPR) only checked that the window
existed: a request in that pass showed the window again, and the controller
went with it on screen. As -[AppController FindViewer::] since #924, they now
skip a controller that answers YES to -windowWillClose, and a new one opens.

-roiGetManager: and -roiDefaults: run compiled with xcrun swiftc, taken from
the ViewerController extensions into a stand-in ViewerController, and
-brushTool: with clang, taken from ViewerController.m, over real windows whose
stand-in controllers have the nib name and the -windowWillClose flag. The
sources are read for the rest: each controller sets the flag in
-windowWillClose:, before its autorelease, and each other lookup skips a
closing controller. `<git revision>` as an optional argument reads the sources
of that revision, the negative control.
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
    encoding = 'utf-8' if path.endswith('.swift') else 'latin1'
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode(encoding)
    return (root / path).read_bytes().decode(encoding)


def method(source, signature, end='\n    }\n'):
    start = source.find(signature)
    if start < 0:
        return None
    return source[start:source.index(end, start) + len(end)]


def top_level(source, signature):
    return method(source, signature, end='\n}\n') or ''


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc, clang)', file=sys.stderr)
    sys.exit(2)

roi_source = read('Horos/Sources/ViewerController+ROI.swift')
editing_source = read('Horos/Sources/ViewerController+ROI+Editing.swift')
viewer_source = read('Horos/Sources/ViewerController.m')

# -- -roiGetManager: and -roiDefaults:, compiled -------------------------------

get_manager = method(roi_source, '    @objc(roiGetManager:)')
defaults = method(editing_source, '    @objc(roiDefaults:)')
if get_manager is None or defaults is None:
    print('FAIL: -roiGetManager: or -roiDefaults: is gone; this test needs a new look')
    sys.exit(1)
helpers = top_level(roi_source, 'fileprivate func objcIsEqualToString(') + '\n' + \
    top_level(roi_source, 'func horosWindowControllerIsClosing(')

swift = r'''import AppKit

%s

final class ViewerController: NSObject {}

extension ViewerController {
%s
%s
}

var created: [String: Int] = [:]

/// An auxiliary window as the lookups see it: a nib name and, as the
/// controllers of the app, the -windowWillClose flag that -windowWillClose:
/// sets before its autorelease.
class Auxiliary: NSWindowController {
    let nib: String
    @objc(windowWillClose) var closing = false
    init(_ nib: String) {
        self.nib = nib
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        created[nib, default: 0] += 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var windowNibName: NSNib.Name? { nib }
    func willClose() { closing = true; window?.close() }
}

final class ROIManagerController: Auxiliary {
    init(viewer: ViewerController) { super.init("ROIManager") }
    required init?(coder: NSCoder) { fatalError() }
}

final class ROIDefaultsWindow: Auxiliary {
    init(controller: ViewerController) { super.init("ROIDefaults") }
    required init?(coder: NSCoder) { fatalError() }
}

_ = NSApplication.shared
let viewer = ViewerController()
var failed = false

func check(_ nib: String, _ lookup: () -> Void) {
    lookup()
    precondition(created[nib] == 1, "\(nib): the first request does not open a window")
    lookup()
    precondition(created[nib] == 1, "\(nib): an open window is not reused")

    let first = NSApp.windows.first { $0.windowController?.windowNibName == nib }!.windowController as! Auxiliary
    first.willClose()
    precondition(NSApp.windows.contains { $0.windowController === first }, "the closed window left NSApp.windows; the test sees nothing")
    lookup()
    if created[nib] != 2 {
        print("\(nib): the window whose controller is closing is reused")
        failed = true
        return
    }
    lookup()
    precondition(created[nib] == 2, "\(nib): the window opened in place of the closing one is not reused")
    print("\(nib): a closing window is skipped, the new one is reused")
}

check("ROIManager") { viewer.roiGetManager(nil) }
check("ROIDefaults") { viewer.roiDefaults(nil) }
exit(failed ? 1 : 0)
''' % (helpers, get_manager, defaults)

# -- -brushTool:, compiled -------------------------------------------------------

brush = re.search(r'\n(-\(void\) brushTool:\(id\) sender\n\{.*?\n\})\n', viewer_source, re.S)
if brush is None:
    print('FAIL: -brushTool: is gone from ViewerController.m; this test needs a new look')
    sys.exit(1)

objc = r'''#import <Cocoa/Cocoa.h>

static int created = 0;

@interface ViewerController : NSObject
- (void) brushTool:(id) sender;
@end

@interface PaletteController : NSWindowController
{
@public
    BOOL windowWillClose;
}
- (id) initWithViewer:(ViewerController*) v;
- (BOOL) windowWillClose;
@end

@implementation PaletteController
- (id) initWithViewer:(ViewerController*) v
{
    NSWindow *window = [[[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 100, 100) styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing: NSBackingStoreBuffered defer: YES] autorelease];
    [window setReleasedWhenClosed: NO];
    if( self = [super initWithWindow: window]) { created++; [self showWindow: self]; }
    return self;
}
- (NSString*) windowNibName { return @"PaletteBrush"; }
- (BOOL) windowWillClose { return windowWillClose; }
@end

@implementation ViewerController
%s
@end

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        ViewerController *viewer = [[ViewerController alloc] init];
        [viewer brushTool: nil];
        [viewer brushTool: nil];
        if( created != 1) { printf("PaletteBrush: an open palette is not reused\n"); return 2; }
        PaletteController *palette = nil;
        for( NSWindow *w in [NSApp windows]) if( [[[w windowController] windowNibName] isEqualToString: @"PaletteBrush"]) palette = [w windowController];
        palette->windowWillClose = YES;
        [[palette window] close];
        [viewer brushTool: nil];
        if( created != 2) { printf("PaletteBrush: the palette whose controller is closing is reused\n"); return 1; }
        [viewer brushTool: nil];
        if( created != 2) { printf("PaletteBrush: the palette opened in place of the closing one is not reused\n"); return 2; }
        printf("PaletteBrush: a closing palette is skipped, the new one is reused\n");
    }
    return 0;
}
''' % brush.group(1)

with tempfile.TemporaryDirectory(prefix='horos-aux-window-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(swift)
    (p / 'main.m').write_text(objc)
    for label, build in (
        ('-roiGetManager: and -roiDefaults:', ['xcrun', 'swiftc', str(p / 'main.swift'), '-o', str(p / 'swift')]),
        ('-brushTool:', ['xcrun', 'clang', '-fno-objc-arc', '-framework', 'Cocoa', str(p / 'main.m'), '-o', str(p / 'objc')]),
    ):
        compiled = subprocess.run(build, capture_output=True, text=True)
        if compiled.returncode:
            print(compiled.stderr.strip()[-2000:])
            failures.append(f'{label} did not compile in the stand-in')
            continue
        run = subprocess.run([build[-1]], capture_output=True, text=True, timeout=60)
        print((run.stdout + run.stderr).strip()[-2000:])
        if run.returncode:
            failures.append(f'{label} reuses a window whose controller is closing')

# -- The flag, set by each controller in -windowWillClose: ------------------------

for name in ('PaletteController', 'ROIManagerController', 'HistogramWindow', 'ROIWindow', 'ROIDefaultsWindow', 'PlotWindow'):
    source = read(f'Horos/Sources/{name}.swift')
    if '@objc(windowWillClose) public private(set) var closing = false' not in source:
        failures.append(f'{name} does not answer -windowWillClose')
    body = re.search(r'public func windowWillClose\(_ notification: [A-Za-z!]+\) \{\n(.*?)\n    \}\n', source, re.S)
    if body is None:
        failures.append(f'the -windowWillClose: of {name} is gone; this test needs a new look')
        continue
    body = body.group(1)
    flag, release = body.find('closing = true'), body.find('.autorelease()')
    if flag < 0 or release < 0 or flag > release:
        failures.append(f'the -windowWillClose: of {name} does not set the flag before its autorelease')

calcium = read('Horos/Sources/CalciumScoringWindowController.m')
body = re.search(r'- \(void\)windowWillClose:\(NSNotification \*\)notification\n\{\n(.*?)\n\}\n', calcium, re.S)
if body is None:
    failures.append('the -windowWillClose: of CalciumScoringWindowController is gone; this test needs a new look')
elif not re.search(r'windowWillClose = YES;.*\[self autorelease\];', body.group(1), re.S):
    failures.append('the -windowWillClose: of CalciumScoringWindowController does not set the flag before its autorelease')
if not re.search(r'- \(BOOL\)windowWillClose\n\{\n\treturn windowWillClose;\n\}', calcium):
    failures.append('CalciumScoringWindowController does not answer -windowWillClose')

# -- The other lookups ------------------------------------------------------------

swift_skip = 'horosWindowControllerIsClosing('
objc_skip = '@selector(windowWillClose)] && ['
lookups = (
    ('Horos/Sources/ViewerController+ROI+Editing.swift', r'windowNibName, "Histogram"\)[^\n]*', swift_skip),
    ('Horos/Sources/ViewerController+ROI+Editing.swift', r'windowNibName, "ROI"\)[^\n]*', swift_skip),
    ('Horos/Sources/ROIWindow.swift', r'windowNibName == "Histogram"[^\n]*', swift_skip),
    ('Horos/Sources/ROIWindow.swift', r'windowNibName == "Plot"[^\n]*', swift_skip),
    ('Horos/Sources/MPRController.swift', r'windowNibName as String\?\) == "ROI"[^\n]*', swift_skip),
    ('Horos/Sources/CPRController.swift', r'windowNibName as String\?\) == "ROI"[^\n]*', swift_skip),
    ('Horos/Sources/ViewerController.m', r'isEqualToString:@"CalciumScoring"\][^\n]*', objc_skip),
    ('Horos/Sources/DCMView.m', r'isEqualToString:@"ROI"\][^\n]*', objc_skip),
)
for path, pattern, skip in lookups:
    found = re.findall(pattern, read(path))
    if len(found) != 1:
        failures.append(f'{len(found)} lookups /{pattern}/ in {path}, not 1; this test needs a new look')
    elif skip not in found[0]:
        failures.append(f'the lookup /{pattern}/ of {path} reuses a window whose controller is closing')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: an auxiliary window whose controller is closing is not reused')
