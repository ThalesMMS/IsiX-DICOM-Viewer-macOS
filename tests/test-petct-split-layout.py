#!/usr/bin/env python3
"""The orthogonal PET-CT fusion window lays out its nine views and they hold (#806).

PETCT.xib, like Endoscopy.xib (#795), is an Auto Layout window whose split
views keep their panes aligned by copying frames: an outer horizontal
KFSplitView (modalitySplitView) holds three vertical KFSplitView rows, and
-[OrthogonalMPRPETCTViewer splitViewDidResizeSubviews:] copies the pane frames
of the row that changed into the other two rows.

The endoscopy defect does not apply as such: the viewer's delegate implements
-splitView:constrainMinCoordinate:ofSubviewAt: and its Max twin, so NSSplitView
already lays these split views out by frame, and KFSplitView's own
-resizeSubviewsWithOldSize: already falls back to -adjustSubviews. The rows
fought all the same. KFSplitView sets its subviews' frames itself, but they
were still NSSplitView's arranged views, which in this window carried no
autoresizing constraints, only NSSplitView.PreferredSize and .FallbackSize
constraints at the nib's 200 points. Each layout pass put panes back to 200
points, the viewer copied frames across the rows, and the next row's layout
undid them: some twenty resize notifications per pass without end (no
exception), rows that kept 200 points when the window grew, columns that
differed between rows, dividers that did not stay, and a full-window row that
did not fill the window. KFSplitView now keeps its subviews out of the arranged
views.

The shipped PETCT.xib window (en and ja-JP) is compiled with ibtool, with plain
views in place of the OrthogonalMPRPETCTView panes and a plain NSWindow for
OSIWindow, and the split views left as the real KFSplitView, built from
KFSplitView.swift and KFSplitView+CAPI.m. It is loaded by a double of
OrthogonalMPRPETCTViewer that holds the four split view outlets, the delegate
methods copied verbatim from the viewer's source (its "NSSplitview's delegate
methods" section), its -adjustHeightSplitView and -adjustWidthSplitView, which
-showWindow: calls, and -expandAllSplitViews. The viewer is Swift since #826:
the double is then a Swift class compiled with KFSplitView.swift; a revision
where the viewer is still OrthogonalMPRPETCTViewer.m gets the Objective-C
double. The
window, offscreen, is opened as the viewer opens it, resized, forced through
more layout passes, each divider is dragged with mouse events sent through the
window, one row is shown full window and back as -fullWindowPlan:: does, and
the run loop runs the display cycle. Exceptions are caught, including the one
raised from the display cycle. `<git revision>` as an optional argument reads
the sources from that revision: that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
import harness_defaults  # the harness's preferences stay in its own process (#923)
from copy import deepcopy
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    return (root / path).read_bytes()


def viewer_source():
    """The viewer's source and whether it is Swift (#826) or the former .m."""
    try:
        return read('Horos/Sources/OrthogonalMPRPETCTViewer.swift').decode('utf-8'), True
    except (FileNotFoundError, subprocess.CalledProcessError):
        # The legacy source mixes CRLF and LF and is not UTF-8.
        text = read('Horos/Sources/OrthogonalMPRPETCTViewer.m').decode('latin-1')
        return text.replace('\r\n', '\n').replace('\r', '\n'), False


source, swift_viewer = viewer_source()
if swift_viewer:
    section = re.search(r"\n    // MARK: - NSSplitview's delegate methods\n(.*?)\n    // MARK:", source, re.S)
    assert section, "OrthogonalMPRPETCTViewer.swift lost its NSSplitview's delegate methods section"
    delegate_methods = section.group(1)
    assert 'func splitViewDidResizeSubviews(' in delegate_methods, 'the rows are no longer kept aligned'
    adjust = re.search(r'\n(    @objc\(adjustHeightSplitView\)\n    public dynamic func adjustHeightSplitView\(\) \{\n.*?\n    \}\n\n'
                       r'    @objc\(adjustWidthSplitView\)\n    public dynamic func adjustWidthSplitView\(\) \{\n.*?\n    \})\n', source, re.S)
    assert adjust, 'OrthogonalMPRPETCTViewer.swift lost -adjustHeightSplitView or -adjustWidthSplitView'
    expand = re.search(r'\n(    @objc\(expandAllSplitViews\)\n    private dynamic func expandAllSplitViews\(\) \{\n.*?\n    \})\n', source, re.S)
    assert expand, 'OrthogonalMPRPETCTViewer.swift lost -expandAllSplitViews'
