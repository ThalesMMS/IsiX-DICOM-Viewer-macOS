#!/usr/bin/env python3
"""A rebuild that stops says why, even when the save gave no error (#863).

-rebuild: stops with a DatabaseRebuildFailure exception whose userInfo named
the underlying error as @{NSUnderlyingErrorKey: error}. A save can fail
without returning an error, and then the literal itself raised, for inserting
nil: the exception that reached the person was about a dictionary, not about
the database. The key is now left out when there is no error, and the reason
is never nil. The count of files it summed and never read is gone too.

The helper runs compiled from the source with xcrun swiftc; where -rebuild:
uses it is read from the source. `<git revision>` as an optional argument
reads the sources of that revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []
SOURCE = 'Horos/Sources/DicomDatabase+Other.swift'
BRIDGE = 'Horos/Sources/DicomDatabase+SwiftIvars.m'


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text()


text = read(SOURCE)
bridge = read(BRIDGE)
start = text.find('@objc(rebuild:)')
end = text.find('@objc(', start + 1)
rebuild = text[start:end] if start >= 0 and end > start else ''
if not rebuild:
    failures.append('-rebuild: is not in %s' % SOURCE)

match = re.search(r'^private func rebuildFailure\(.*?^}\n', text, re.S | re.M)
helper = match.group(0) if match else None
if helper is None:
    failures.append('there is no rebuild failure that tolerates a missing error')
if 'NSUnderlyingErrorKey: error}' in bridge:
    failures.append('the Objective-C literal that raises for a nil error is still there')
if 'DicomDatabaseRebuildFailure(' in rebuild:
    failures.append('-rebuild: still builds its exception with the literal that raises for a nil error')
raised = re.findall(r'NSException\(name: NSExceptionName\("DatabaseRebuildFailure"\)[^\n]*', rebuild)
for line in raised:
    if 'NSUnderlyingErrorKey' in line:
        failures.append('-rebuild: builds its own underlying error key: %s' % line.strip())
if rebuild.count('rebuildFailure(') < 5:
    failures.append('not every stop of -rebuild: with an error goes through the tolerant exception '
                    '(%d of 5)' % rebuild.count('rebuildFailure('))
if 'totalFiles' in rebuild:
    failures.append('-rebuild: still sums a count of files that nothing reads')

DRIVER = '''
import Foundation

func emit(_ key: String, _ value: String) { print("\\(key)\\t\\(value)") }

let silent = rebuildFailure(nil)
emit("silent.name", silent.name.rawValue)
emit("silent.reason", silent.reason ?? "<nil>")
emit("silent.key", silent.userInfo?[NSUnderlyingErrorKey] == nil ? "absent" : "present")

let cause = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
let named = rebuildFailure(cause)
emit("named.reason", named.reason == cause.localizedDescription ? "same" : named.reason ?? "<nil>")
emit("named.key", (named.userInfo?[NSUnderlyingErrorKey] as? NSError) === cause ? "cause" : "other")
'''

results = {}
if helper is not None:
    with tempfile.TemporaryDirectory(prefix='horos-rebuild-failure-') as directory:
        directory = Path(directory)
        # File-private in the app; the driver is another file.
        (directory / 'helper.swift').write_text('import Foundation\n\n' + helper.replace('private func ', 'func '))
        (directory / 'main.swift').write_text(DRIVER)
        binary = directory / 'rebuild-failure'
        built = subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-o', str(binary),
                                str(directory / 'helper.swift'), str(directory / 'main.swift')],
                               capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the rebuild failure does not compile:\n%s' % built.stderr[-1500:])
        else:
            run = subprocess.run([str(binary)], capture_output=True, text=True)
            if run.returncode != 0:
                failures.append('the driver failed: %s' % run.stderr[-800:])
            for line in run.stdout.splitlines():
                key, _, value = line.partition('\t')
                results[key] = value

if results:
    expected = {'silent.name': 'DatabaseRebuildFailure', 'silent.key': 'absent',
                'named.reason': 'same', 'named.key': 'cause'}
    for key, want in expected.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))
    if results.get('silent.reason') in (None, '', '<nil>'):
        failures.append('a save that failed without an error stops the rebuild with no reason')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a rebuild that stops names the underlying error when there is one, and still has a reason when there is not')
