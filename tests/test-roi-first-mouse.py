#!/usr/bin/env python3
"""A measure starts with the first click in a viewer that is not the key window.

With a ROI or measuring tool, -[DCMView acceptsFirstMouse:] answered NO, so the
first click in the second of two tiled viewers only made it the key window: the
two-click Length lost its first point there and measuring in turn felt broken.
It now answers YES when the application is active - the click comes from
another window of this application - and NO only when the click brings the
application forward from another one. Tools that are not ROIs accept it as
before.

The method is compiled from the source, in a stand-in view, with an
application whose activity the test sets, and run.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/DCMView.m').read_bytes().decode('latin1')
start = source.index('-(BOOL) acceptsFirstMouse:(NSEvent*) theEvent')
method = source[start:source.index('\n}\n', start) + 3]

DRIVER = r'''
#import <AppKit/AppKit.h>
static BOOL active;
@interface TestApplication : NSApplication
@end
@implementation TestApplication
- (BOOL)isActive { return active; }
@end
@interface DCMView : NSView { @public int currentTool; }
@end
@implementation DCMView
METHOD
@end
int main(void) { @autoreleasepool {
    [TestApplication sharedApplication];
    DCMView *view = [[DCMView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    int failures = 0;
    struct { int tool; BOOL active; BOOL expected; const char *what; } cases[] = {
        {5, YES, YES, "a ROI tool, the click from another viewer of the application"},
        {5, NO, NO, "a ROI tool, the click bringing the application forward"},
        {20, YES, YES, "another ROI tool, within the application"},
        {0, NO, YES, "window level, from another application"},
        {0, YES, YES, "window level, within the application"},
    };
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        view->currentTool = cases[i].tool;
        active = cases[i].active;
        if ([view acceptsFirstMouse:nil] != cases[i].expected) { fprintf(stderr, "FAIL: %s\n", cases[i].what); failures++; }
    }
    if (failures) return 1;
    puts("PASS: a measure starts with the first click in another viewer of the application");
    return 0;
}}
'''.replace('METHOD', method)

with tempfile.TemporaryDirectory(prefix='horos-first-mouse-') as directory:
    work = Path(directory)
    (work / 'main.m').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-framework', 'AppKit', str(work / 'main.m'), '-o', str(work / 'check')],
                           capture_output=True, text=True)
    if built.returncode:
        print('FAIL: the method does not compile\n' + built.stderr[-1500:])
        sys.exit(1)
    run = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=60)
    print((run.stdout + run.stderr).strip())
    sys.exit(run.returncode)
