#!/usr/bin/env python3
"""-[VRController dealloc] removes only the shading observer that was added.

-[VRController initWithPix:::::style:mode:] observed the `selectedObjects` of
the shading presets' array controller only at its end, but -dealloc always
removed that observer. Its failures after the window is loaded ("Not enough
memory": the 3D engine refused the volume) autorelease the controller before
the observer is added, and EndoscopyVRController, whose initializer does not
call the superclass's, never added it: removing an observer that was not added
raises NSRangeException inside -dealloc.

The observer is now added by -horosObserveShadingSelection, which records it in
an instance variable that -dealloc reads. The endoscopy's controller adds it
too, at the end of its successful initializer: the shading panel's preset popup
in Endoscopy.xib, as in VR.xib, has no action and applies the chosen preset
only through that observer.

The controller keeps the array controller it observes retained while it
observes it. shadingsPresetsController is an outlet the controller does
not retain. In VR.xib the controller owns the nib, and -[NSWindowController
dealloc] releases the array controller after -[VRController dealloc] removed the
observer. In Endoscopy.xib both are top-level objects of the EndoscopyViewer:
the viewer released the array controller while an autorelease pool still held
the endoscopy's controller, whose -dealloc then removed its observer from a
freed object and brought the application down when the endoscopy was closed.

The check runs: -horosObserveShadingSelection, -observeValueForKeyPath:... and
the observer lines of -dealloc are compiled, as VRController.mm has them, into
a stand-in controller whose outlet is not retained, with NSZombieEnabled so a
message to a freed object stops the probe. A selection chosen in the array
controller must reach -applyShading:, and the two release orders must both end
with the observer removed and both objects freed:

- VR's order, the controller first (the control: it always works);
- the endoscopy's, the array controller first while a pool holds the controller.

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8', errors='replace')


def block(source, signature):
    """The text of `signature` up to the brace that closes its body."""
    at = source.find(signature)
    if at < 0:
        return ''
    brace = source.find('{', at)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[at:index + 1]
    return ''


def code(text):
    """`text` without its // comments."""
    return re.sub(r'//[^\n]*', '', text)


ADD = '[shadingsPresetsController addObserver:self forKeyPath:@"selectedObjects"'
REMOVE = '[shadingsPresetsController removeObserver:self forKeyPath:@"selectedObjects"'
OBSERVED = 'horosObservedShadings'
REMOVE_OBSERVED = f'[{OBSERVED} removeObserver:self forKeyPath:@"selectedObjects"'
REGISTER = '[self horosObserveShadingSelection];'

vr_source = read('Horos/Sources/VRController.mm')
vr = code(vr_source)

implementation = block(vr, '@implementation VRController\n{')
check(re.search(r'\bShadingArrayController\s*\*\s*' + OBSERVED + r';', implementation),
      'VRController must keep, in its @implementation, the array controller it observes')

register = block(vr, '- (void) horosObserveShadingSelection\n{')
check(register, 'VRController.mm lost -horosObserveShadingSelection')
at_add = register.find(ADD)
at_set = register.find(OBSERVED + ' = [shadingsPresetsController retain];')
check(at_add >= 0 and at_set > at_add,
      '-horosObserveShadingSelection must add the observer, then retain the object it observes')
check(re.search(r'if\(\s*' + OBSERVED + r'\b[^)]*\)\s*return;', register),
      '-horosObserveShadingSelection must not add the observer twice')
check(vr.count(ADD) == 1,
      f'the shading observer is added {vr.count(ADD)} times in VRController.mm; only -horosObserveShadingSelection may add it')

dealloc = block(vr, '-(void) dealloc\n{')
check(dealloc, 'VRController.mm lost -dealloc')
check(REMOVE not in dealloc,
      '-dealloc must remove the observer from the object it retained, not from the outlet, which it does not retain')
at_remove = dealloc.find(REMOVE_OBSERVED)
at_release = dealloc.find(f'[{OBSERVED} release];')
check(at_remove >= 0 and at_release > at_remove,
      '-dealloc must remove the shading observer from the object it observes, then release that object')
check(re.search(r'if\(\s*' + OBSERVED + r'\)\s*\{?\s*' + re.escape(REMOVE_OBSERVED), dealloc),
      '-dealloc must remove the shading observer only if it was added')

init = block(vr, '-(id) initWithPix:(NSMutableArray*) pix\n')
check(init, 'VRController.mm lost -initWithPix:::::style:mode:')
at_register = init.find(REGISTER)
check(at_register >= 0, '-initWithPix:::::style:mode: must observe the shading presets through -horosObserveShadingSelection')
engine = init.find('[view setPixSource:pixList[0]')
failed = init.find('[self autorelease];\n            return nil;', engine)
check(engine >= 0 and failed > engine and at_register > failed,
      'the 3D engine failure must release the controller before the shading observer is added')

endoscopy = code(read('Horos/Sources/EndoscopyVRController+CAPI.m'))
reinit = block(endoscopy, '-(id) initWithPix:(NSMutableArray*) pix :(NSArray*) f :(NSData*) vData :(ViewerController*) bC :(ViewerController*) vC\n{')
check(reinit, 'EndoscopyVRController+CAPI.m lost -initWithPix:::::')
check(ADD not in reinit, 'the endoscopy must observe through -horosObserveShadingSelection, which -dealloc knows of')
at_register = reinit.find(REGISTER)
check(at_register >= 0, "the endoscopy's controller must observe its shading presets, as its superclass does")
check(at_register > reinit.rfind('return nil;') and reinit.find('return self;', at_register) >= 0,
      "the endoscopy's controller must observe its shading presets only once its initializer succeeds")