else:
    section = re.search(r"#pragma mark NSSplitview's delegate methods\n(.*?)\n#pragma mark", source, re.S)
    assert section, "OrthogonalMPRPETCTViewer.m lost its NSSplitview's delegate methods section"
    delegate_methods = section.group(1)
    assert 'splitViewDidResizeSubviews:' in delegate_methods, 'the rows are no longer kept aligned'
    adjust = re.search(r'\n(- \(void\) adjustHeightSplitView\n\{.*?\n\}\n\n- \(void\) adjustWidthSplitView\n\{.*?\n\})\n', source, re.S)
    assert adjust, 'OrthogonalMPRPETCTViewer.m lost -adjustHeightSplitView or -adjustWidthSplitView'
    expand = re.search(r'\n(- \(void\) expandAllSplitViews\n\{.*?\n\})\n', source, re.S)
    assert expand, 'OrthogonalMPRPETCTViewer.m lost -expandAllSplitViews'

OUTLETS = ('window', 'originalSplitView', 'xReslicedSplitView', 'yReslicedSplitView', 'modalitySplitView')


def window_xib(text):
    """The window of PETCT.xib, with plain views for the panes and the window."""
    source = ET.fromstring(text)
    document = ET.Element('document', source.attrib)
    for dependency in source.findall('dependencies'):
        document.append(deepcopy(dependency))
    objects = ET.SubElement(document, 'objects')
    owner = ET.SubElement(objects, 'customObject', id='-2', userLabel="File's Owner", customClass='OrthogonalMPRPETCTViewer')
    connections = ET.SubElement(owner, 'connections')
    for outlet in source.find('objects/customObject[@id="-2"]/connections'):
        if outlet.get('property') in OUTLETS:
            connections.append(deepcopy(outlet))
    assert len(connections) == len(OUTLETS), 'PETCT.xib lost a split view outlet'
    ET.SubElement(objects, 'customObject', id='-1', userLabel='First Responder', customClass='FirstResponder')
    ET.SubElement(objects, 'customObject', id='-3', userLabel='Application', customClass='NSObject')
    window = deepcopy(source.find('objects/window[@id="5"]'))
    classes = set()
    for node in window.iter():
        name = node.get('customClass')
        if name:
            classes.add(name)
            if node is window:
                del node.attrib['customClass']
            elif name != 'KFSplitView':
                node.set('customClass', 'HarnessPane')
        for group in list(node.findall('connections')):
            for outlet in list(group):
                if outlet.get('destination') != '-2':
                    group.remove(outlet)
            if len(group) == 0:
                node.remove(group)
    assert classes == {'OSIWindow', 'KFSplitView', 'OrthogonalMPRPETCTView'}, f'unexpected views in the window: {classes}'
    objects.append(window)
    return ET.tostring(document, encoding='unicode')


bridge = '''#define HOROS_BRIDGING_HEADER 1
#import "KFSplitView.h"
'''

# The Swift viewer's -splitViewWillResizeSubviews: asks the window for this; an
# NSWindow has none.
swift_bridge = bridge + '''
@interface N2OpenGLViewWithSplitsWindow : NSWindow
- (void)disableUpdatesUntilFlush;
@end
'''

# The double of the Swift viewer (#826): the same outlets and ivar, the methods
# copied from OrthogonalMPRPETCTViewer.swift, and what the harness drives.
swift_double = r'''
import Cocoa

@objc(OrthogonalMPRPETCTViewer)
public final class OrthogonalMPRPETCTViewer: NSWindowController, NSSplitViewDelegate {
    @IBOutlet private var originalSplitView: KFSplitView?
    @IBOutlet private var xReslicedSplitView: KFSplitView?
    @IBOutlet private var yReslicedSplitView: KFSplitView?
    @IBOutlet private var modalitySplitView: KFSplitView?
    private var minSplitViewsSize: Float = 0

ADJUST_METHODS

EXPAND_METHOD

DELEGATE_METHODS

    // The split view part of -fullWindowPlan:: (the rest drives the MPR controllers).
    @objc public func fullWindowRow(_ index: UInt) {
        self.expandAllSplitViews()
        for i in 0..<3 where UInt(i) != index {
            modalitySplitView!.setSubview(modalitySplitView!.subviews[i], isCollapsed: true)
        }
        self.resizeAll()
    }

    @objc public func restoreFromFullWindow() {
        self.expandAllSplitViews()
        self.adjustHeightSplitView()
        self.adjustWidthSplitView()
        self.resizeAll()
    }

    @objc public func resizeAll() {
        originalSplitView!.resizeSubviews(withOldSize: originalSplitView!.bounds.size)
        xReslicedSplitView!.resizeSubviews(withOldSize: xReslicedSplitView!.bounds.size)
        yReslicedSplitView!.resizeSubviews(withOldSize: yReslicedSplitView!.bounds.size)
        modalitySplitView!.resizeSubviews(withOldSize: modalitySplitView!.bounds.size)
    }

    @objc public var rows: [KFSplitView] { [originalSplitView!, xReslicedSplitView!, yReslicedSplitView!] }
    @objc public var modality: KFSplitView { modalitySplitView! }

    @objc public func open() {
        // As -initWithPixList::::: does.
        originalSplitView?.delegate = self
        xReslicedSplitView?.delegate = self
        yReslicedSplitView?.delegate = self
        modalitySplitView?.delegate = self
        minSplitViewsSize = 150.0
    }
}
'''

