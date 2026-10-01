#!/usr/bin/env python3
"""Database drags reach Finder through file promises, on the real routes (#605).

Source level, with `<git revision>` as an optional argument for the negative
control:

* the outline no longer advertises the legacy `NSFilesPromisePboardType` nor
  spins the main thread waiting for the export thread; it hands AppKit one
  promise per row through `pasteboardWriterForItem:`, skips a series whose
  study is selected, and switches to JPEG with Option;
* the promise captures object identifiers, the database and the export
  settings before the drop; its worker resolves the identifiers on an
  independent database, refuses an encrypted export without a password, writes
  to staging and commits only when something was produced;
* the export core honours the captured settings and stays silent (no modal
  alert) when asked, reporting the error through the parameters instead;
* album and Sources drops read every pasteboard item;
* the thumbnail matrix drags a DICOM promise and, with Option, a JPEG of the
  captured frame or a JPEG/PDF folder; the Carbon promise fulfilment is gone.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]


def read(path):
    if len(sys.argv) > 1:
        # A revision older than the file has none of its code.
        result = subprocess.run(['git', '-C', str(root), 'show', sys.argv[1] + ':' + path], capture_output=True)
        return result.stdout.decode('latin1') if result.returncode == 0 else ''
    return (root / path).read_bytes().decode('utf-8' if path.endswith('.swift') else 'latin1')


browser = read('Horos/Sources/BrowserController.m')
header = read('Horos/Sources/BrowserController.h')
# BrowserController (Sources) is Swift since #722.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_path  # noqa: E402
sources = read(str(source_path('BrowserController+Sources').relative_to(root)))
# The database drag export block (#605) is Swift since #831.
drag = read('Horos/Sources/BrowserController+DatabaseDragExport.swift')
drag_selection = read('Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift')
drag_header = read('Horos/Sources/BrowserController+DatabaseDragExport.h')
albums = read('Horos/Sources/BrowserController+AlbumsTableView.swift')
# BrowserMatrix is Swift since #828.
matrix = read(str(source_path('BrowserMatrix').relative_to(root)))
failures = []


def method(source, signature, terminator='\n}\n'):
    start = source.find(signature)
    if start < 0:
        return ''
    return source[start:source.find(terminator, start) + len(terminator)]


# --- outline drag source ------------------------------------------------------
outline_sources = browser + drag + drag_selection
if 'namesOfPromisedFiles' in outline_sources:
    failures.append('the outline still fulfils the legacy file promise')
if 'NSFilesPromisePboardType' in outline_sources or 'filesPromise' in drag + drag_selection:
    failures.append('the outline still advertises NSFilesPromisePboardType')
if 'fourSeconds' in outline_sources:
    failures.append('a drop still waits up to four seconds on the main thread')
SWIFT_END = '\n    }\n'
writer = method(drag, '@objc(outlineView:pasteboardWriterForItem:)\n', SWIFT_END)
if 'func outlineView(_ outlineView: NSOutlineView!, pasteboardWriterForItem item: Any!)' not in writer:
    failures.append('the outline has no pasteboardWriterForItem:')
else:
    if 'isRowSelected(parentRow)' not in writer:
        failures.append('a series under a selected study is not skipped')
    if 'NSEvent.ModifierFlags.option' not in writer:
        failures.append('Option does not switch the row drag to JPEG')

promise = method(drag, '@objc(filePromiseForDatabaseObjects:asJPEG:)\n', SWIFT_END)
for key in ('"rootObjectIDs":', '"database":', '"folderTreeTag":', '"compressionTag":', '"addDICOMDIR":', '"encrypt":', '"password":'):
    if key not in promise:
        failures.append('the promise snapshot lacks %s' % key)
if 'BatchExportPlan.exportName(itemNames:' not in promise:
    failures.append('the promised name is not built by the plan')
if 'promise.extraTypes = BrowserController.databaseObjectXIDsPasteboardTypes()' not in promise:
    failures.append('a DICOM promise does not carry the object identifiers for internal drops')
if 'PromiseCompletionGuard(completion:' not in promise or 'watch(thread: thread)' not in promise:
    failures.append('the promise writer has no completion guard for a thread that never starts')
if 'writeDatabaseFilePromise(_:)' not in promise or 'addThreadAndStart' not in promise:
    failures.append('the promise writer does not run on an activity thread')

worker = method(drag, '@objc(writeDatabaseFilePromise:)\n', SWIFT_END)
# userCancelledError() is the file's NSCocoaErrorDomain/NSUserCancelledError error.
cancelled = method(drag, 'fileprivate func userCancelledError() -> NSError {', '\n}\n')
if 'NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)' not in cancelled:
    worker = worker.replace('userCancelledError()', '')
for needed in ('privateQueueIndependentDatabase()', 'objects(withIDs:', 'ExportStaging.stagingDirectory(for:', 'fire(error:', 'ExportStaging.commit(staging:',
               'ExportStaging.discard(staging:', 'ExportStaging.stagingHasContent(', 'parameters?["quietErrors"]', 'parameters?["exportError"]', 'userCancelledError()',
               'isDeleted', 'set an encryption password'):
    if needed not in worker:
        failures.append('the promise worker lacks %s' % needed)
if worker.find('ExportStaging.commit(staging:') < worker.find('self.writeReportFileExports('):
    failures.append('reports must be written before the staging is committed')

# --- export core honours the snapshot and can be quiet -----------------------
core = method(browser, '- (NSArray*) exportDICOMFileInt: (NSMutableDictionary*) parameters\n', '\n#pragma mark')
if not core:
    core = browser[browser.find('- (NSArray*) exportDICOMFileInt: (NSMutableDictionary*) parameters\n'):]
    core = core[:core.find('\n- (', 100)]
for needed in ('[parameters objectForKey:@"addDICOMDIR"]', '[parameters objectForKey:@"encrypt"]', '[parameters objectForKey:@"password"]',
               '[parameters objectForKey:@"folderTreeTag"]', '[parameters objectForKey:@"compressionTag"]', 'quietErrors'):
    if needed not in core:
        failures.append('the export core ignores %s' % needed)
if core.count('if( !quietErrors)') < 2:
    failures.append('the export core still shows a modal alert on a quiet export')
if 'forKey: @"exportError"' not in core:
    failures.append('the export core does not report its error through the parameters')

# --- drops read every item ----------------------------------------------------
if 'BrowserController.databaseObjectXIDs(on: pb)' not in albums:
    failures.append('the album drop reads the first pasteboard item only')
if 'BrowserController.databaseObjectXIDs(on: pb)' not in sources:
    failures.append('the Sources drop reads the first pasteboard item only')
if 'PasteboardObjectIdentifiers.identifiers(on: pasteboard, types: BrowserController.databaseObjectXIDsPasteboardTypes()' not in drag:
    failures.append('the aggregation is not delegated to HorosPasteboardObjectIdentifiers')

# --- thumbnail matrix -----------------------------------------------------------
if 'kPasteboardTypeFileURLPromise' in matrix or 'PasteboardCopyPasteLocation' in matrix:
    failures.append('the matrix still fulfils the Carbon promise')
if 'startDragOriginalFrame' in matrix:
    failures.append('the Option+Shift original-frame drag is still there')
if 'filePromise(forDatabaseObjects: objects' not in matrix:
    failures.append('the matrix drag is not a database promise')
jpeg = method(matrix, 'func startDragJPEG(_ event: NSEvent)', '\n    }\n')
if 'filePromise(forJPEGData: jpeg, name: name)' not in jpeg or 'asJPEG: true' not in jpeg:
    failures.append('Option-drag of a thumbnail does not promise a JPEG or a JPEG/PDF folder')
if 'previewPix(Int32(truncatingIfNeeded: selectedButtonCellTag))' not in jpeg:
    failures.append('the image thumbnail JPEG is not the displayed frame captured at drag start')
mouse = method(matrix, 'public override func mouseDown(with event: NSEvent)', '\n    }\n')
if 'modifierFlags.contains(.option)' not in mouse or 'self.startDragJPEG(event)' not in mouse or 'dx * dx + dy * dy < 16.0' not in mouse:
    failures.append('mouseDown does not route Option to JPEG after a four-point drag')
# The one-second click-hold and its periodic pump are A297 behaviour the new
# drag routing must not displace; test-event-capture-pauses.py owns them too.
if 'NSEvent.startPeriodicEvents(afterDelay: 0, withPeriod: 0.001)' not in mouse or 'start.timeIntervalSinceNow >= -1' not in mouse:
    failures.append('mouseDown lost the one-second click-hold or its periodic pump')
if mouse.count('NSEvent.stopPeriodicEvents()') < 4:
    failures.append('every exit from mouseDown must stop the periodic pump')

# Objective-C sees the Swift methods through the block header BrowserController.h imports.
if '#import "BrowserController+DatabaseDragExport.h"' not in header:
    failures.append('BrowserController.h does not import BrowserController+DatabaseDragExport.h')
for declaration, selector in (('- (id<NSPasteboardWriting>) filePromiseForDatabaseObjects:(NSArray*) items asJPEG:(BOOL) jpeg;', 'filePromiseForDatabaseObjects:asJPEG:'),
                              ('+ (NSArray*) databaseObjectXIDsOnPasteboard:(NSPasteboard*) pasteboard;', 'databaseObjectXIDsOnPasteboard:'),
                              ('+ (BOOL) isReportSeriesForFileExport:(DicomSeries*) series;', 'isReportSeriesForFileExport:')):
    if declaration not in drag_header:
        failures.append('BrowserController+DatabaseDragExport.h lacks %r' % declaration)
    if '@objc(%s)\n' % selector not in drag:
        failures.append('the Swift extension does not export %s' % selector)

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: database drags are file promises with captured selection, staging and quiet errors')
