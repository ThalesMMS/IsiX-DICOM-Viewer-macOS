#!/usr/bin/env python3
"""Closing the fused 2D series dims the Volume Rendering Fusion item.

A VR window opened on a fused series enables the Fusion item's slider and
percentage. When the fused 2D viewer closes, it posts
OsirixCloseViewerNotification and VRView drops the fusion
(-setBlendingPixSource: nil), but VRController only handled the close of its
own 2D viewer: the slider and the percentage stayed enabled without a fusion,
and the controller kept pointing at the closed viewer, which it does not
retain.

The check runs: the -CloseViewerNotification: bodies of VRController.swift
and of the view (VRView+State.swift, a Swift extension of VRView; VRView.m in
a revision that still has it) are compiled, as they are, into stand-ins of the
two classes, with a real NSSlider and NSTextField as the
outlets, and the notification is posted with both observers registered, in
both orders, since NotificationCenter does not promise one:

- the close of another viewer changes nothing;
- the close of the fused viewer drops the view's fusion, forgets the fused
  viewer in the controller, and dims the slider and the percentage, which
  keeps showing the slider's value, as before the fusion; the window stays;
- the close of the VR's own 2D viewer still closes the window.

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
SIGNATURE = '- (void) CloseViewerNotification: (NSNotification*) note'
SWIFT_SIGNATURE = '    public final func closeViewerNotification(_ note: Notification!)'


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('latin1')


def body(text, signature):
    """The braces of the method whose line starts with `signature`, without them; None if absent."""
    at = text.find('\n' + signature)
    if at < 0:
        return None
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[opening + 1:index]
    return None


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang)', file=sys.stderr)
    sys.exit(SKIPPED)

controller_body = body(read('Horos/Sources/VRController.swift'), SWIFT_SIGNATURE)
try:
    view_body = body(read('Horos/Sources/VRView.m'), SIGNATURE)
except (OSError, subprocess.CalledProcessError):
    # The class is Swift since (VRView.swift).
    view_body = None
view_swift = None
if view_body is None:
    # The view's handler is Swift: the method, to the line that closes it at
    # the extension's indentation.
    try:
        state = read('Horos/Sources/VRView+State.swift')
    except subprocess.CalledProcessError:
        state = ''
    at = state.find('    @objc(CloseViewerNotification:)\n')
    if at >= 0:
        view_swift = state[at:state.index('\n    }\n', at) + 7]
if controller_body is None or (view_body is None and view_swift is None):
    print('VRController.swift or the view has no -CloseViewerNotification:; this test needs a new look',
          file=sys.stderr)
    sys.exit(1)

# The controller's stand-in: the state its handler reads, by the names it uses.
stub = r'''
import AppKit

@objc(StubWindow) public final class StubWindow: NSObject {
    @objc public var closed = false
    @objc public func close() { closed = true }
}

@objc(StubVRController) public final class StubVRController: NSObject {
    @objc public var viewer2DStorage: AnyObject?
    @objc public var blendingControllerStorage: AnyObject?
    @objc public var blendingPixList: NSMutableArray?
    @objc public var blendingSlider: NSSlider?
    @objc public var blendingPercentage: NSTextField?
    @objc public var window: StubWindow?
    @objc public var horosViewerClosing = false
    @objc public func offFullScreen() {}
    @objc(CloseViewerNotification:) public func closeViewerNotification(_ note: Notification!) {
CONTROLLER_BODY
    }
}
VIEW_STUB'''.replace('CONTROLLER_BODY', controller_body)

# The view's stand-in in Swift, around its Swift handler: the fused series'
# viewer it compares and the fusion it drops.
VIEW_STUB = '''
@objc(StubVRView) public final class StubVRView: NSObject {
    @objc public var horos_blendingController: AnyObject?
    @objc public var unfused: Int32 = 0
    @objc public var needsDisplay = false
    @objc public func setBlendingPixSource(_ bC: AnyObject?) {
        horos_blendingController = bC
        if bC == nil { unfused += 1 }
    }

VIEW_SWIFT}
'''
stub = stub.replace('VIEW_STUB', VIEW_STUB.replace('VIEW_SWIFT', view_swift) if view_swift else '')

probe = r'''
#import <AppKit/AppKit.h>

static NSString *OsirixCloseViewerNotification = @"OsirixCloseViewerNotification";

#import "Stub-Swift.h"

OBJC_VIEW


static int failures = 0;
static void check( BOOL condition, NSString *message)
{
    if( !condition) { failures++; fprintf( stderr, "FAIL: %s\n", message.UTF8String); }
}

int main( void)
{
    @autoreleasepool
    {
        [NSApplication sharedApplication];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        for( int order = 0; order < 2; order++)
        {
            NSString *context = order ? @"view observes first" : @"controller observes first";
            NSObject *viewer2D = [[NSObject new] autorelease];
            NSObject *fused = [[NSObject new] autorelease];
            NSObject *other = [[NSObject new] autorelease];
            NSMutableArray *fusedPixList = [NSMutableArray arrayWithObject: @"pix"];

            StubVRController *controller = [[StubVRController new] autorelease];
            StubVRView *view = [[StubVRView new] autorelease];
            controller.viewer2DStorage = viewer2D;
            controller.window = [[StubWindow new] autorelease];
            controller.blendingSlider = [[[NSSlider alloc] initWithFrame: NSMakeRect( 0, 0, 60, 20)] autorelease];
            controller.blendingPercentage = [[[NSTextField alloc] initWithFrame: NSMakeRect( 0, 0, 30, 14)] autorelease];
            [controller.blendingSlider setMinValue: 0];
            [controller.blendingSlider setMaxValue: 256];

            // A VR window opened on a fused series, as its initializer leaves it.
            controller.blendingControllerStorage = fused;
            controller.blendingPixList = fusedPixList;
            VIEW_BC(view) = fused;
            [controller.blendingSlider setEnabled: YES];
            [controller.blendingPercentage setEnabled: YES];
            [controller.blendingSlider setFloatValue: 200];
            [controller.blendingPercentage setStringValue: @"78%"];

            NSArray *observers = order ? @[view, controller] : @[controller, view];
            for( id observer in observers)
                [nc addObserver: observer selector: @selector(CloseViewerNotification:) name: OsirixCloseViewerNotification object: nil];

            [nc postNotificationName: OsirixCloseViewerNotification object: other userInfo: nil];
            check( controller.blendingControllerStorage == fused && VIEW_BC(view) == fused,
                   [NSString stringWithFormat: @"%@: another viewer's close dropped the fusion", context]);
            check( [controller.blendingSlider isEnabled] && [controller.blendingPercentage isEnabled],
                   [NSString stringWithFormat: @"%@: another viewer's close dimmed the Fusion item", context]);
            check( !controller.window.closed, [NSString stringWithFormat: @"%@: another viewer's close closed the VR window", context]);

            [nc postNotificationName: OsirixCloseViewerNotification object: fused userInfo: nil];
            check( VIEW_BC(view) == nil && VIEW_UNFUSED(view) == 1,
                   [NSString stringWithFormat: @"%@: VRView did not drop the fusion once (%d)", context, VIEW_UNFUSED(view)]);
            check( controller.blendingControllerStorage == nil,
                   [NSString stringWithFormat: @"%@: VRController still points at the closed fused viewer", context]);
            check( controller.blendingPixList == nil,
                   [NSString stringWithFormat: @"%@: VRController still holds the closed viewer's pixList", context]);
            check( ![controller.blendingSlider isEnabled],
                   [NSString stringWithFormat: @"%@: the Fusion slider stays enabled without a fusion", context]);
            check( ![controller.blendingPercentage isEnabled],
                   [NSString stringWithFormat: @"%@: the Fusion percentage stays enabled without a fusion", context]);
            check( [[controller.blendingPercentage stringValue] isEqualToString: @"78%"],
                   [NSString stringWithFormat: @"%@: the percentage reads \"%@\", not the slider's 78%%", context,
                    [controller.blendingPercentage stringValue]]);
            check( !controller.window.closed, [NSString stringWithFormat: @"%@: the fused viewer's close closed the VR window", context]);

            // The VR's own 2D viewer still closes the window.
            [nc postNotificationName: OsirixCloseViewerNotification object: viewer2D userInfo: nil];
            check( controller.window.closed, [NSString stringWithFormat: @"%@: the 2D viewer's close left the VR window open", context]);
            check( controller.horosViewerClosing, [NSString stringWithFormat: @"%@: the 2D viewer's close was not recorded before the VR window closed", context]);

            for( id observer in observers)
                [nc removeObserver: observer];
        }
    }
    return failures ? 1 : 0;
}
'''

# The Objective-C view of a revision that has it.
OBJC_VIEW = r'''
@interface StubVRView : NSObject { @public id blendingController; int unfused; }
@end
@implementation StubVRView
- (void) setBlendingPixSource:(id) bC { blendingController = bC; if( bC == nil) unfused++; }
- (void) setNeedsDisplay:(BOOL) flag {}
- (void) CloseViewerNotification: (NSNotification*) note
{
VIEW_BODY
}
@end
#define VIEW_BC(v) v->blendingController
#define VIEW_UNFUSED(v) v->unfused
'''
SWIFT_VIEW = '''
#define VIEW_BC(v) v.horos_blendingController
#define VIEW_UNFUSED(v) v.unfused
'''
probe = probe.replace('OBJC_VIEW', SWIFT_VIEW if view_swift else OBJC_VIEW.replace('VIEW_BODY', view_body))

with tempfile.TemporaryDirectory() as tmp:
    source = Path(tmp) / 'probe.m'
    binary = Path(tmp) / 'probe'
    source.write_text(probe, encoding='latin1')
    (Path(tmp) / 'Stub.swift').write_text(stub)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Stub', '-parse-as-library',
                            '-emit-objc-header-path', str(Path(tmp) / 'Stub-Swift.h'), '-c', str(Path(tmp) / 'Stub.swift'),
                            '-o', str(Path(tmp) / 'stub.o')], capture_output=True, text=True)
    if not build.returncode:
        build = subprocess.run(['xcrun', 'clang', '-c', '-fno-objc-arc', '-fmodules', '-w', '-I', tmp,
                                str(source), '-o', str(Path(tmp) / 'probe.o')], capture_output=True, text=True)
    if not build.returncode:
        build = subprocess.run(['xcrun', 'swiftc', str(Path(tmp) / 'stub.o'), str(Path(tmp) / 'probe.o'),
                                '-framework', 'AppKit', '-o', str(binary)], capture_output=True, text=True)
    if build.returncode:
        print(build.stderr, file=sys.stderr)
        print('FAIL: the probe does not compile', file=sys.stderr)
        sys.exit(1)
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    sys.stderr.write(run.stderr)
    if run.returncode:
        sys.exit(1)

print('PASS: closing the fused series drops the VR fusion, forgets the fused viewer and dims the Fusion item, '
      'whichever observer runs first')
