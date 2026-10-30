#!/usr/bin/env python3
"""Files of the same name reach the decompression folder in one scan.

With ListenerCompressionSettings at 2, the INCOMING importer moves each image
to be compressed into DECOMPRESSION.noindex. It used the file's own name there
and ignored the result of the move: of study-000/1.dcm and study-001/1.dcm only
the first got there, the second stayed in INCOMING for the next scan, and its
path still went to the helper, which found nothing to read. The import moved
two files per scan.

This compiles IsiXDatabase's AvailablePath, which the importer calls
(DicomDatabase+IncomingImport.swift and +ImportCleanup.swift), and checks that a
taken name gets a new one with the same extension, and that the three moves
into the decompression folder (archives, deflated files, files to compress or
decompress) use it and queue a path only once the file is there. The routing
of deflated files stays.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402
source = (root / 'Horos/Sources/DicomDatabase+IncomingImport.swift').read_text()
cleanup = (root / 'Horos/Sources/DicomDatabase+ImportCleanup.swift').read_text()
failures = []

if 'AvailablePath.inDirectory(directory, name: name)' not in cleanup:
    print('FAIL: the importer no longer asks IsiXDatabase for a name of its own')
    sys.exit(1)

DRIVER = r'''
import Foundation
import IsiXDatabase
let folder = CommandLine.arguments[1]
let fm = FileManager.default
func name(_ path: String) -> String { (path as NSString).lastPathComponent }
let first = AvailablePath.inDirectory(folder, name: "1.dcm")
print("first\t\(name(first))")
fm.createFile(atPath: first, contents: Data())
let second = AvailablePath.inDirectory(folder, name: "1.dcm")
print("second\t\(name(second))")
fm.createFile(atPath: second, contents: Data())
let third = AvailablePath.inDirectory(folder, name: "1.dcm")
print("third\t\(name(third))")
print("archive\t\(name(AvailablePath.inDirectory(folder, name: "a.zip")))")
fm.createFile(atPath: (folder as NSString).appendingPathComponent("a.zip"), contents: Data())
print("archive.again\t\(name(AvailablePath.inDirectory(folder, name: "a.zip")))")
print("noextension\t\(name(AvailablePath.inDirectory(folder, name: "IM0001")))")
'''

EXPECTED = {'first': '1.dcm', 'second': '1-1.dcm', 'third': '1-2.dcm', 'archive': 'a.zip',
            'archive.again': 'a-1.zip', 'noextension': 'IM0001'}

with tempfile.TemporaryDirectory(prefix='horos-decompression-names-') as work:
    work = Path(work)
    (work / 'main.swift').write_text(DRIVER)
    (work / 'folder').mkdir()
    built = subprocess.run(['xcrun', 'swiftc', *isix_modules.module_flags('IsiXDatabase', work / 'modules'),
                            str(work / 'main.swift'), '-o', str(work / 'driver')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the helper did not compile:\n' + built.stderr[-2000:])
    else:
        run = subprocess.run([str(work / 'driver'), str(work / 'folder')], capture_output=True, text=True, timeout=60)
        results = dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)
        for key, value in EXPECTED.items():
            if results.get(key) != value:
                failures.append('%s: expected %r, got %r' % (key, value, results.get(key)))

importer = source[source.index('private final func importAdmittedFilesFromIncomingDir('):]
importer = importer[:importer.index('    func importFilesFromIncomingDirThread()')]
if 'DicomDatabaseObjC.appending(self.decompressionDirPath(), lastPathComponent)' in importer:
    failures.append('a move into the decompression folder still takes the file\'s own name')
if importer.count('availablePath(inDirectory: self.decompressionDirPath(), name: lastPathComponent)') != 3:
    failures.append('the archive, deflated and compression moves do not all get a name of their own')
if 'try? FileManager.default.moveItem(atPath: srcPath, toPath: compressedPath' in importer:
    failures.append('a move into the decompression folder still ignores its result')
compress = importer[importer.index('IncomingScanRules.queuesForConversion('):]
compress = compress[:compress.index('return\n')]
if not re.search(r'if let moveError = moveItem\(srcPath, compressedPath\) \{.*?\} else if let compressedPath \{\s*compressedPathArray\.append\(compressedPath\)', compress, re.S):
    failures.append('a file to compress is queued whether or not it reached the decompression folder')
if '} else if isDeflatedDICOM(srcPath) {' not in importer or 'deflatedPathArray.append(compressedPath)' not in importer:
    failures.append('the routing of deflated files is gone')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: files of the same name get names of their own in the decompression folder, and are queued once they are there')
