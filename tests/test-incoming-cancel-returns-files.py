#!/usr/bin/env python3
"""A cancelled incoming import leaves nothing in the database folder without a row.

-importFilesFromIncomingDir: moves each file from INCOMING into the database
folder before it indexes it. Quitting cancels the pass, and a cancelled pass
used to leave those files there: the scan returned at once with what it had
moved, and -addFilesAtPaths: emptied its list and returned an empty array, not
nil, so the "move them back" branch never ran. Quitting during an import of
30,000 files left 7,155 files in the database folder with no row - received
images that no study shows and nothing indexes again.

What must stay true:

- the scan stops on cancellation without returning, so what it moved reaches
  the end of the pass;
- -addFilesAtPaths: reports what a cancelled pass did not index - the files of
  the chunk it was in, under the name they were read from, and every file after
  - and stops there;
- the pass moves those back into INCOMING, under the name they arrived with,
  the image of an Analyze pair with its header; a cancelled pass also returns
  what it moved for decompression and starts no decompression;
- the move back itself is compiled and run.

DicomDatabase is Swift: the scan is DicomDatabase+IncomingImport.swift, the
import DicomDatabase+Import.swift, and the move back a member of
DicomDatabase+ImportCleanup.swift that finds a free name with IsiXDatabase's
AvailablePath. A checkout with DicomDatabase.mm is read as before.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
import isix_modules  # noqa: E402
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def method(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    return source[at:source.index('\n}\n', at) + 3]


SWIFT = (root / 'Horos/Sources/DicomDatabase+IncomingImport.swift').exists()


def member(source, signature):
    """A Swift member from `signature` through its closing brace."""
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth = 0
    for index in range(opening, len(source)):
        depth += {'{': 1, '}': -1}.get(source[index], 0)
        if depth == 0:
            return source[at:index + 1]
    return ''


if SWIFT:
    incoming_source = (root / 'Horos/Sources/DicomDatabase+IncomingImport.swift').read_text()
    import_source = (root / 'Horos/Sources/DicomDatabase+Import.swift').read_text()
    cleanup_source = (root / 'Horos/Sources/DicomDatabase+ImportCleanup.swift').read_text()
    instance_source = (root / 'Horos/Sources/DicomDatabase+Instance.swift').read_text()

    scan = member(incoming_source, 'private final func importAdmittedFilesFromIncomingDir(')
    check(scan, 'importAdmittedFilesFromIncomingDir: not found')
    check(re.search(r'if thread\.isCancelled \{\s*break\s*\}', scan) and not re.search(r'if thread\.isCancelled \{\s*return 0\s*\}', scan),
          'the scan still returns on cancellation with the files it moved left behind')
    check('unindexedPaths: unindexedFiles)' in scan, 'the pass does not ask -addFilesAtPaths: what it left unindexed')
    check(re.search(r'if addedFiles == nil \{[^\n]*\n\s*self\.returnFilesToIncomingDir\(\(filesArray as\? \[String\]\) \?\? \[\]\)\s*'
                    r'\} else if unindexedFiles\.count != 0 \{[^\n]*\n\s*self\.returnFilesToIncomingDir\(\(unindexedFiles as\? \[String\]\) \?\? \[\]\)', scan),
          'the pass does not return what was not indexed')
    # The @finally of the Objective-C is the code after the attempt.
    tail = scan[scan.find('// @finally'):]
    cancelled = tail.find('if thread.isCancelled {')
    check(-1 < cancelled < tail.find('self.queueForDecompression(deflatedPathArray)'),
          'a cancelled pass still starts the decompression')
    window = tail[cancelled:tail.find('return addedFilesCount', cancelled)]
    check('self.returnFilesToIncomingDir(deflatedPathArray)' in window and 'self.returnFilesToIncomingDir(compressedPathArray)' in window,
          'a cancelled pass leaves what it moved for decompression in the decompression folder')
    check('if plugins.count != 0 && thread.isCancelled == false {' in scan,
          'the preprocessing plugins still run on a cancelled pass')

    add = member(import_source, 'final func addFiles(atPaths paths: NSArray?, postNotifications: Bool, dicomOnly: Bool, '
                                'rereadExistingItems: Bool, generatedByOsiriX: Bool,')
    check(add, 'addFilesAtPaths:...unindexedPaths: not found')
    stop = add[add.find('if stopped {'):]
    check('read.object(forKey: "filePath")' in stop and 'unindexedPaths?.add(readPath)' in stop,
          'a cancelled chunk does not report the files it had read')
    check('paths.subarray(with: NSRange(location: i + 1, length: paths.count - (i + 1)))' in stop,
          'a cancelled pass does not report the files it never read')
    check(-1 < stop.find('unindexedPaths?.addObjects(from:') < stop.find('dicomFilesArray.removeAllObjects()'),
          'the read files are dropped before they are reported')
    check(re.search(r'return stopped\s*\}\s*if endOfPass \{ break \}', add), 'a cancelled pass goes on to the next chunk')
    former = member(import_source, 'func addFiles(atPaths paths: [Any]!, postNotifications: Bool, dicomOnly: Bool, rereadExistingItems: Bool, '
                                   'generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]! {')
    check('unindexedPaths: nil)' in former, 'the former entry point no longer forwards to the one that reports')

    back = member(cleanup_source, 'final func returnFilesToIncomingDir(_ paths: [String]) {')
    available = member(cleanup_source, 'final func availablePath(inDirectory directory: String?, name: String) -> String? {')
    arg = member(instance_source, 'static func arg(_ object: Any?) -> CVarArg {')
    check(back and available and arg, 'returnFilesToIncomingDir: not found')
else:
    database = source_text('DicomDatabase')

if not SWIFT:
    scan = method(database, '-(NSInteger)importAdmittedFilesFromIncomingDir:')
    check(scan, 'importAdmittedFilesFromIncomingDir: not found')
    check(re.search(r'if \(thread\.isCancelled\)\s*break;', scan) and not re.search(r'if \(thread\.isCancelled\)\s*return 0;', scan),
          'the scan still returns on cancellation with the files it moved left behind')
    check('unindexedPaths: unindexedFiles]' in scan, 'the pass does not ask -addFilesAtPaths: what it left unindexed')
    check(re.search(r'if \(!addedFiles\)[^\n]*\n\s*\[self returnFilesToIncomingDir: filesArray\];\s*'
                    r'else if \(unindexedFiles\.count\)[^\n]*\n\s*\[self returnFilesToIncomingDir: unindexedFiles\];', scan),
          'the pass does not return what was not indexed')
    tail = scan[scan.find('@finally'):]
    cancelled = tail.find('if (thread.isCancelled)')
    check(-1 < cancelled < tail.find('kickstartCompressDecompress'),
          'a cancelled pass still starts the decompression')
    check('[self returnFilesToIncomingDir: deflatedPathArray];' in tail and '[self returnFilesToIncomingDir: compressedPathArray];' in tail,
          'a cancelled pass leaves what it moved for decompression in the decompression folder')
    check(re.search(r'if \(\[\[PluginManager preProcessPlugins\] count\] && thread\.isCancelled == NO\)', scan),
          'the preprocessing plugins still run on a cancelled pass')

    add = method(database, '-(NSArray*)addFilesAtPaths:(NSArray*)paths postNotifications:(BOOL)postNotifications dicomOnly:(BOOL)dicomOnly '
                           'rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX importedFiles: (BOOL) importedFiles '
                           'returnArray: (BOOL) returnArray unindexedPaths:')
    check(add, 'addFilesAtPaths:...unindexedPaths: not found')
    stop = add[add.find('if( stopped)'):]
    check('[read objectForKey: @"filePath"]' in stop and '[unindexedPaths addObject: readPath]' in stop,
          'a cancelled chunk does not report the files it had read')
    check('[paths subarrayWithRange: NSMakeRange( i+1, paths.count-(i+1))]' in stop,
          'a cancelled pass does not report the files it never read')
    check(stop.find('[unindexedPaths addObjectsFromArray:') < stop.find('[dicomFilesArray removeAllObjects];'),
          'the read files are dropped before they are reported')
    check(re.search(r'\[pool2 release\];\s*if \(stopped\)\s*break;', add), 'a cancelled pass goes on to the next chunk')
    check('unindexedPaths: nil];' in method(database, '-(NSArray*)addFilesAtPaths:(NSArray*)paths postNotifications:(BOOL)postNotifications '
                                                      'dicomOnly:(BOOL)dicomOnly rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX '
                                                      'importedFiles: (BOOL) importedFiles returnArray: (BOOL) returnArray\n'),
          'the former entry point no longer forwards to the one that reports')

    back = method(database, '-(void)returnFilesToIncomingDir:(NSArray*)paths')
    available = database[database.index('static NSString *availablePathInDirectory( NSString *directory, NSString *name)\n{'):]
    available = available[:available.index('\n}\n') + 3]
    check(back, 'returnFilesToIncomingDir: not found')

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (clang)', file=sys.stderr)
    sys.exit(2)

harness = r'''
#import <Foundation/Foundation.h>
static NSDictionary *remembered;
@interface HorosImportedFileNames : NSObject
+ (NSString *)nameForPath:(NSString *)path;
@end
@implementation HorosImportedFileNames
+ (NSString *)nameForPath:(NSString *)path { return remembered[path]; }
@end
@interface HorosHeaderImagePair : NSObject
+ (NSString *)imagePathForHeader:(NSString *)path;
@end
@implementation HorosHeaderImagePair
+ (NSString *)imagePathForHeader:(NSString *)path {
    if (![path.pathExtension isEqualToString: @"hdr"]) return nil;
    NSString *image = [path.stringByDeletingPathExtension stringByAppendingPathExtension: @"img"];
    return [NSFileManager.defaultManager fileExistsAtPath: image] ? image : nil;
}
@end
@interface DicomDatabase : NSObject
@property (copy) NSString *incomingDirPath;
- (void)returnFilesToIncomingDir:(NSArray *)paths;
@end
''' + available + r'''
@implementation DicomDatabase
''' + back + r'''
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *root = @(argv[1]);
        NSString *data = [root stringByAppendingPathComponent: @"DATABASE"], *incoming = [root stringByAppendingPathComponent: @"INCOMING"];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath: data withIntermediateDirectories: YES attributes: nil error: NULL];
        [fm createDirectoryAtPath: incoming withIntermediateDirectories: YES attributes: nil error: NULL];
        NSArray *made = @[@"1.dcm", @"2.png", @"3.hdr", @"3.img", @"5.dcm"];
        for (NSString *name in made)
            [name writeToFile: [data stringByAppendingPathComponent: name] atomically: NO encoding: NSUTF8StringEncoding error: NULL];
        [@"already here" writeToFile: [incoming stringByAppendingPathComponent: @"1.dcm"] atomically: NO encoding: NSUTF8StringEncoding error: NULL];
        remembered = @{[data stringByAppendingPathComponent: @"2.png"]: @"scan.png",
                       [data stringByAppendingPathComponent: @"3.hdr"]: @"brain.hdr",
                       [data stringByAppendingPathComponent: @"5.dcm"]: @".hidden"};
        DicomDatabase *db = [DicomDatabase new];
        db.incomingDirPath = incoming;
        [db returnFilesToIncomingDir: @[[data stringByAppendingPathComponent: @"1.dcm"], [data stringByAppendingPathComponent: @"2.png"],
                                        [data stringByAppendingPathComponent: @"3.hdr"], [data stringByAppendingPathComponent: @"4.dcm"],
                                        [data stringByAppendingPathComponent: @"5.dcm"]]];
        [db returnFilesToIncomingDir: @[]];
        for (NSString *folder in @[data, incoming]) {
            NSArray *names = [[fm contentsOfDirectoryAtPath: folder error: NULL] sortedArrayUsingSelector: @selector(compare:)];
            printf("%s\t%s\n", folder.lastPathComponent.UTF8String, [names componentsJoinedByString: @","].UTF8String);
        }
        NSString *moved = [NSString stringWithContentsOfFile: [incoming stringByAppendingPathComponent: @"1-1.dcm"] encoding: NSUTF8StringEncoding error: NULL];
        printf("content\t%s\n", moved.UTF8String ?: "");
    }
    return 0;
}
'''
SWIFT_HARNESS = r'''
import Foundation
import IsiXDatabase

enum DicomDatabaseObjC {
ARG
}

nonisolated(unsafe) var remembered: [String: String] = [:]

enum ImportedFileNames {
    static func name(forPath path: String) -> String? { remembered[path] }
}

enum HeaderImagePair {
    static func imagePath(forHeader path: String) -> String? {
        guard (path as NSString).pathExtension == "hdr" else { return nil }
        let image = ((path as NSString).deletingPathExtension as NSString).appendingPathExtension("img")!
        return FileManager.default.fileExists(atPath: image) ? image : nil
    }
}

final class DicomDatabase {
    var incoming = ""
    func incomingDirPath() -> String! { incoming }
AVAILABLE
BACK
}

let root = CommandLine.arguments[1]
let data = (root as NSString).appendingPathComponent("DATABASE"), incoming = (root as NSString).appendingPathComponent("INCOMING")
let fm = FileManager.default
try! fm.createDirectory(atPath: data, withIntermediateDirectories: true)
try! fm.createDirectory(atPath: incoming, withIntermediateDirectories: true)
for name in ["1.dcm", "2.png", "3.hdr", "3.img", "5.dcm"] {
    try! name.write(toFile: (data as NSString).appendingPathComponent(name), atomically: false, encoding: .utf8)
}
try! "already here".write(toFile: (incoming as NSString).appendingPathComponent("1.dcm"), atomically: false, encoding: .utf8)
remembered = [(data as NSString).appendingPathComponent("2.png"): "scan.png",
              (data as NSString).appendingPathComponent("3.hdr"): "brain.hdr",
              (data as NSString).appendingPathComponent("5.dcm"): ".hidden"]
let db = DicomDatabase()
db.incoming = incoming
db.returnFilesToIncomingDir(["1.dcm", "2.png", "3.hdr", "4.dcm", "5.dcm"].map { (data as NSString).appendingPathComponent($0) })
db.returnFilesToIncomingDir([])
for folder in [data, incoming] {
    let names = (try! fm.contentsOfDirectory(atPath: folder)).sorted()
    print("\((folder as NSString).lastPathComponent)\t\(names.joined(separator: ","))")
}
let moved = (try? String(contentsOfFile: (incoming as NSString).appendingPathComponent("1-1.dcm"), encoding: .utf8)) ?? ""
print("content\t\(moved)")
'''

with tempfile.TemporaryDirectory() as folder:
    folder = Path(folder)
    if SWIFT:
        (folder / 'main.swift').write_text(SWIFT_HARNESS.replace('ARG', arg).replace('AVAILABLE', available).replace('BACK', back))
        modules = isix_modules.module_flags('IsiXDatabase', folder / 'IsiXDatabase')
        build = subprocess.run(['xcrun', 'swiftc', *modules, str(folder / 'main.swift'), '-o', str(folder / 'probe')],
                               capture_output=True, text=True, timeout=300)
    else:
        (folder / 'probe.m').write_text(harness)
        build = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', str(folder / 'probe.m'), '-o', str(folder / 'probe')],
                               capture_output=True, text=True)
    check(build.returncode == 0, 'returnFilesToIncomingDir: does not compile on its own\n' + build.stderr[-3000:])
    if build.returncode == 0:
        (folder / 'work').mkdir()
        run = subprocess.run([str(folder / 'probe'), str(folder / 'work')], capture_output=True, text=True, timeout=60)
        results = dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)
        check(results.get('DATABASE') == '', f'files stayed in the database folder: {results.get("DATABASE")!r}')
        check(results.get('INCOMING') == '1-1.dcm,1.dcm,5.dcm,brain.hdr,brain.img,scan.png',
              f'INCOMING holds {results.get("INCOMING")!r}, not the files under the names they arrived with')
        check(results.get('content') == '1.dcm', 'the file already in INCOMING was overwritten')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: a cancelled import returns to INCOMING what it moved and did not index')
