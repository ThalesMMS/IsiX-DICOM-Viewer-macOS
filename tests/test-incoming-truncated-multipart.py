#!/usr/bin/env python3
"""A WADO-RS multipart cut short in the incoming folder is dealt with once.

Without its closing boundary such a file used to give its good parts under new
names and raise, and stayed where it was. Every scan wrote the same parts again,
and the exception skipped the indexing of that pass, so what the pass had already
moved to the data folder stayed without a row until a rebuild.

Here the scan's own method runs, compiled from the application's source with a
stand-in for the database around it, over real files, in as many passes as it
takes for nothing more to happen: the file reaches the folder of errors once, its
good parts enter once, and the files around it are all taken in the pass that
found them. An exception would end the program, so none can pass unnoticed.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

incoming = (root / 'Horos/Sources/IncomingAdmission.swift').read_text()
cleanup = (root / 'Horos/Sources/ImportDisposal.swift').read_text()


def member(source, signature):
    at = source.find(signature)
    if at < 0:
        raise SystemExit('FAIL: %s not found' % signature)
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        if depth == 0:
            return source[at:index + 1]
    raise SystemExit('FAIL: %s has no end' % signature)


unpack = member(incoming, 'private func unpackWADORSMultipart(')
if '.raise()' in unpack or 'NSException' in unpack:
    raise SystemExit('FAIL: a multipart still raises out of the scan')
scan = member(incoming, 'private func importAdmittedFilesFromIncomingDir(')
if not re.search(r'if unpackWADORSMultipart\(srcPath, enclosingArchive: enclosingArchive\) \{\s*continue\s*\}', scan):
    raise SystemExit('FAIL: the scan does not go on to the next file after a multipart')

code = r'''
import Foundation
import IsiXDatabase

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected { fail("\(message): \(actual) != \(expected)") }
}

enum DicomDatabaseObjC {
    static func appending(_ path: String?, _ component: String) -> String? {
        (path as NSString?)?.appendingPathComponent(component)
    }
}

final class ArchiveImportLedger {
    nonisolated(unsafe) static let shared = ArchiveImportLedger()
    var indexed = 0, kept = 0
    func recordIndexedEntry(inArchive archive: String) { indexed += 1 }
    func recordKeptEntry(inArchive archive: String) { kept += 1 }
}

__FILE_HELPERS__

final class Database {
    let folder: String
    var refusals: [String] = []
    var indexed: [Data] = []
    var errorsFolder: String?
    init(folder: String) {
        self.folder = folder
        errorsFolder = folder + "/NOT READABLE"
    }
    func incomingDirPath() -> String? { folder + "/INCOMING" }
    func errorsDirPath() -> String? { errorsFolder }
    func addImportRefusalSummary(_ summary: String!) { refusals.append(summary) }
    __AVAILABLE__
    var database: Database { self }
    // The scan finds a free name through ImportDisposal, which the stand-in is too.
    var disposal: Database { self }
    __UNPACK__

    /// The shape of a pass: every file in turn, what the method does not take
    /// going on to the index, which runs when the loop ends.
    func pass(enclosingArchive: String? = nil) throws {
        let incoming = incomingDirPath()!
        var taken: [Data] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: incoming).sorted() {
            let path = incoming + "/" + name
            if self.unpackWADORSMultipart(path, enclosingArchive: enclosingArchive) { continue }
            taken.append(try Data(contentsOf: URL(fileURLWithPath: path)))
            try FileManager.default.removeItem(atPath: path)
        }
        indexed += taken
    }
}

func multipart(_ parts: [Data], closed: Bool) -> Data {
    var body = Data("--frontier\r\n".utf8)
    for (index, part) in parts.enumerated() {
        body += Data("Content-Type: application/dicom;transfer-syntax=1.2.840.10008.1.2.1\r\n\r\n".utf8)
        body += part
        body += Data((index == parts.count - 1 ? (closed ? "\r\n--frontier--\r\n" : "\r\n") : "\r\n--frontier\r\n").utf8)
    }
    return body
}

func dicom(_ fill: UInt8, _ size: Int) -> Data {
    Data(repeating: 0, count: 128) + Data("DICM".utf8) + Data(repeating: fill, count: size)
}

func folder() throws -> Database {
    let root = NSTemporaryDirectory() + UUID().uuidString
    for name in ["INCOMING", "NOT READABLE"] {
        try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
    }
    return Database(folder: root)
}

let manager = FileManager.default
let good = [dicom(1, 2000), dicom(2, 3000)], cut = dicom(3, 4000)
let body = multipart(good + [cut], closed: false)
let before = dicom(7, 100), after = dicom(8, 200)

let database = try folder()
let incoming = database.incomingDirPath()!, errors = database.errorsDirPath()!
try body.write(to: URL(fileURLWithPath: incoming + "/m-response"))
try before.write(to: URL(fileURLWithPath: incoming + "/a-before.dcm"))
try after.write(to: URL(fileURLWithPath: incoming + "/z-after.dcm"))

try database.pass(enclosingArchive: "study.zip")
expect(try manager.contentsOfDirectory(atPath: errors), ["m-response"], "the first pass keeps the file aside")
expect(try Data(contentsOf: URL(fileURLWithPath: errors + "/m-response")), body, "whole")
expect(database.indexed.sorted { $0.count < $1.count }, [before, after], "the files around it are indexed in that pass")
expect(database.refusals.count, 1, "the refusal is said")
expect(ArchiveImportLedger.shared.kept, 1, "the archive counts it as kept")
expect(ArchiveImportLedger.shared.indexed, 0, "and not as indexed")
expect(try manager.contentsOfDirectory(atPath: incoming).count, good.count, "the good parts wait for the next pass")

for _ in 0..<3 { try database.pass() }
expect(database.indexed.filter { good.contains($0) }.sorted { $0.count < $1.count }, good, "each good part enters once")
expect(database.indexed.count, good.count + 2, "and nothing else does")
expect(database.indexed.contains(cut), false, "the cut part does not enter")
expect(try manager.contentsOfDirectory(atPath: incoming), [], "the incoming folder ends empty")
expect(try manager.contentsOfDirectory(atPath: errors), ["m-response"], "kept once")
expect(database.refusals.count, 1, "said once")

// A second file of the same name has a name of its own there.
try body.write(to: URL(fileURLWithPath: incoming + "/m-response"))
try database.pass()
expect(try manager.contentsOfDirectory(atPath: errors).count, 2, "the former one is not overwritten")
try database.pass()

// With nowhere to keep it, it stays, and no pass gives its parts.
let stuck = try folder()
stuck.errorsFolder = nil
let stuckIncoming = stuck.incomingDirPath()!
try body.write(to: URL(fileURLWithPath: stuckIncoming + "/m-response"))
try after.write(to: URL(fileURLWithPath: stuckIncoming + "/z-after.dcm"))
for _ in 0..<3 { try stuck.pass() }
expect(try manager.contentsOfDirectory(atPath: stuckIncoming), ["m-response"], "it stays, alone")
expect(stuck.indexed, [after], "the rest of the pass is indexed, and no part")

// A whole response still goes as it did.
let whole = try folder()
let wholeIncoming = whole.incomingDirPath()!
try multipart(good, closed: true).write(to: URL(fileURLWithPath: wholeIncoming + "/m-response"))
for _ in 0..<2 { try whole.pass(enclosingArchive: "whole.zip") }
expect(whole.indexed.sorted { $0.count < $1.count }, good, "both parts")
expect(try manager.contentsOfDirectory(atPath: whole.errorsDirPath()!), [], "nothing kept aside")
expect(ArchiveImportLedger.shared.indexed, 1, "the archive counts it as indexed")

for each in [database, stuck, whole] { try? manager.removeItem(atPath: each.folder) }
print("PASS: a multipart cut short is kept aside once, its good parts enter once, the pass goes on")
'''

helpers = incoming[incoming.index('/// `[[NSFileManager defaultManager] moveItemAtPath:from'):incoming.index('/// The scan of the incoming folder of one database')]
available = member(cleanup, 'func availablePath(inDirectory directory: String?, name: String) -> String? {')
code = code.replace('__FILE_HELPERS__', helpers).replace('__AVAILABLE__', available).replace('__UNPACK__', unpack)

with tempfile.TemporaryDirectory(prefix='horos-truncated-multipart-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(code)
    target = ['-target', 'arm64-apple-macos15.0']
    flags = isix_modules.module_flags('IsiXDatabase', path / 'modules', target)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', *target, *flags, str(path / 'main.swift'),
                            '-o', str(path / 'test')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-3000:])
        raise SystemExit('FAIL: the scan method did not compile')
    ran = subprocess.run([str(path / 'test')], capture_output=True, text=True, timeout=60)
    if ran.returncode:
        print(ran.stderr or ran.stdout)
        raise SystemExit(ran.returncode)
    print(ran.stdout.strip())