harness = r'''
#import <Cocoa/Cocoa.h>
#import "PETCTHarness-Swift.h"

NSString* const KFSplitViewDidCollapseSubviewNotification = @"KFSplitViewDidCollapseSubviewNotification";
NSString* const KFSplitViewDidExpandSubviewNotification = @"KFSplitViewDidExpandSubviewNotification";

static NSMutableArray<NSString *> *raised;
static NSUInteger resizes;

@interface HarnessApplication : NSApplication @end
@implementation HarnessApplication
// Where an exception raised by the display cycle's layout ends up once
// NSApplicationCrashOnExceptions is off.
- (void)reportException:(NSException *)exception { [raised addObject: exception.reason ?: exception.name]; }
@end

@interface HarnessPane : NSView @end
@implementation HarnessPane @end

// -splitViewWillResizeSubviews: asks the window for this; an NSWindow has none.
@interface N2OpenGLViewWithSplitsWindow : NSWindow
- (void)disableUpdatesUntilFlush;
@end

OBJC_DOUBLE_BEGIN
@interface OrthogonalMPRPETCTViewer : NSWindowController <NSSplitViewDelegate>
{
    IBOutlet KFSplitView *originalSplitView, *xReslicedSplitView, *yReslicedSplitView, *modalitySplitView;
    float minSplitViewsSize;
}
@end

@implementation OrthogonalMPRPETCTViewer
DELEGATE_METHODS
ADJUST_METHODS
EXPAND_METHOD
// The split view part of -fullWindowPlan:: (the rest drives the MPR controllers).
- (void)fullWindowRow:(NSUInteger)index
{
    [self expandAllSplitViews];
    for (NSUInteger i = 0; i < 3; i++)
        if (i != index) [modalitySplitView setSubview:[[modalitySplitView subviews] objectAtIndex:i] isCollapsed:YES];
    [self resizeAll];
}
- (void)restoreFromFullWindow
{
    [self expandAllSplitViews];
    [self adjustHeightSplitView];
    [self adjustWidthSplitView];
    [self resizeAll];
}
- (void)resizeAll
{
    [originalSplitView resizeSubviewsWithOldSize:[originalSplitView bounds].size];
    [xReslicedSplitView resizeSubviewsWithOldSize:[xReslicedSplitView bounds].size];
    [yReslicedSplitView resizeSubviewsWithOldSize:[yReslicedSplitView bounds].size];
    [modalitySplitView resizeSubviewsWithOldSize:[modalitySplitView bounds].size];
}
- (NSArray<KFSplitView *> *)rows { return @[originalSplitView, xReslicedSplitView, yReslicedSplitView]; }
- (KFSplitView *)modality { return modalitySplitView; }
- (void)open
{
    // As -initWithPixList::::: does.
    [originalSplitView setDelegate:self];
    [xReslicedSplitView setDelegate:self];
    [yReslicedSplitView setDelegate:self];
    [modalitySplitView setDelegate:self];
    minSplitViewsSize = 150.0;
}
@end
OBJC_DOUBLE_END

static int failures;
static void fail(NSString *reason) { failures++; printf("FAIL: %s\n", reason.UTF8String); }

static NSString *columns(OrthogonalMPRPETCTViewer *viewer) {
    NSMutableArray *rows = [NSMutableArray array];
    for (KFSplitView *row in viewer.rows) {
        NSArray *p = row.subviews;
        [rows addObject: [NSString stringWithFormat: @"%.0f | %.0f | %.0f",
                          NSWidth([p[0] frame]), NSWidth([p[1] frame]), NSWidth([p[2] frame])]];
    }
    NSArray *r = viewer.modality.subviews;
    return [NSString stringWithFormat: @"columns %@; rows %.0f / %.0f / %.0f", [rows componentsJoinedByString: @", "],
            NSHeight([r[0] frame]), NSHeight([r[1] frame]), NSHeight([r[2] frame])];
}

static NSArray *frames(OrthogonalMPRPETCTViewer *viewer) {
    NSMutableArray *all = [NSMutableArray array];
    for (NSView *row in viewer.modality.subviews) {
        [all addObject: [NSValue valueWithRect: row.frame]];
        for (NSView *pane in row.subviews) [all addObject: [NSValue valueWithRect: pane.frame]];
    }
    return all;
}

// Layout passes as the display cycle runs them, and more: every split view is
// marked as needing constraints and layout again, as a window move or a
// backing change would do. The panes must not move while nothing changes.
static BOOL settle(NSWindow *window, OrthogonalMPRPETCTViewer *viewer, NSString *step) {
    NSMutableArray *splits = [viewer.rows mutableCopy];
    [splits addObject: viewer.modality];
    @try {
        [window layoutIfNeeded];
        [window displayIfNeeded];
    } @catch (NSException *exception) {
        fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]);
        return NO;
    }
    NSArray *before = frames(viewer);
    resizes = 0;
    @try {
        for (int pass = 0; pass < 4; pass++) {
            for (NSSplitView *split in splits) {
                split.needsUpdateConstraints = YES;
                split.needsLayout = YES;
            }
            [window layoutIfNeeded];
            [window displayIfNeeded];
        }
    } @catch (NSException *exception) {
        fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]);
        return NO;
    }
    if (resizes > 40) {
        fail([NSString stringWithFormat: @"%@: the rows resized each other %lu times in four layout passes", step, (unsigned long)resizes]);
        return NO;
    }
    if (![frames(viewer) isEqual: before]) {
        fail([NSString stringWithFormat: @"%@: the panes moved in layout passes where nothing changed (%@)", step, columns(viewer)]);
        return NO;
    }
    return YES;
}

static void aligned(OrthogonalMPRPETCTViewer *viewer, NSString *step) {
    NSArray *first = viewer.rows[0].subviews;
    for (KFSplitView *row in viewer.rows) {
        NSArray *panes = row.subviews;
        for (int i = 0; i < 3; i++)
            if (fabs(NSMinX([first[i] frame]) - NSMinX([panes[i] frame])) > 0.5 || fabs(NSWidth([first[i] frame]) - NSWidth([panes[i] frame])) > 0.5)
                return fail([NSString stringWithFormat: @"%@: the columns of the three rows differ (%@)", step, columns(viewer)]);
        if (fabs(NSHeight([panes[0] frame]) - NSHeight(row.bounds)) > 0.5)
            return fail([NSString stringWithFormat: @"%@: a row's panes do not fill its height (%@)", step, columns(viewer)]);
    }
}

// Sizes along the axis that the split view divides, which should all be equal.
static void even(NSSplitView *split, NSString *what, OrthogonalMPRPETCTViewer *viewer, NSString *step) {
    CGFloat low = CGFLOAT_MAX, high = 0, total = 0;
    for (NSView *view in split.subviews) {
        CGFloat size = split.isVertical ? NSWidth(view.frame) : NSHeight(view.frame);
        low = MIN(low, size); high = MAX(high, size); total += size;
    }
    if (high - low > 0.02 * total)
        fail([NSString stringWithFormat: @"%@: the %@ of equal size did not resize alike (%@)", step, what, columns(viewer)]);
}

static NSEvent *mouse(NSEventType type, NSWindow *window, NSPoint location) {
    return [NSEvent mouseEventWithType: type location: location modifierFlags: 0 timestamp: 0
                          windowNumber: window.windowNumber context: nil eventNumber: 0 clickCount: 1 pressure: 1];
}

// A divider drag: a mouse down on the divider, sent through the window, then
// the dragged and up events that KFSplitView reads from the queue.
static void drag(KFSplitView *split, NSInteger divider, CGFloat position) {
    NSWindow *window = split.window;
    NSRect pane = [split.subviews[divider] frame];
    CGFloat from = (split.isVertical ? NSMaxX(pane) : NSMaxY(pane)) + split.dividerThickness / 2;
    CGFloat to = position + split.dividerThickness / 2;
    CGFloat minor = split.isVertical ? NSMidY(split.bounds) : NSMidX(split.bounds);
    NSPoint start = [split convertPoint: split.isVertical ? NSMakePoint(from, minor) : NSMakePoint(minor, from) toView: nil];
    NSPoint end = [split convertPoint: split.isVertical ? NSMakePoint(to, minor) : NSMakePoint(minor, to) toView: nil];
    [NSApp postEvent: mouse(NSEventTypeLeftMouseDragged, window, end) atStart: NO];
    [NSApp postEvent: mouse(NSEventTypeLeftMouseUp, window, end) atStart: NO];
    [window sendEvent: mouse(NSEventTypeLeftMouseDown, window, start)];
}


@interface SplitContractDelegate : NSObject <NSSplitViewDelegate>
@property NSUInteger collapsedCount, expandedCount, doubleClicks, finishedDrags;
@end
@implementation SplitContractDelegate
- (CGFloat)splitView:(NSSplitView *)split constrainMinCoordinate:(CGFloat)position ofSubviewAt:(NSInteger)index { return position + 100; }
- (CGFloat)splitView:(NSSplitView *)split constrainMaxCoordinate:(CGFloat)position ofSubviewAt:(NSInteger)index { return position - 100; }
- (BOOL)splitView:(NSSplitView *)split canCollapseSubview:(NSView *)pane { return YES; }
- (void)splitViewDidCollapseSubview:(NSNotification *)note { self.collapsedCount++; }
- (void)splitViewDidExpandSubview:(NSNotification *)note { self.expandedCount++; }
- (void)splitView:(id)split didDoubleClickInDivider:(int)index { self.doubleClicks++; }
- (void)splitView:(id)split didFinishDragInDivider:(int)index { self.finishedDrags++; }
@end

static void savedStateAndConstraints(void) {
    KFSplitView *split = [[KFSplitView alloc] initWithFrame:NSMakeRect(0, 0, 800, 400)];
    split.vertical = YES;
    for (int i = 0; i < 3; i++) [split addSubview:[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 400)]];
    [split adjustSubviews];
    SplitContractDelegate *delegate = [SplitContractDelegate new];
    split.delegate = delegate;
    for (NSString *name in @[@"kfRecalculateDividerRects", @"plistObjectWithSavedPosition", @"positionAutosaveName",
        @"savePositionUsingName:", @"setPositionAutosaveName:", @"setPositionFromPlistObject:",
        @"setPositionUsingName:", @"setSubview:isCollapsed:"]) {
        if (![split respondsToSelector:NSSelectorFromString(name)]) fail([@"SDK selector missing: " stringByAppendingString:name]);
    }
    if (![KFSplitView respondsToSelector:@selector(removePositionUsingName:)]) fail(@"SDK class selector missing");

    [split setPosition:-100 ofDividerAtIndex:0];
    if (![split isSubviewCollapsed:split.subviews[0]] || delegate.collapsedCount != 1)
        fail(@"collapse state and delegate notification lost");
    [split setPosition:70 ofDividerAtIndex:0];
    if ([split isSubviewCollapsed:split.subviews[0]] || fabs(split.subviews[0].frame.size.width - 100) > 1 || delegate.expandedCount != 1)
        fail(@"minimum size and expand notification lost");
    [split setPosition:100000 ofDividerAtIndex:1];
    if (![split isSubviewCollapsed:split.subviews[2]]) fail(@"last pane does not collapse");
    [split setPosition:700 ofDividerAtIndex:1];
    if ([split isSubviewCollapsed:split.subviews[2]] || split.subviews[2].frame.size.width < 100)
        fail(@"maximum size does not preserve the last pane minimum");

    [split setSubview:split.subviews[0] isCollapsed:YES];
    [split resizeSubviewsWithOldSize:split.bounds.size];
    NSDictionary *saved = [split plistObjectWithSavedPosition];
    [split setSubview:split.subviews[0] isCollapsed:NO];
    [split adjustSubviews];
    [split setPositionFromPlistObject:saved];
    if (![saved isEqual:[split plistObjectWithSavedPosition]]) fail(@"version 2 geometry/collapse restoration differs");
    [split setPositionFromPlistObject:@{@"version": @99}];
    if (![saved isEqual:[split plistObjectWithSavedPosition]]) fail(@"invalid state changed panes");

    NSString *name = [@"horos-split-test-" stringByAppendingString:NSUUID.UUID.UUIDString];
    KFSplitView *other = [[KFSplitView alloc] initWithFrame:split.frame];
    if (![split setPositionAutosaveName:name] || ![split setPositionAutosaveName:name] || [other setPositionAutosaveName:name])
        fail(@"autosave ownership is not exclusive/idempotent");
    [split resizeSubviewsWithOldSize:split.bounds.size];
    saved = [split plistObjectWithSavedPosition];
    [split setSubview:split.subviews[0] isCollapsed:NO];
    if (![split setPositionUsingName:name] || ![saved isEqual:[split plistObjectWithSavedPosition]])
        fail(@"autosave failed to restore geometry/collapse state");
    [split setPositionAutosaveName:nil];
    if (![other setPositionAutosaveName:name]) fail(@"autosave name was not released");
    [other setPositionAutosaveName:nil];
    [KFSplitView removePositionUsingName:name];
    if ([other setPositionUsingName:name]) fail(@"removed autosave still restores");

    NSError *error = nil;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:split requiringSecureCoding:NO error:&error];
    KFSplitView *decoded = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:archive error:&error];
    if (!decoded || error || ![saved isEqual:[decoded plistObjectWithSavedPosition]])
        fail([@"NSCoding did not preserve state: " stringByAppendingString:error.description ?: @"geometry mismatch"]);

    // Rapid resizing in both orientations remains finite and fills the bounds.
    split.delegate = nil;
    for (int direction = 0; direction < 2; direction++) {
        split.vertical = direction;
        for (int i = 0; i < 100; i++) {
            [split setFrameSize:NSMakeSize(700 + i % 7, 500 + i % 9)];
            [split resizeSubviewsWithOldSize:split.bounds.size];
            CGFloat total = 2 * split.dividerThickness;
            for (NSView *pane in split.subviews) if (![split isSubviewCollapsed:pane]) {
                CGFloat size = split.vertical ? pane.frame.size.width : pane.frame.size.height;
                if (!isfinite(size) || size < 0) fail(@"rapid resize produced invalid size");
                total += size;
            }
            CGFloat available = split.vertical ? split.bounds.size.width : split.bounds.size.height;
            if (fabs(total - available) > 0.01) fail(@"rapid resize no longer fills bounds");
        }
    }
    // A split resized smaller in small steps and back, through a size of a few
    // points too, keeps each pane's share: the frames at the end are those at
    // the start. Weights read from the frames the last step had rounded gave
    // every remainder to the same pane.
    for (int direction = 0; direction < 2; direction++) {
        split.vertical = direction;
        [split setFrameSize:NSMakeSize(907, 613)];
        [split resizeSubviewsWithOldSize:split.bounds.size];
        [split setPosition:(direction ? 211 : 157) ofDividerAtIndex:0];
        NSMutableArray *before = [NSMutableArray array];
        for (NSView *pane in split.subviews) [before addObject:NSStringFromRect(pane.frame)];
        CGFloat first = direction ? split.subviews[0].frame.size.width : split.subviews[0].frame.size.height;
        CGFloat whole = (direction ? 907 : 613) - 2 * split.dividerThickness;
        for (int i = 0; i <= 360; i++) {
            int k = i <= 180 ? i : 360 - i;
            [split setFrameSize:NSMakeSize(907 - 5 * k, 613 - 3.3 * k)];
            [split resizeSubviewsWithOldSize:split.bounds.size];
            if (k == 100) {
                CGFloat available = (direction ? split.bounds.size.width : split.bounds.size.height) - 2 * split.dividerThickness;
                CGFloat now = direction ? split.subviews[0].frame.size.width : split.subviews[0].frame.size.height;
                if (fabs(now - available * first / whole) > 1.01)
                    fail([NSString stringWithFormat:@"a pane lost its share while the split shrank (%g of %g, was %g of %g)", now, available, first, whole]);
            }
        }
        NSMutableArray *after = [NSMutableArray array];
        for (NSView *pane in split.subviews) [after addObject:NSStringFromRect(pane.frame)];
        if (![before isEqual:after])
            fail([NSString stringWithFormat:@"shrinking and growing back changed the panes: %@ became %@",
                  [before componentsJoinedByString:@" "], [after componentsJoinedByString:@" "]]);
    }
    [split setPosition:10 ofDividerAtIndex:-1];
    [split setPosition:10 ofDividerAtIndex:99];
    [split setPosition:NAN ofDividerAtIndex:0];
    [split setSubviews:@[]];
    [split adjustSubviews];
    [split kfRecalculateDividerRects];
    printf("state/constraints: collapse, min/max, restoration, autosave, NSCoding, 200 rapid resizes, shares kept across 720 resizes passed\n");
}

int main(int argc, char **argv) {

    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"NSApplicationCrashOnExceptions"];
        raised = [NSMutableArray array];
        [HarnessApplication sharedApplication];
        savedStateAndConstraints();
        [[NSNotificationCenter defaultCenter] addObserverForName: NSSplitViewDidResizeSubviewsNotification object: nil queue: nil
                                                      usingBlock: ^(NSNotification *note) { resizes++; }];
        OrthogonalMPRPETCTViewer *viewer = [OrthogonalMPRPETCTViewer alloc];
        viewer = [viewer initWithWindowNibPath: [NSString stringWithUTF8String: argv[1]] owner: viewer];
        NSWindow *window = viewer.window;
        [viewer open];
        [window setFrameOrigin: NSMakePoint(-20000, -20000)];
        // As -showWindow: does: the window, then equal rows and columns.
        [window orderFront: nil];
        @try {
            [viewer adjustHeightSplitView];
            [viewer adjustWidthSplitView];
        } @catch (NSException *exception) { fail([NSString stringWithFormat: @"opening: %@", exception.reason]); }
        if (settle(window, viewer, @"opening")) {
            aligned(viewer, @"opening");
            even(viewer.rows[0], @"columns", viewer, @"opening");
            even(viewer.modality, @"rows", viewer, @"opening");
        }

        NSArray *sizes = @[[NSValue valueWithSize: NSMakeSize(1512, 944)], [NSValue valueWithSize: NSMakeSize(900, 700)],
                           [NSValue valueWithSize: NSMakeSize(1920, 1080)]];
        for (NSValue *size in sizes) {
            NSString *step = [NSString stringWithFormat: @"window %@", NSStringFromSize(size.sizeValue)];
            NSRect frame = window.frame;
            frame.size = size.sizeValue;
            @try { [window setFrame: frame display: YES]; }
            @catch (NSException *exception) { fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]); continue; }
            if (!settle(window, viewer, step)) continue;
            aligned(viewer, step);
            even(viewer.rows[0], @"columns", viewer, step);
            even(viewer.modality, @"rows", viewer, step);
        }

        // Dragging a divider of one row moves the other rows' divider with it,
        // and it holds; dragging a divider between rows holds too.
        NSArray *names = @[@"original", @"x resliced", @"y resliced"];
        for (NSUInteger r = 0; r < 3; r++) {
            KFSplitView *split = viewer.rows[r];
            CGFloat position = round(NSWidth(split.bounds) / 4);
            NSString *step = [NSString stringWithFormat: @"%@ row divider to %.0f", names[r], position];
            @try { drag(split, 0, position + 10 * r); }
            @catch (NSException *exception) { fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]); continue; }
            if (!settle(window, viewer, step)) continue;
            aligned(viewer, step);
            if (fabs(NSWidth([split.subviews[0] frame]) - (position + 10 * r)) > 1)
                fail([NSString stringWithFormat: @"%@: the divider did not stay (%@)", step, columns(viewer)]);
        }
        {
            KFSplitView *split = viewer.modality;
            CGFloat position = round(NSHeight(split.bounds) / 4);
            NSString *step = [NSString stringWithFormat: @"row divider to %.0f", position];
            @try { drag(split, 0, position); }
            @catch (NSException *exception) { fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]); }
            if (settle(window, viewer, step)) {
                aligned(viewer, step);
                if (fabs(NSHeight([split.subviews[0] frame]) - position) > 1)
                    fail([NSString stringWithFormat: @"%@: the divider did not stay (%@)", step, columns(viewer)]);
            }
        }

        // One row fills the window, as the full-window command does, and the
        // three come back alike.
        {
            NSString *step = @"x resliced row full window";
            @try { [viewer fullWindowRow: 1]; }
            @catch (NSException *exception) { fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]); }
            if (settle(window, viewer, step)) {
                // KFSplitView keeps the dividers of the collapsed rows.
                NSRect bounds = viewer.modality.bounds;
                CGFloat divider = viewer.modality.dividerThickness;
                NSRect expected = NSMakeRect(0, divider, NSWidth(bounds), NSHeight(bounds) - 2 * divider);
                NSView *row = viewer.modality.subviews[1];
                if (!NSEqualRects(row.frame, expected))
                    fail([NSString stringWithFormat: @"%@: the row does not fill the window (%@)", step, NSStringFromRect(row.frame)]);
                for (NSUInteger i = 0; i < 3; i++)
                    if (i != 1 && NSIntersectsRect([viewer.modality.subviews[i] frame], bounds))
                        fail([NSString stringWithFormat: @"%@: row %lu is still on screen", step, (unsigned long)i]);
                aligned(viewer, step);
            }
            step = @"back from full window";
            @try { [viewer restoreFromFullWindow]; }
            @catch (NSException *exception) { fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]); }
            if (settle(window, viewer, step)) {
                aligned(viewer, step);
                even(viewer.rows[0], @"columns", viewer, step);
                even(viewer.modality, @"rows", viewer, step);
            }
        }

        // The window changes size by a lot at once, again and again, as zoom,
        // tiling and a change of screen make it: the three rows keep their
        // thirds. The middle row used to give up some height at each change
        // and end at zero.
        {
            for (int i = 0; i < 60; i++) {
                NSRect frame = window.frame;
                frame.size = i % 2 ? NSMakeSize(1200, 850) : NSMakeSize(700, 520);
                NSString *step = [NSString stringWithFormat: @"abrupt size %d", i];
                @try { [window setFrame: frame display: YES]; }
                @catch (NSException *exception) { fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]); break; }
                if (!settle(window, viewer, step)) break;
                if (i % 6 == 5 || i == 59) {
                    aligned(viewer, step);
                    even(viewer.modality, @"rows", viewer, step);
                    even(viewer.rows[0], @"columns", viewer, step);
                }
            }
        }

        {
            KFSplitView *row = viewer.rows[0];
            id oldDelegate = row.delegate;
            SplitContractDelegate *delegate = [SplitContractDelegate new];
            row.delegate = delegate;
            drag(row, 0, 300);
            CGFloat divider = NSMaxX(row.subviews[0].frame) + row.dividerThickness / 2;
            NSPoint location = [row convertPoint:NSMakePoint(divider, NSMidY(row.bounds)) toView:nil];
            NSEvent *doubleClick = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:location
                modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:2 pressure:1];
            [window sendEvent:doubleClick];
            if (delegate.finishedDrags != 1 || delegate.doubleClicks != 1)
                fail(@"legacy divider callbacks did not receive actual mouse events");
            row.delegate = oldDelegate;
            [viewer adjustWidthSplitView];
            [viewer resizeAll];
        }

        // The display cycle, where the endoscopy window raised (#795).
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]];
        for (NSString *reason in raised)
            fail([NSString stringWithFormat: @"the display cycle raised: %@", reason]);
        [window orderOut: nil];
        printf("done %s\n", columns(viewer).UTF8String);
        return 0;
    }
}
'''


