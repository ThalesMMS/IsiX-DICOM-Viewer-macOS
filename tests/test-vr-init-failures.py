#!/usr/bin/env python3
"""-[VRController initWithPix:::::style:mode:] gives back what it took when it fails.

Three failure paths of the Objective-C initializer returned nil without
releasing the controller its caller allocated (the initial memory test, "Slice
interval/thickness" and "Images size"), and the last two kept the file list
they had retained; -dealloc then released a pixel list and a volume the
initializer had not retained.

VRController is Swift: a failable convenience initializer under ARC, so a
failure frees the controller and whatever it took without a release written
by hand. What is checked in VRController.swift:

- the checks that need no window (the memory test, the slice interval or
  thickness, the images' size) fail before the controller exists, and the 3D
  engine's refusal fails after: five ways out with nil, none releasing by hand;
- the shading observer is added only once every check passed, and the
  controller's deinit removes it only when it was added.

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


vr = code(read('Horos/Sources/VRController.swift'))

init = block(vr, '    public convenience init?(pix: NSMutableArray!, _ f: NSArray!, _ vData: NSData!, _ bC: ViewerController!,\n'
                 '                             _ vC: ViewerController!, style m: String!, mode renderingMode: String!)')
check(init, 'VRController.swift lost -initWithPix:::::style:mode:')
nib = init.find('self.init(windowNibName: "VR")')
check(nib >= 0, 'the initializer no longer loads VR.xib')
# The checks run in volumeIsRenderable, called before the nib; the volume is
# taken and the engine asked in adoptVolume, called after it. Both run under
# HorosObjCException (tests/test-vr-state-exception-guard.py).
checks = block(vr, '    private static func volumeIsRenderable(_ pix: NSMutableArray, _ firstObject: DCMPix) -> Bool {')
adopt = block(vr, '    private final func adoptVolume(')
check(checks and adopt, 'VRController.swift lost volumeIsRenderable or adoptVolume')
called = init.find('VRController.volumeIsRenderable(')
check(0 <= called < init.find('guard renderable else { return nil }') < nib,
      'the checks no longer run, and fail with nil, before the controller exists')
for title in ('Not enough memory', 'Slice interval/thickness', 'Images size'):
    at = checks.find(f'NSLocalizedString("{title}"')
    check(at >= 0 and checks.find('return false', at) >= 0,
          f'"{title}" no longer fails before the controller exists')
finish = adopt.find('guard finishInit(renderingMode: renderingMode) else {')
check(finish >= 0 and adopt.find('return false', finish) > finish
      and nib < init.find('self.adoptVolume(') < init.find('guard ready else { return nil }'),
      'the 3D engine\'s refusal no longer fails once the controller has its volume')
check(init.count('return nil') == 5, f'{init.count("return nil")} ways out with nil, expected 5')
for manual in ('autorelease', 'release()', 'Unmanaged'):
    check(manual not in init + checks + adopt, f'the initializer releases by hand ({manual}): ARC does')

# The shading observer is added only at the end, after every failure.
finish_init = block(vr, '    private final func finishInit(renderingMode: String?) -> Bool {')
register = finish_init.find('horosObserveShadingSelection()')
check(register > finish_init.find('if err != 0 { return false }') >= 0 and 'return false' not in finish_init[register:],
      'the shading observer must be added only once every check passed')
deinit = block(vr, '    isolated deinit {')
check(re.search(r'if let shadings = horosObservedShadings \{\s*shadings\.removeObserver\(self, forKeyPath: "selectedObjects"', deinit),
      'deinit must remove the shading observer only when it was added')

for failure_message in failures:
    print(f'FAIL: {failure_message}')
if failures:
    sys.exit(1)
print('PASS: every failure of -[VRController initWithPix:::::style:mode:] gives back what it took')
