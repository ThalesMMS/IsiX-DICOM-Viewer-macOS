#!/usr/bin/env python3
"""Exercise the production C-STORE publication hook against real filesystem errors.

The listener's database (SCPDatabaseSession.swift) moves each complete
received file into the incoming folder; its method is compiled here as it is,
with the database's incoming folder given by the test. The DCMTK adapter's
storeRequest (IsiXDCMTKSCPDatabase.mm) refuses the C-STORE with Out of
resources and that message when the publication fails, before any Success.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/SCPDatabaseSession.swift').read_text()
start = source.index('    func publishReceivedFile(atPath path: String) -> String? {')
method = source[start:source.index('\n    }\n', start) + 7]

failures = []
adapter = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKSCPDatabase.mm').read_text()
store = adapter[adapter.index('OFCondition IsiXDCMTKSCPDatabaseHandle::storeRequest('):]
store = store[:store.index('\n}\n')]
if not re.search(r'NSString \*failure = \[state_->database publishReceivedFileAtPath:file\];\s*if \(failure\) \{\s*'
                 r'status->setStatus\(STATUS_STORE_Refused_OutOfResources\);\s*'
                 r'return makeOFCondition\(OFM_imagectn, 0x001, OF_error, failure\.UTF8String \?: ""\);', store) \
        or store.index('publishReceivedFileAtPath') > store.index('status->setStatus(STATUS_Success)'):
    failures.append('the adapter no longer refuses a C-STORE whose file could not be published, before Success')

code = r'''
import Foundation
import Darwin
nonisolated(unsafe) var incoming = ""
final class DicomDatabase {
    static func activeLocal() -> DicomDatabase? { DicomDatabase() }
    func incomingDirPathC() -> UnsafePointer<CChar>? { UnsafePointer(strdup(incoming)) }
}
final class Session {
METHOD
}
func writeFile(_ path: String) { precondition(FileManager.default.createFile(atPath: path, contents: Data("synthetic payload".utf8))) }
func exists(_ path: String) -> Bool { access(path, F_OK) == 0 }
precondition(chdir(CommandLine.arguments[1]) == 0 && mkdir("incoming", 0o700) == 0)
let session = Session()
incoming = "incoming"
writeFile("received")
precondition(session.publishReceivedFile(atPath: "received") == nil)
precondition(!exists("received") && exists("incoming/received"))
for scenario in 0..<4 {
    writeFile("pending")
    incoming = scenario == 0 ? "missing" : scenario == 1 ? "incoming" : "blocked"
    if scenario == 1 { precondition(chmod("incoming", 0o500) == 0) }
    if scenario == 2 { writeFile("blocked") }
    if scenario == 3 { unlink("blocked"); precondition(mkdir("blocked", 0o700) == 0 && mkdir("blocked/pending", 0o700) == 0) }
    let failure = session.publishReceivedFile(atPath: "pending")
    precondition(failure != nil, "scenario \(scenario) published")
    precondition(failure!.contains(incoming) && failure!.contains("errno"), "scenario \(scenario): \(failure!)")
    precondition(exists("pending"), "the caller still owns cleanup after a failed publication")
    precondition(chmod("incoming", 0o700) == 0)
    unlink("pending")
}
incoming = "incoming"
writeFile("retry")
precondition(session.publishReceivedFile(atPath: "retry") == nil)
print("PASS: publication precedes success; missing, read-only and conflicting destinations return refusal and preserve source; retry succeeds")
'''.replace('METHOD', method)

if not failures:
    with tempfile.TemporaryDirectory(prefix='horos-store-publication-') as folder:
        p = Path(folder)
        (p / 'work').mkdir()
        (p / 'main.swift').write_text(code)
        built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(p / 'modules'), str(p / 'main.swift'),
                                '-o', str(p / 'test')], capture_output=True, text=True)
        if built.returncode:
            failures.append('the publication does not compile on its own:\n' + built.stderr[-2000:])
        else:
            run = subprocess.run([str(p / 'test'), str(p / 'work')], capture_output=True, text=True)
            print(run.stdout, end='')
            if run.returncode:
                failures.append('the publication failed: ' + run.stderr[-2000:])

for failure in failures:
    print('FAIL:', failure)
sys.exit(1 if failures else 0)
