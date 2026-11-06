#!/usr/bin/env python3
"""Surgical procedure CSV/SR import is wired into the host without a sidecar table."""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
failures = []


def read(path):
    return path.read_bytes().decode('latin1')


def stripped(path):
    return re.sub(r'//[^\n]*', '', read(path))


source = read(root / 'Horos/Sources/SurgicalProcedureImport.swift')
for token in ('1.2.840.10008.5.1.4.1.1.88.11', 'Horos Surgical Procedure SR',
              'parseCSV', 'preview', 'encodeBasicTextSR', 'isSurgicalProcedureSR',
              'isStructuredReport', 'confirming'):
    if token not in source:
        failures.append('SurgicalProcedureImport.swift no longer names %r' % token)
if 'not a sidecar table' not in source:
    failures.append('the importer no longer says procedures are DICOM SR, not a sidecar table')
if 'name similarity is not a merge key' not in source:
    failures.append('identity matching no longer refuses name-similarity merges')

if 'timelineEventsFromSRPaths' not in source:
    failures.append('the surgical timeline is no longer indexed from SR files')
if 'numbersReaderScript' not in source:
    failures.append('the Numbers JXA reader is missing')
if 'table(fromNumbersJSON' not in source:
    failures.append('Numbers JSON can no longer become a surgical log table')
if 'displayModality' not in source or 'SURG' not in source:
    failures.append('the timeline no longer distinguishes SURG from image modalities')
if 'appleEventsDeniedErrorNumber' not in source or '-1743' not in source or '-10814' not in source:
    failures.append('Numbers/Apple Events diagnosis no longer reports host error numbers')
if 'detailsHTML' not in source:
    failures.append('timeline events no longer have a display HTML')

# The browser's surgical log actions are Swift (BrowserController+DatabaseMaintenance.swift);
# its outline's rows (BrowserController+OutlineDataSource.swift) and the refresh
# that merges the SURG rows into the list (StudyListContent.swift, which
# -outlineViewRefresh forwards to) are Swift too.
browser = stripped(root / 'Horos/Sources/BrowserController.swift') + stripped(root / 'Horos/Sources/BrowserController+DatabaseMaintenance.swift') \
    + stripped(root / 'Horos/Sources/StudyListContent.swift')
outline_rows = stripped(root / 'Horos/Sources/BrowserController+OutlineDataSource.swift')
if 'installSurgicalProcedureImportMenu' not in browser:
    failures.append('the File menu no longer installs Import Surgical Procedure Log')
if '@objc(importSurgicalProcedureLog:)' not in browser:
    failures.append('the database window no longer has importSurgicalProcedureLog:')
if 'SurgicalProcedureImportSession()' not in browser:
    failures.append('the action no longer uses the Swift import session')
if 'DatabaseIngest.process.index(paths, preset: .surgicalRecords, in: database)' not in browser:
    failures.append('committed SR files are no longer imported through the existing DICOM path')
surgical_import = browser[browser.index('func importSurgicalProcedureLog'):browser.index('func surgicalProcedureTimelineEvents')]
if 'SurgicalRecordFiling.file(written, replacing: session.formerReportPaths, newDataFilePath:' not in surgical_import \
        or 'database.uniquePathForNewDataFile(withExtension: "dcm")' not in surgical_import:
    failures.append('the records are no longer moved into the data folder before they are indexed')
if surgical_import.index('SurgicalRecordFiling.file(') > surgical_import.index('DatabaseIngest.process.index(paths'):
    failures.append('the records are indexed outside the filing that moves them first')
if 'retire: { removeSurgicalReports(atPaths: $0, in: database) })' not in surgical_import:
    failures.append('a report updated under another patient leaves its former file indexed')
retire = browser[browser.index('func removeSurgicalReports'):browser.index('func importSurgicalProcedureLog')]
if 'study.series?.count == 1' not in retire or 'context?.delete(study)' not in retire or 'context?.delete(series)' not in retire \
        or 'database.save()' not in retire:
    failures.append('the former report no longer leaves with the series and the study it leaves empty')
if 'saved: database.save()' not in surgical_import:
    failures.append('the filing is no longer told whether the rows reached the store')
