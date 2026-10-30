#!/usr/bin/env python3
"""The two-argument isDataVolumicIn4D:checkEverythingLoaded: forwards its flags.

That overload discarded check4D and checkEverythingLoaded: and
always called the three-argument form with NO / YES / YES. The one-argument
isDataVolumicIn4D: YES therefore never inspected other 4D timepoints.

The series-replace peer probe already goes through the three-argument form
and HorosSeriesReplaceLoadPolicy. This fix does not change that probe.

-changeImageData:::: is Swift (ViewerController+RetrieveAndView.swift):
the probe is read there, in its Swift spelling (SeriesReplaceLoadPolicy, the
three-argument isDataVolumicIn4D(_:checkEverythingLoaded:tryToCorrect:)), and the
caller scans cover the Swift sources too.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources as horos_sources

root = Path(__file__).resolve().parents[1]
failures = []
viewer = root / 'Horos/Sources/ViewerController.m'
retrieve_and_view = horos_sources.source_path('ViewerController+RetrieveAndView')
swift_sources = sorted((root / 'Horos/Sources').glob('*.swift'))
sources = sorted((root / 'Horos/Sources').glob('*.m')) + sorted(
    (root / 'Horos/Sources').glob('*.mm'))


def body(path, signature):
    # A file that is gone (ViewerController.m) has no body to give.
    source = path.read_bytes().decode('latin1') if path.exists() else ''
    start = 0
    while True:
        at = source.find(signature, start)
        if at < 0:
            return ''
        after = source[at + len(signature):].lstrip()
        if after.startswith('{'):
            opening = source.index('{', at)
            depth, index = 0, opening
            while index < len(source):
                if source[index] == '{':
                    depth += 1
                elif source[index] == '}':
                    depth -= 1
                    if depth == 0:
                        return source[opening:index + 1]
                index += 1
            return ''
        start = at + 1


def comments_stripped(text):
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'/\*.*?\*/', '', text, flags=re.S)


def check(condition, message):
    if not condition:
        failures.append(message)


TWO_ARG = '- (BOOL) isDataVolumicIn4D: (BOOL) check4D checkEverythingLoaded:(BOOL) c;'
ONE_ARG = '- (BOOL) isDataVolumicIn4D: (BOOL) check4D'
ZERO_ARG = '- (BOOL) isDataVolumic'
THREE_ARG = ('- (BOOL) isDataVolumicIn4D: (BOOL) check4D '
             'checkEverythingLoaded:(BOOL) c tryToCorrect: (BOOL) tryToCorrect')

two_arg = body(viewer, TWO_ARG)
one_arg = body(viewer, ONE_ARG)
zero_arg = body(viewer, ZERO_ARG)
three_arg = body(viewer, THREE_ARG)
# The volumic checks are Swift, in ViewerController+VolumeCheck.swift: the same
# checks in their Swift spelling.
volume_swift = not three_arg
if volume_swift:
    volume_check = horos_sources.source_path('ViewerController+VolumeCheck')
    two_arg = body(volume_check, 'func isDataVolumicIn4D(_ check4D: Bool, checkEverythingLoaded c: Bool) -> Bool')
    one_arg = body(volume_check, 'func isDataVolumicIn4D(_ check4D: Bool) -> Bool')
    zero_arg = body(volume_check, 'func isDataVolumic() -> Bool')
    three_arg = body(volume_check, 'func isDataVolumicIn4D(_ check4D: Bool, checkEverythingLoaded c: Bool, tryToCorrect: Bool) -> Bool')
SPELLING = {
    'isDataVolumicIn4D: check4D checkEverythingLoaded: c tryToCorrect:': 'isDataVolumicIn4D(check4D, checkEverythingLoaded: c, tryToCorrect:',
    'isDataVolumicIn4D: NO checkEverythingLoaded: YES tryToCorrect: YES': 'isDataVolumicIn4D(false, checkEverythingLoaded: true, tryToCorrect: true)',
    'tryToCorrect: YES': 'tryToCorrect: true',
    'isDataVolumicIn4D: check4D checkEverythingLoaded: YES': 'isDataVolumicIn4D(check4D, checkEverythingLoaded: true)',
    'check4D == YES || x == curMovieIndex': 'check4D || x == Int(horos_curMovieIndex)',
    'if( c == NO)': 'if !c {',
}


def spelled(text):
    """The Objective-C fragment, or its Swift spelling once the checks are Swift."""
    return SPELLING[text] if volume_swift else text
change = body(retrieve_and_view, 'func changeImageData(_ f: NSMutableArray!, _ d: NSMutableArray!, _ v: NSData!, _ newViewerWindow: Bool)')
peer_at = change.find('Try to find another viewer')
peer = change[peer_at:peer_at + 900] if peer_at >= 0 else ''

# --- the two-argument wrapper must pass both flags through -------------------
check(two_arg, 'the two-argument isDataVolumicIn4D:checkEverythingLoaded: is gone')
check(spelled('isDataVolumicIn4D: check4D checkEverythingLoaded: c tryToCorrect:') in comments_stripped(two_arg),
      'the two-argument overload must forward check4D and checkEverythingLoaded:')
check(spelled('isDataVolumicIn4D: NO checkEverythingLoaded: YES tryToCorrect: YES') not in comments_stripped(two_arg),
      'the two-argument overload must not discard its flags')
check(spelled('tryToCorrect: YES') in comments_stripped(two_arg),
      'the two-argument form still corrects; callers that must not mutate use three arguments')

# --- one-argument YES reaches 4D only if the wrapper keeps check4D -----------
check(one_arg and spelled('isDataVolumicIn4D: check4D checkEverythingLoaded: YES') in comments_stripped(one_arg),
      'the one-argument form must still pass check4D into the two-argument overload')
check(zero_arg and spelled('isDataVolumicIn4D: NO checkEverythingLoaded: YES tryToCorrect: YES') in comments_stripped(zero_arg),
      'isDataVolumic (no arguments) stays on the current timepoint and waits')

# --- three-argument form still honours check4D when deciding which movies ----
check(three_arg and spelled('check4D == YES || x == curMovieIndex') in three_arg,
      'the three-argument form must still inspect other 4D timepoints when check4D is YES')
check(three_arg and spelled('if( c == NO)') in three_arg,
      'the three-argument form must still honour checkEverythingLoaded: NO')

# --- callers: only the one-argument wrapper uses the two-argument form -------
# A two-argument send ends at checkEverythingLoaded: <token>]; three-argument
# sends name tryToCorrect: before that closing bracket.
two_arg_calls = []
for path in sources:
    text = comments_stripped(path.read_bytes().decode('latin1'))
    for match in re.finditer(
            r'isDataVolumicIn4D:\s*(\w+)\s*checkEverythingLoaded:\s*([\w.]+)\s*\]',
            text):
        two_arg_calls.append((path.name, match.group(1), match.group(2)))

# The Swift spelling of a two-argument call: isDataVolumicIn4D(x, checkEverythingLoaded: y).
for path in swift_sources:
    text = comments_stripped(path.read_bytes().decode('latin1'))
    for match in re.finditer(
            r'isDataVolumicIn4D\(\s*(\w+)\s*,\s*checkEverythingLoaded:\s*([\w.]+)\s*\)',
            text):
        two_arg_calls.append((path.name, match.group(1), match.group(2)))

check(two_arg_calls == ([('ViewerController+VolumeCheck.swift', 'check4D', 'true')] if volume_swift else [('ViewerController.m', 'check4D', 'YES')]),
      'only the one-argument wrapper may call the two-argument form; found %s' % two_arg_calls)

one_arg_yes = 0
one_arg_no = 0
one_call = re.compile(r'isDataVolumicIn4D:\s*(YES|NO)(?!\s*checkEverythingLoaded)')
for path in sources:
    text = comments_stripped(path.read_bytes().decode('latin1'))
    for match in one_call.finditer(text):
        if match.group(1) == 'YES':
            one_arg_yes += 1
        else:
            one_arg_no += 1

swift_one_call = re.compile(r'isDataVolumicIn4D\(\s*(true|false)\s*\)')
for path in swift_sources:
    text = comments_stripped(path.read_bytes().decode('latin1'))
    for match in swift_one_call.finditer(text):
        if match.group(1) == 'true':
            one_arg_yes += 1
        else:
            one_arg_no += 1

check(one_arg_yes >= 1, 'isDataVolumicIn4D: YES callers are gone; 4D inspection would be unused')
check(one_arg_no >= 1, 'isDataVolumicIn4D: NO callers are gone')

# --- the peer probe stays on the three-argument policy path -----------------
check(peer and 'SeriesReplaceLoadPolicy.' in peer,
      'peer probe must keep HorosSeriesReplaceLoadPolicy')
check('peerVolumicProbeWaitsForLoad' in peer and 'peerVolumicProbeCorrectsPeer' in peer,
      'peer probe must still name both policy flags')
check('tryToCorrect:' in peer,
      'peer probe must keep the three-argument form')
check(not re.search(r'isDataVolumicIn4D\(\s*false\s*,\s*checkEverythingLoaded:\s*true\s*\)',
                     comments_stripped(peer)),
      'peer probe must not go back to the two-argument wait-always call')

if failures:
    for item in failures:
        print('FAIL:', item)
    sys.exit(1)
print('ok: two-argument isDataVolumicIn4D:checkEverythingLoaded: forwards its flags')
