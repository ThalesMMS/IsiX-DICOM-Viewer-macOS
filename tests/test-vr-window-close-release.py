#!/usr/bin/env python3
"""Closing the 3D window runs -[VRController windowWillClose:] and releases the controller (#920).

The Metal renderer of VRHostBridge.mm, when it was made, removed the
controller's registration for the window's NSWindowWillCloseNotification and
added its own. The controller is the window's delegate: AppKit registers a
delegate for the notifications of the NSWindowDelegate methods it implements,
under the same observer, name and object, so the removal also took away
-windowWillClose:. It never ran, and the controller, its volume (some 300 MB
for a CT of 347 slices) and its hidden window stayed alive; reopening the 3D
view reused that window.

The check runs: the lines VRHostBridge.mm runs once it has a renderer are
compiled into a stand-in NSWindowController that is its window's delegate,
with the renderer-dropping methods of the bridge copied as they are. A window
is closed, as the user closes the 3D window, and:

- the delegate's -windowWillClose: must run exactly once (the same stand-in
  without the bridge's lines is the control: it always does);
- the controller must be released by it, as VRController's own does;
- the renderer must be released exactly once: when -windowWillClose: drops it,
  or with the controller's associated objects, not twice.

In the sources: VRController.mm's -windowWillClose: drops the Metal
renderers, and VRView's -prepareForRelease, which -[VRController dealloc]
sends, invalidates the auto-rotation timers. Those timers retain the view and
were invalidated only by the view's -windowWillClose:, which a window never
shown does not post: the endoscopy viewer's, when its initializer fails.

`<git revision>` as an optional argument reads that revision, the negative
control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs (#803)
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


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

bridge = read('Horos/Sources/VRHostBridge.mm')
controller = read('Horos/Sources/VRController.mm')
view = read('Horos/Sources/VRView.mm')

# What the bridge runs once it made a renderer.
made = re.search(r'renderer = \[HorosVolumeRenderer makeAndReturnError:&failure\];\s*if \(renderer\) \{(.*?)\n\s*\} else reason',
                 bridge, re.S)
if not made:
    print('VRHostBridge.mm no longer makes its renderer as this test expects; it needs a new look', file=sys.stderr)
    sys.exit(1)
on_renderer = made.group(1)

closing = body(controller, '- (void)windowWillClose:(NSNotification *)notification')
if closing is None:
    print('VRController.mm has no -windowWillClose:; this test needs a new look', file=sys.stderr)
    sys.exit(1)
drops_on_close = '[self horosVolumeMetalDropRenderers];' in closing
drop = body(bridge, '- (void)horosVolumeMetalDropRenderers') or ''
handler = body(bridge, '- (void)horosVolumeMetalWindowWillClose:(NSNotification *)note') or ''

PROBE = r'''
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static char rendererKey, fusedRendererKey;
static int closes, controllersFreed, renderersFreed;

@interface HorosVolumeRenderer : NSObject
@end
@implementation HorosVolumeRenderer
- (void)releaseVolume {}
- (void)dealloc { renderersFreed++; [super dealloc]; }
@end

@interface Controller : NSWindowController <NSWindowDelegate>
@end
@implementation Controller
- (void)makeRenderer
{
    const void *rendererSlot = &rendererKey;
    HorosVolumeRenderer *renderer = [[[HorosVolumeRenderer alloc] init] autorelease];
    if (renderer) {
#if WITH_BRIDGE
        @@ON_RENDERER@@
#else
        objc_setAssociatedObject(self, rendererSlot, renderer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#endif
    }
}
- (void)horosVolumeMetalRelease
{
    [(HorosVolumeRenderer *)objc_getAssociatedObject(self, &rendererKey) releaseVolume];
}
- (void)horosVolumeMetalWindowWillClose:(NSNotification *)note
{
    @@HANDLER@@
}
- (void)horosVolumeMetalDropRenderers
{
    @@DROP@@
}
// VRController's: it drops the renderers when its source does, and is
// released by its window's closing.
- (void)windowWillClose:(NSNotification *)notification
{
    if ([notification object] != [self window]) return;
    closes++;
#if DROPS_ON_CLOSE
    [self horosVolumeMetalDropRenderers];
#endif
    [[self window] setDelegate:nil];
    [self autorelease];
}
- (void)dealloc { controllersFreed++; [[NSNotificationCenter defaultCenter] removeObserver:self]; [super dealloc]; }
@end

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        @autoreleasepool {
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 200, 200)
                                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                             backing:NSBackingStoreBuffered defer:YES];
            [window setReleasedWhenClosed:NO];
            Controller *controller = [[Controller alloc] initWithWindow:window];   // released by -windowWillClose:
            [window setDelegate:controller];
            [window release];
            [controller makeRenderer];
            [window close];
        }
        printf("%d %d %d\n", closes, controllersFreed, renderersFreed);
    }
    return 0;
}
'''

with tempfile.TemporaryDirectory() as tmp:
    results = {}
    for name, with_bridge in (('control', 0), ('bridge', 1)):
        source = Path(tmp) / f'{name}.m'
        source.write_text(PROBE.replace('@@ON_RENDERER@@', on_renderer).replace('@@HANDLER@@', handler).replace('@@DROP@@', drop))
        binary = Path(tmp) / name
        build = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-w', f'-DWITH_BRIDGE={with_bridge}',
                                f'-DDROPS_ON_CLOSE={int(drops_on_close)}', '-framework', 'AppKit',
                                str(source), '-o', str(binary)], capture_output=True, text=True)
        if build.returncode:
            print(build.stderr, file=sys.stderr)
            failures.append(f'the {name} probe does not compile')
            continue
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
        if run.returncode:
            failures.append(f'the {name} probe exited with {run.returncode}: {run.stderr.strip()}')
            continue
        results[name] = tuple(int(value) for value in run.stdout.split())

    if results.get('control') != (1, 1, 1):
        failures.append(f'the control (a delegate with no other observer) gave closes, controllers freed, renderers freed = '
                        f'{results.get("control")}, not (1, 1, 1): the probe cannot tell')
    elif 'bridge' in results:
        closes, freed, renderers = results['bridge']
        if closes != 1:
            failures.append(f'with the Metal renderer made, closing the window ran the delegate\'s -windowWillClose: {closes} '
                            'times, not once: an observer registration of the bridge took the delegate\'s')
        if freed != 1:
            failures.append('closing the window did not release the controller')
        if renderers != 1:
            failures.append(f'the renderer was released {renderers} times, not once')

if not drops_on_close:
    failures.append('-[VRController windowWillClose:] does not drop the Metal renderers')
if drop and ('rendererKey, nil' not in drop or 'fusedRendererKey, nil' not in drop):
    failures.append('-horosVolumeMetalDropRenderers does not drop both renderers')
if re.search(r'removeObserver:\s*self\s+name:\s*NSWindowWillCloseNotification', bridge):
    failures.append('VRHostBridge.mm still removes the controller\'s registrations for NSWindowWillCloseNotification')

release = body(view, '- (void) prepareForRelease')
if release is None or '[autoRotate invalidate];' not in release or '[startAutoRotate invalidate];' not in release:
    failures.append('-[VRView prepareForRelease] does not invalidate the auto-rotation timers, which retain the view')
dealloc = body(controller, '-(void) dealloc') or ''
if '[view prepareForRelease];' not in dealloc:
    failures.append('-[VRController dealloc] no longer sends -prepareForRelease to its view')

if failures:
    print('\n'.join(failures), file=sys.stderr)
    sys.exit(1)
print('VR window close: the delegate runs -windowWillClose:, the controller and the renderer are released once, '
      'and the view\'s timers stop with the controller')
