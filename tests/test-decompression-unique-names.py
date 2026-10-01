#!/usr/bin/env python3
"""Files of the same name reach the decompression folder in one scan (#1008).

With ListenerCompressionSettings at 2, the INCOMING importer moves each image
to be compressed into DECOMPRESSION.noindex. It used the file's own name there
and ignored the result of the move: of study-000/1.dcm and study-001/1.dcm only
the first got there, the second stayed in INCOMING for the next scan, and its
path still went to the helper, which found nothing to read. The import moved
two files per scan.

This compiles the importer's availablePathInDirectory() as it is in
DicomDatabase.mm and checks that a taken name gets a new one with the same
extension, and that the three moves into the decompression folder (archives,
deflated files, files to compress or decompress) use it and queue a path only
once the file is there. The #1003 routing of deflated files stays.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Horos/Sources/DicomDatabase.mm').read_bytes().decode('latin1')
failures = []

match = re.search(r'^static NSString \*availablePathInDirectory\( NSString \*directory, NSString \*name\)\n\{.*?^\}\n',
                  source, re.S | re.M)
if not match:
    print('FAIL: availablePathInDirectory() is not in DicomDatabase.mm')
    sys.exit(1)

DRIVER = r'''
#import <Foundation/Foundation.h>
HELPER
int main(int argc, char **argv) { @autoreleasepool {
    NSString *folder = [NSString stringWithUTF8String: argv[1]];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *first = availablePathInDirectory(folder, @"1.dcm");
    printf("first\t%s\n", first.lastPathComponent.UTF8String);
    [fm createFileAtPath: first contents: [NSData data] attributes: nil];
    NSString *second = availablePathInDirectory(folder, @"1.dcm");
    printf("second\t%s\n", second.lastPathComponent.UTF8String);
    [fm createFileAtPath: second contents: [NSData data] attributes: nil];
    NSString *third = availablePathInDirectory(folder, @"1.dcm");
    printf("third\t%s\n", third.lastPathComponent.UTF8String);
    printf("archive\t%s\n", availablePathInDirectory(folder, @"a.zip").lastPathComponent.UTF8String);
    [fm createFileAtPath: [folder stringByAppendingPathComponent: @"a.zip"] contents: [NSData data] attributes: nil];
    printf("archive.again\t%s\n", availablePathInDirectory(folder, @"a.zip").lastPathComponent.UTF8String);
    printf("noextension\t%s\n", availablePathInDirectory(folder, @"IM0001").lastPathComponent.UTF8String);
}}
'''.replace('HELPER', match.group(0))

EXPECTED = {'first': '1.dcm', 'second': '1-1.dcm', 'third': '1-2.dcm', 'archive': 'a.zip',
            'archive.again': 'a-1.zip', 'noextension': 'IM0001'}

with tempfile.TemporaryDirectory(prefix='horos-decompression-names-') as work:
    work = Path(work)
    (work / 'main.m').write_text(DRIVER)
    (work / 'folder').mkdir()
    built = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', str(work / 'main.m'),
                            '-o', str(work / 'driver')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the helper did not compile:\n' + built.stderr[-2000:])
    else:
        run = subprocess.run([str(work / 'driver'), str(work / 'folder')], capture_output=True, text=True, timeout=60)
        results = dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)
        for key, value in EXPECTED.items():
            if results.get(key) != value:
                failures.append('%s: expected %r, got %r' % (key, value, results.get(key)))

importer = source[source.index('-(NSInteger)importFilesFromIncomingDir: (NSNumber*) showGUI\n           listenerCompressionSettings:'):]
importer = importer[:importer.index('\n}\n')]
if '[self.decompressionDirPath stringByAppendingPathComponent: lastPathComponent]' in importer:
    failures.append('a move into the decompression folder still takes the file\'s own name')
if importer.count('availablePathInDirectory( self.decompressionDirPath, lastPathComponent)') != 3:
    failures.append('the archive, deflated and compression moves do not all get a name of their own')
if 'moveItemAtPath:srcPath toPath:compressedPath error:NULL' in importer:
    failures.append('a move into the decompression folder still ignores its result')
compress = importer[importer.index('listenerCompressionSettings == 2'):]
compress = compress[:compress.index('continue;')]
if not re.search(r'if \(\[\[NSFileManager defaultManager\] moveItemAtPath:srcPath toPath:compressedPath error:&moveError\]\)\s*\{\s*\[compressedPathArray addObject: compressedPath\];', compress):
    failures.append('a file to compress is queued whether or not it reached the decompression folder')
if 'else if ([HorosEnhancedImportTriage isDeflatedDICOMAtPath: srcPath])' not in importer or '[deflatedPathArray addObject: compressedPath];' not in importer:
    failures.append('the #1003 routing of deflated files is gone')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('ok: files of the same name get names of their own in the decompression folder, and are queued once they are there')
