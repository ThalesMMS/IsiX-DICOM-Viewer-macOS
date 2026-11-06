#!/usr/bin/env python3
"""The step an import stops on says what went wrong with it.

The report is of an import that parks on "Synchronizing database..." and never
moves. That status is set immediately before the only step that could not say
anything:

    thread.status = NSLocalizedString(@"Synchronizing database...", nil);
    thread.progress = -1;

    if( protectionAgainstReentry == NO)
    {
        protectionAgainstReentry = YES;
        [self.managedObjectContext save:NULL];
        protectionAgainstReentry = NO;
    }

Two things follow from that shape. The error is thrown away, so a save that fails
leaves the panel on an indeterminate bar with nothing said. And a save that
*raises* never clears the flag - the enclosing @catch swallows the exception -
so every later import in the session skips its save in silence, with the images
in the context and never written.

Measured with the store file made unwritable, importing a disc of 15 instances
into a database that already held 10:

    (addFilesDescribedInDictionaries): the database could not be saved: The file
    couldn't be saved because you don't have permission; 15 file(s) are in the
    database folder and not in the index, and rebuilding the database index will
    bring them in
      studies 1  series 2  images 10
      files in DATABASE.noindex: 25

The thread ends (`volumeScanThread: end`), so the panel goes away rather than
parking; nothing was deleted; and after a restart the database still holds its 10
and the 25 files are still there.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []
# DicomDatabase is Swift (DicomDatabase.swift and its DicomDatabase+*.swift
# extensions); the assertions read its Swift spelling.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources as dicom_database_sources  # noqa: E402
database = dicom_database_sources.class_text('DicomDatabase')

at = database.find('NSLocalizedString("Synchronizing database..."')
if at < 0:
    failures.append('the step that synchronises the database is gone')
else:
    region = re.sub(r'//[^\n]*', '', database[at:at + 3200])
    if 'save:NULL' in region or 'save: NULL' in region:
        failures.append('the save still throws its error away, so the step that an import parks '
                        'on cannot say what went wrong')
    if 'saveError' not in region:
        failures.append('the save does not ask for an error')
    if 'could not be saved' not in region:
        failures.append('a failed save says nothing')
    if 'thread.status' not in region[region.find('could not be saved'):]:
        failures.append('the failure is logged but not shown on the progress panel, which is '
                        'where the user is looking')
    if 'rebuilding the database index' not in region:
        failures.append('a failed save does not say what state it leaves the copied files in')

    if 'protectionAgainstReentry' in database:
        failures.append('the process-wide flag is back: its second import skips its save, and a '
                        'context writes only its own rows')
    if 'try context?.save()' not in region:
        failures.append('the import no longer saves')

    # The gate is left whatever the save did: the method runs in an @try
    # (HorosObjCException.caught) inside the gate, so that an exception reaches
    # no `defer` it would pass over, and it is logged once the gate is free.
    add = database[database.find('raised = database.databaseWriterGate.withExclusiveWrite {'):]
    gate = add.find('database.databaseWriterGate.withExclusiveWrite {')
    attempt = add.find('HorosObjCException.caught {')
    index = add.find('self.indexDescribedFiles(')
    logged = add.find('if let raised { DicomDatabaseObjC.log(raised')
    if not 0 <= gate < attempt < index < logged:
        failures.append('an exception inside the writer gate is not caught before the gate is '
                        'left, and it would stay held for the session')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the synchronising step names its error, keeps the copied files, and cannot leave the '
      'writer gate held')
