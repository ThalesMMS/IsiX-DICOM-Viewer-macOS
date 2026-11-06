#!/usr/bin/env python3
"""A portal made before the first-use database opens must get that database.

Compile the actual WebPortal method with a stand-in portal and database, and
confirm the launch calls it after first-use setup. Pass --source <WebPortal.swift>
to check an earlier copy as a negative control.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=root / 'Horos/Sources/WebPortal.swift')
args = parser.parse_args()
source = args.source.read_text()
signature = '    @MainActor static func adoptOpenedDatabase()'
if signature not in source:
    print('FAIL: the portal has no way to receive the database opened at first use')
    sys.exit(1)
start = source.index(signature)
method = source[start:source.index('\n    }\n', start) + 6]

# The launch is ApplicationLifecycle's, which reaches the browser through the process graph.
launch = (root / 'Horos/Sources/ApplicationLifecycle.swift').read_text()
setup = launch.index('browser?.completeFirstUseDatabaseSetup()')
if 'DatabaseFirstUse.databaseDidOpen()' not in launch[setup:setup + 300]:
    print('FAIL: the launch does not finish first use after the database setup')
    sys.exit(1)
first_use = (root / 'Horos/Sources/DatabaseFirstUse.swift').read_text()
finish = first_use.index('func databaseDidOpen()')
body = first_use[finish:first_use.index('\n    }\n', finish)]
for call in ('WebPortal.adoptOpenedDatabase()', 'ForeignDatabaseChoice.startPendingImport()'):
    if call not in body:
        print(f'FAIL: first use no longer calls {call}')
        sys.exit(1)

# The portals are kept in one Mutex, each a reference threads may share; an
# earlier revision kept them in statics under a recursive lock.
held = 'instances.withLock' in method
STORAGE = '''    struct SharedPortal: @unchecked Sendable { let portal: WebPortal }
    struct Instances { var defaultPortal: SharedPortal?; var wadoOnlyPortal: SharedPortal? }
    private static let instances = Mutex(Instances())
    static func install(_ portal: WebPortal?, wado: WebPortal?) {
        instances.withLock { $0.defaultPortal = portal.map(SharedPortal.init); $0.wadoOnlyPortal = wado.map(SharedPortal.init) }
    }''' if held else '''    private static let instancesLock = NSRecursiveLock()
    nonisolated(unsafe) private static var defaultWebPortalInstance: WebPortal? = nil
    nonisolated(unsafe) private static var wadoOnlyWebPortalInstance: WebPortal? = nil
    static func install(_ portal: WebPortal?, wado: WebPortal?) {
        defaultWebPortalInstance = portal
        wadoOnlyWebPortalInstance = wado
    }'''

code = r'''
import Foundation
import Synchronization

final class DicomDatabase: NSObject {
    nonisolated(unsafe) static var opened: DicomDatabase?
    nonisolated(unsafe) static var requests = 0
    static func `default`() -> DicomDatabase! { requests += 1; return opened }
}
final class WebPortal: NSObject, @unchecked Sendable {
STORAGE
    var dicomDatabase: DicomDatabase!
    init(_ database: DicomDatabase?) { dicomDatabase = database }
METHOD
}
func require(_ condition: Bool, _ reason: String) {
    if !condition { print("FAIL: \(reason)"); exit(1) }
}
MainActor.assumeIsolated {
    WebPortal.install(nil, wado: nil)
    WebPortal.adoptOpenedDatabase()
    require(DicomDatabase.requests == 0, "a launch with no portal opened the database")

    let chosen = DicomDatabase()
    DicomDatabase.opened = chosen
    let early = WebPortal(nil)
    WebPortal.install(early, wado: nil)
    WebPortal.adoptOpenedDatabase()
    require(early.dicomDatabase === chosen, "the default portal stayed without a database")

    let other = DicomDatabase()
    let settled = WebPortal(other)
    let wado = WebPortal(nil)
    WebPortal.install(settled, wado: wado)
    WebPortal.adoptOpenedDatabase()
    require(settled.dicomDatabase === other, "a portal that had a database lost it")
    require(wado.dicomDatabase === chosen, "the WADO portal stayed without a database")
}
print("PASS: portals made before the first-use database opens receive it, and no other portal changes")
'''.replace('STORAGE', STORAGE).replace('METHOD', method)

with tempfile.TemporaryDirectory(prefix='isix-first-use-portal-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(code)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', str(folder / 'main.swift'), '-o', str(folder / 'test')],
                   check=True, timeout=300)
    subprocess.run([str(folder / 'test')], check=True, timeout=60)
