#!/usr/bin/env python3
"""The endoscopy window lays out its four views without looping.

Opening the endoscopy viewer closed the app: AppKit raised "The window has been
marked as needing another Update Constraints in Window pass, but it has already
had more Update Constraints in Window passes than there are views in the
window", from -[NSSplitView layout] setting a pane's frame.

Endoscopy.xib puts the four views in two rows, each a vertical NSSplitView, and
-[EndoscopyViewer splitViewDidResizeSubviews:] keeps the columns aligned by
copying the pane frames of the row that changed into the other row. The window
uses Auto Layout, and a split view whose delegate does not implement
-splitView:resizeSubviewsWithOldSize: places its panes with constraints of its
own ("NSSplitView.Edge", "NSSplitView.FallbackSize"), not by frame. A frame
copied into the other row was therefore undone by that row's next layout, which
reported its own widths back through the same delegate method: the rows traded
widths without end (a divider drag was undone the same way, and the two rows
could settle with different columns, one pane left at the nib's 300 points).
The delegate now implements -splitView:resizeSubviewsWithOldSize: with
-adjustSubviews, so both rows stay frame-based, the copied frames hold, and
the panes resize proportionally.

The shipped Endoscopy.xib window (en and ja-JP) is compiled with ibtool, with
plain views in place of the MPR and VR views, and loaded by a double of
EndoscopyViewer that holds the two split view outlets and the delegate methods
copied verbatim from the viewer's source (its "NSSplitview's delegate methods"
section). The viewer is Swift: the double is then a Swift class; a
revision where the viewer is still EndoscopyViewer.m gets the Objective-C
double. The window, offscreen, is resized, both rows are forced through more
layout passes, the dividers are moved, and the run loop runs the display
cycle. Exceptions are caught, including the one raised from the display cycle.
`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
import harness_defaults  # the harness's preferences stay in its own process
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
    """The viewer's source and whether it is Swift or the former .m."""
    try:
        return read('Horos/Sources/EndoscopyViewer.swift').decode('utf-8'), True
    except (FileNotFoundError, subprocess.CalledProcessError):
        return read('Horos/Sources/EndoscopyViewer.m').decode('utf-8'), False


source, swift_viewer = viewer_source()
if swift_viewer:
    section = re.search(r"\n    // MARK: - NSSplitview's delegate methods\n(.*?)\n    // MARK:", source, re.S)
    assert section, "EndoscopyViewer.swift lost its NSSplitview's delegate methods section"
    delegate_methods = section.group(1)
    assert 'func splitViewDidResizeSubviews(' in delegate_methods, 'the rows are no longer kept aligned'
else:
    section = re.search(r"#pragma mark NSSplitview's delegate methods\n(.*?)\n#pragma mark", source, re.S)
    assert section, "EndoscopyViewer.m lost its NSSplitview's delegate methods section"
    delegate_methods = section.group(1)
    assert 'splitViewDidResizeSubviews:' in delegate_methods, 'the rows are no longer kept aligned'


def window_xib(text):
    """The window of Endoscopy.xib, with plain views for the MPR and VR views."""
    source = ET.fromstring(text)
    document = ET.Element('document', source.attrib)
    for dependency in source.findall('dependencies'):
        document.append(deepcopy(dependency))
    objects = ET.SubElement(document, 'objects')
    owner = ET.SubElement(objects, 'customObject', id='-2', userLabel="File's Owner", customClass='EndoscopyViewer')
    connections = ET.SubElement(owner, 'connections')
    for outlet in source.find('objects/customObject[@id="-2"]/connections'):
        if outlet.get('property') in ('window', 'topSplitView', 'bottomSplitView'):
            connections.append(deepcopy(outlet))
    ET.SubElement(objects, 'customObject', id='-1', userLabel='First Responder', customClass='FirstResponder')
    ET.SubElement(objects, 'customObject', id='-3', userLabel='Application', customClass='NSObject')
    window = deepcopy(source.find('objects/window[@id="5"]'))
    classes = set()
    for node in window.iter():
        if node.get('customClass'):
            classes.add(node.get('customClass'))
            node.set('customClass', 'HarnessPane')
        for group in list(node.findall('connections')):
            for outlet in list(group):
                if outlet.get('destination') != '-2':
                    group.remove(outlet)
            if len(group) == 0:
                node.remove(group)
    assert classes == {'EndoscopyMPRView', 'EndoscopyVRView'}, f'unexpected views in the window: {classes}'
    objects.append(window)
    return ET.tostring(document, encoding='unicode')


