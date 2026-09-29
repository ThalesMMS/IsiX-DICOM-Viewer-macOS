#!/usr/bin/env python3
"""-[VRController dealloc] removes only the shading observer that was added (#884).

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

`<git revision>` as an optional argument reads the sources from that revision:
that is the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys

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
FLAG = 'horosObservesShadingSelection'
REGISTER = '[self horosObserveShadingSelection];'

vr = code(read('Horos/Sources/VRController.mm'))

implementation = block(vr, '@implementation VRController\n{')
check(re.search(r'\bBOOL\s+' + FLAG + r';', implementation),
      'VRController must keep, in its @implementation, whether it added the shading observer')

register = block(vr, '- (void) horosObserveShadingSelection\n{')
check(register, 'VRController.mm lost -horosObserveShadingSelection')
at_add = register.find(ADD)
at_set = register.find(FLAG + ' = YES;')
check(at_add >= 0 and at_set > at_add,
      '-horosObserveShadingSelection must add the observer, then record it')
check(re.search(r'if\(\s*' + FLAG + r'\)\s*return;', register),
      '-horosObserveShadingSelection must not add the observer twice')
check(vr.count(ADD) == 1,
      f'the shading observer is added {vr.count(ADD)} times in VRController.mm; only -horosObserveShadingSelection may add it')

dealloc = block(vr, '-(void) dealloc\n{')
check(dealloc, 'VRController.mm lost -dealloc')
check(dealloc.count(REMOVE) == 1, '-dealloc must still remove the shading observer it added')
check(re.search(r'if\(\s*' + FLAG + r'\)\s*' + re.escape(REMOVE), dealloc),
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

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: VRController removes only the shading observer it added, and the endoscopy adds it')
