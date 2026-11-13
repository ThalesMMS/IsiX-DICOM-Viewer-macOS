#!/usr/bin/env python3
"""A main database and its independent databases never give two files one name.

Every file a database stores in its data folder takes a number from
-uniquePathForNewDataFileWithExtension:, from any thread and any context: the
listener's scan, the copies from a medium, the anonymization, the reports and
the viewers' exports. A main database shares the count with its independent
databases, which import off the main thread.

The count was an N2MutableUInteger under @synchronized, and the name of the
file was formatted from the shared count after the lock that took the number
was left, so another thread could move it between the two; the scan of the
data folder held the lock over every file system call.

This compiles IsiXStorage's DataFileAllocator with the selector as it is in
DicomDatabase+Instance.swift and the line of DicomDatabase.swift that hands an
independent database the allocator of its main database, over a stand-in of
the database and a disposable data folder that already holds files. Twelve
threads, over the main database and two independent ones, each take numbers and
write the files at once, as the callers do; no two may get one name, none may
get the name of a file that was there, and the count goes on from the folder.
The highest number the index uses, which the selector hands the allocator, is a
stand-in here; tests/test-data-file-number-not-reused.py is about it.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


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


instance = (root / 'Horos/Sources/DicomDatabase+Instance.swift').read_text()
database = (root / 'Horos/Sources/DicomDatabase.swift').read_text()
selector = member(instance, '    dynamic func uniquePathForNewDataFile(withExtension ext: String!) -> String! {')
compute = member(instance, '    dynamic func computeDataFileIndex() -> UInt {')
size = member(instance, '    private static var dataFolderSize: UInt64 {')
shared = re.search(r'^\s*dataFileAllocator = \(main as\? DicomDatabase\)\?\.dataFileAllocator \?\? DataFileAllocator\(\)$', database, re.M)
check(shared, 'an independent database does not take the allocator of its main database')
check('dataFileIndex' not in database and 'dataFileIndex' not in instance,
      'the former count of the data files is still kept beside the allocator')

PROBE = r'''
import Foundation
import IsiXStorage
import Synchronization

enum DicomDatabaseObjC {
    static func arg(_ object: Any?) -> CVarArg { (object as? NSObject) ?? ("(null)" as NSString) }
}

enum BrowserController {
    static func defaultFolderSizeForDB() -> Int32 { 100 }
}

extension FileManager {
    func confirmNoIndexDirectory(atPath path: String?) {
        if let path { try? createDirectory(atPath: path, withIntermediateDirectories: true) }
    }
    func confirmDirectory(atPath path: String?) {
        if let path { try? createDirectory(atPath: path, withIntermediateDirectories: true) }
    }
}

/// The index of the stand-in database: the highest number its records use,
/// below what the folder holds, and how many times it was asked.
enum RecordedDataFileNumbers {
    static let asked = Mutex(0)
    static func highest(in database: DicomDatabase) -> UInt64 {
        asked.withLock { $0 += 1 }
        return 40
    }
}

final class DicomDatabase: @unchecked Sendable {
    let folder: String
    let dataFileAllocator: DataFileAllocator

    init(folder: String, main: DicomDatabase?) {
        self.folder = folder
        // As DicomDatabase.swift hands it out:
        @SHARED@
    }

    func dataDirPath() -> String! { folder }

@SELECTOR@

@COMPUTE@

@SIZE@
}

let data = CommandLine.arguments[1]
let main = DicomDatabase(folder: data, main: nil)
let independents = [DicomDatabase(folder: data, main: main), DicomDatabase(folder: data, main: main)]
let databases = [main] + independents
print("shared\t\(independents.allSatisfy { $0.dataFileAllocator === main.dataFileAllocator } ? 1 : 0)")

let given = Mutex<[String]>([])
DispatchQueue.concurrentPerform(iterations: 12) { worker in
    let database = databases[worker % databases.count]
    var mine: [String] = []
    for _ in 0..<250 {
        let path: String = database.uniquePathForNewDataFile(withExtension: worker % 4 == 0 ? "jpegxl" : "dcm")
        if !FileManager.default.createFile(atPath: path, contents: Data("\(worker)".utf8)) {
            print("unwritten\t\(path)")
        }
        mine.append(path)
    }
    given.withLock { $0 += mine }
}
let all = given.withLock { $0 }
print("given\t\(all.count)")
print("distinct\t\(Set(all).count)")
print("preexisting\t\(all.filter { $0.hasSuffix("/200/150.dcm") || $0.hasSuffix("/200/151.dcm") }.count)")
print("lowest\t\(all.map { Int((($0 as NSString).lastPathComponent as NSString).deletingPathExtension) ?? 0 }.min() ?? 0)")
print("extensions\t\(Set(all.map { ($0 as NSString).pathExtension }).sorted().joined(separator: ","))")
print("asked\t\(RecordedDataFileNumbers.asked.withLock { $0 })")
print("count\t\(main.computeDataFileIndex())")
'''

with tempfile.TemporaryDirectory(prefix='horos-data-file-allocation-') as directory:
    work = Path(directory)
    data = work / 'DATABASE.noindex'
    (data / '200').mkdir(parents=True)
    for name in ('150.dcm', '151.dcm'):
        (data / '200' / name).write_text('there before')
    (work / 'probe.swift').write_text(PROBE.replace('@SHARED@', shared.group(0).strip() if shared else 'dataFileAllocator = DataFileAllocator()')
                                      .replace('@SELECTOR@', selector).replace('@COMPUTE@', compute).replace('@SIZE@', size))
    flags = isix_modules.module_flags('IsiXStorage', work / 'modules', ['-target', 'arm64-apple-macos15.0'])
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0', *flags,
                            str(work / 'probe.swift'), '-o', str(work / 'probe')], capture_output=True, text=True, timeout=300)
    if built.returncode:
        print(built.stderr[-3000:])
        raise SystemExit('FAIL: the selector does not compile with the allocator')
    ran = subprocess.run([str(work / 'probe'), str(data)], capture_output=True, text=True, timeout=120)
    results = dict(line.split('\t', 1) for line in ran.stdout.splitlines() if '\t' in line)
    print(results)
    check(ran.returncode == 0, 'the probe failed: %s' % ran.stderr[-1500:])
    check(results.get('shared') == '1', 'the independent databases count on their own')
    check(results.get('given') == '3000' and results.get('distinct') == '3000',
          'concurrent allocations gave %s distinct names of %s' % (results.get('distinct'), results.get('given')))
    check('unwritten' not in ran.stdout, 'a name given could not be written')
    check(results.get('preexisting') == '0', 'a name of a file that was there was given again')
    check(results.get('lowest') == '152', 'the count did not go on from the files of the folder: lowest %s' % results.get('lowest'))
    check(results.get('extensions') == 'dcm', 'an extension of six characters was kept: %s' % results.get('extensions'))
    check(results.get('count') == '3151', 'the count of the main database is %s after 3000 files from 151' % results.get('count'))
    # The index is asked when the folder is read, by each thread that found the count not read yet: never for each file.
    check(1 <= int(results.get('asked', '0')) <= 12, 'the index was asked %s times for 3000 files' % results.get('asked'))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: a main database and two independent databases share one count, and twelve threads never get one name twice')