harness = r'''
#import <Cocoa/Cocoa.h>

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

OBJC_DOUBLE_BEGIN
@interface EndoscopyViewer : NSWindowController <NSSplitViewDelegate>
{
    IBOutlet NSSplitView *topSplitView, *bottomSplitView;
}
@end

@implementation EndoscopyViewer
DELEGATE_METHODS
- (NSSplitView *)top { return topSplitView; }
- (NSSplitView *)bottom { return bottomSplitView; }
@end
OBJC_DOUBLE_END

static int failures;
static void fail(NSString *reason) { failures++; printf("FAIL: %s\n", reason.UTF8String); }

static NSString *columns(EndoscopyViewer *viewer) {
    NSArray *t = viewer.top.subviews, *b = viewer.bottom.subviews;
    return [NSString stringWithFormat: @"top %.0f | %.0f, bottom %.0f | %.0f",
            NSWidth([t[0] frame]), NSWidth([t[1] frame]), NSWidth([b[0] frame]), NSWidth([b[1] frame])];
}

// Layout passes as the display cycle runs them, and more: both rows are marked
// as needing constraints and layout again, as a window move or a backing
// change would do.
static BOOL settle(NSWindow *window, EndoscopyViewer *viewer, NSString *step) {
    resizes = 0;
    @try {
        for (int pass = 0; pass < 4; pass++) {
            for (NSSplitView *split in @[viewer.top, viewer.bottom]) {
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
    return YES;
}

static void aligned(EndoscopyViewer *viewer, NSString *step) {
    NSArray *t = viewer.top.subviews, *b = viewer.bottom.subviews;
    for (int i = 0; i < 2; i++)
        if (fabs(NSMinX([t[i] frame]) - NSMinX([b[i] frame])) > 0.5 || fabs(NSWidth([t[i] frame]) - NSWidth([b[i] frame])) > 0.5)
            return fail([NSString stringWithFormat: @"%@: the columns of the two rows differ (%@)", step, columns(viewer)]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        [[NSUserDefaults standardUserDefaults] setBool: NO forKey: @"NSApplicationCrashOnExceptions"];
        raised = [NSMutableArray array];
        [HarnessApplication sharedApplication];
        [[NSNotificationCenter defaultCenter] addObserverForName: NSSplitViewDidResizeSubviewsNotification object: nil queue: nil
                                                      usingBlock: ^(NSNotification *note) { resizes++; }];
        EndoscopyViewer *viewer = [EndoscopyViewer alloc];
        viewer = [viewer initWithWindowNibPath: [NSString stringWithUTF8String: argv[1]] owner: viewer];
        NSWindow *window = viewer.window;
        // As -[EndoscopyViewer initWithPixList:::::] does.
        [viewer.top setDelegate: viewer];
        [viewer.bottom setDelegate: viewer];
        [window setFrameOrigin: NSMakePoint(-20000, -20000)];
        [window orderFront: nil];

        if (settle(window, viewer, @"opening")) aligned(viewer, @"opening");

        // A split view keeps the proportion of its columns when the window grows,
        // as -[EndoscopyVRController initWithPix:::::] does with -performZoom:.
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
            NSArray *t = viewer.top.subviews;
            CGFloat left = NSWidth([t[0] frame]), right = NSWidth([t[1] frame]);
            if (fabs(left - right) > 0.02 * (left + right))
                fail([NSString stringWithFormat: @"%@: the two columns of equal width did not resize alike (%@)", step, columns(viewer)]);
        }

        // Moving a divider moves the other row's divider with it, and it holds.
        for (NSSplitView *split in @[viewer.top, viewer.bottom]) {
            CGFloat position = round(NSWidth(split.bounds) / 3);
            NSString *step = [NSString stringWithFormat: @"%@ divider to %.0f", split == viewer.top ? @"top" : @"bottom", position];
            @try { [split setPosition: position ofDividerAtIndex: 0]; }
            @catch (NSException *exception) { fail([NSString stringWithFormat: @"%@: %@", step, exception.reason]); continue; }
            if (!settle(window, viewer, step)) continue;
            aligned(viewer, step);
            if (fabs(NSWidth([split.subviews[0] frame]) - position) > 1)
                fail([NSString stringWithFormat: @"%@: the divider did not stay (%@)", step, columns(viewer)]);
        }

        // The display cycle, where the app raised.
        [[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.5]];
        for (NSString *reason in raised)
            fail([NSString stringWithFormat: @"the display cycle raised: %@", reason]);
        [window orderOut: nil];
        printf("done %s\n", columns(viewer).UTF8String);
        return 0;
    }
}
'''

