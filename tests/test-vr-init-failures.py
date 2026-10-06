#!/usr/bin/env python3
"""-[VRController initWithPix:::::style:mode:] gives back what it took when it fails.

Three failure paths of the initializer returned nil without releasing the
controller its caller allocated: the initial memory test, "Slice
interval/thickness" and "Images size". The last two also kept the file list they
had retained. They now release the controller, as the 3D engine failure and the
exception handler did.

Releasing it runs -dealloc, which releases pixList[0] and volumeData[0] up to
maxMovieIndex, already 1 there, although those two failures come before the
initializer retains them: -horosAbandonInitBeforeVolume gives back the file list
and forgets both, as -horosAbandonInitWithPix: does for the endoscopy.
The exception handler does the same when the exception comes before that
retain. The shading observer is added only at the end, so -dealloc
removes none on these paths.

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


ABANDON = '[self horosAbandonInitBeforeVolume];'
RELEASE = '[self autorelease];'

vr = code(read('Horos/Sources/VRController.mm'))

init = block(vr, '-(id) initWithPix:(NSMutableArray*) pix\n')
check(init, 'VRController.mm lost -initWithPix:::::style:mode:')

retain_files = init.find('[fileList retain];')
retain_volume = init.find('[volumeData[0] retain];')
engine = init.find('[view setPixSource:pixList[0]')
catch = init.find('@catch')
check(0 <= retain_files < retain_volume < engine < catch,
      'the initializer no longer retains the file list, then the volume, then feeds the 3D engine')

# The premise: -dealloc releases pixList[0] and volumeData[0] up to maxMovieIndex,
# which is 1 before the two checks that precede the volume's retain.
dealloc = block(vr, '-(void) dealloc\n{')
check(re.search(r'for\( int i = 0; i < maxMovieIndex; i\+\+\)\s*\{\s*\[pixList\[ i\] release\];\s*\[volumeData\[ i\] release\];', dealloc),
      '-dealloc no longer releases the pixel lists and volumes up to maxMovieIndex; revise this test')
check(0 <= init.find('maxMovieIndex = 1;') < retain_files,
      'maxMovieIndex is no longer 1 before the file list is retained; revise this test')


def failure(title):
    """The statements from the alert titled `title` to the next return nil."""
    at = init.find(f'@"{title}"')
    end = init.find('return nil;', at)
    return (at, init[at:end + len('return nil;')]) if at >= 0 and end >= 0 else (-1, '')


memory_at, memory = failure('Not enough memory')
check(memory_at >= 0 and memory_at < retain_files, 'the memory test no longer precedes the file list retain')
check(re.search(re.escape(RELEASE) + r'\s*return nil;$', memory),
      'the memory test failure must release the controller')
check(ABANDON not in memory, 'the memory test failure has nothing to give back but the controller')

for title in ('Slice interval/thickness', 'Images size'):
    at, path = failure(title)
    check(retain_files < at < retain_volume, f'"{title}" no longer fails between the two retains')
    check(re.search(re.escape(ABANDON) + r'\s*' + re.escape(RELEASE) + r'\s*return nil;$', path),
          f'"{title}" must give back the file list, forget the unretained volume, then release the controller')

engine_path = init[engine:init.find('return nil;', engine) + len('return nil;')]
check(re.search(re.escape(RELEASE) + r'\s*return nil;$', engine_path) and ABANDON not in engine_path,
      'the 3D engine failure comes after the retain: -dealloc releases the volume')

check(re.search(r'\bBOOL\s+volumeRetained = NO;', init[:init.find('@try')]),
      'the initializer must record, outside its @try, whether it retained the volume')
check(re.search(re.escape('[volumeData[0] retain];') + r'\s*volumeRetained = YES;', init),
      'the initializer must record the retain right after it')
handler = init[catch:]
check(re.search(r'if\( volumeRetained == NO\)\s*' + re.escape(ABANDON) + r'\s*' + re.escape(RELEASE) + r'\s*return nil;', handler),
      'the exception handler must forget the unretained volume before it releases the controller')

# Every way out with nil releases the controller.
returns = init.count('return nil;')
released = len(re.findall(re.escape(RELEASE) + r'\s*return nil;', init))
check(returns == 5 and released == returns,
      f'{released} of the {returns} failure paths of the initializer release the controller; expected 5 of 5')

abandon = block(vr, '- (void) horosAbandonInitBeforeVolume\n{')
check(abandon, 'VRController.mm lacks -horosAbandonInitBeforeVolume')
for needle in ('pixList[0] = nil;', 'volumeData[0] = nil;', '[fileList release];', 'fileList = nil;'):
    check(needle in abandon, f'-horosAbandonInitBeforeVolume must do {needle}')
check('[pixList[0] release]' not in abandon and '[volumeData[0] release]' not in abandon,
      '-horosAbandonInitBeforeVolume must not release the pixel list and volume the initializer did not retain')
check(abandon.find('[fileList release];') < abandon.find('fileList = nil;'),
      '-horosAbandonInitBeforeVolume must release the file list before it forgets it')

# The shading observer is added only at the end, after every failure.
register = init.find('[self horosObserveShadingSelection];')
check(register > engine and register > init.rfind('return nil;', 0, catch),
      'the shading observer must be added only once every check passed')

for failure_message in failures:
    print(f'FAIL: {failure_message}')
if failures:
    sys.exit(1)
print('PASS: every failure of -[VRController initWithPix:::::style:mode:] gives back what it took')
