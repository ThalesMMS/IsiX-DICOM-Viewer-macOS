#!/usr/bin/env python3
"""Retrievals running at once give ListenerCompressionSettings back its value.

-[BrowserController comparativeRetrieve:] runs on up to five threads at once.
Each saved the ListenerCompressionSettings default, set it to 0 (no
decompression while the retrieved images are imported) and put the saved
value back when done. A retrieval that began while another held the 0 saved
that 0, and when it ended last it left the setting at 0 for good; one that
ended first put the value back under the other's feet. The browser does the
same when restoring a saved workspace with remote studies. Hanging protocols
use the shared comparative retrieval worker.

The harness takes from PatientHistoryList.swift (the retrieve that
-comparativeRetrieve: forwards to, DistantStudyRetrieves.retrieveNow) and
ViewerOpener.swift (the opening of the browser's studies), as they are, the statements of
each of those places that save, set and restore the setting (whatever
they are: the inline save and restore, or ListenerCompressionSuspension
since the fix), and compiles them into functions around a piece of
work, with ListenerCompressionSuspension.swift when the sources have it. The
defaults are an in-memory subclass of UserDefaults in place of the standard
ones, so nothing is written to disk.

- concurrent: with the setting at 3, eight threads run 150 retrievals each
  through those places (five of them the comparative one), each waiting
  a few hundred microseconds. During each retrieval the setting must be 0,
  and after the last one it must be 3 again.
- sequential: one retrieval at a time, through each place in turn, leaves the
  setting at 3 and holds it at 0 while it runs.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
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


def exists(path):
    if revision:
        return subprocess.run(['git', '-C', str(root), 'cat-file', '-e', f'{revision}:{path}'],
                              capture_output=True).returncode == 0
    return (root / path).is_file()


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text()


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

HELPER = 'Horos/Sources/ListenerCompressionSuspension.swift'
HISTORY = 'Horos/Sources/PatientHistoryList.swift'
OPENER = 'Horos/Sources/ViewerOpener.swift'


def function(text, signature):
    """The text of the Swift method with that signature, up to the next method."""
    start = text.find(signature)
    if start < 0:
        print(f'FAIL: {signature} not found')
        sys.exit(1)
    following = re.search(r'\n    (?:(?:private|nonisolated|static|@\w+) )*func ', text[start + len(signature):])
    return text[start:start + len(signature) + following.start() if following else len(text)]


def sites(text, where, count):
    """The statements that save, set and restore the setting, one (before, after) pair a place."""
    lines = [line.strip() for line in text.splitlines()
             if 'ListenerCompression' in line and not line.strip().startswith('//')]
    found, current = [], None
    for line in lines:
        if current is None:
            current = []
        if re.search(r'\.set\((copy|Int\(copy\)),|\.end\(\)', line):
            found.append((current, [line]))
            current = None
        else:
            current.append(line)
    if current is not None or len(found) != count or any(not before for before, _ in found):
        print(f'FAIL: {where}: expected {count} places that save and restore ListenerCompressionSettings, '
              f'found the statements {lines}')
        sys.exit(1)
    return found


def harness_statements(statements):
    return '\n'.join('    ' + line.replace('UserDefaults.standard', 'defaults')
                     .replace('ListenerCompressionSuspension.shared', 'suspension') for line in statements)


history = source(HISTORY)
at = history.find('func retrieveNow(')
if at < 0:
    print('FAIL: func retrieveNow( not found in %s' % HISTORY)
    sys.exit(1)
comparative = sites(history[at:history.find('// MARK:', at)], 'retrieveNow', 1)
# The comparative studies a hanging protocol waits for, and a workspace's
# study retrieved from a node.
opener = source(OPENER)
opening = sites(function(opener, 'private func retrieveIfMissing(studyUID:'), 'databaseOpenStudy:', 1)
if 'private func comparativeStudies(of ' in opener:
    opening = sites(function(opener, 'private func comparativeStudies(of '), 'databaseOpenStudy:withProtocol:', 1) + opening
places = comparative + opening
helper = exists(HELPER)

functions = ''
for index, (before, after) in enumerate(places):
    functions += f'''
func retrieval{index}(_ work: () -> Void) {{
{harness_statements(before)}
    work()
{harness_statements(after)}
}}
'''

MAIN = r'''
import Foundation

// The defaults, kept in memory: the setting never reaches a preferences file.
final class MemoryDefaults: UserDefaults {
    private let storeLock = NSLock()
    private var store: [String: Int] = [:]
    override func integer(forKey key: String) -> Int {
        storeLock.lock(); defer { storeLock.unlock() }
        return store[key] ?? 0
    }
    override func set(_ value: Int, forKey key: String) {
        storeLock.lock(); defer { storeLock.unlock() }
        store[key] = value
    }
    override func set(_ value: Any?, forKey key: String) {
        print("FAIL: the setting was written as \(String(describing: value)), not as an integer")
        exit(1)
    }
}
let defaults: UserDefaults = MemoryDefaults(suiteName: "horos-listener-compression-849")!
''' + ('let suspension = ListenerCompressionSuspension(defaults: defaults)\n' if helper else '') + functions + r'''
let sites: [(() -> Void) -> Void] = [RETRIEVAL_SITES]
let places = Array(repeating: sites[0], count: 5) + [sites[1], sites.last!, sites[1]]
let lock = NSLock()
var wrong = 0
var wrongValue = 0

func work() {
    let value = defaults.integer(forKey: "ListenerCompressionSettings")
    if value != 0 {
        lock.lock(); wrong += 1; wrongValue = value; lock.unlock()
    }
    usleep(UInt32.random(in: 50...400))
}

func finish(_ case_: String) -> Int32 {
    let value = defaults.integer(forKey: "ListenerCompressionSettings")
    var failed = false
    if wrong > 0 {
        print("FAIL: \(case_): \(wrong) retrievals saw the setting at \(wrongValue), not 0, while they ran")
        failed = true
    }
    if value != 3 {
        print("FAIL: \(case_): after the retrievals the setting is \(value), not 3")
        failed = true
    }
    if !failed {
        print("the setting was 0 during each retrieval and is 3 after them")
    }
    return failed ? 1 : 0
}

let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
defaults.set(3, forKey: "ListenerCompressionSettings")
if which == "concurrent" {
    let group = DispatchGroup()
    for place in places {
        group.enter()
        Thread.detachNewThread {
            for _ in 0..<150 { place(work) }
            group.leave()
        }
    }
    group.wait()
    exit(finish(which))
} else if which == "sequential" {
    for _ in 0..<5 {
        for site in sites { site(work) }
    }
    exit(finish(which))
} else {
    print("FAIL: unknown case \(which)")
    exit(64)
}
'''

MAIN = MAIN.replace('RETRIEVAL_SITES', ', '.join(f'retrieval{i}' for i in range(len(places))))

CASES = [
    ('concurrent', 'eight threads retrieving at once hold the setting at 0 and give it back its value'),
    ('sequential', 'retrievals one at a time hold the setting at 0 and give it back its value'),
]

failures = []
with tempfile.TemporaryDirectory(prefix='horos-listener-compression-849-') as tmp:
    tmp = Path(tmp)
    (tmp / 'main.swift').write_text(MAIN)
    inputs = [str(tmp / 'main.swift')]
    if helper:
        (tmp / 'ListenerCompressionSuspension.swift').write_text(source(HELPER))
        inputs.append(str(tmp / 'ListenerCompressionSuspension.swift'))
    try:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-g',
                        *inputs, '-o', str(tmp / 'harness')], check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print('FAIL: the harness did not build:', (e.stderr or b'').decode(errors='replace')[-3000:])
        sys.exit(1)

    for case, claim in CASES:
        try:
            result = subprocess.run([str(tmp / 'harness'), case], capture_output=True, text=True, timeout=120)
        except subprocess.TimeoutExpired:
            failures.append(f'{claim}: timed out')
            continue
        lines = [line for line in (result.stdout + result.stderr).splitlines() if line.strip()]
        if result.returncode == 0:
            print('ok:', claim, '-', lines[-1] if lines else 'exit 0')
        else:
            detail = '; '.join(line[len('FAIL: '):] for line in lines if line.startswith('FAIL:')) or \
                (lines[-1] if lines else f'exit {result.returncode}')
            failures.append(f'{claim}: {detail}')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: retrievals running at once, and one at a time, hold ListenerCompressionSettings at 0 and '
      'give it back its value')
