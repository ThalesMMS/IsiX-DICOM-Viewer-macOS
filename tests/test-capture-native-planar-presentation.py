#!/usr/bin/env python3
"""The native planar capturer activates the application and refuses an inactive snapshot.

tools/verify-native-planar-presentation.py only accepts a capture of an active
application, so a capture of an inactive one must fail when it is taken, with
nothing saved, rather than later in the verifier. The capturer runs here against
stand-ins for LLDB (xcrun) and LaunchServices (lsappinfo) on PATH, without
opening the application. The LLDB stand-in records every attach and answers the
capture's attach with the snapshot each case chooses, written where the capture
expression writes it: the state at the staged path and the output image beside
it, as an inactive application did before the capturer checked. The
LaunchServices stand-in reports the application in front, another one in front,
or never answers, so the wait for the front stays bounded and only the
snapshot decides. The commands the capturer prepares are read too: the snapshot
itself must read the activity before it writes anything, and write only the
refusal state when the application is inactive.

An optional argument runs another capturer instead, such as an earlier version.
"""
from pathlib import Path
import json
import os
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
capturer = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'tools/capture-native-planar-presentation.py'
PID = 424242
BUNDLE = 'thalesmms.isis.workstation.planar-performance'
TITLE = 'A111 NM low contrast'
# The capturer waits at most 3 s for the front, then 1 s more once it is there.
WAIT, SETTLE, SLACK = 3, 1, 2.5

FAKE_LLDB = r'''#!PYTHON
import json, os, re, sys, time
from pathlib import Path
arguments = sys.argv[1:]
call = {'arguments': arguments, 'time': time.monotonic()}
if '-s' in arguments:
    commands = Path(arguments[arguments.index('-s') + 1]).read_text()
    staged = re.search(r'@"([^"]*\.partial)"', commands)[1]
    base = staged.rsplit('.', 2)[0]
    if os.environ['FAKE_STATE']:
        Path(staged).write_text(os.environ['FAKE_STATE'])
        Path(base + '.bgra').write_bytes(bytes(16))
    else:
        # The synthetic guard stopped the snapshot inside its layer loop.
        Path(base + '-layer-0.f32').write_bytes(bytes(16))
with open(os.environ['FAKE_CALLS'], 'a') as calls:
    calls.write(json.dumps(call) + '\n')
'''

FAKE_LAUNCH_SERVICES = r'''#!PYTHON
import os, sys, time
front = os.environ['FAKE_FRONT']
if front == 'hang':
    time.sleep(30)
elif sys.argv[1:] == ['front']:
    print('ASN:0x0-0x67b32:' if front == 'self' else 'ASN:0x0-0x1d01d:')
elif sys.argv[1:] == ['find', 'pid=PID']:
    print('ASN:0x0-0x67b32-"Fake":')
'''.replace('PID', str(PID))

SNAPSHOT = {'captureAPI': 'horosPlanarPixelsWidth:height:inverted:+uploaded-texture', 'captureError': 0,
            'rowOrder': 'bottom-up', 'metalEnabled': True, 'fallback': '', 'keyWindow': '', 'layers': [],
            'viewSize': [2, 2]}
INACTIVE = {'applicationActive': False}
# label, snapshot (None: the synthetic guard refused), what LaunchServices says, whether a capture is saved
CASES = (
    ('active', dict(SNAPSHOT, applicationActive=True), 'self', True),
    ('inactive', dict(SNAPSHOT, applicationActive=False), 'self', False),
    ('inactive-refusal-state', INACTIVE, 'self', False),
    ('never-in-front', INACTIVE, 'other', False),
    ('launch-services-silent', INACTIVE, 'hang', False),
    ('guard-refused', None, 'self', False),
)
# Another label's capture in the same folder, which a refusal must leave alone.
OTHERS = ('keep.json', 'keep.bgra', 'keep-layer-0.f32', 'guard-refused-layer-1-layer-0.f32', 'guard-refused-layer-1.json')

failures = []


def report(ok, message):
    if not ok:
        failures.append(message)


