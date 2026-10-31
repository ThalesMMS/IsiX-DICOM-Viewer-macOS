#!/usr/bin/env python3
"""Execute the production startup recovery block with real filesystem entries.

The launch is ApplicationLifecycle's (ApplicationLifecycle.swift): its
moveInterruptedFilesToIncoming() is compiled with swiftc, together with
ImageExportPath.swift, over a stand-in DicomDatabase, a stand-in
DatabaseIngest that resolves the incoming folder as DatabaseIngest.swift does,
and a stand-in process graph that hands both out.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=source_path('ApplicationLifecycle'))
args = parser.parse_args()
source = args.source.read_bytes().decode('utf-8')


def swift_block(text, at):
    """From `at` to the brace closing the first block that opens after it,
    outside comments and string literals."""
    index, depth, opened = at, 0, False
    while index < len(text):
        if text.startswith('//', index):
            index = text.find('\n', index)
            if index < 0:
                break
            continue
        if text.startswith('/*', index):
            index = text.index('*/', index) + 2
            continue
        if text[index] == '"':
            index += 1
            while text[index] != '"':
                index += 2 if text[index] == '\\' else 1
        elif text[index] == '{':
            depth, opened = depth + 1, True
        elif text[index] == '}':
            depth -= 1
            if opened and depth == 0:
                return text[at:index + 1]
        index += 1
    return ''


# The recovery is the last statement of the launch, after -initTilingWindows.
launch = swift_block(source, source.index('    func willFinishLaunching() {'))
tail = launch[launch.rindex('controller.initTilingWindows()') + len('controller.initTilingWindows()'):]
if [line.strip() for line in tail.splitlines() if line.strip()] != ['moveInterruptedFilesToIncoming()', '}']:
    print('FAIL: the recovery is not the last statement after -initTilingWindows')
    raise SystemExit(1)
at = source.index('    private func moveInterruptedFilesToIncoming() {')
recovery = swift_block(source, at).replace('private func moveInterruptedFilesToIncoming()', 'func moveInterruptedFilesToIncoming()', 1)
program = r'''
import Foundation
var temporary = "", decompression = "", incoming = ""
final class DicomDatabase: NSObject {
    class func activeLocal() -> DicomDatabase? { return DicomDatabase() }
    func tempDirPath() -> String! { return temporary }
    func decompressionDirPath() -> String! { return decompression }
    func incomingDirPath() -> String! { return incoming }
}
// DatabaseIngest.swift's entry for the incoming folder: the database's
// incomingDirPath, nil without a database.
struct DatabaseIngest {
    static let process = DatabaseIngest()
    func incomingFolderPath(of database: DicomDatabase?) -> String? {
        database.map { $0.incomingDirPath() }
    }
}
extension FileManager {
    // NSFileManager+N2.swift's signature.
    func enumerator(atPath path: String?, filesOnly: Bool, recursive: Bool) -> NSEnumerator {
        precondition(!filesOnly && !recursive, "production recovery enumerates direct children")
        return (((try? self.contentsOfDirectory(atPath: path ?? "")) ?? []) as NSArray).objectEnumerator()
    }
}
// ProcessGraph's entries the recovery reads.
struct Graph {
    var activeLocalDatabase: DicomDatabase? { DicomDatabase.activeLocal() }
    let databaseIngest = DatabaseIngest.process
}
let processGraph = Graph()
RECOVERY
func recover() { moveInterruptedFilesToIncoming() }
func writeFixture(_ root: String, _ name: String) {
    let path = (root as NSString).appendingPathComponent(name)
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true, attributes: nil)
    try? "preserved fixture bytes".write(toFile: path, atomically: true, encoding: .utf8)
}
func intact(_ root: String, _ name: String) -> Bool {
    return (try? String(contentsOfFile: (root as NSString).appendingPathComponent(name), encoding: .utf8)) == "preserved fixture bytes"
}
func CHECK(_ value: Bool, _ message: String) {
    if !value { FileHandle.standardError.write((message + "\n").data(using: .utf8)!); exit(1) }
}
let root = CommandLine.arguments[1]
temporary = (root as NSString).appendingPathComponent("TEMP.noindex")
decompression = (root as NSString).appendingPathComponent("DECOMPRESSION.noindex")
incoming = (root as NSString).appendingPathComponent("INCOMING.noindex")
let exports = ["EXPORT/0001.jpg", "EXPORT-74E335A4-D689-4E8E-837F-F68C2D338536/0001.jpg"]
let received = ["received.dcm", "EXPORT-received-series/image.dcm", "EXPORT-77A064F6-249D-40B0-87B4-38F0DD5819FA"]
let compressed = ["decompressed.dcm", "EXPORT-0779CBB5-F953-4A54-921F-655EE22F38C0/image.dcm"]
for name in exports { writeFixture(temporary, name) }
for name in received { writeFixture(temporary, name) }
for name in compressed { writeFixture(decompression, name) }
writeFixture(incoming, "already.dcm")
recover()
for name in exports {
    CHECK(intact(temporary, name), "exported attachment was moved or changed by recovery")
    CHECK(!intact(incoming, name), "export was handed to the DICOM importer")
}
for name in received {
    CHECK(intact(incoming, name) && !intact(temporary, name), "received entry was not recovered")
}
for name in compressed {
    CHECK(intact(incoming, name) && !intact(decompression, name), "decompression entry was not recovered")
}
CHECK(intact(incoming, "already.dcm"), "existing incoming data changed")
recover()
for name in exports { CHECK(intact(temporary, name), "repeated recovery changed export") }
print("PASS: current/legacy exports retained; received files, unrelated folders and decompression recovered; second pass preserves bytes")
'''.replace('RECOVERY', recovery)

with tempfile.TemporaryDirectory(prefix='horos-startup-export-') as folder:
    path = Path(folder)
    (path / 'main.swift').write_text(program)
    subprocess.run(['xcrun', 'swiftc', '-sanitize=address', '-module-name', 'RecoveryTest',
                    str(path / 'main.swift'), str(root / 'Horos/Sources/ImageExportPath.swift'),
                    '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(path / 'files')], check=True)
