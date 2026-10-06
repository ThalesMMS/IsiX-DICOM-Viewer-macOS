#!/usr/bin/env python3
"""Run BLAuthentication.getPID's real source without authorization/UI.

A Python child carries a unique literal command-line label. Queries enter the
Swift probe over stdin, so the probe's own arguments cannot accidentally match.
Only getPID is extracted: no privilege acquisition, kill or install code runs.
An optional git revision is a negative control. Historical code may compile
with its original deprecation warnings; the current source must pass Swift 6,
complete strict concurrency and warnings as errors.
"""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'Horos/Sources/BLAuthentication.swift'
revision = sys.argv[1] if len(sys.argv) > 1 else None
if not shutil.which('xcrun'):
    print('skipped: needs xcrun swiftc on macOS', file=sys.stderr)
    sys.exit(2)
text = (subprocess.check_output(['git', '-C', str(ROOT), 'show', f'{revision}:{SOURCE}']).decode()
        if revision else (ROOT / SOURCE).read_text())
start = text.index('    @objc(getPID:)')
opening = text.index('{', start)
depth = 1
end = opening + 1
while depth and end < len(text):
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
assert depth == 0, 'getPID body is incomplete'
method = text[start:end]
DRIVER = '''
import AppKit
final class BLAuthentication: NSObject {
ACTUAL_METHOD
}
let input = FileHandle.standardInput.readDataToEndOfFile()
let queries = try JSONDecoder().decode([String?].self, from: input)
let lookup = BLAuthentication()
let results = queries.map { lookup.getPID($0) }
FileHandle.standardOutput.write(try JSONEncoder().encode(results))
'''.replace('ACTUAL_METHOD', method)

with tempfile.TemporaryDirectory(prefix='horos-auth-process-') as temporary:
    work = Path(temporary)
    source = work / 'main.swift'
    binary = work / 'process-lookup-probe'
    source.write_text(DRIVER)
    flags = ['-swift-version', '6', '-strict-concurrency=complete']
    if not revision:
        flags.append('-warnings-as-errors')
    built = subprocess.run(['xcrun', 'swiftc', *flags, str(source), '-o', str(binary)],
                           capture_output=True, text=True)
    assert built.returncode == 0, built.stdout + built.stderr
    if built.stderr:
        print(built.stderr, file=sys.stderr, end='')

    token = 'horos-auth-' + uuid.uuid4().hex
    # Spaces, both quote forms, UTF-8 and regex metacharacters must all be literal.
    label = token + ' spaces \'single\' "double" café 漢字 [a-z].*+$^'
    marker = work / 'shell-marker'
    payload = f'$(touch {marker})'
    child = subprocess.Popen([sys.executable, '-c',
                              'import sys,time; print("ready",flush=True); time.sleep(30)',
                              label, payload], stdout=subprocess.PIPE, text=True)
    try:
        assert child.stdout.readline().strip() == 'ready', 'child did not start'
        # Run the injection control first, while its literal text is in the child.
        ran = subprocess.run([str(binary)], input=json.dumps([payload]),
                             capture_output=True, text=True, timeout=10)
        assert ran.returncode == 0, ran.stdout + ran.stderr
        assert not marker.exists(), 'shell payload executed: disposable marker was created'
        assert json.loads(ran.stdout) == [child.pid], 'payload must match the literal child argument'

        queries = [label, token, token + '.*', None, '', token + '-absent', str(binary)]
        expected = [child.pid, child.pid, 0, 0, 0, 0]
        known = subprocess.Popen([str(binary)], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            output, errors = known.communicate(json.dumps(queries), timeout=10)
        except subprocess.TimeoutExpired:
            known.kill()
            known.communicate()
            raise
        assert known.returncode == 0, output + errors
        values = json.loads(output)
        assert values[:6] == expected, (queries, values, expected)
        assert len(values) == 7 and values[6] == known.pid, values
        assert not marker.exists(), 'shell marker appeared during later lookups'
    finally:
        child.terminate()
        child.wait(timeout=5)
        child.stdout.close()
print('ok: real getPID, literal Python-child PID (spaces/quotes/Unicode/regex), '
      'shell payload inert, nil/empty/absent zero, known process; Swift 6 strict/Werror')