def run(command, what):
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        print((result.stdout + result.stderr).decode('utf-8', 'replace')[-3000:])
        failures.append(f'{what} does not compile')
    return not result.returncode


failures = []
with tempfile.TemporaryDirectory(prefix='horos-petct-split-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.petct-split-test',
        'CFBundlePackageType': 'BNDL',
    }))
    (work / 'KFSplitView.h').write_bytes(read('Horos/Sources/KFSplitView.h'))
    (work / 'KFSplitView.swift').write_bytes(read('Horos/Sources/KFSplitView.swift'))
    (work / 'KFSplitView+CAPI.m').write_bytes(read('Horos/Sources/KFSplitView+CAPI.m'))
    # The main-actor callbacks the viewer's methods use (#961).
    swift_files = [str(work / 'KFSplitView.swift'), str(root / 'Horos/Sources/MainActorCallbacks.swift')]
    if swift_viewer:
        # The Swift double, with the viewer's methods; the harness keeps only
        # main and its helpers, and defines the window class the methods name.
        (work / 'bridge.h').write_text(swift_bridge)
        (work / 'double.swift').write_text(swift_double.replace('DELEGATE_METHODS', delegate_methods)
                                           .replace('ADJUST_METHODS', adjust.group(1))
                                           .replace('EXPAND_METHOD', expand.group(1)))
        swift_files.append(str(work / 'double.swift'))
        objc_harness = re.sub(r'OBJC_DOUBLE_BEGIN\n.*?OBJC_DOUBLE_END\n', '@implementation N2OpenGLViewWithSplitsWindow @end\n',
                              harness, flags=re.S)
    else:
        (work / 'bridge.h').write_text(bridge)
        objc_harness = (harness.replace('OBJC_DOUBLE_BEGIN\n', '').replace('OBJC_DOUBLE_END\n', '')
                        .replace('DELEGATE_METHODS', delegate_methods)
                        .replace('ADJUST_METHODS', adjust.group(1))
                        .replace('EXPAND_METHOD', expand.group(1)))
    (work / 'harness.m').write_bytes((objc_harness + harness_defaults.OBJC).encode('latin-1'))
    built = (run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'PETCTHarness', '-wmo',
                  '-import-objc-header', str(work / 'bridge.h'),
                  '-emit-objc-header-path', str(work / 'PETCTHarness-Swift.h'),
                  '-c'] + swift_files + ['-o', str(work / 'kf.o')], 'KFSplitView.swift' + (' and the viewer double' if swift_viewer else ''))
             and run(['xcrun', 'clang', '-c', str(work / 'KFSplitView+CAPI.m'), '-o', str(work / 'capi.o')],
                     'KFSplitView+CAPI.m')
             and run(['xcrun', 'clang', '-fobjc-arc', '-fmodules', '-Wno-deprecated-declarations', '-I', str(work),
                      '-c', str(work / 'harness.m'), '-o', str(work / 'harness.o')], 'the harness')
             and run(['xcrun', 'swiftc', str(work / 'harness.o'), str(work / 'capi.o'), str(work / 'kf.o'),
                      '-framework', 'Cocoa', '-o', str(work / 'harness')], 'the harness link'))
    for locale in ('en', 'ja-JP') if built else ():
        xib = work / f'{locale}.xib'
        xib.write_text(window_xib(read(f'Horos/Resources/{locale}.lproj/PETCT.xib')))
        nib = resources / f'{locale}.nib'
        compiled = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(xib)], capture_output=True, text=True)
        if compiled.returncode:
            failures.append(f'{locale}: ibtool: {(compiled.stdout + compiled.stderr)[-500:]}')
            continue
        try:
            result = subprocess.run([str(work / 'harness'), str(nib)], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            failures.append(f'{locale}: the window did not finish its layout within 120 s')
            continue
        lines = result.stdout.splitlines()
        failures += [f'{locale}: {line[6:]}' for line in lines if line.startswith('FAIL: ')]
        done = [line for line in lines if line.startswith('done ')]
        if result.returncode or not done:
            reason = next((line for line in result.stderr.splitlines() if 'Update Constraints' in line), result.stderr[-300:])
            failures.append(f'{locale}: the harness stopped with status {result.returncode}: {reason}')
        else:
            print(f'{locale}: {done[0][5:]}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the PET-CT fusion rows open, resize proportionally, follow each other\'s dividers and stay aligned '
      'through repeated layout and the display cycle, in en and ja-JP')
