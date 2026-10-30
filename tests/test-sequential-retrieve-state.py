#!/usr/bin/env python3
"""Run production request initialization and iteration with injected DB outcomes.

The native --same-association probe covers the full C-GET path. This smaller
harness checks reset-before-failure and empty-result behavior without a database.

The listener's retrieve is SCPDatabaseSession+Retrieve.swift: its reset of the
previous request, its count and its iterator are compiled here as they are,
in a class that stands in for the session, with the fetch replaced by the
files, or the failure, the test injects.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/SCPDatabaseSession+Retrieve.swift').read_text()
start = source[source.index('    func startRetrieve(withSOPClass'):]
start = start[:start.index('\n    }\n')]
reset = '        retrievePaths = nil\n        retrievePosition = 0\n'
failures = []
if reset not in start:
    failures.append('a retrieve no longer resets the previous one')
elif not start.index(reset) < start.index('guard let context') < start.index('prepareRetrieve('):
    failures.append('the previous retrieve is reset after something that can fail or leave early')
prepare = source[source.index('    private func prepareRetrieve('):]
prepare = prepare[:prepare.index('\n    }\n')]
if not re.search(r'guard failure == nil else \{ return \}.*retrievePaths = ', prepare, re.S):
    failures.append('a fetch that failed can still leave files to send')


def member(signature):
    at = source.index(signature)
    opening = source.index('{', at)
    depth, index = 0, opening
    while True:
        depth += (source[index] == '{') - (source[index] == '}')
        index += 1
        if depth == 0:
            return source[at:index]


count = member('    var retrieveCount: Int')
iterator = member('    func nextRetrievePath() -> String?')
code = r'''
import Foundation
final class LogManager: NSObject {
    static func currentLogManager() -> Any? { nil }
    func addLogLine(_ line: Any) {}
}
final class Harness {
    var retrievePaths: [String]?
    var retrievePosition = 0
    var retrieveLog: NSMutableDictionary?
    static func int(_ value: Any?) -> Int32 { (value as? NSNumber)?.int32Value ?? 0 }
    /// startRetrieve's reset, then the fetch: its files, or a failure that leaves none.
    func prepare(_ files: [String], fail: Bool) {
RESET        if fail { return }
        retrievePaths = files
    }
COUNT
ITERATOR
}
let h = Harness()
func next() -> String? { h.nextRetrievePath() }
h.prepare(["first", "second", "third"], fail: false)
precondition(h.retrieveCount == 3 && next() == "first" && next() == "second")
h.prepare(["new-first", "new-second"], fail: false)
precondition(h.retrieveCount == 2 && next() == "new-first")
h.prepare([], fail: true)
precondition(h.retrieveCount == 0 && next() == nil, "a stale new-second after a failed request")
h.prepare([], fail: false)
precondition(h.retrieveCount == 0 && next() == nil)
h.prepare(["last"], fail: false)
precondition(next() == "last" && next() == nil)
print("PASS: production initialization and iterator isolate successive, failed and empty retrieval requests")
'''.replace('RESET', reset).replace('COUNT', count).replace('ITERATOR', iterator)

if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-retrieve-state-') as folder:
        p = Path(folder)
        (p / 'main.swift').write_text(code)
        built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(p / 'modules'), str(p / 'main.swift'),
                                '-o', str(p / 'test')], capture_output=True, text=True)
        if built.returncode:
            failures.append('the harness does not compile:\n' + built.stderr[-2000:])
        else:
            run = subprocess.run([str(p / 'test')], capture_output=True, text=True)
            print(run.stdout, end='')
            if run.returncode:
                failures.append('the harness failed: ' + run.stderr[-2000:])

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
