#!/usr/bin/env python3
"""A new data file never takes a number that a record of the index still uses.

The database keeps its files as <folder>/<n>.<extension>, and a record of the
index names its file by that number. The next number was read from the data
folder alone: when the files with the highest numbers were gone from the
folder (deleted by another program, a volume restored from a partial copy, a
copy that failed) while their records stayed, the next import took their
numbers. The old record then read the new file: an image of another study,
perhaps of another patient, shown in the wrong study, without a word.

The count now goes on from the highest number of the folder and of the index.
The sources are read as they are:

- scenario: DataFileAllocator.swift, compiled, around a folder of its own and
  an index kept as the test keeps it. Studies A and B are imported together,
  so their files alternate; B is deleted in the application (records and
  files); the last file of A is removed from the folder from outside; the
  application starts again and study C is imported. No file of C may be at
  the place a record of A names, and the record of A whose file is gone still
  finds no file there. The same after a second restart, with C deleted and A's
  file still gone; with the folder emptied from outside altogether; and when a
  file another program wrote is in the way.
- text: DicomDatabase hands the allocator the highest number of its index,
  read once the folder is read and never once per file, on a context of its
  own, so that any thread may ask.

`<git revision>` as an optional argument reads the sources from that
revision, the negative control.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None

ALLOCATOR = 'Modules/IsiXStorage/Sources/DataFileAllocator.swift'
DATABASE = 'Horos/Sources/DicomDatabase+Instance.swift'


def source(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode()
    return (root / path).read_text(encoding='utf-8')


def fail(message):
    print('FAIL:', message)
    sys.exit(1)


if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

allocator = source(ALLOCATOR)
# The allocator is asked as the application asks it: with the index's highest
# number once the sources have that, without it in a revision before.
hook = 'highestRecorded: { index.highest }, ' if 'highestRecorded' in allocator else ''

MAIN = r'''
import Foundation

var failures: [String] = []
func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

let files = FileManager.default
let data = CommandLine.arguments[1]
let folderSize: UInt64 = 10_000

/// The index: the number of the file of each image, by the image's name.
final class Index {
    var records: [String: UInt64] = [:]
    var highest: UInt64 { records.values.max() ?? 0 }
    func path(of image: String) -> String? {
        records[image].map { DataFileNumbering.path(forIndex: $0, extension: "dcm", inDataFolder: data, folderSize: folderSize).file }
    }
}
let index = Index()

func prepare(_ folder: String) { try? files.createDirectory(atPath: folder, withIntermediateDirectories: true) }

/// The application, from one launch to the next: the allocator lives as long.
final class Launch {
    let allocator = DataFileAllocator()

    /// Imports the images: each gets a new file with its own name in it, and a record.
    func importImages(_ images: [String]) -> [String] {
        images.map { image in
            let path = allocator.uniquePath(inDataFolder: data, extension: "dcm", folderSize: folderSize, ''' + hook + r'''prepareFolder: prepare)
            files.createFile(atPath: path, contents: Data(image.utf8))
            index.records[image] = UInt64(DataFileNumbering.number(inName: (path as NSString).lastPathComponent))
            return path
        }
    }

    /// Deletes the images as the application does: their files and their records.
    func delete(_ images: [String]) {
        for image in images {
            if let path = index.path(of: image) { try? files.removeItem(atPath: path) }
            index.records[image] = nil
        }
    }
}

/// What the file of each record holds: the record's own image, nothing, or the image of another record.
func wrongFiles() -> [String] {
    index.records.keys.sorted().compactMap { image in
        guard let path = index.path(of: image), let held = files.contents(atPath: path) else { return nil }
        let name = String(decoding: held, as: UTF8.self)
        return name == image ? nil : "\(image) reads the file of \(name)"
    }
}

func sharedNumbers() -> [UInt64] {
    Dictionary(grouping: index.records.values, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
}

// Studies A and B arrive together.
var launch = Launch()
_ = launch.importImages(["A1", "B1", "A2", "B2"])
check(wrongFiles().isEmpty && sharedNumbers().isEmpty, "the first import is already wrong: \(wrongFiles()) \(sharedNumbers())")
// B is deleted in the application; the last file of A goes from outside.
launch.delete(["B1", "B2"])
let lost = index.path(of: "A2")!
try? files.removeItem(atPath: lost)

// The application starts again and study C is imported.
launch = Launch()
let arrived = launch.importImages(["C1", "C2"])
check(!arrived.contains(lost), "a file of study C was written where the record of A2 names its file")
check(sharedNumbers().isEmpty, "two records name the file number \(sharedNumbers())")
check(wrongFiles().isEmpty, "a record reads the file of another image: \(wrongFiles())")
check(!files.fileExists(atPath: lost), "the record of A2, whose file is gone, finds a file: its absence is no longer said")
check(Set(arrived).count == 2 && arrived.allSatisfy { files.fileExists(atPath: $0) }, "study C did not get two files of its own")

// C is deleted, A2's file is still gone, and the application starts again.
launch.delete(["C1", "C2"])
launch = Launch()
let again = launch.importImages(["D1", "D2", "D3"])
check(!again.contains(lost) && wrongFiles().isEmpty && sharedNumbers().isEmpty,
      "after a second restart a record reads another image: \(wrongFiles()) \(sharedNumbers())")

// The whole folder goes from outside while the records stay.
try? files.removeItem(atPath: data)
prepare(data)
launch = Launch()
let recorded = Set(index.records.keys.compactMap { index.path(of: $0) })
let fresh = launch.importImages(["E1", "E2"])
check(recorded.isDisjoint(with: fresh), "with the folder emptied from outside, new files took the places the records name")
check(wrongFiles().isEmpty && sharedNumbers().isEmpty, "with the folder emptied from outside a record reads another image: \(wrongFiles())")

// A file another program wrote is in the way: it is kept, and the count goes past it.
let next = DataFileNumbering.path(forIndex: index.highest + 1, extension: "dcm", inDataFolder: data, folderSize: folderSize).file
files.createFile(atPath: next, contents: Data("foreign".utf8))
launch = Launch()
let after = launch.importImages(["F1"])
check(!after.contains(next) && files.contents(atPath: next) == Data("foreign".utf8), "a file another program wrote was written over")
check(wrongFiles().isEmpty && sharedNumbers().isEmpty, "past a file of another program a record reads another image: \(wrongFiles())")

for failure in failures { print("FAIL: \(failure)") }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-data-file-number-') as tmp:
    tmp = Path(tmp)
    (tmp / 'DataFileAllocator.swift').write_text(allocator)
    (tmp / 'main.swift').write_text(MAIN)
    try:
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-name', 'IsiXStorage', str(tmp / 'DataFileAllocator.swift'),
                        str(tmp / 'main.swift'), '-o', str(tmp / 'scenario')], check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        fail('the scenario did not build: ' + (e.stderr or b'').decode(errors='replace')[-3000:])
    folder = tmp / 'DATABASE.noindex'
    folder.mkdir()
    result = subprocess.run([str(tmp / 'scenario'), str(folder)], capture_output=True, text=True, timeout=120)
    if result.returncode != 0:
        fail('; '.join(line[len('FAIL: '):] for line in (result.stdout + result.stderr).splitlines() if line.startswith('FAIL:'))
             or f'exit {result.returncode}: {(result.stdout + result.stderr)[-600:]}')
print('ok: scenario - after a file of the folder is lost and the application starts again, no new file takes the place a record names')

# ---------------------------------------------------------------- text

database = '\n'.join(line for line in source(DATABASE).splitlines() if not line.strip().startswith('//'))


def function(signature):
    start = database.find(signature)
    if start < 0:
        fail(f'{signature.strip()} not found in {DATABASE}')
    return database[start:database.index('\n    }\n', start)]


naming = function('    dynamic func uniquePathForNewDataFile(withExtension ext: String!) -> String! {')
if 'highestRecorded: { RecordedDataFileNumbers.highest(in: self) }' not in naming:
    fail('a new data file is named without the highest number the index uses')
if 'managedObjectContext' in naming or 'NSFetchRequest' in naming:
    fail('the index is asked where every new file is named, not only when the folder is read')
counting = function('    dynamic func computeDataFileIndex() -> UInt {')
if 'highestRecorded: { RecordedDataFileNumbers.highest(in: self) }' not in counting:
    fail('the count read from the data folder leaves out the highest number the index uses')
reading = function('    static func highest(in database: DicomDatabase) -> UInt64 {')
for expected, reason in (
        ('NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)', 'the index is not read on a context of its own, so a thread that is not the context\'s could not ask'),
        ('NSExpression(forFunction: "max:", arguments: [NSExpression(forKeyPath: "pathNumber")])', 'the highest number is not asked of the store in one request'),
        ('NSFetchRequest<NSFetchRequestResult>(entityName: "Image")', 'the highest number is not read from the images of the index')):
    if expected not in reading:
        fail(reason)

resume = allocator[allocator.index('    public func resume(fromDataFolder dataFolder: String'):]
resume = resume[:resume.index('\n    }\n')]
if 'highestRecorded()' not in resume:
    fail('reading the data folder does not take the highest number the index uses')
naming = allocator[allocator.index('    public func uniquePath(inDataFolder dataFolder: String'):]
naming = naming[:naming.index('\n    }\n')]
if naming.count('highestRecorded()') != 0 or naming.count('highestRecorded: highestRecorded') != 2:
    fail('the allocator asks the index for every file, or does not ask it each time it reads the folder')
print('ok: text - the database gives the allocator the highest number of its index, asked only when the folder is read')
print('PASS: a new data file never takes a number that a record of the index still uses')
