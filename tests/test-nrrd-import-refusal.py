#!/usr/bin/env python3
"""An NRRD file left for import is kept aside, not consumed and deleted.

The incoming folder let `.nrrd` through its door because of its extension, and
no reader could make a record or pixels from it: the one that tried never
reported success, with fixed 512x512 dimensions. The file was moved into the
database, found unreadable and deleted. NRRD is now refused at the door and
kept in the folder of unreadable files whatever DELETEFILELISTENER says, and
the reader that could not succeed is gone.

-getNRRDFile is a selector of the former plugin SDK, which a plugin built for
it may still send: DicomFile answers it, with -1 and nothing else, the answer
for a file that could not be decoded. No other file has it, and nothing of the
application sends it.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


# DicomDatabase is Swift: the incoming scan is IncomingAdmission.swift,
# where each file is examined in a method that returns to go on to the next.
database = (root / 'Horos/Sources/IncomingAdmission.swift').read_text()
refusal = database.find('if isDicomFile == false && DicomFile.isNRRDFile(srcPath) {')
door = database.find('let takesFile = IncomingScanRules.takesFile(')
require(refusal != -1 and door != -1 and refusal < door, 'NRRD is not refused before the door of the incoming folder')
if refusal != -1 and door != -1:
    branch = database[refusal:database.index('return\n', refusal)]
    require('addImportRefusalSummary(' in branch, 'the refusal of an NRRD file is not reported')
    require('availablePath(inDirectory: database.errorsDirPath(), name: lastPathComponent)' in branch and 'moveItem(srcPath, kept)' in branch,
            'a refused NRRD file is not kept in the folder of unreadable files')
    require('removeItem(' not in branch and 'DELETEFILELISTENER' not in branch.split('NSLog')[0].replace('whatever DELETEFILELISTENER says', ''),
            'a refused NRRD file can be deleted')
    accepted = database[door:database.index('destinationTaken:', door)]
    require('isNRRDFile' not in accepted, 'the incoming folder still lets NRRD in, to be found unreadable and deleted')
    for reader in ('isFVTiffFile', 'isTiffFile', 'isNIfTIFile', 'isImageFile'):
        require(reader in accepted, 'the incoming folder lost %s, a format that is read' % reader)

# Nothing pretends to read the format.
# DicomFile is Swift (DicomFile.swift and DicomFile+<category>.swift); its DCMTK
# category is declared in DicomFileDCMTKCategory.h.
readers = ['Horos/Sources/DicomFile.swift'] + [str(p.relative_to(root)) for p in sorted((root / 'Horos/Sources').glob('DicomFile+*.swift'))]
FACADE = 'Horos/Sources/DicomFile+LegacyPluginSDK.swift'
for name in (*readers, 'Horos/Sources/DicomFileDCMTKCategory.h'):
    text = (root / name).read_text(errors='replace')
    require('nrrdLoad' not in text and ('getNRRDFile' not in text or name == FACADE),
            '%s still carries the NRRD reader that never reported success' % name)
# The selector of the former SDK answers that the file could not be decoded, and reads nothing.
facade = (root / FACADE).read_text()
declared = '@objc(getNRRDFile) nonisolated func legacyGetNRRDFile() -> Int16 {'
require(facade.count('getNRRDFile') == 2 and declared in facade, 'DicomFile no longer answers -getNRRDFile as the former SDK declared it')
if declared in facade:
    body = facade[facade.index(declared) + len(declared):]
    body = [line.strip() for line in body[:body.index('\n    }\n')].splitlines() if line.strip()]
    require(len(body) == 2 and body[0].startswith('FormerSDKFacade.inert("DicomFile", "-getNRRDFile", because: ') and body[1] == 'return -1',
            '-getNRRDFile does more than answer -1: %s' % body)
for path in sorted((root / 'Horos/Sources').rglob('*')):
    if path.suffix in ('.swift', '.m', '.mm', '.h') and path != root / FACADE:
        source = path.read_text(errors='replace')
        require('getNRRDFile' not in source and 'legacyGetNRRDFile' not in source, '%s names the NRRD reader' % path.name)
category = (root / 'Horos/Sources/DicomFile+DCMTKFields.swift').read_text(errors='replace')
start = category.index('class func isNRRDFile(_ file: String!) -> Bool {')
require('pathExtension.lowercased() == "nrrd"' in category[start:category.index('\n    }\n', start)], 'NRRD is no longer recognised by its extension')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: an NRRD file is refused at the incoming door and kept aside; no reader pretends to read it, and the selector of the '
      'former SDK answers -1 alone')