# The premise of the endoscopy's observer: its preset popup, as VR's, has no action.
for xib in ('Horos/Resources/en.lproj/Endoscopy.xib', 'Horos/Resources/en.lproj/VR.xib'):
    text = read(xib)
    controller = re.search(r'<outlet property="shadingsPresetsController" destination="([^"]+)"', text)
    check(controller, f'{xib} no longer connects shadingsPresetsController')
    if controller:
        popup = re.search(r'<popUpButton [^>]*>(?:(?!</popUpButton>).)*?<binding destination="' + re.escape(controller.group(1))
                          + r'" name="selectedIndex" keyPath="selectionIndex"(?:(?!</popUpButton>).)*</popUpButton>', text, re.S)
        check(popup, f"{xib} lost the shading presets' popup")
        if popup:
            check('<action ' not in popup.group(0),
                  f"{xib}: the shading presets' popup has an action now; the observer may no longer be needed")



def raw_body(text, signature):
    """The braces' content of the method whose line starts with `signature`; None if absent."""
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


# The ownership, run.
ivars = raw_body(vr_source, '@implementation VRController')
observe = raw_body(vr_source, '- (void) horosObserveShadingSelection')
notified = raw_body(vr_source, '- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object')
dealloc_source = raw_body(vr_source, '-(void) dealloc') or ''
removal = re.search(r'NSLog\(@"Dealloc VRController"\);(.*?)\[style release\];', dealloc_source, re.S)

PROBE = r"""
#import <AppKit/AppKit.h>

static int shadingsFreed, controllersFreed, applied;

@interface ShadingArrayController : NSArrayController
@end
@implementation ShadingArrayController
- (void)dealloc { shadingsFreed++; [super dealloc]; }
@end

@interface VRController : NSObject
{
    ShadingArrayController *shadingsPresetsController;   // the nib's outlet, not retained
    @@IVARS@@
}
@end
@implementation VRController
- (instancetype)initWithShadings:(ShadingArrayController *)shadings
{
    if ((self = [super init])) shadingsPresetsController = shadings;
    return self;
}
- (void)applyShading:(id)sender { applied++; }
- (void) horosObserveShadingSelection
{
    @@OBSERVE@@
}
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context
{
    @@NOTIFIED@@
}
- (void)dealloc
{
    @@REMOVAL@@
    controllersFreed++;
    [super dealloc];
}
@end

int main(int argc, char **argv)
{
    BOOL endoscopy = argc > 1 && strcmp(argv[1], "endoscopy") == 0;
    @autoreleasepool {
        // The nib's top-level objects.
        NSMutableArray *presets = [NSMutableArray arrayWithObjects:@{@"name": @"a"}, @{@"name": @"b"}, nil];
        ShadingArrayController *shadings = [[ShadingArrayController alloc] initWithContent:presets];
        VRController *controller = [[VRController alloc] initWithShadings:shadings];
        [controller horosObserveShadingSelection];
        [controller horosObserveShadingSelection];   // once only
        [shadings setSelectionIndex:1];               // a preset chosen in the popup
        if (endoscopy) {
            // EndoscopyViewer's -dealloc releases its top-level objects while a
            // pool still holds the VR controller.
            @autoreleasepool {
                [[controller retain] autorelease];
                [shadings release];
                [controller release];
            }
        } else {
            // VR.xib: the controller owns the nib and removes its observer
            // before -[NSWindowController dealloc] releases the array controller.
            [controller release];
            [shadings release];
        }
    }
    printf("%d %d %d\n", applied, controllersFreed, shadingsFreed);
    return 0;
}
"""

if None in (ivars, observe, notified) or not removal:
    failures.append('VRController.mm no longer has the observer code this probe compiles; the test needs a new look')
elif shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang)', file=sys.stderr)
    sys.exit(SKIPPED)
else:
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / 'probe.m'
        source.write_text(PROBE.replace('@@IVARS@@', ivars).replace('@@OBSERVE@@', observe)
                          .replace('@@NOTIFIED@@', notified).replace('@@REMOVAL@@', removal.group(1)))
        binary = Path(tmp) / 'probe'
        build = subprocess.run(['xcrun', 'clang', '-fno-objc-arc', '-w', '-framework', 'AppKit', str(source), '-o', str(binary)],
                               capture_output=True, text=True)
        if build.returncode:
            print(build.stderr, file=sys.stderr)
            failures.append('the ownership probe does not compile')
        else:
            env = dict(os.environ, NSZombieEnabled='YES')
            for order in ('vr', 'endoscopy'):
                run = subprocess.run([str(binary), order], capture_output=True, text=True, timeout=60, env=env)
                if run.returncode:
                    detail = (run.stderr.strip().splitlines() or [''])[-1]
                    failures.append(f'{order} release order: the probe stopped with {run.returncode}'
                                    f' (a message to a freed object?): {detail}')
                    continue
                counts = tuple(int(value) for value in run.stdout.split())
                if counts != (1, 1, 1):
                    failures.append(f'{order} release order: presets applied, controllers freed, array controllers freed = '
                                    f'{counts}, not (1, 1, 1)')

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: VRController removes only the shading observer it added, keeps the observed array controller alive until then, '
      'and the endoscopy adds it')
