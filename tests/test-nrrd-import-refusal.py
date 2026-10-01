#!/usr/bin/env python3
"""An NRRD file left for import is kept aside, not consumed and deleted.

The incoming folder let `.nrrd` through its door because of its extension, and
no reader could make a record or pixels from it: the one that tried never
reported success, with fixed 512x512 dimensions. The file was moved into the
database, found unreadable and deleted. NRRD is now refused at the door and
kept in the folder of unreadable files whatever DELETEFILELISTENER says, and
the reader that could not succeed is gone.
"""
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def require(condition, message):
    if not condition:
        failures.append(message)


database = (root / 'Horos/Sources/DicomDatabase.mm').read_text(errors='replace')
refusal = database.find('if (isDicomFile == NO && [DicomFile isNRRDFile: srcPath])')
door = database.find('if (isDicomFile == YES ||\n                            (([DicomFile isFVTiffFile:srcPath] ||')
require(refusal != -1 and door != -1 and refusal < door, 'NRRD is not refused before the door of the incoming folder')
if refusal != -1 and door != -1:
    branch = database[refusal:database.index('continue;', refusal)]
    require('addImportRefusalSummary:' in branch, 'the refusal of an NRRD file is not reported')
    require('availablePathInDirectory( self.errorsDirPath, lastPathComponent)' in branch and 'moveItemAtPath: srcPath toPath: kept' in branch,
            'a refused NRRD file is not kept in the folder of unreadable files')
    require('removeItemAtPath' not in branch and 'DELETEFILELISTENER' not in branch.split('NSLog')[0].replace('whatever DELETEFILELISTENER says', ''),
            'a refused NRRD file can be deleted')
    accepted = database[door:database.index('fileExistsAtPath:dstPath] == NO))', door)]
    require('isNRRDFile' not in accepted, 'the incoming folder still lets NRRD in, to be found unreadable and deleted')
    for reader in ('isFVTiffFile', 'isTiffFile', 'isNIfTIFile', 'isImageFile'):
        require(reader in accepted, 'the incoming folder lost %s, a format that is read' % reader)

# Nothing pretends to read the format.
for name in ('Horos/Sources/DicomFile.mm', 'Horos/Sources/DicomFileDCMTKCategory.mm', 'Horos/Sources/DicomFileDCMTKCategory.h'):
    text = (root / name).read_text(errors='replace')
    require('getNRRDFile' not in text and 'nrrdLoad' not in text, '%s still carries the NRRD reader that never reported success' % name)
category = (root / 'Horos/Sources/DicomFileDCMTKCategory.mm').read_text(errors='replace')
start = category.index('+ (BOOL) isNRRDFile:(NSString *) file')
require('isEqualToString:@"nrrd"' in category[start:category.index('\n}\n', start)], 'NRRD is no longer recognised by its extension')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: an NRRD file is refused at the incoming door and kept aside; no reader pretends to read it')
