#!/usr/bin/env python3
"""Database drags reach Finder through file promises, on the real routes.

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


header = read('Horos/Sources/BrowserController.h')
# BrowserController and its extensions are Swift.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_path, class_text  # noqa: E402
browser = class_text('BrowserController') if len(sys.argv) == 1 else read('Horos/Sources/BrowserController.m')
sources = read(str(source_path('BrowserController+Sources').relative_to(root)))
# The database drag export block is Swift.
drag = read('Horos/Sources/BrowserController+DatabaseDragExport.swift')
drag_selection = read('Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift')
albums = read('Horos/Sources/BrowserController+AlbumsTableView.swift')
# BrowserMatrix is Swift.
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
# The export core is Swift (BrowserController+DICOMExport.swift).
export = read('Horos/Sources/BrowserController+DICOMExport.swift')
core = export[export.find('    @objc(exportDICOMFileInt:)\n'):export.find('    @objc(exportDICOMFile:)\n')] if export else ''
for needed in ('parameters["addDICOMDIR"]', 'parameters["encrypt"]', 'parameters["password"]',
               'key: "folderTreeTag"', 'key: "compressionTag"', 'parameters["quietErrors"]'):
    if needed not in core:
        failures.append('the export core ignores %s' % needed)
if core.count('if !quietErrors {') < 2 or 'showGUI: !quietErrors' not in core:
    failures.append('the export core still shows a modal alert on a quiet export')
if 'parameters["exportError"] = exportError' not in core or 'parameters["exportError"] = zipError' not in core:
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

# Objective-C sees the Swift methods through the generated interface BrowserController.h imports.
if '#import "Horos-Swift.h"' not in header:
    failures.append('BrowserController.h does not import the generated interface')
for selector in ('filePromiseForDatabaseObjects:asJPEG:', 'databaseObjectXIDsOnPasteboard:', 'isReportSeriesForFileExport:'):
    if '@objc(%s)\n' % selector not in drag:
        failures.append('the Swift extension does not export %s' % selector)

if failures:
    for failure in failures:
        print('FAIL:', failure)
    raise SystemExit(1)
print('ok: database drags are file promises with captured selection, staging and quiet errors')
