#!/usr/bin/env python3
"""The study, image and node entities no longer crash, raise or overrun (#778).

Found while DicomStudy, DicomImage, DicomSeries and the node identifiers moved
to Swift (#721), which kept their behaviour:

1. An ROI SR that cannot be read (no file, no ROI data) hands back nil from
   +[SRAnnotation roiFromDICOM:], and +[NSUnarchiver unarchiveObjectWithData:]
   dies on nil with a segmentation fault that no @catch stops. -roiImages and
   -roiForImage:inArray: sent it nil, and so did the browser's ROI images and
   the import of an "OsiriX ROI SR" without ROI data. Nil is now nil.
2. -valueForUndefinedKey: gathered -paths, every file of the study, and sent
   -completePath to one of those strings, which raised. It reads one image's
   file now.
3. -authorizedUsers tested canAccessPatientsOtherStudies for nil, so a user
   who may not see the patient's other studies had the access of one who may.
4. Two RTSTRUCT series gave the modalities "RT\\RT": the list was searched for
   "RTSTRUCT", and "RT" was what it held.
5. -imagesForKeyImages:andForROIs: was declared and never implemented.
6. +dbModifyLock created its lock lazily, unprotected between threads.
7. -didTurnIntoFault did not call super.
8. The screen captures sent nil to NSUnarchiver when an SR had no ROI data;
   the Swift answers nil (kept, and checked here).
9. -graphicAnnotationSequence read completePath, sopInstanceUID and rois as
   primitive values, keys the model does not have, and sent -values to the
   SOP Class UID string, which raised whenever the file could be read.
10. sopInstanceUIDEncode and sopInstanceUIDDecode wrote into 1024-byte buffers
    whatever the length of the UID.
11. DicomNodeIdentifier's -isEqualToDataNodeIdentifier: read host, port and AE
    title uninitialized for a location without "@"; the Swift starts them
    empty (kept, and checked here).

1, 4 and 8 run the Swift code compiled from the sources; 10 runs the C code
under AddressSanitizer; the rest is checked in the sources. `<git revision>`
as an optional argument reads the sources from that revision, the negative
control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def read(path):
    if revision:
        data = subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}'])
    else:
        data = (root / path).read_bytes()
    return data.decode('utf-8' if path.endswith('.swift') else 'latin1')


def block(text, start):
    """From `start` to the brace that closes the first one after it."""
    at = text.find(start)
    if at < 0:
        return None
    opening = text.index('{', at)
    depth = 0
    for index in range(opening, len(text)):
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        if depth == 0:
            return text[at:index + 1]
    return None


def functions(text, name):
    """Every file-level overload of `name`."""
    found = []
    at = text.find('fileprivate func %s(' % name)
    while at >= 0:
        found.append(block(text[at:], 'fileprivate func'))
        at = text.find('fileprivate func %s(' % name, at + 1)
    return found


def code(text):
    return '\n'.join(line.split('//')[0] for line in text.split('\n'))


def run(steps, binary, arguments):
    for step in steps:
        built = subprocess.run(step, capture_output=True, text=True)
        if built.returncode != 0:
            failures.append('the harness does not compile:\n' + built.stderr[-2500:])
            return None
    result = subprocess.run([binary] + arguments, capture_output=True, text=True)
    return result


study = read('Horos/Sources/DicomStudy.swift')
image = read('Horos/Sources/DicomImage.swift')
header = read('Horos/Sources/DicomStudy.h')
capi = read('Horos/Sources/DicomImage+CAPI.m')
nodes = read('Horos/Sources/RemoteDataNodeIdentifier.swift')
browser = read('Horos/Sources/BrowserController.m')
dcmtk = read('Horos/Sources/DicomFileDCMTKCategory.mm')

# --- 1, 4 and 8: the Swift, compiled ----------------------------------------
helpers = []
for name in ('dicomStudyGet', 'dicomStudyPerform', 'dicomStudyEnumerate', 'dicomStudyElementEqual',
             'dicomStudyUnarchive', 'dicomImageUnarchive'):
    found = functions(study if name.startswith('dicomStudy') else image, name)
    if not found or None in found:
        failures.append('%s is gone' % name)
    helpers += [f for f in found if f]
modalities = block(study, '    @objc(displayedModalitiesForSeries:)')
if modalities is None:
    failures.append('+displayedModalitiesForSeries: is gone')

if not failures:
    HARNESS = '\n\n'.join(['import Foundation'] + helpers + ['''
@objc(DicomStudy)
class DicomStudy: NSObject {
''' + modalities + '''
}

switch CommandLine.arguments[1] {
case "study-nil":
    print(dicomStudyUnarchive(nil) == nil ? "nil" : "object")
case "image-nil":
    print(dicomImageUnarchive(nil) == nil ? "nil" : "object")
case "study-data":
    let archived = NSArchiver.archivedData(withRootObject: ["a", "b"])
    let garbage = Data("not an archive".utf8)
    print((dicomStudyUnarchive(archived) as? NSArray)?.count ?? -1, dicomStudyUnarchive(garbage) == nil ? "nil" : "object")
default:
    for list in [["RTSTRUCT", "RTSTRUCT", "CT"], ["CT", "RTSTRUCT", "RTSTRUCT"], ["RTSTRUCT"], ["MR", "MR"], ["SR", "PR"], ["CT", "SR", "KO"]] {
        print(DicomStudy.displayedModalities(forSeries: list as NSArray)!)
    }
}
'''])
    with tempfile.TemporaryDirectory(prefix='horos-entity-defects-') as folder:
        source = Path(folder) / 'main.swift'
        binary = str(Path(folder) / 'entities')
        source.write_text(HARNESS, encoding='utf-8')
        steps = [['xcrun', 'swiftc', '-suppress-warnings', str(source), '-o', binary]]
        if 'RestrictedUnarchiver' in ''.join(helpers):
            # The ROI helpers decode through the restricted unarchiver (#816),
            # which catches NSUnarchiver's exceptions with HorosObjCException.
            for name in ('RestrictedUnarchiver.swift', 'HorosObjCException.h', 'HorosObjCException.m'):
                (Path(folder) / name).write_text(read('Horos/Sources/' + name), encoding='utf-8')
            (Path(folder) / 'bridge.h').write_text('#import "HorosObjCException.h"\n')
            steps = [['xcrun', 'clang', '-c', '-fobjc-exceptions', str(Path(folder) / 'HorosObjCException.m'),
                      '-o', str(Path(folder) / 'HorosObjCException.o')],
                     ['xcrun', 'swiftc', '-suppress-warnings', '-import-objc-header', str(Path(folder) / 'bridge.h'),
                      str(source), str(Path(folder) / 'RestrictedUnarchiver.swift'),
                      str(Path(folder) / 'HorosObjCException.o'), '-o', binary]]
        expected = {
            'study-nil': ('nil', '-roiImages and -roiForImage:inArray: send nil data to NSUnarchiver'),
            'image-nil': ('nil', 'the screen captures send nil data to NSUnarchiver'),
            'study-data': ('2 nil', 'an ROI archive is no longer read, or unreadable data is not nil'),
            'modalities': ('RT\\CT\nCT\\RT\nRT\nMR\nSR\\PR\nCT', 'RTSTRUCT series are listed as RT more than once'),
        }
        for index, (check, (answer, failure)) in enumerate(expected.items()):
            result = run(steps if index == 0 else [], binary, [check])
            if result is None:
                break
            if result.returncode != 0:
                failures.append('%s: the harness died (%d)' % (failure, result.returncode))
            elif result.stdout.strip() != answer:
                failures.append('%s: %r' % (failure, result.stdout.strip()))

# --- 1: the Objective-C callers -----------------------------------------------
for name, text in (('BrowserController.m', browser), ('DicomFileDCMTKCategory.mm', dcmtk)):
    if re.search(r'unarchiveObjectWithData:\s*\[SRAnnotation roiFromDICOM:', code(text)):
        failures.append('%s sends +[SRAnnotation roiFromDICOM:] to NSUnarchiver unchecked' % name)

# --- 2 ------------------------------------------------------------------------
undefined = block(study, '    public override func value(forUndefinedKey key: String)')
if undefined is None or 'self.paths()' in undefined or '"completePath")' in undefined \
        or 'as? DicomImage' not in undefined or '.completePath()' not in undefined:
    failures.append('-valueForUndefinedKey: gathers the study\'s paths, or sends -completePath to a path')

# --- 3 ------------------------------------------------------------------------
authorized = block(study, '    @objc public dynamic func authorizedUsers()')
if authorized is None or 'canAccessPatientsOtherStudies != nil' in authorized \
        or authorized.count('canAccessPatientsOtherStudies?.boolValue') != 2:
    failures.append('-authorizedUsers tests canAccessPatientsOtherStudies for nil instead of reading it')

# --- 5 ------------------------------------------------------------------------
implemented = block(study, '    @objc(imagesForKeyImages:andForROIs:)')
if implemented is None or 'roiAndKeyImages()' not in implemented or 'roiImages()' not in implemented:
    failures.append('-imagesForKeyImages:andForROIs: is still not implemented')
swift_branch = header[header.find('#elif __has_include("Horos-Swift.h")'):header.find('#else', header.find('#elif __has_include("Horos-Swift.h")'))]
if 'imagesForKeyImages' in swift_branch:
    failures.append('DicomStudy.h still declares -imagesForKeyImages:andForROIs: beside the Swift class')

# --- 6 ------------------------------------------------------------------------
if 'private static let dbModifyLockStorage = NSRecursiveLock()' not in study or 'dbModifyLockStorage == nil' in study:
    failures.append('+dbModifyLock still creates its lock lazily')

# --- 7 ------------------------------------------------------------------------
fault = block(study, '    public override func didTurnIntoFault()')
if fault is None or 'super.didTurnIntoFault()' not in fault:
    failures.append('-didTurnIntoFault does not call super')

# --- 9 ------------------------------------------------------------------------
annotation = block(image, '    @objc public func graphicAnnotationSequence()')
if annotation is None or 'primitiveValue(forKey:' in annotation or '"values"' in annotation \
        or 'self.completePath()' not in annotation or 'attributeArray(withName: "SOPClassUID")' not in annotation:
    failures.append('-graphicAnnotationSequence reads keys the model does not have, or sends -values to a string')

# --- 10: the C code, under AddressSanitizer -------------------------------------
start = capi.find('static inline int charToInt')
end = capi.find('// Declared for Swift in DicomImage.h.')
if start < 0 or end < 0:
    failures.append('the UID encoding is gone from DicomImage+CAPI.m')
else:
    UIDS = '#import <Foundation/Foundation.h>\n' + capi[start:end] + r'''
#define check(c) do { if (!(c)) { printf("FAIL: %s (line %d)\n", #c, __LINE__); return 1; } } while (0)
int main(void) { @autoreleasepool {
    // A short UID, odd and even, and UIDs past what 1024 bytes held both ways.
    NSMutableString *longer = [NSMutableString stringWithString: @"1.2.840"];
    while (longer.length < 5000) [longer appendString: @".12345"];
    for (NSString *uid in @[@"1.2.840.10008.5.1.4.1.1.2", @"1.2.840.10008.5.1.4.1.1.24", longer, [longer stringByAppendingString: @"9"]]) {
        int length = (int) (uid.length + 1) / 2;
        unsigned char *encoded = sopInstanceUIDEncode(uid);
        check(encoded != NULL);
        check([sopInstanceUIDDecode(encoded, length) isEqualToString: uid]);
        free(encoded);
    }
    printf("ok\n");
    return 0;
} }
'''
    with tempfile.TemporaryDirectory(prefix='horos-entity-uids-') as folder:
        source = Path(folder) / 'uids.m'
        binary = str(Path(folder) / 'uids')
        source.write_text(UIDS, encoding='latin1')
        result = run([['xcrun', 'clang', '-fno-objc-arc', '-fsanitize=address', '-g', '-framework', 'Foundation',
                       str(source), '-o', binary]], binary, [])
        if result is not None and (result.returncode != 0 or result.stdout.strip() != 'ok'):
            report = (result.stdout + result.stderr).strip().splitlines()
            summary = [line for line in report if 'SUMMARY' in line or 'FAIL' in line] or report[-3:]
            failures.append('the SOP Instance UID buffers overrun: ' + ' | '.join(summary))

# --- 11 -------------------------------------------------------------------------
dicom_nodes = nodes[nodes.find('@objc(DicomNodeIdentifier)'):]
equal = block(dicom_nodes, '    public override func isEqual(to dni: DataNodeIdentifier!)')
# Since #805 each node's own fields are read into an endpoint, all set
# (test-dicom-node-identity.py checks the comparison itself).
if equal is None or (any(declaration not in equal for declaration in (
        'var selfHost: Host? = nil', 'var selfPort = 0', 'var selfAet: NSString? = nil',
        'var dniHost: Host? = nil', 'var dniPort = 0', 'var dniAet: NSString? = nil'))
        and not ('dicomNodeEndpoint(self)' in equal and 'dicomNodeEndpoint(dni)' in equal)):
    failures.append('DicomNodeIdentifier compares a host, port or AE title it did not set')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: the study, image and node entities neither crash, raise nor overrun (#778)')
