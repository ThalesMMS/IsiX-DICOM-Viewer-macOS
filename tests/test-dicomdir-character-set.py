#!/usr/bin/env python3
"""The scan of a medium decodes a DICOMDIR's names in the character set it states.

A DICOMDIR record carries Specific Character Set (0008,0005) when its texts are
not in the default repertoire. The scan (DicomdirReader.swift) took the
element out of the record and decoded every name in the encodings of no
character set, so a medium whose DICOMDIR says ISO_IR 100, ISO 2022 IR 87 or
ISO_IR 192 showed its patients and studies with wrong characters until the
files were indexed. The table of encodings for a stated character set is now
IsiXDICOMFile's DICOMCharacterSet.encodings(forSpecificCharacterSet:), which
DicomFile uses for the files' own texts.

The test writes, with pydicom, a medium of four studies in four character sets
(ISO_IR 100, ISO 2022 IR 87 with ideographic and phonetic names, ISO_IR 144,
ISO_IR 192) and its DICOMDIR, whose records state the character set of their
study. It compiles DicomdirReader.swift as it is written, with the
IsiXDICOMFile and IsiXDatabase modules, the DICOMDIR adapter
(IsiXDCMTKDicomDir, against the DCMTK of the Debug build: exit 2 without it),
DicomFile's decoding as written in DicomFile+Text.swift, and stand-ins for what
of the application it consults. The patient name and study description of each
entry the reader gives must be those of its file, as pydicom reads them and as
the import cleans text.

`<git revision>` as an optional argument reads the reader from that revision,
under the name it had there, the negative control. Exit 2 without a Python with pydicom
(HOROS_PYTHON or the local venvs).
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402
import process_graph_stand_in  # noqa: E402  - the scan reads the preferences through the process graph
from dcmtk_build import ROOT, dcmtk_flags  # noqa: E402
from python_with import interpreter_or_skip  # noqa: E402

revision = sys.argv[1] if len(sys.argv) > 1 else None
SCAN = 'Horos/Sources/DicomdirReader.swift'
FORMER_SCAN = 'Horos/Sources/DicomDatabase+DicomDir.swift'
ADAPTERS = ROOT / 'Horos/Sources/Adapters/DCMTK'

flags = dcmtk_flags('dcmnet', 'dcmjpeg', 'ijg8', 'ijg12', 'ijg16', 'dcmimage', 'dcmimgle')


python = interpreter_or_skip('import pydicom', need='the medium needs', packages="'pydicom>=3,<4'")

GENERATOR = r'''
import json, sys
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.fileset import FileSet
from pydicom.uid import ExplicitVRLittleEndian, SecondaryCaptureImageStorage, generate_uid
import pydicom

studies = [
    ('ISO_IR 100', 'Müller^José', 'Études crâniennes'),
    (['', 'ISO 2022 IR 87'], 'Yamada^Tarou=山田^太郎=やまだ^たろう', '胸部 単純'),
    ('ISO_IR 144', 'Иванов^Иван', 'Грудная клетка'),
    ('ISO_IR 192', 'Ñandú^Ζωή', 'Θώρακας ✓'),
]
medium = FileSet()
for index, (characters, name, description) in enumerate(studies):
    ds = Dataset()
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = SecondaryCaptureImageStorage
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.SOPClassUID = SecondaryCaptureImageStorage
    ds.SOPInstanceUID = ds.file_meta.MediaStorageSOPInstanceUID = generate_uid()
    ds.SpecificCharacterSet = characters
    ds.PatientName = name
    ds.PatientID = 'CHARSET-%d' % index
    ds.StudyInstanceUID = generate_uid()
    ds.SeriesInstanceUID = generate_uid()
    ds.StudyDate, ds.StudyTime, ds.StudyID, ds.AccessionNumber = '20260101', '120000', str(index + 1), ''
    ds.StudyDescription = description
    ds.Modality, ds.SeriesNumber, ds.InstanceNumber = 'OT', 1, 1
    medium.add(ds)
medium.write(sys.argv[1])
# What the files say, as pydicom decodes them.
files = {}
for instance in pydicom.dcmread(sys.argv[1] + '/DICOMDIR').DirectoryRecordSequence:
    if instance.DirectoryRecordType == 'IMAGE':
        path = sys.argv[1] + '/' + '/'.join(instance.ReferencedFileID)
        ds = pydicom.dcmread(path)
        files[str(ds.SOPInstanceUID)] = {'patientName': str(ds.PatientName),
                                         'studyDescription': str(ds.StudyDescription),
                                         'specificCharacterSet': ds['SpecificCharacterSet'].repval}
print(json.dumps(files))
'''

BRIDGE = r'''
#import <Cocoa/Cocoa.h>
#import "IsiXDCMTKDicomDir.h"
'''

# What of the application the reader consults, standing in; in a revision
# where it was an extension, the database receiving the entries too.
STUBS = r'''
import Foundation
import IsiXDICOMFile

class DicomDatabase {
    var described: [Any] = []
    func addFilesDescribed(inDictionaries dictionaries: [Any]?, postNotifications: Bool, rereadExistingItems: Bool,
                           generatedByOsiriX: Bool, importedFiles: Bool, returnArray: Bool) -> [Any]? {
        described = dictionaries ?? []
        return described
    }
    func objects(withIDs ids: [Any]?) -> [Any]? { ids }
}

final class DicomDirParser {
    init(_ path: String) {}
    func parseArray(_ files: NSMutableArray) {}
}

final class HorosObjCException {
    static func perform(_ body: () -> Void) throws { body() }
}
let HorosObjCExceptionKey = "HorosObjCException"
let OsirixDicomImageSizeUnknown = Int32.max

func N2LogStackTraceMessage(_ message: String) { print(message) }
func HorosRunTaskUntilExit(_ task: Process, _ timeout: TimeInterval, _ error: UnsafeMutablePointer<NSError?>?) -> Bool { false }

extension Thread {
    var status: String { get { "" } set {} }
}

extension NSDate {
    static func date(withYYYYMMDD date: NSString?, hhmmss time: NSString?) -> NSDate? { nil }
}

final class DicomFile {
    DECODING

    class func patientUID(_ src: Any!) -> String! { "" }
}
'''

DRIVER = r'''
import Foundation
import IsiXDICOMFile

let folder = CommandLine.arguments[1]
let expected = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    as! [String: [String: String]]
let paths = FileManager.default.enumerator(atPath: folder)!.compactMap { $0 as? String }.map { folder + "/" + $0 }
READ
var failed = false
var seen = 0
for case let entry as NSDictionary in entries {
    guard let uid = entry["SOPUID"] as? String, let file = expected[uid] else { continue }
    seen += 1
    for key in ["patientName", "studyDescription"] {
        // The import cleans every text it keeps, the file's as the DICOMDIR's.
        let wanted = NSMutableString(string: file[key]!)
        ImportedText.clean(wanted)
        let got = entry[key] as? String ?? "(none)"
        let mark = got == wanted as String ? "ok  " : "FAIL"
        if got != wanted as String { failed = true }
        print("\(mark) \(file["specificCharacterSet"]!): \(key) \(got)" + (got == wanted as String ? "" : " where the file has \(wanted)"))
    }
}
if seen != expected.count { print("FAIL: the scan gave \(seen) of the \(expected.count) entries"); failed = true }
exit(failed ? 1 : 0)
'''


def scan_source():
    if revision:
        for path in (SCAN, FORMER_SCAN):
            shown = subprocess.run(['git', '-C', str(ROOT), 'show', '%s:%s' % (revision, path)], capture_output=True)
            if shown.returncode == 0:
                return shown.stdout.decode('utf-8')
        raise SystemExit('FAIL: %s has neither %s nor %s' % (revision, SCAN, FORMER_SCAN))
    return (ROOT / SCAN).read_text(encoding='utf-8')


READERS = {
    'current': 'let entries = DicomdirReader().read(at: folder + "/DICOMDIR", withPaths: paths).entries',
    'former': 'let database = DicomDatabase()\n'
              '_ = database.scanDicomdir(at: folder + "/DICOMDIR", withPaths: paths as NSArray, pathsToScanAnyway: NSMutableArray())\n'
              'let entries = database.described',
}


def decoding():
    """+stringWithBytes:encodings:replaceBadCharacters: as DicomFile+Text.swift has it."""
    text = (ROOT / 'Horos/Sources/DicomFile+Text.swift').read_text(encoding='utf-8')
    match = re.search(r'\n    class func string\(withBytes str: UnsafeMutablePointer<CChar>!, encodings: '
                      r'UnsafeMutablePointer<UInt>!,\n.*?\n    }\n', text, re.S)
    if not match:
        raise SystemExit('FAIL: DicomFile+Text.swift no longer has +stringWithBytes:encodings:replaceBadCharacters:')
    return match.group(0).strip()


with tempfile.TemporaryDirectory(prefix='isix-dicomdir-charset-') as directory:
    work = Path(directory)
    medium = work / 'medium'
    made = subprocess.run([python, '-c', GENERATOR, str(medium)], capture_output=True, text=True, timeout=120)
    if made.returncode:
        raise SystemExit('FAIL: the medium cannot be written:\n' + made.stderr[-2000:])
    (work / 'expected.json').write_text(made.stdout)
    (work / 'scan.swift').write_text(scan_source(), encoding='utf-8')
    (work / 'stubs.swift').write_text(STUBS.replace('DECODING', decoding()), encoding='utf-8')
    reader = 'current' if 'struct DicomdirReader' in scan_source() else 'former'
    (work / 'main.swift').write_text(DRIVER.replace('READ', READERS[reader]))
    (work / 'bridge.h').write_text(BRIDGE)
    modules = work / 'modules'
    module_flags = isix_modules.module_flags('IsiXDICOMFile', modules) + isix_modules.module_flags('IsiXDatabase', modules)[4:]
    includes = ['-I' + str(ROOT / 'Horos/Sources'), '-I' + str(ADAPTERS)]
    objects = []
    for name in ('IsiXDCMTKError.mm', 'IsiXDCMTKDicomDir.mm'):
        obj = work / (name + '.o')
        built = subprocess.run(['xcrun', 'clang++', '-std=gnu++17', '-w', '-mmacosx-version-min=15.0', '-fobjc-arc',
                                '-x', 'objective-c++', *includes, *flags[:2], '-c', str(ADAPTERS / name), '-o', str(obj)],
                               capture_output=True, text=True, timeout=600)
        if built.returncode:
            raise SystemExit('FAIL: %s does not compile against the build\'s DCMTK:\n%s' % (name, built.stderr[-3000:]))
        objects.append(str(obj))
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-module-name', 'Horos',
                            '-import-objc-header', str(work / 'bridge.h'),
                            *[part for flag in includes for part in ('-Xcc', flag)], *module_flags,
                            str(work / 'scan.swift'), str(work / 'stubs.swift'), str(work / 'main.swift'),
                            str(process_graph_stand_in.source(work)), *objects,
                            *flags[2:], '-Xlinker', '-lc++', '-framework', 'Cocoa', '-o', str(work / 'check')],
                           capture_output=True, text=True, timeout=600)
    if built.returncode:
        raise SystemExit('FAIL: the scan does not compile with its driver:\n' + built.stderr[-4000:])
    failed = []
    # As installed, and with a code page chosen for files that state no
    # character set, which must not touch a record that states one.
    for preference in ([], ['-DefaultCharacterSetWhenAbsent', 'WINDOWS-1251']):
        print('-- DefaultCharacterSetWhenAbsent %s' % (preference[1] if preference else 'empty'))
        try:
            run = subprocess.run([str(work / 'check'), str(medium), str(work / 'expected.json'), *preference],
                                 capture_output=True, text=True, timeout=60)
        except subprocess.TimeoutExpired:
            raise SystemExit('FAIL: the scan did not end within 60 s')
        print(run.stdout, end='')
        if run.returncode:
            print(run.stderr[-2000:], end='')
            failed.append(preference[1] if preference else 'empty')
    if failed:
        raise SystemExit('FAIL: the scan does not show the names its files have (DefaultCharacterSetWhenAbsent %s)'
                         % ', '.join(failed))
    print('PASS: a DICOMDIR in ISO_IR 100, ISO 2022 IR 87, ISO_IR 144 and ISO_IR 192 shows in the scan the names '
          'and descriptions of its files, whatever is chosen for files that state no character set')
