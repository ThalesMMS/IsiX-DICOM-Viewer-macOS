#!/usr/bin/env python3
"""Retrievals that need their images at once have them imported as they arrive, and the setting is never written.

-[BrowserController comparativeRetrieve:] runs on up to five threads at once.
Each saved the ListenerCompressionSettings default, set it to 0 (no
decompression while the retrieved images are imported) and put the saved
value back when done. A retrieval that began while another held the 0 saved
that 0, and when it ended last it left the setting at 0 for good; one that
ended first put the value back under the other's feet. The browser did the
same on the main thread when it opened a study whose hanging protocol or
saved workspace needed studies of a DICOM node. Both then handed those studies
to one retrieve, which counted the retrievals running and stored the 0 for the
first and the saved value for the last: an application that ended during a
retrieval still left the 0 as the user's setting, and a value that was only
the registered one was stored as the user's. The retrievals now hold a state
of the process (ListenerCompressionSuspension.shared), which the import of the
incoming folder asks; the setting stays as the user has it.

The harness takes from PatientHistoryList.swift (the retrieve that
-comparativeRetrieve: forwards to, DistantStudyRetrieves.retrieveNow), as it
is, the statements that begin and end the suspension, and compiles them into a
function around a piece of work (the guard it runs the retrieval in, since
it has one), with ListenerCompressionSuspension.swift, PreferenceWorkGuards.swift,
HorosObjCException and the IsiXPreferences module. What the import reads is the expression of
IncomingAdmission.listenerCompressionSettings, as it is. ViewerOpener.swift
(the opening of the browser's studies) must not touch the setting. The
preferences are a suite of the test's own, in its TMPDIR.

- concurrent: with the setting stored at 3, eight threads run 150 retrievals
  each, each waiting a few hundred microseconds. During each retrieval the
  import must read 0 and the stored preferences must be as before; after the
  last one the import reads 3 again.
- sequential: one retrieval at a time: the same.
- registered: the setting only registered (3): the import reads 0 during a
  retrieval and 3 after, and nothing is stored.
- abandoned: a retrieval that never ends, as when the application ends in
  the middle: what is stored is still the user's 3.
- raising: a retrieval that raises an NSException, which reaches its caller:
  the suspension has ended, and the import reads 3 again.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control: a revision that stored the 0 fails.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile

import harness_defaults
import isix_modules
import objc_exception_guards

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
ADMISSION = 'Horos/Sources/IncomingAdmission.swift'


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
        if current is None and line.endswith('ListenerCompressionSuspension.shared.whileWorking {'):
            # The retrieval runs inside the guard, which ends the suspension when it returns or raises.
            found.append(([line], ['}']))
            continue
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


def harness_statements(statements, shared):
    return '\n'.join('    ' + (line if shared else line.replace('ListenerCompressionSuspension.shared', 'suspension'))
                     .replace('UserDefaults.standard', 'defaults') for line in statements)


history = source(HISTORY)
at = history.find('func retrieveNow(')
if at < 0:
    print('FAIL: func retrieveNow( not found in %s' % HISTORY)
    sys.exit(1)
comparative = sites(history[at:history.find('// MARK:', at)], 'retrieveNow', 1)
# The opening of a study goes through that retrieve for the comparative
# studies a hanging protocol waits for and for a workspace's study that a node
# has. A revision that still retrieved them itself has those places taken too.
opener = source(OPENER)
opening = []
if 'private func comparativeStudies(of ' in opener:
    opening += sites(function(opener, 'private func comparativeStudies(of '), 'databaseOpenStudy:withProtocol:', 1)
if 'private func retrieveIfMissing(studyUID:' in opener:
    opening += sites(function(opener, 'private func retrieveIfMissing(studyUID:'), 'databaseOpenStudy:', 1)
if not opening:
    touching = [line.strip() for line in opener.splitlines()
                if 'ListenerCompression' in line and not line.strip().startswith('//')]
    if touching:
        print(f'FAIL: {OPENER} touches ListenerCompressionSettings outside the retrieve of the history: {touching}')
        sys.exit(1)
    if 'retrieves.retrieveNow(' not in opener:
        print(f'FAIL: {OPENER} no longer retrieves the studies of a node through DistantStudyRetrieves.retrieveNow')
        sys.exit(1)
places = comparative + opening
helper = exists(HELPER)
# The state the retrievals hold, or (a revision before it) the object that stored the 0.
shared = helper and 'ForcedPreference' in source(HELPER)
admission = source(ADMISSION) if exists(ADMISSION) else ''
reads = re.search(r'var listenerCompressionSettings: Int32 \{\n\s*(.+)\n', admission)
if not reads:
    print(f'FAIL: {ADMISSION} no longer has the listenerCompressionSettings the import reads')
    sys.exit(1)
if shared and 'ListenerCompressionSuspension.shared.value(in: preferences)' not in reads.group(1):
    print(f'FAIL: the import of the incoming folder does not ask the suspension: {reads.group(1)}')
    sys.exit(1)

functions = ''
for index, (before, after) in enumerate(places):
    # A retrieval that begins and never ends: the guard's beginning alone.
    begun = [line.replace('.whileWorking {', '.begin()') for line in before]
    functions += f"""
func retrieval{index}(_ work: () -> Void) {{
{harness_statements(before, shared)}
    work()
{harness_statements(after, shared)}
}}
func retrievalBegun{index}() {{
{harness_statements(begun, shared)}
}}
"""

MAIN = harness_defaults.DOMAINS + r"""
import IsiXPreferences