if 'removeItem(atPath: directory)' not in surgical_import:
    failures.append('the folder the records are written in is no longer removed')
if 'NSTemporaryDirectory()' in surgical_import.replace('database.tempDirPath() ?? NSTemporaryDirectory()', ''):
    failures.append('the records are written outside the database folder again')
if 'alertMessage(notMoved:' not in surgical_import:
    failures.append('a failed filing is no longer told to the person')
if 'guard let database = self.database, database.isLocal(), !database.isReadOnly else { return }' not in surgical_import:
    failures.append('the import no longer refuses a remote or read-only database')
selection = (root / 'Horos/Sources/BrowserController+DatabaseDragExport+Selection.swift').read_text()
double_pressed = selection[selection.index('func databaseDoublePressed'):selection.index('objcSend(item, "numberOfImages")')]
if 'if item is SurgicalProcedureOutlineRow { return }' not in double_pressed:
    failures.append('a double click on a surgical record reaches the message it does not answer')
if 'object.responds(to: NSSelectorFromString(selector))' not in selection:
    failures.append('the walk of the study list sends messages the surgical records do not answer')
study_list = (root / 'Horos/Sources/StudyListContent.swift').read_text()
counted = study_list.index('Result = %@ studies')
if study_list.index('hidingReportsOf: timelineEvents') > study_list.index('for obj in listedStudies {\n            images +=') \
        or 'truncatingIfNeeded: listedStudies.count' not in study_list:
    failures.append('the study made for a surgical record is counted before it leaves the list')
if counted > study_list.index('SurgicalProcedureOutline.array(insertingEvents:'):
    failures.append('the surgical records are counted as studies in the status line')
if 'surgicalProcedureTimelineEvents' not in browser:
    failures.append('the database window no longer indexes the surgical timeline from SR files')
if 'item is SurgicalProcedureOutlineRow { return 0 }' not in outline_rows:
    failures.append('the database outline no longer inserts SURG timeline rows')
if 'SurgicalProcedureOutline.array(insertingEvents: timelineEvents, intoStudies: listedStudies)' not in browser:
    failures.append('the outline refresh no longer merges SURG rows into the study list')
if 'surgicalRow: object is SurgicalProcedureOutlineRow' not in outline_rows:
    failures.append('timeline rows are no longer distinct from DicomStudy in the outline')
if '@objc(showSurgicalProcedureTimeline:)' not in browser:
    failures.append('the database window no longer displays the surgical timeline')
if 'AEDeterminePermissionToAutomateTarget' not in browser or 'automationStatus: Int(numbersAutomationStatus())' not in browser:
    failures.append('Numbers/Apple Events are no longer probed with a host error status')

# AppController is Swift: the call is read in its Swift spelling, in the launch
# of ApplicationLifecycle.
app = stripped(source_path('ApplicationLifecycle'))
if 'BrowserController.installSurgicalProcedureImportMenu()' not in app:
    failures.append('startup no longer installs the surgical log menu')

# The class is Swift: the generated interface, which BrowserController.h
# imports, declares the selectors the Swift exports.
header = stripped(root / 'Horos/Sources/BrowserController.h')
if '#import "Horos-Swift.h"' not in header:
    failures.append('BrowserController.h no longer imports the generated interface')
if '@objc(installSurgicalProcedureImportMenu)' not in browser or '@objc(importSurgicalProcedureLog:)' not in browser:
    failures.append('the browser no longer exports the surgical import selectors')
if '@objc(surgicalProcedureTimelineEvents)' not in browser:
    failures.append('the browser no longer exports the surgical timeline')
if '@objc(showSurgicalProcedureTimeline:)' not in browser:
    failures.append('the browser no longer exports showSurgicalProcedureTimeline:')

project = read(root / 'Horos.xcodeproj/project.pbxproj')
if 'SurgicalProcedureImport.swift' not in project:
    failures.append('SurgicalProcedureImport.swift is not in the Xcode project')
if 'SurgicalProcedureOutline.swift' not in project:
    failures.append('SurgicalProcedureOutline.swift is not in the Xcode project')


for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('ok: surgical CSV/SR import is compiled, menu-wired and imports via DICOM SR files')