# The double of the Swift viewer: the same outlets, the methods copied
# from EndoscopyViewer.swift, and what the harness reads.
swift_double = r'''
import Cocoa

@objc(EndoscopyViewer)
public final class EndoscopyViewer: NSWindowController, NSSplitViewDelegate {
    @IBOutlet private var topSplitView: NSSplitView?
    @IBOutlet private var bottomSplitView: NSSplitView?

DELEGATE_METHODS

    @objc public var top: NSSplitView { topSplitView! }
    @objc public var bottom: NSSplitView { bottomSplitView! }
}
'''


def run(command, what):
    result = subprocess.run(command, capture_output=True)
    if result.returncode:
        print((result.stdout + result.stderr).decode('utf-8', 'replace')[-3000:])
        failures.append(f'{what} does not compile')
    return not result.returncode


failures = []
with tempfile.TemporaryDirectory(prefix='horos-endoscopy-split-') as folder:
    work = Path(folder)
    resources = work / 'Probe.bundle/Contents/Resources'
    resources.mkdir(parents=True)
    (resources.parent / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'org.horosproject.endoscopy-split-test',
        'CFBundlePackageType': 'BNDL',
    }))
    if swift_viewer:
        # The Swift double, with the viewer's methods; the harness keeps only
        # main and its helpers, and reads the double's generated interface.
        (work / 'double.swift').write_text(swift_double.replace('DELEGATE_METHODS', delegate_methods))
        objc_harness = re.sub(r'OBJC_DOUBLE_BEGIN\n.*?OBJC_DOUBLE_END\n', '#import "EndoscopyHarness-Swift.h"\n',
                              harness, flags=re.S)
        (work / 'harness.m').write_text(objc_harness + harness_defaults.OBJC)
        run(['xcrun', 'swiftc', '-parse-as-library', '-module-name', 'EndoscopyHarness', '-wmo',
             '-emit-objc-header-path', str(work / 'EndoscopyHarness-Swift.h'),
             '-c', str(work / 'double.swift'), '-o', str(work / 'double.o')], 'the viewer double')
        if not failures:
            run(['xcrun', 'clang', '-fobjc-arc', '-fmodules', '-Wno-deprecated-declarations', '-I', str(work),
                 '-c', str(work / 'harness.m'), '-o', str(work / 'harness.o')], 'the harness')
        if not failures:
            run(['xcrun', 'swiftc', str(work / 'harness.o'), str(work / 'double.o'),
                 '-framework', 'Cocoa', '-o', str(work / 'harness')], 'the harness link')
    else:
        objc_harness = (harness.replace('OBJC_DOUBLE_BEGIN\n', '').replace('OBJC_DOUBLE_END\n', '')
                        .replace('DELEGATE_METHODS', delegate_methods))
        (work / 'harness.m').write_text(objc_harness + harness_defaults.OBJC)
        run(['xcrun', 'clang', '-fobjc-arc', '-Wno-deprecated-declarations', '-framework', 'Cocoa',
             str(work / 'harness.m'), '-o', str(work / 'harness')], 'the harness')
    for locale in ('en', 'ja-JP') if not failures else ():
        xib = work / f'{locale}.xib'
        xib.write_text(window_xib(read(f'Horos/Resources/{locale}.lproj/Endoscopy.xib')))
        nib = resources / f'{locale}.nib'
        compiled = subprocess.run(['xcrun', 'ibtool', '--compile', str(nib), str(xib)], capture_output=True, text=True)
        if compiled.returncode:
            failures.append(f'{locale}: ibtool: {(compiled.stdout + compiled.stderr)[-500:]}')
            continue
        try:
            run = subprocess.run([str(work / 'harness'), str(nib)], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            failures.append(f'{locale}: the window did not finish its layout within 120 s')
            continue
        lines = run.stdout.splitlines()
        failures += [f'{locale}: {line[6:]}' for line in lines if line.startswith('FAIL: ')]
        done = [line for line in lines if line.startswith('done ')]
        if run.returncode or not done:
            reason = next((line for line in run.stderr.splitlines() if 'Update Constraints' in line), run.stderr[-300:])
            failures.append(f'{locale}: the harness stopped with status {run.returncode}: {reason}')
        else:
            print(f'{locale}: {done[0][5:]}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: the endoscopy rows open, resize proportionally, follow each other\'s divider and stay aligned '
      'through repeated layout and the display cycle, in en and ja-JP')