// The preferences: a suite of the test's own, in a file of its TMPDIR.
let suite = harnessDomainName("listener-compression-\(getpid())")
let defaults = UserDefaults(suiteName: suite)!
let preferences = defaults
func stored() -> [String: Int] { (defaults.persistentDomain(forName: suite) ?? [:]).compactMapValues { $0 as? Int } }
/// What the import of the incoming folder reads.
func imported() -> Int32 { READS }
""" + ('let suspension = ListenerCompressionSuspension(defaults: defaults)\n' if helper and not shared else '') + functions + r"""
let sites: [(() -> Void) -> Void] = [RETRIEVAL_SITES]
let begun: [() -> Void] = [RETRIEVALS_BEGUN]
// Five threads through the retrieve of the history, three through the places of the opening, if any.
let places = Array(repeating: sites[0], count: 5) + (0..<3).map { sites[sites.count > 1 ? 1 + $0 % (sites.count - 1) : 0] }
let lock = NSLock()
nonisolated(unsafe) var wrong = 0
nonisolated(unsafe) var wrongValue: Int32 = 0
nonisolated(unsafe) var written = 0
nonisolated(unsafe) var before: [String: Int] = [:]

func work() {
    let value = imported()
    let changed = stored() != before
    if value != 0 || changed {
        lock.lock()
        if value != 0 { wrong += 1; wrongValue = value }
        if changed { written += 1 }
        lock.unlock()
    }
    usleep(UInt32.random(in: 50...400))
}

func finish(_ case_: String) -> Int32 {
    var failed = false
    if wrong > 0 {
        print("FAIL: \(case_): \(wrong) retrievals had the import read \(wrongValue), not 0, while they ran")
        failed = true
    }
    if written > 0 {
        print("FAIL: \(case_): the stored preferences were not the user's during \(written) retrievals")
        failed = true
    }
    if imported() != 3 {
        print("FAIL: \(case_): after the retrievals the import reads \(imported()), not 3")
        failed = true
    }
    if stored() != before {
        print("FAIL: \(case_): after the retrievals the stored preferences are \(stored()), not \(before)")
        failed = true
    }
    if !failed {
        print("the import read 0 during each retrieval and reads 3 after them; the stored preferences stayed \(before)")
    }
    defaults.removePersistentDomain(forName: suite)
    return failed ? 1 : 0
}

let which = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
if which == "registered" {
    defaults.register(defaults: ["ListenerCompressionSettings": 3])
} else {
    defaults.set(3, forKey: "ListenerCompressionSettings")
}
defaults.set(7, forKey: "sentinel")
before = stored()
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
} else if which == "sequential" || which == "registered" {
    for _ in 0..<5 {
        for site in sites { site(work) }
    }
    exit(finish(which))
} else if which == "raising" {
    // A retrieval that raises: the exception reaches its caller, and the suspension has ended.
    for site in sites {
        let raised = HorosObjCException.caught {
            site {
                work()
                NSException(name: .genericException, reason: "the retrieve", userInfo: nil).raise()
            }
        }
        if raised?.reason != "the retrieve" {
            print("FAIL: raising: the exception of the retrieval did not reach its caller")
            exit(1)
        }
    }
    exit(finish(which))
} else if which == "abandoned" {
    // The retrieval begins and the application ends: only what is stored is left.
    for begin in begun { begin() }
    work()
    let left = stored()
    defaults.removePersistentDomain(forName: suite)
    if wrong > 0 || left != before {
        print("FAIL: abandoned: a retrieval that never ended had the import read \(wrong > 0 ? wrongValue : 0) and left \(left) stored, not \(before)")
        exit(1)
    }
    print("a retrieval that never ended left the stored preferences at \(before)")
    exit(0)
} else {
    print("FAIL: unknown case \(which)")
    exit(64)
}
"""

MAIN = MAIN.replace('READS', reads.group(1))
MAIN = MAIN.replace('RETRIEVALS_BEGUN', ', '.join(f'retrievalBegun{i}' for i in range(len(places))))
MAIN = MAIN.replace('RETRIEVAL_SITES', ', '.join(f'retrieval{i}' for i in range(len(places))))

CASES = [
    ('concurrent', 'eight threads retrieving at once have the import read 0, and the setting is not written'),
    ('sequential', 'retrievals one at a time have the import read 0, and the setting is not written'),
    ('registered', 'a setting that is only the registered one is not stored as the user\'s'),
    ('abandoned', 'a retrieval that never ends leaves the user\'s setting stored'),
    ('raising', 'a retrieval that raises ends its suspension: the import reads the setting again'),
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
        # The guards the retrieval runs in, as they stand, over the real HorosObjCException.
        (tmp / 'guards.swift').write_text(objc_exception_guards.source(log=False))
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=15.0', '-c', str(root / 'Horos/Sources/HorosObjCException.m'),
                        '-o', str(tmp / 'HorosObjCException.o')], check=True, capture_output=True)
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'Horos', '-g',
                        '-import-objc-header', str(root / 'Horos/Sources/HorosObjCException.h'),
                        *isix_modules.module_flags('IsiXPreferences', tmp / 'modules'),
                        *inputs, str(tmp / 'guards.swift'), str(root / 'Horos/Sources/PreferenceWorkGuards.swift'),
                        str(tmp / 'HorosObjCException.o'), '-o', str(tmp / 'harness')], check=True, capture_output=True)
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
print('PASS: retrievals running at once, one at a time, never ended and raising have the import read 0 while they run '
      'and the setting again afterwards, and ListenerCompressionSettings is never written, stored or only registered')
