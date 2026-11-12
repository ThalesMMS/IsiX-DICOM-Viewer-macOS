#!/usr/bin/env python3
"""Check CPR draw lifecycle and the host viewport geometry at 1x and 2x."""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

root = Path(__file__).resolve().parents[1]
# CPRMPRDCMView is Swift: its -checkForFrame is compiled, as it is
# written, into a Swift view that stands in for it.
mpr_source = source_text('CPRMPRDCMView')
frame_start = mpr_source.index('    @objc(checkForFrame)\n')
frame_end = mpr_source.index('\n    }\n', frame_start) + len('\n    }\n')
check_for_frame = mpr_source[frame_start:frame_end]
assert 'private dynamic func checkForFrame()' in check_for_frame
# -checkForFrame hands the hidden volume view the scale of the pane's window,
# read by the pane's own accessor: that comes along as written too.
scale_start = mpr_source.index('    private var backingScaleFactor: CGFloat {\n')
scale_end = mpr_source.index('\n    }\n', scale_start) + len('\n    }\n')
backing_scale_factor = mpr_source[scale_start:scale_end]
# What VRView does with that scale is its section on the scale of the window
# that shows its pictures, compiled as written into the view that stands in for
# it; only -prepareRenderWindow, which sizes the VTK window, is counted instead.
volume_source = source_text('VRView')
volume_start = volume_source.index('    // MARK: - Scale of the window that shows the pictures\n')
volume_end = volume_source.index('\n    // MARK: - ', volume_start + 1)
volume_host_scale = volume_source[volume_start:volume_end]
assert '@objc var hostBackingScale: CGFloat = 0 {' in volume_host_scale
assert volume_host_scale.count('public override func convertToBacking(') == 3
host = r'''
import Cocoa

/// The message the pane sends the hidden volume view. The product declares it
/// in an Objective-C protocol that the volume view adopts in a category.
@objc(CPRHostedVolumeMessages)
public protocol CPRHostedVolumeMessages: NSObjectProtocol {
    @objc(setHostBackingScale:) func setHostBackingScale(_ scale: CGFloat)
}

@objc(CPRFrameView)
public class CPRFrameView: NSView {
    @objc public var backingScale: CGFloat = 1
    var _vrView: (NSView & CPRHostedVolumeMessages)? = nil
    @objc public var vrView: NSView? {
        get { return _vrView }
        set { _vrView = newValue as? (NSView & CPRHostedVolumeMessages) }
    }

    public override func convertToBacking(_ rect: NSRect) -> NSRect {
        return NSMakeRect(rect.origin.x * backingScale, rect.origin.y * backingScale,
                          rect.size.width * backingScale, rect.size.height * backingScale)
    }

HOST_BACKING_SCALE_FACTOR
HOST_CHECK_FOR_FRAME
}

@objc(CPRHostedVolumeView)
public class CPRHostedVolumeView: NSView {
    @objc public private(set) var renderWindowPreparations = 0
    /// The scale the view had been given when its frame was last set.
    @objc public private(set) var scaleWhenFramed: CGFloat = -1

    @discardableResult
    func prepareRenderWindow() -> Bool {
        renderWindowPreparations += 1
        return true
    }

    public override var frame: NSRect {
        get { return super.frame }
        set {
            scaleWhenFramed = hostBackingScale
            super.frame = newValue
        }
    }

VOLUME_HOST_SCALE
}
'''
code = r'''
#import <Cocoa/Cocoa.h>
#import "CPRRender-Swift.h"

static int superCalls;
static int repaintsAsked;

@interface CPRFrameView (Test)
- (void)checkForFrame;
@end

// VRView's property, internal to Swift, whose setter is the pane's message; the
// protocol is adopted in a category, as VRView adopts the product's.
@interface CPRHostedVolumeView (Test)
@property (nonatomic) CGFloat hostBackingScale;
@end

@interface CPRHostedVolumeView (CPRHostedVolumeMessages) <CPRHostedVolumeMessages>
@end

@implementation CPRHostedVolumeView (CPRHostedVolumeMessages)
@end

// A window on a screen of a chosen scale, whatever the screens of this Mac are.
@interface ScaledWindow : NSWindow
@property (nonatomic) CGFloat scale;
@end

@implementation ScaledWindow
- (CGFloat)backingScaleFactor
{
    return _scale > 0 ? _scale : [super backingScaleFactor];
}
@end

// What the hidden volume view renders for a pane of `size` points on a screen
// of `scale`: that many pixels, whatever the scale of its own window, and the
// rect, size and point conversions alike.
static BOOL volumeRendersAt(CPRHostedVolumeView *volume, NSSize size, int scale)
{
    NSRect pixels = [volume convertRectToBacking:[volume bounds]];
    NSSize half = [volume convertSizeToBacking:NSMakeSize(size.width / 2, size.height / 2)];
    NSPoint centre = [volume convertPointToBacking:NSMakePoint(size.width / 2, size.height / 2)];
    return NSEqualRects(pixels, NSMakeRect(0, 0, size.width * scale, size.height * scale))
        && NSEqualSizes(half, NSMakeSize(size.width * scale / 2, size.height * scale / 2))
        && NSEqualPoints(centre, NSMakePoint(size.width * scale / 2, size.height * scale / 2));
}

// The real views take the lifecycle from their window controller, so a second
// Curved MPR window cannot gate this one.
@interface FakeCPRView : NSObject
@property (nonatomic, retain) HorosCPRRenderLifecycle *lifecycle;
- (void)drawRect;
@end

@implementation FakeCPRView
- (void)drawRect
{
    NSString *geo = [HorosCPRRenderLifecycle diagnoseSpacingX:1 spacingY:1];
    if ([geo isEqualToString:@"ready"] == NO) {
        NSLog(@"FAIL: ready geometry was refused: %@", geo);
        exit(1);
    }
    HorosCPRRenderDecision *decision = [self.lifecycle beginDrawNamed:@"mpr-native"];
    if (decision.accepted == NO) {
        // Returning paints nothing; the panel would stay blank unless the view
        // asks for another pass once this stack unwinds.
        if ([decision.phase isEqualToString:@"reentrant"])
            repaintsAsked++;
        return;
    }
    @try {
        superCalls++;
        [self drawRect];
    }
    @finally {
        [self.lifecycle endDrawNamed:@"mpr-native"];
    }
}
@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        ScaledWindow *host = [[ScaledWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(80, 30, 600, 500)];
        [[host contentView] addSubview:container];
        CPRFrameView *plane = [[CPRFrameView alloc] initWithFrame:NSMakeRect(20, 15, 400, 300)];
        [container addSubview:plane];
        // The volume view lives in a window of its own, never on screen.
        NSWindow *hidden = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 800, 600)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        CPRHostedVolumeView *volume = [[CPRHostedVolumeView alloc] initWithFrame:NSZeroRect];
        [[hidden contentView] addSubview:volume];
        plane.vrView = volume;
        if (plane.vrView != volume) {
            NSLog(@"FAIL: the pane did not take the volume view");
            return 1;
        }
        for (int scale = 1; scale <= 2; ++scale) {
            host.scale = scale;
            plane.backingScale = scale;
            long prepared = volume.renderWindowPreparations;
            [plane setFrame:NSMakeRect(20, 15, 400, 300)];
            [plane checkForFrame];
            if (volume.hostBackingScale != scale) {
                NSLog(@"FAIL: the volume view was given scale %g by a pane on a %dx screen",
                    volume.hostBackingScale, scale);
                return 1;
            }
            if (volume.scaleWhenFramed != scale) {
                NSLog(@"FAIL: at %dx the volume view was framed while its scale was still %g",
                    scale, volume.scaleWhenFramed);
                return 1;
            }
            if (volume.renderWindowPreparations != prepared + 1) {
                NSLog(@"FAIL: a pane newly at %dx sized the render window %ld times, expected once",
                    scale, (long)(volume.renderWindowPreparations - prepared));
                return 1;
            }
            if (!volumeRendersAt(volume, NSMakeSize(400, 300), scale)) {
                NSLog(@"FAIL: at %dx the volume view renders %@ for a pane of 400 x 300 points", scale,
                    NSStringFromRect([volume convertRectToBacking:[volume bounds]]));
                return 1;
            }
            NSRect expected = NSMakeRect(100, 45, 400, 300);
            if (!NSEqualRects([plane.vrView frame], expected)) {
                NSLog(@"FAIL: CPR renderer frame at %dx: %@, expected %@", scale,
                    NSStringFromRect([plane.vrView frame]), NSStringFromRect(expected));
                return 1;
            }
            [plane setFrame:NSMakeRect(30, 25, 320, 240)];
            [plane checkForFrame];
            expected = NSMakeRect(110, 55, 320, 240);
            if (!NSEqualRects([plane.vrView frame], expected)) {
                NSLog(@"FAIL: CPR renderer frame after resizing at %dx", scale);
                return 1;
            }
            if (!volumeRendersAt(volume, NSMakeSize(320, 240), scale)) {
                NSLog(@"FAIL: after resizing at %dx the volume view renders %@ for a pane of 320 x 240 points",
                    scale, NSStringFromRect([volume convertRectToBacking:[volume bounds]]));
                return 1;
            }
            if (volume.renderWindowPreparations != prepared + 1) {
                NSLog(@"FAIL: the scale given again at %dx sized the render window again", scale);
                return 1;
            }
        }

        // A pane out of its window has no scale to give: the volume view goes
        // back to the scale of its own window.
        NSView *own = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 240)];
        [[hidden contentView] addSubview:own];
        [plane removeFromSuperview];
        [plane checkForFrame];
        if (volume.hostBackingScale != 0) {
            NSLog(@"FAIL: a pane without a window gave the volume view scale %g", volume.hostBackingScale);
            return 1;
        }
        if (!NSEqualSizes([volume convertSizeToBacking:NSMakeSize(320, 240)],
                          [own convertSizeToBacking:NSMakeSize(320, 240)])) {
            NSLog(@"FAIL: without a host scale the volume view does not use its own window's");
            return 1;
        }

        HorosCPRRenderLifecycle *window = [[HorosCPRRenderLifecycle alloc] init];
        [window reset];
        [window beginOpeningResampled:NO];
        [window markOpen];
        [window markCurveReady];
        FakeCPRView *view = [FakeCPRView new];
        view.lifecycle = window;
        [view drawRect];
        if (superCalls != 1) {
            NSLog(@"FAIL: nested drawRect was not gated, superCalls=%d", superCalls);
            return 1;
        }
        if (repaintsAsked != 1) {
            NSLog(@"FAIL: the refused nested draw did not ask for another pass, repaintsAsked=%d", repaintsAsked);
            return 1;
        }
        NSString *nan = [HorosCPRRenderLifecycle diagnoseSpacingX:NAN spacingY:1];
        if ([nan isEqualToString:@"not a number"] == NO) {
            NSLog(@"FAIL: NaN spacing diagnosis: %@", nan);
            return 1;
        }

        // A second window closing must not stop this one from drawing.
        HorosCPRRenderLifecycle *other = [[HorosCPRRenderLifecycle alloc] init];
        [other reset];
        [other markOpen];
        [other beginClosing];
        [other markClosed];
        superCalls = 0;
        [view drawRect];
        if (superCalls != 1) {
            NSLog(@"FAIL: closing another CPR window blanked this one, superCalls=%d", superCalls);
            return 1;
        }

        [window beginClosing];
        HorosCPRRenderDecision *duringClose = [window beginDrawNamed:@"mpr-native"];
        if (duringClose.accepted) {
            NSLog(@"FAIL: draw during close was accepted");
            return 1;
        }
        [window markClosed];
        NSLog(@"PASS: CPR viewport stays in points at 1x/2x and after resizing; the volume view renders at the pane's scale; nested draw repaints; window lifecycle is isolated");
    }
    return 0;
}
'''
host = (host.replace('HOST_BACKING_SCALE_FACTOR', backing_scale_factor)
        .replace('HOST_CHECK_FOR_FRAME', check_for_frame)
        .replace('VOLUME_HOST_SCALE', volume_host_scale))
with tempfile.TemporaryDirectory(prefix='horos-cpr-render-native-') as d:
    p = Path(d)
    (p / 'test.m').write_text(code)
    (p / 'CPRFrameView.swift').write_text(host)
    subprocess.run([
        'xcrun', 'swiftc',
        str(root / 'Horos/Sources/CPRRenderLifecycle.swift'),
        # VRView's conversions are VTKRetinaGeometry's, which needs the other.
        str(root / 'Horos/Sources/VRInteractionGeometry.swift'),
        str(root / 'Horos/Sources/VTKRetinaGeometry.swift'),
        str(p / 'CPRFrameView.swift'),
        '-emit-library', '-module-name', 'CPRRender',
        '-emit-objc-header-path', str(p / 'CPRRender-Swift.h'),
        '-o', str(p / 'libCPRRender.dylib'),
    ], check=True)
    subprocess.run([
        'xcrun', 'clang', '-fno-objc-arc', '-framework', 'Cocoa',
        '-I', d, str(p / 'test.m'), '-L', d, '-lCPRRender',
        '-o', str(p / 'test'),
    ], check=True)
    subprocess.run([str(p / 'test')], check=True)