def run(label, state, front, *extra):
    with tempfile.TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        tools = temporary / 'bin'
        tools.mkdir()
        for name, source in (('xcrun', FAKE_LLDB), ('lsappinfo', FAKE_LAUNCH_SERVICES)):
            (tools / name).write_text(source.replace('#!PYTHON', '#!' + sys.executable, 1))
            (tools / name).chmod(0o755)
        output, calls = temporary / 'captures', temporary / 'calls.jsonl'
        output.mkdir()
        for name in OTHERS:
            (output / name).write_bytes(b'other')
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'], FAKE_FRONT=front,
                           FAKE_STATE=json.dumps(state) if state is not None else '', FAKE_CALLS=str(calls))
        result = subprocess.run([sys.executable, str(capturer), label, '--pid', str(PID), '--bundle-id', BUNDLE,
                                 '--title-prefix', TITLE, '--output', str(output), *extra],
                                cwd=temporary, env=environment, capture_output=True, text=True, timeout=60)
        recorded = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        files = {path.name: path.read_bytes() for path in output.iterdir()}
        return result, recorded, files


def check_prepared():
    """The snapshot reads [NSApp isActive] first and, inactive, writes only the refusal state."""
    result, calls, files = run('prepared', None, 'self', '--prepare-only')
    report(result.returncode == 0 and not calls, 'prepared: --prepare-only failed or attached to the application')
    commands = files.get('prepared.lldb', b'').decode()
    expression = next((line for line in commands.splitlines() if 'writeToFile:' in line), '')
    active = re.search(r'BOOL (\w+)=\(BOOL\)\[\(NSApplication\*\)NSApp isActive\];', expression)
    report(active is not None, 'prepared: the snapshot does not read [NSApp isActive]')
    if active is None:
        return
    name = active[1]
    report(expression.count('isActive]') == 1 and active.start() < expression.index('writeToFile:'),
           'prepared: the activity is not read once, before anything is written')
    report('@"applicationActive":@(%s)' % name in expression, 'prepared: the saved state does not carry the activity read')
    capture = 'if (a111Synthetic && %s) {' % name
    report(capture in expression, 'prepared: the capture does not depend on the activity read')
    if capture in expression:
        before, after = expression.split(capture, 1)
        refusal = re.search(r'if \(a111Synthetic && !%s\)\s+\[\[NSJSONSerialization dataWithJSONObject:'
                            r'@\{@"applicationActive":@NO\} options:0 error:nil\]writeToFile:@"[^"]*\.partial"' % name, before)
        report(refusal is not None and before.count('writeToFile:') == 1,
               'prepared: an inactive snapshot writes more than the refusal state at the staged path')
        report('.bgra' in after, 'prepared: the output image is not written by the active capture')


check_prepared()
for label, state, front, saved in CASES:
    result, calls, files = run(label, state, front)
    attaches = [call for call in calls if call['arguments'][:4] == ['lldb', '--batch', '-p', str(PID)]]
    activation = next((index for index, call in enumerate(attaches)
                       if any('activateIgnoringOtherApps:YES' in argument and '@"%s"' % BUNDLE in argument
                              and '@"%s"' % TITLE in argument for argument in call['arguments'])), None)
    capture = next((index for index, call in enumerate(attaches) if '-s' in call['arguments']), None)
    report(activation is not None, label + ': the capturer never asked the synthetic viewer\'s application to activate')
    report(capture is not None, label + ': the capturer never attached for the capture')
    if activation is not None and capture is not None:
        report(activation < capture, label + ': the application was asked to activate only after the capture')
        gap = attaches[capture]['time'] - attaches[activation]['time']
        if front == 'self':
            report(gap >= SETTLE * 0.9, label + ': the capture did not let the activation settle (%.1f s)' % gap)
        else:
            report(gap <= WAIT + SLACK, label + ': the wait for the front was not bounded (%.1f s)' % gap)
    if saved:
        report(result.returncode == 0, label + ': an active capture failed: ' + result.stderr.strip())
        capture_state = json.loads(files.get(label + '.json', b'{}'))
        report(capture_state.get('applicationActive') is True and
               label + '.bgra' in capture_state.get('captureHashes', {}),
               label + ': the active capture was not saved with its hashes')
    else:
        report(result.returncode != 0, label + ': a refused capture was accepted')
        expected = 'synthetic guard refused' if state is None else 'not active'
        report(expected in result.stderr and 'Traceback' not in result.stderr,
               label + ': the refusal does not say why: ' + result.stderr.strip()[-300:])
        left = sorted(name for name in files if name not in (label + '.lldb', label + '.lldb.log') + OTHERS)
        report(not left, label + ': a refused capture left files behind: ' + ', '.join(left))
    report(all(files.get(name) == b'other' for name in OTHERS), label + ': another capture in the folder was changed')

if failures:
    for failure in failures:
        print('FAIL: %s' % failure)
    sys.exit(1)
print('ok')
