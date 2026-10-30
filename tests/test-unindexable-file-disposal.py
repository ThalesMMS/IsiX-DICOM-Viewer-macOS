#!/usr/bin/env python3
"""A file that cannot be indexed does not stay in the database folder.

The incoming import moves a file into the database folder first and indexes it
afterwards. When the indexing refuses it, it has to leave: deleted, or kept in
NOT READABLE, according to `DELETEFILELISTENER`. That was done only for a file
that opened and produced no dictionary:

    if (curFile)
    {
        curDict = [curFile dicomElements];
        ...
        else  // curDict == nil
        {
            if (dataDirPath && [newFile hasPrefix: dataDirPath]) { delete or move }
        }
    }

A file `-[DicomFile init:]` could not construct at all - a truncated one, say -
fell outside that `if (curFile)` and was left where it was. Measured on an import
of 1204 files with one truncated instance among them:

    (importFilesFromIncomingDir): 1201 file(s) taken from the incoming folder,
                                  1200 indexed, in 1.4 s
      DATABASE.noindex   1201 file(s)
      NOT READABLE       0 file(s)

1201 files for 1200 images, and nothing said. Both failures share one disposal
now, and it says which of the two happened:

    ---- import: 739.dcm could not be indexed; deleted (DELETEFILELISTENER)
      DATABASE.noindex   1200 file(s)

    ---- import: 739.dcm could not be indexed; kept in NOT READABLE
      DATABASE.noindex   1200 file(s)      NOT READABLE  3 file(s)
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []
# DicomDatabase is Swift: -addFilesAtPaths:... and the file reader it calls
# are DicomDatabase+Import.swift, and the disposal they share is a method of
# DicomDatabase+ImportCleanup.swift.
database = (root / 'Horos/Sources/DicomDatabase+Import.swift').read_text()
cleanup = (root / 'Horos/Sources/DicomDatabase+ImportCleanup.swift').read_text()

start = database.find('final func addFiles(atPaths paths: NSArray?, postNotifications: Bool, '
                      'dicomOnly: Bool, rereadExistingItems: Bool, generatedByOsiriX: Bool,')
if start < 0:
    failures.append('-addFilesAtPaths:... is gone')
else:
    region = re.sub(r'//[^\n]*', '', database[start:database.find('// MARK: - Add files described in dictionaries', start + 10)])
    call = ('disposeOfUnreadable(newFile, dataDirPath: dataDirPath, errorsDirPath: errorsDirPath, '
            'deleteFileListener: deleteFileListener)')

    if 'disposeOfUnreadable' not in region or 'final func disposeOfUnreadable(' not in cleanup:
        failures.append('there is no single place that gets an unindexable file out of the '
                        'database folder')
    else:
        if region.count(call) != 2:
            failures.append('only one of the two ways indexing can refuse a file disposes of it: '
                            'a file that could not be opened at all, and one that opened and '
                            'produced no dictionary (%d of 2)'
                            % region.count(call))
        at = cleanup.find('final func disposeOfUnreadable(')
        body = cleanup[at:cleanup.find('\n    }\n', at)]
        if 'unreadable.hasPrefix(dataDirPath) else { return }' not in body:
            failures.append('a file outside the database folder would be deleted too')
        # The preference is read once per import and handed to the disposal,
        # which deletes or keeps as it says.
        if ('let deleteFileListener = UserDefaults.standard.bool(forKey: "DELETEFILELISTENER")' not in region
                or 'if deleteFileListener {' not in body):
            failures.append('the preference that decides between deleting and keeping is not read')
        if 'availablePath(inDirectory: errorsDirPath, name: name)' not in body:
            failures.append('a second unreadable file of the same name is moved onto the first, '
                            'and the failed move then deletes it')
        for outcome in ('deleted (DELETEFILELISTENER)', 'kept in', 'could not be deleted',
                        'could not be kept'):
            if outcome not in body:
                failures.append('the disposal does not say what happened when it %r' % outcome)

    if 'Unreadable file' in region:
        failures.append('the old branch is still here beside the new one')

if 'final func availablePath(inDirectory directory: String?, name: String) -> String? {' not in cleanup:
    failures.append('the helper that finds a free name is gone')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: whichever way indexing refuses a file, it leaves the database folder and says how')
