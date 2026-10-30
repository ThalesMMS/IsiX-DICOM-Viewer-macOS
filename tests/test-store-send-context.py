#!/usr/bin/env python3
"""Each send owns its state: options, temporary copies, TLS layer and report.

Sends run in parallel (the Send sheet's operation queue, routing, Bonjour, the
portal). What one send uses belongs to it alone: the network syntax and its
quality, the timeouts, the folder of its converted copies (removed when the
send ends, also when it raises), the TLS layer of its association and the
report that names the original paths. Checked in DCMTKStoreSCU*.swift and in
the adapter; the folder of the copies is also run here, two sends at once.
"""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = {name: (root / 'Horos/Sources' / name).read_text()
           for name in ('DCMTKStoreSCU.swift', 'DCMTKStoreSCU+Association.swift', 'DCMTKStoreSCU+File.swift')}
everything = '\n'.join(sources.values())
code = '\n'.join(line.split('//')[0] for line in everything.splitlines())

# No state shared between sends but the TLS lock.
statics = [line.strip() for line in code.splitlines()
           if re.search(r'\bstatic\s+(var|let)\b', line) and not re.search(r'static let \w+ = "[^"]*"$', line.strip())]
assert statics == ['private static let secureTransportLock = NSLock()'], statics
assert 'nonisolated(unsafe)' not in code

send = sources['DCMTKStoreSCU.swift']
run = send[send.index('public func run('):send.index('/// The send itself')]
assert 'let files = StoreTemporaryFiles()' in run
assert run.index('files.remove()') < run.index('.raise()'), 'the copies outlive a send that raises'
assert 'let network = StoreSendSyntax.network(forSetting: Int(transferSyntax))' in send
assert 'StoreFileSender(association: association, report: report, network: network, temporaryFiles: temporaryFiles)' in send

store = sources['DCMTKStoreSCU+File.swift']
assert 'report.recordSent(path: path,' in store and 'storedPath' not in store, 'reports must keep the original path'
assert 'temporaryFiles.nextPath()' in store

association = sources['DCMTKStoreSCU+Association.swift']
assert 'private let uniqueStringID = UUID().uuidString' in association
assert association.count('Self.secureTransportLock.lock()') == 2
# The TLS layer is the association's own, made and destroyed by the adapter.
adapter = (root / 'Horos/Sources/Adapters/DCMTK/IsiXDCMTKQueryRetrieveSCU.mm').read_text()
assert 'static DcmTLSTransportLayer' not in adapter and 'DcmTLSTransportLayer *_layer;' in adapter
assert 'HorosConfigureTLSCipherSuites(*_layer, parameters.cipherSuites)' in adapter
print('ok: each send keeps its options, copies, TLS files and layer, and report to itself')

# The folder of the copies, run: two sends at once, unique names, removal.
folder_class = send[send.index('final class StoreTemporaryFiles {'):]
driver = folder_class.replace('FileManager.default.tmpDirectoryPath(inDir: DicomDatabase.activeLocal()?.tempDirPath())',
                              'Self.make()') + r'''
extension StoreTemporaryFiles {
    nonisolated(unsafe) static var root = ""
    static func make() -> String {
        let path = (root as NSString).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}
StoreTemporaryFiles.root = CommandLine.arguments[1]
let first = StoreTemporaryFiles(), second = StoreTemporaryFiles()
var paths = Set<String>()
for _ in 0..<50 {
    for files in [first, second] {
        let path = files.nextPath()!
        precondition(paths.insert(path).inserted, "a copy name was given twice")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
    }
}
let firstFolder = (paths.first { $0.contains("/0.dcm") }! as NSString).deletingLastPathComponent
first.remove()
precondition(FileManager.default.fileExists(atPath: (second.nextPath()! as NSString).deletingLastPathComponent))
second.remove()
let left = try! FileManager.default.contentsOfDirectory(atPath: CommandLine.arguments[1])
precondition(left.isEmpty, "copies left behind: \(left) \(firstFolder)")
print("ok: two sends name their copies apart and each removes its own folder")
'''
with tempfile.TemporaryDirectory(prefix='horos-store-context-') as temporary:
    folder = Path(temporary)
    (folder / 'main.swift').write_text('import Foundation\n' + driver)
    (folder / 'copies').mkdir()
    built = subprocess.run(['xcrun', 'swiftc', str(folder / 'main.swift'), '-o', str(folder / 'probe')],
                           capture_output=True, text=True)
    assert built.returncode == 0, built.stderr[-3000:]
    ran = subprocess.run([str(folder / 'probe'), str(folder / 'copies')], capture_output=True, text=True, timeout=60)
    assert ran.returncode == 0, ran.stdout + ran.stderr
    print(ran.stdout, end='')
