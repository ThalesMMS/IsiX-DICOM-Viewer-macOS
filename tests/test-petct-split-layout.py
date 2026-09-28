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
methods copied verbatim from OrthogonalMPRPETCTViewer.m (its "NSSplitview's
delegate methods" section), its -adjustHeightSplitView and
-adjustWidthSplitView, which -showWindow: calls, and -expandAllSplitViews. The
window, offscreen, is opened as the viewer opens it, resized, forced through
more layout passes, each divider is dragged with mouse events sent through the
window, one row is shown full window and back as -fullWindowPlan:: does, and
the run loop runs the display cycle. Exceptions are caught, including the one
raised from the display cycle. `<git revision>` as an optional argument reads
the sources from that revision: that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
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


# The legacy source mixes CRLF and LF and is not UTF-8.
source = read('Horos/Sources/OrthogonalMPRPETCTViewer.m').decode('latin-1').replace('\r\n', '\n').replace('\r', '\n')
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

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"NSApplicationCrashOnExceptions"];
        raised = [NSMutableArray array];
        [HarnessApplication sharedApplication];
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
    (work / 'bridge.h').write_text(bridge)
    (work / 'KFSplitView.swift').write_bytes(read('Horos/Sources/KFSplitView.swift'))
    (work / 'KFSplitView+CAPI.m').write_bytes(read('Horos/Sources/KFSplitView+CAPI.m'))
    (work / 'harness.m').write_bytes(harness.replace('DELEGATE_METHODS', delegate_methods)
                                     .replace('ADJUST_METHODS', adjust.group(1))
                                     .replace('EXPAND_METHOD', expand.group(1)).encode('latin-1'))
    built = (run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'PETCTHarness',
                  '-import-objc-header', str(work / 'bridge.h'),
                  '-emit-objc-header-path', str(work / 'PETCTHarness-Swift.h'),
                  '-c', str(work / 'KFSplitView.swift'), '-o', str(work / 'kf.o')], 'KFSplitView.swift')
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
