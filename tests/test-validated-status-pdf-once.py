#!/usr/bin/env python3
"""A study's status made validated writes its report's DICOM PDF once, not each time it is set.

A 2D viewer writes the status chosen in its pop-up (-applyStatusValue) each time it
closes or changes series, also after the status was already applied, and choosing
the status shown sets it again. The setter of DicomStudy.stateText
(Horos/Sources/DicomStudy.swift), which every route reaches, makes the DICOM PDF of
the report only when the status changes to validated (4), as the rule
ValidatedReportPDF of IsiXDatabase says.

The real setter and the real rule are compiled as they are against doubles of what
the setter calls (the preferences, the database, the DICOM files' update, the PDF
and the annotations SR, counted) over a Core Data store in memory, and driven:

- 0 -> 4 makes one PDF; 4 again, twice (the viewer's apply, then its close),
  makes none;
- 4 -> 2 -> 4 makes one more; none (nil) -> 4 also makes one;
- a study first seen validated makes none when set validated again;
- without the preference, without DICOM files or without a report, none;
- with the status written in the DICOM files, they are updated only on a change,
  and the annotations SR is written only on a change, as before.

The viewer still applies its status through the setter, at its close and at a
change of series (ViewerSeriesLoad.finalize, StudyAnnotationEditor.applyStatus).
No app, no DICOM file and no network are needed.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import importlib.util
import shutil
import subprocess
import sys
import tempfile

SKIPPED = 2
ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / 'Horos/Sources'
spec = importlib.util.spec_from_file_location('swift_idiom_indicator', ROOT / 'tools/swift-idiom-indicator.py')
indicator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(indicator)


def member(source, signature):
    """A declaration of Swift, from `signature` through its closing brace."""
    at = source.index(signature)
    code = indicator.swift_code(source)
    depth, index = 0, code.index('{', at)
    while True:
        depth += {'{': 1, '}': -1}.get(code[index], 0)
        index += 1
        if depth == 0:
            return source[at:index]


failures = []
study = (SOURCES / 'DicomStudy.swift').read_text(encoding='utf-8')
state_text = member(study, '@objc public dynamic var stateText: NSNumber!')
if indicator.swift_code(state_text).count('self.archiveValidatedReportAsDICOMPDF()') != 1:
    failures.append('the status setter does not make the DICOM PDF through archiveValidatedReportAsDICOMPDF')
if 'ValidatedReportPDF.isDue(' not in indicator.swift_code(state_text):
    failures.append('the status setter does not ask ValidatedReportPDF whether the PDF is due')
length = member(study, 'fileprivate func dicomStudyLength(')
RULE = ROOT / 'Modules/IsiXDatabase/Sources/ValidatedReportPDF.swift'

editor = indicator.swift_code((SOURCES / 'StudyAnnotationEditor.swift').read_text(encoding='utf-8'))
apply_status = member(editor, 'func applyStatus()')
if '$0?.series?.study?.stateText = status' not in apply_status:
    failures.append("the viewer's status pop-up no longer writes the study's status through its setter")
load = indicator.swift_code((SOURCES / 'ViewerSeriesLoad.swift').read_text(encoding='utf-8'))
if 'viewer.applyStatusValue()' not in member(load, 'func finalize(viewerStays: Bool)'):
    failures.append('the viewer no longer applies its status when it closes or changes series')

if shutil.which('xcrun') is None:
    for failure in failures:
        print('FAIL:', failure)
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(1 if failures else SKIPPED)

DOUBLES = r'''
import CoreData

// What the setter reads, set by the driver.
nonisolated(unsafe) var studyHasDICOM = true
nonisolated(unsafe) var studyReport: String? = "REPORTS/report.rtf"
nonisolated(unsafe) var generatesPDF = true
nonisolated(unsafe) var savesStatusInFiles = false
// What it does, counted.
nonisolated(unsafe) var pdfs = 0
nonisolated(unsafe) var annotationSRs = 0
nonisolated(unsafe) var fileUpdates = 0

enum HorosObjCException {
    @discardableResult
    static func logged(_ function: String, stack: Bool = false, _ body: () -> Void) -> Bool { body(); return false }
}

struct PreferenceKey { let name: String }
enum DatabasePreferences {
    static let savedCommentsAndStatusInDICOMFiles = PreferenceKey(name: "savedCommentsAndStatusInDICOMFiles")
    static let generatesDICOMPDFWhenValidated = PreferenceKey(name: "generateDICOMPDFWhenValidated")
}
struct Preferences {
    subscript(key: PreferenceKey) -> Bool {
        key.name == "generateDICOMPDFWhenValidated" ? generatesPDF : savesStatusInFiles
    }
}
struct PreferencesSource {
    static let process = PreferencesSource()
    var preferences: Preferences { Preferences() }
}

// What a state does by itself when applied (StudyStates) is not this test's.
enum StudyStates {
    static func stateChanged(of study: DicomStudy, from previous: Int32, to state: Int32) {}
}

final class DicomDatabase {
    init?(for context: NSManagedObjectContext?) {}
    func isLocal() -> Bool { true }
}

final class ThreadsManager {
    static let shared = ThreadsManager()
    static func `default`() -> ThreadsManager { shared }
    func addThreadAndStart(_ thread: Thread) { fileUpdates += 1 }
}
extension Thread {
    @objc var status: String? { get { nil } set {} }
}

func dicomStudyModifyDictionary(_ files: Any?, _ field: String, _ value: Any?) -> NSDictionary {
    ["field": field, "value": value ?? NSNull(), "files": []]
}
func dicomStudySingularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String { "\(count) \(plural)" }

@objc(DicomStudy) final class DicomStudy: NSManagedObject {
    var hasDICOM: NSNumber! { NSNumber(value: studyHasDICOM) }
    var reportURL: String! { studyReport }
    func paths() -> NSSet! { NSSet() }
    @objc func dcmodifyThread(_ dict: NSDictionary!) {}
    func archiveValidatedReportAsDICOMPDF() { pdfs += 1 }
    func archiveAnnotationsAsDICOMSR() { annotationSRs += 1 }
'''

DRIVER = r'''
import CoreData

func expect(_ condition: Bool, _ what: String) {
    if !condition {
        print("FAIL: \(what)")
        exit(1)
    }
}

let attribute = NSAttributeDescription()
attribute.name = "stateText"
attribute.attributeType = .integer32AttributeType
attribute.isOptional = true
let entity = NSEntityDescription()
entity.name = "Study"
entity.managedObjectClassName = "DicomStudy"
entity.properties = [attribute]
let model = NSManagedObjectModel()
model.entities = [entity]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
_ = try! coordinator.addPersistentStore(ofType: NSInMemoryStoreType, configurationName: nil, at: nil, options: nil)
let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator

func newStudy(_ state: Int32?) -> DicomStudy {
    let study = DicomStudy(entity: entity, insertInto: context)
    study.setPrimitiveValue(state.map { NSNumber(value: $0) }, forKey: "stateText")
    return study
}
func set(_ study: DicomStudy, _ state: Int32?) {
    study.stateText = state.map { NSNumber(value: $0) }
}
func reset() {
    pdfs = 0; annotationSRs = 0; fileUpdates = 0
    studyHasDICOM = true; studyReport = "REPORTS/report.rtf"; generatesPDF = true; savesStatusInFiles = false
}

// validated from another status: one PDF; the same status again (the viewer's
// -applyStatusValue, then its close) makes none
reset()
let study = newStudy(0)
set(study, 4)
expect(pdfs == 1, "0 -> 4 made \(pdfs) PDFs, not one")
expect(study.stateText?.int32Value == 4, "the status is not validated")
set(study, 4)
set(study, 4)
expect(pdfs == 1, "4 -> 4 -> 4 made \(pdfs - 1) more PDFs")
expect(annotationSRs == 1, "the same status again wrote the annotations SR again (\(annotationSRs))")

// another status, then validated again: one more PDF
set(study, 2)
expect(pdfs == 1, "4 -> 2 made a PDF")
set(study, 4)
expect(pdfs == 2, "2 -> 4 made \(pdfs - 1) PDFs, not one")
set(study, 4)
expect(pdfs == 2, "4 -> 4 after 2 -> 4 made another PDF")

// no status (nil), then validated: one PDF; nil again: none
reset()
let fresh = newStudy(nil)
set(fresh, 4)
expect(pdfs == 1, "nil -> 4 made \(pdfs) PDFs, not one")
set(fresh, nil)
set(fresh, 4)
expect(pdfs == 2, "4 -> nil -> 4 made \(pdfs - 1) PDFs, not one")

// a study already validated when it is read: validated again makes none
reset()
let validated = newStudy(4)
set(validated, 4)
expect(pdfs == 0, "a study read validated made a PDF when set validated again")

// without the preference, without DICOM files or without a report: none
reset()
generatesPDF = false
set(newStudy(0), 4)
studyHasDICOM = false
generatesPDF = true
set(newStudy(0), 4)
studyHasDICOM = true
studyReport = ""
set(newStudy(0), 4)
studyReport = nil
set(newStudy(0), 4)
expect(pdfs == 0, "a PDF without the preference, DICOM files or a report (\(pdfs))")

// the status in the DICOM files: updated only on a change, as before
reset()
savesStatusInFiles = true
let saved = newStudy(0)
set(saved, 4)
set(saved, 4)
expect(fileUpdates == 1 && pdfs == 1, "files updated \(fileUpdates) times and \(pdfs) PDFs for 0 -> 4 -> 4")
set(saved, 3)
expect(fileUpdates == 2 && pdfs == 1, "4 -> 3: files updated \(fileUpdates) times, \(pdfs) PDFs")
print("PASS")
'''

with tempfile.TemporaryDirectory(prefix='isix-validated-status-pdf-') as directory:
    work = Path(directory)
    setter = state_text.replace('@objc public dynamic var stateText', '@objc dynamic var stateText')
    (work / 'study.swift').write_text(DOUBLES + '\n' + setter + '\n}\n\n' + length.replace('fileprivate ', '') + '\n')
    (work / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                            str(RULE), str(work / 'study.swift'), str(work / 'main.swift'), '-o', str(work / 'check')],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        failures.append('the setter does not compile with its doubles:\n' + built.stderr[-3000:])
    else:
        ran = subprocess.run([str(work / 'check')], capture_output=True, text=True, timeout=60)
        if ran.returncode or 'PASS' not in ran.stdout:
            failures.append((ran.stdout + ran.stderr).strip()[-1500:])

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: validated from another status makes one DICOM PDF; the same status again, as the viewer applies it at its close, '
      'makes none')
