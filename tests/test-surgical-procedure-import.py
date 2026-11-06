#!/usr/bin/env python3
"""CSV/SR surgical-log contract: preview, identity, idempotency, Basic Text SR."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
import isix_modules  # noqa: E402
source = root / 'Horos/Sources/SurgicalProcedureImport.swift'
if not source.is_file():
    raise SystemExit('FAIL: Horos/Sources/SurgicalProcedureImport.swift is missing')

code = r'''
import Foundation

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected { fail("\(message): \(actual) != \(expected)") }
}

do {
    _ = try SurgicalProcedureImport.parseCSV("Foo,Bar\n1,2")
    fail("missing columns must throw")
} catch let error as SurgicalProcedureImportError {
    guard case .missingColumns(let columns) = error else { fail("wrong error \(error)") }
    if !columns.contains("Date") || !columns.contains("Operation") {
        fail("missing-column error must name Date and Operation, got \(columns)")
    }
} catch {
    fail("missing columns threw \(error)")
}

let quoted = [
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants",
    "21 Mar 2024,\"Test, Patient\",001234,Endoscopic surgery,\"line1\nline2\",\"Result: \"\"benign\"\"\",,Assistant",
].joined(separator: "\n")
let table = try SurgicalProcedureImport.parseCSV(quoted)
expect(table.rows.count, 1, "one data row")
expect(table.rows[0].name, "Test, Patient", "quoted comma in name")
expect(table.rows[0].patientID, "001234", "quoted id")
expect(table.rows[0].operation, "Endoscopic surgery", "operation")
expect(table.rows[0].diagnosis, "line1\nline2", "multiline diagnosis")
expect(table.rows[0].results, "Result: \"benign\"", "escaped quotes")
expect(table.rows[0].assistants, "Assistant", "assistants")
if table.rows[0].procedureDate == nil { fail("21 Mar 2024 must parse") }

let patients = [
    SurgicalProcedurePatient(name: "Test, Patient", patientID: "001234",
        patientUID: "TEST-001234-19700101", birthDate: SurgicalProcedureImport.date(from: "1970-01-01"),
        studyInstanceUID: "1.2.3.study-a"),
    SurgicalProcedurePatient(name: "Other Person", patientID: "999",
        patientUID: "OTHER-999-", birthDate: nil, studyInstanceUID: "1.2.3.study-b"),
]

var store: [SurgicalProcedureRecord] = []
let preview = SurgicalProcedureImport.preview(table: table, patients: patients, existing: store)
expect(preview.rows.count, 1, "preview one row")
expect(preview.rows[0].action, .add, "new row is add")
expect(store.isEmpty, true, "preview must not write")
expect(preview.changes.count, 1, "add is a change")
expect(store.isEmpty, true, "cancelled preview must not commit")

let first = try SurgicalProcedureImport.commit(preview, into: &store, now: Date(timeIntervalSince1970: 1_700_000_000))
expect(first.inserted, 1, "first commit inserts")
expect(store.count, 1, "store gained a record")
let originalEventID = store[0].eventID
expect(store[0].operation, "Endoscopic surgery", "operation stored")
expect(store[0].anchorStudyInstanceUID, "1.2.3.study-a", "matched study")

let again = SurgicalProcedureImport.preview(table: table, patients: patients, existing: store)
expect(again.rows[0].action, .unchanged, "identical reimport is unchanged")
expect(again.changes.isEmpty, true, "unchanged is not a change")
_ = try SurgicalProcedureImport.commit(again, into: &store, now: Date(timeIntervalSince1970: 1_700_000_100))
expect(store.count, 1, "reimport must not duplicate the SR")
expect(store[0].eventID, originalEventID, "event identity is stable")

let updatedCSV = "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "2024-03-21,\"Test, Patient\",001234,Endoscopic surgery,Updated diagnosis,Result: \"\"benign\"\",,Assistant\n"
let updatedTable = try SurgicalProcedureImport.parseCSV(updatedCSV)
let updatePreview = SurgicalProcedureImport.preview(table: updatedTable, patients: patients, existing: store)
expect(updatePreview.rows[0].action, .update, "material field change is update")
let updated = try SurgicalProcedureImport.commit(updatePreview, into: &store, now: Date(timeIntervalSince1970: 1_700_000_200))
expect(updated.updated, 1, "update count")
expect(store.count, 1, "update does not add a second SR")
expect(store[0].eventID, originalEventID, "update keeps SOP identity")
expect(store[0].diagnosis, "Updated diagnosis", "diagnosis updated")

let movedCSV = "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "2024-03-21,\"Test, Patient\",001234,Endoscopic surgery,Updated diagnosis,Result: \"\"benign\"\",,Assistant\n"
let moved = try SurgicalProcedureImport.parseCSV(movedCSV, sourcePath: "/tmp/other.csv")
let provenance = SurgicalProcedureImport.preview(table: moved, patients: patients, existing: store)
expect(provenance.rows[0].action, .unchanged, "source path is provenance, not a material field")

let similar = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n2024-03-21,Test Patient,555555,Craniotomy,,,,\n")
let similarPreview = SurgicalProcedureImport.preview(table: similar, patients: patients, existing: [])
expect(similarPreview.rows[0].action, .skipped, "different ID is not a name-similarity merge")
if !similarPreview.rows[0].details.lowercased().contains("id") {
    fail("skip reason must mention the identifier, got \(similarPreview.rows[0].details)")
}

let twins = [
    SurgicalProcedurePatient(name: "Alpha One", patientID: "SHARED",
        patientUID: "A-SHARED-19800101", birthDate: SurgicalProcedureImport.date(from: "1980-01-01"),
        studyInstanceUID: "1.2.3.a"),
    SurgicalProcedurePatient(name: "Beta Two", patientID: "SHARED",
        patientUID: "B-SHARED-19900101", birthDate: SurgicalProcedureImport.date(from: "1990-01-01"),
        studyInstanceUID: "1.2.3.b"),
]
let ambiguous = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n2024-01-01,Someone,SHARED,Bypass,,,,\n")
let review = SurgicalProcedureImport.preview(table: ambiguous, patients: twins, existing: [])
expect(review.rows[0].action, .review, "ambiguous identity needs confirmation")
expect(review.changes.isEmpty, true, "review is not committed until confirmed")
let confirmed = review.confirming(row: review.rows[0].row, patientUID: "A-SHARED-19800101")
expect(confirmed.rows[0].action, .add, "confirmed ambiguous row becomes add")
expect(confirmed.changes.count, 1, "confirmed review is a change")

let historical = [
    SurgicalProcedurePatient(name: "Ruth Anderson", patientID: "NEW-ID",
        patientUID: "ANDERSON-1008254730-19500101",
        birthDate: SurgicalProcedureImport.date(from: "1950-01-01"),
        studyInstanceUID: "1.2.3.hist"),
]
let histCSV = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n2007-02-14,\"Anderson, Ruth\",1008254730,RF Crani Planum Meningioma,,,,\n")
let histPreview = SurgicalProcedureImport.preview(table: histCSV, patients: historical, existing: [])
expect(histPreview.rows[0].action, .add, "historical ID inside patientUID must match")

let invalid = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "not-a-date,Test Patient,001234,Endoscopic surgery,,,,\n"
    + ",Test Patient,001234,,,,,\n"
    + "2024-03-21,,001234,Endoscopic surgery,,,,\n")
let skipped = SurgicalProcedureImport.preview(table: invalid, patients: patients, existing: [])
expect(skipped.rows.allSatisfy { $0.action == .skipped }, true, "invalid rows are skipped")
expect(skipped.changes.isEmpty, true, "skipped rows are not changes")

let numbers = SurgicalProcedureImport.diagnoseSource(
    at: URL(fileURLWithPath: "/tmp/log.numbers"),
    numbersAvailable: false,
    appleEventsAuthorized: false)
expect(numbers.kind, .numbersMissing, "Numbers absent")
expect(numbers.errorNumber, SurgicalProcedureImport.numbersMissingErrorNumber, "Numbers-missing uses kLSApplicationNotFoundErr")
if !numbers.message.lowercased().contains("csv") { fail("Numbers-missing must offer CSV: \(numbers.message)") }
if !numbers.message.contains("-10814") { fail("Numbers-missing must include error -10814: \(numbers.message)") }

let denied = SurgicalProcedureImport.diagnoseSource(
    at: URL(fileURLWithPath: "/tmp/log.numbers"),
    numbersAvailable: true,
    appleEventsAuthorized: false)
expect(denied.kind, .appleEventsDenied, "Apple Events denied")
expect(denied.errorNumber, -1743, "denied uses errAEEventNotPermitted")
if !denied.message.lowercased().contains("csv") { fail("denied automation must offer CSV: \(denied.message)") }
if !denied.message.contains("-1743") { fail("denied automation must include error -1743: \(denied.message)") }
if !denied.message.contains("Automation") { fail("denied automation must name Automation: \(denied.message)") }

let consent = SurgicalProcedureImport.diagnoseSource(
    at: URL(fileURLWithPath: "/tmp/log.numbers"),
    numbersAvailable: true,
    automationStatus: -1744)
expect(consent.kind, .appleEventsDenied, "consent-required is a denial")
expect(consent.errorNumber, -1744, "consent uses errAEEventWouldRequireUserConsent")
if !consent.message.contains("-1744") { fail("consent-required must include error -1744: \(consent.message)") }

do {
    _ = try SurgicalProcedureImport.parseCSV("")
    fail("empty file must throw")
} catch let error as SurgicalProcedureImportError {
    guard case .invalidFile = error else { fail("empty file should be invalid, got \(error)") }
} catch {
    fail("empty file threw \(error)")
}

let srData = try SurgicalProcedureImport.encodeBasicTextSR(store[0])
if srData.count < 256 { fail("SR file is too small") }
let preamble = String(data: srData.subdata(in: 128..<132), encoding: .ascii)
expect(preamble, "DICM", "DICOM preamble")
expect(SurgicalProcedureImport.isSurgicalProcedureSR(srData), true, "surgical SR discriminator")
expect(SurgicalProcedureImport.isStructuredReport(sopClassUID: SurgicalProcedureImport.basicTextSRSOPClassUID), true, "Basic Text SR is an SR")
expect(SurgicalProcedureImport.isStructuredReport(sopClassUID: "1.2.840.10008.5.1.4.1.1.88.33"), true, "third-party Comprehensive SR stays an SR")
expect(SurgicalProcedureImport.isSurgicalProcedureSR(sopClassUID: SurgicalProcedureImport.basicTextSRSOPClassUID,
    seriesDescription: "Some vendor report"), false, "third-party Basic Text SR is not a surgical log")
expect(SurgicalProcedureImport.isSurgicalProcedureSR(sopClassUID: SurgicalProcedureImport.basicTextSRSOPClassUID,
    seriesDescription: SurgicalProcedureImport.surgicalSeriesDescription), true, "our series description")

let decoded = try SurgicalProcedureImport.decodeBasicTextSR(srData)
expect(decoded.eventID, store[0].eventID, "SR round-trip eventID")
expect(decoded.operation, store[0].operation, "SR round-trip operation")
expect(decoded.diagnosis, store[0].diagnosis, "SR round-trip diagnosis")
expect(decoded.matchedPatientID, store[0].matchedPatientID, "SR round-trip patient ID")
expect(decoded.sopClassUID, SurgicalProcedureImport.basicTextSRSOPClassUID, "Basic Text SR SOP Class")
expect(decoded.modality, "SR", "DICOM modality remains SR")
if decoded.sopInstanceUID.isEmpty { fail("SOP Instance UID missing") }

let foreign = try SurgicalProcedureImport.encodeGenericStructuredReport(
    sopClassUID: "1.2.840.10008.5.1.4.1.1.88.33",
    seriesDescription: "Vendor Comprehensive SR",
    text: "Unrelated findings")
expect(SurgicalProcedureImport.isStructuredReport(sopClassUID: "1.2.840.10008.5.1.4.1.1.88.33"), true, "foreign SR class")
expect(SurgicalProcedureImport.isSurgicalProcedureSR(foreign), false, "foreign SR must stay visible as a normal SR, not a surgical log")

let secondCSV = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "2023-01-02,\"Test, Patient\",001234,Earlier shunt,,,,\n")
let secondPreview = SurgicalProcedureImport.preview(table: secondCSV, patients: patients, existing: [])
var secondStore: [SurgicalProcedureRecord] = []
_ = try SurgicalProcedureImport.commit(secondPreview, into: &secondStore, now: Date(timeIntervalSince1970: 1_600_000_000))
let mixed = SurgicalProcedureImport.timeline(surgical: store + secondStore, otherSR: [foreign])
expect(mixed.count, 2, "timeline indexes surgical events only")
expect(mixed[0].displayModality, "SURG", "timeline does not present surgery as an image")
expect(mixed[0].dicomModality, "SR", "the backing object remains SR")
expect(mixed[0].operation, "Endoscopic surgery", "newest procedure first")
expect(mixed[1].operation, "Earlier shunt", "older procedure follows")
expect(mixed.contains(where: { $0.operation.contains("Unrelated") }), false, "third-party SR stays off the surgical timeline")
expect(mixed[0].displayValue(forColumn: "modality"), "SURG", "display column is SURG")
expect(mixed[0].displayValue(forColumn: "numberOfImages"), "0", "timeline is not an image series")
if mixed[0].displayTitle.contains("Endoscopic surgery") == false {
    fail("display title must show the operation")
}
if mixed[0].detailsHTML().contains("Endoscopic surgery") == false {
    fail("details HTML must show the operation")
}

// A reimport: the record found again in the file the session wrote, the way the
// browser hands it over, is unchanged, and nothing is written.
let sessionFolder = NSTemporaryDirectory() + "surgical-session-" + UUID().uuidString
try FileManager.default.createDirectory(atPath: sessionFolder, withIntermediateDirectories: true)
let logPath = sessionFolder + "/log.csv"
try quoted.write(toFile: logPath, atomically: true, encoding: .utf8)
let rows: [[AnyHashable: Any]] = [
    ["name": "Test, Patient", "patientID": "001234", "patientUID": "TEST-001234-19700101",
     "studyInstanceUID": "1.2.3.study-a", "dateOfBirth": SurgicalProcedureImport.date(from: "1970-01-01")!],
]
let firstImport = SurgicalProcedureImportSession()
try firstImport.prepareCSV(atPath: logPath, patients: rows, existingPaths: [])
expect(firstImport.changeCount, 1, "the first import writes the record")
let firstFiles = try firstImport.commit(toDirectory: sessionFolder + "/first")
expect(firstFiles.count, 1, "one report for one record")

let found = SurgicalProcedureImportSession()
try found.prepareCSV(atPath: logPath, patients: rows, existingPaths: firstFiles)
expect(found.changeCount, 0, "the same log finds its record and writes nothing")
if found.summary.contains("unchanged 1") == false { fail("the reimport must say unchanged: \(found.summary)") }

// The UIDs come from the event, not from the import: a report that was not found
// again, because its file is out of reach, still has the same instance, which
// the index then updates instead of adding a second one.
let lost = SurgicalProcedureImportSession()
try lost.prepareCSV(atPath: logPath, patients: rows, existingPaths: [sessionFolder + "/gone.dcm"])
expect(lost.changeCount, 1, "a report out of reach is written again")
let secondFiles = try lost.commit(toDirectory: sessionFolder + "/second")
let firstRecord = try SurgicalProcedureImport.decodeBasicTextSR(Data(contentsOf: URL(fileURLWithPath: firstFiles[0])))
let secondRecord = try SurgicalProcedureImport.decodeBasicTextSR(Data(contentsOf: URL(fileURLWithPath: secondFiles[0])))
expect(secondRecord.sopInstanceUID, firstRecord.sopInstanceUID, "SOP Instance UID is stable across imports")
expect(secondRecord.seriesInstanceUID, firstRecord.seriesInstanceUID, "Series Instance UID is stable across imports")
expect(secondRecord.studyInstanceUID, firstRecord.studyInstanceUID, "Study Instance UID is stable across imports")

// The studies of the database come in no order: the same person's studies, one
// with a birth date and one without, must give the same identity either way.
let withBirth = SurgicalProcedurePatient(name: "Test, Patient", patientID: "001234",
    patientUID: "TEST-001234-19700101", birthDate: SurgicalProcedureImport.date(from: "1970-01-01"),
    studyInstanceUID: "1.2.3.study-a")
let withoutBirth = SurgicalProcedurePatient(name: "Test, Patient", patientID: "001234",
    patientUID: "TEST-001234-", birthDate: nil, studyInstanceUID: "1.2.3.study-c")
let oneWay = SurgicalProcedureImport.preview(table: table, patients: [withBirth, withoutBirth], existing: [])
let otherWay = SurgicalProcedureImport.preview(table: table, patients: [withoutBirth, withBirth], existing: [])
expect(oneWay.rows[0].record?.eventID, otherWay.rows[0].record?.eventID, "the order of the studies does not change the event")

// Without a birth date the identity holds the ID of the chosen study, so the
// choice among studies alike must not depend on their order either: two IDs
// under one patient UID, and two UIDs reached by the name alone.
let noID = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "2024-03-21,\"Test, Patient\",,Endoscopic surgery,,,,\n")
func eventIDs(_ first: SurgicalProcedurePatient, _ second: SurgicalProcedurePatient, _ log: SurgicalProcedureTable) -> (String?, String?) {
    (SurgicalProcedureImport.preview(table: log, patients: [first, second], existing: []).rows[0].record?.eventID,
     SurgicalProcedureImport.preview(table: log, patients: [second, first], existing: []).rows[0].record?.eventID)
}
let sameUID = (SurgicalProcedurePatient(name: "Test, Patient", patientID: "001234", patientUID: "TEST-001234-19700101",
                                        birthDate: nil, studyInstanceUID: "1.2.3.study-b"),
               SurgicalProcedurePatient(name: "Test, Patient", patientID: "NEW-9", patientUID: "TEST-001234-19700101",
                                        birthDate: nil, studyInstanceUID: "1.2.3.study-a"))
let sameUIDEvents = eventIDs(sameUID.0, sameUID.1, table)
expect(sameUIDEvents.0, sameUIDEvents.1, "the Study Instance UID settles a tie of patient UIDs")
let byName = (SurgicalProcedurePatient(name: "Test, Patient", patientID: "001234", patientUID: "TEST PATIENT-001234-",
                                       birthDate: nil, studyInstanceUID: "1.2.3.study-a"),
              SurgicalProcedurePatient(name: "Test, Patient", patientID: "NEW-9", patientUID: "TEST PATIENT-NEW-9-",
                                       birthDate: nil, studyInstanceUID: "1.2.3.study-a"))
let byNameEvents = eventIDs(byName.0, byName.1, noID)
expect(byNameEvents.0, byNameEvents.1, "the patient UID settles the choice among studies found by name")

// A study that arrives later changes the chosen patient, and with it the event
// made from the same line of the log. The patient ID finds the record filed
// before, with its UIDs, so the same log adds nothing.
let noBirthStudy = SurgicalProcedurePatient(name: "Test, Patient", patientID: "001234",
    patientUID: "TEST-001234-", birthDate: nil, studyInstanceUID: "1.2.3.study-c")
let firstFiled = SurgicalProcedureImport.preview(table: table, patients: [noBirthStudy], existing: [])
var filedStore: [SurgicalProcedureRecord] = []
_ = try SurgicalProcedureImport.commit(firstFiled, into: &filedStore, now: Date(timeIntervalSince1970: 1_700_000_000))
let filed = try SurgicalProcedureImport.decodeBasicTextSR(SurgicalProcedureImport.encodeBasicTextSR(filedStore[0]))
let grown = SurgicalProcedureImport.preview(table: table, patients: [noBirthStudy, withBirth], existing: [filed])
expect(grown.rows[0].action, .unchanged, "a study with a birth date does not add the procedure again")
expect(grown.changes.count, 0, "nothing is written")
let grownCorrected = SurgicalProcedureImport.preview(table: updatedTable, patients: [noBirthStudy, withBirth], existing: [filed])
expect(grownCorrected.rows[0].action, .update, "a changed line updates the record filed before")
expect(grownCorrected.rows[0].record?.eventID, filed.eventID, "the update keeps the event")
expect(grownCorrected.rows[0].record?.patientKey, filed.patientKey, "the update keeps the patient key")
expect(grownCorrected.rows[0].record?.sopInstanceUID, filed.sopInstanceUID, "the update keeps the SOP Instance UID")
expect(grownCorrected.rows[0].record?.studyInstanceUID, filed.studyInstanceUID, "the update keeps the Study Instance UID")
var grownStore = grownCorrected.existing
_ = try SurgicalProcedureImport.commit(grownCorrected, into: &grownStore, now: Date(timeIntervalSince1970: 1_700_000_200))
expect(grownStore.count, 1, "the update replaces the record filed before")

// The second of two procedures of a day finds the second record, not the first.
let sameDay = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "2024-03-21,\"Test, Patient\",001234,Endoscopic surgery,First,,,\n"
    + "2024-03-21,\"Test, Patient\",001234,Endoscopic surgery,Second,,,\n")
var sameDayStore: [SurgicalProcedureRecord] = []
_ = try SurgicalProcedureImport.commit(SurgicalProcedureImport.preview(table: sameDay, patients: [noBirthStudy], existing: []),
                                       into: &sameDayStore, now: Date(timeIntervalSince1970: 1_700_000_000))
expect(sameDayStore.count, 2, "two procedures on one day")
let sameDayAgain = SurgicalProcedureImport.preview(table: sameDay, patients: [noBirthStudy, withBirth], existing: sameDayStore)
expect(sameDayAgain.rows.map(\.action), [.unchanged, .unchanged], "each line finds its own record")

// An ID is what says it is the same person: a name alone, or a birth date that
// disagrees, never takes over another patient's record.
let otherPerson = SurgicalProcedurePatient(name: "Test, Patient", patientID: "777",
    patientUID: "TEST-777-19800202", birthDate: SurgicalProcedureImport.date(from: "1980-02-02"),
    studyInstanceUID: "1.2.3.study-d")
let otherLog = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "2024-03-21,\"Test, Patient\",777,Endoscopic surgery,,,,\n")
expect(SurgicalProcedureImport.preview(table: otherLog, patients: [noBirthStudy, otherPerson], existing: [filed]).rows[0].action,
       .add, "the same name under another ID is another person")
var bornElsewhere = filed
bornElsewhere.matchedBirthDate = SurgicalProcedureImport.date(from: "1980-02-02")
expect(SurgicalProcedureImport.preview(table: table, patients: [withBirth], existing: [bornElsewhere]).rows[0].action,
       .add, "birth dates that disagree say it is another person")

// The same report can be indexed twice, under two patients: the latest one
// counts, and the preview must not stop on the repeated event.
var older = store[0]
older.diagnosis = "Older diagnosis"
older.updatedAt = store[0].updatedAt.addingTimeInterval(-100)
let twice = SurgicalProcedureImport.preview(table: updatedTable, patients: patients, existing: [older, store[0]])
expect(twice.existing.count, 1, "one record for each event")
expect(twice.rows[0].action, .unchanged, "the record updated last is the one compared")
expect(SurgicalProcedureImport.preview(table: updatedTable, patients: patients, existing: [store[0], older]).rows[0].action,
       .unchanged, "the record updated last is the one compared, whichever comes first")
var twiceStore = twice.existing
_ = try SurgicalProcedureImport.commit(twice, into: &twiceStore, now: Date(timeIntervalSince1970: 1_700_000_300))
expect(twiceStore.count, 1, "the commit keeps one record")

// The timeline counts the same record: one event, with the text updated last,
// whatever the order of the paths.
var newest = try SurgicalProcedureImport.decodeBasicTextSR(srData)
newest.diagnosis = "Newest diagnosis"
newest.updatedAt = decoded.updatedAt.addingTimeInterval(100)
let reports = sessionFolder + "/reports"
try FileManager.default.createDirectory(atPath: reports, withIntermediateDirectories: true)
let newestPath = reports + "/newest.dcm", stalePath = reports + "/stale.dcm"
try SurgicalProcedureImport.encodeBasicTextSR(newest).write(to: URL(fileURLWithPath: newestPath))
try srData.write(to: URL(fileURLWithPath: stalePath))
for order in [[stalePath, newestPath], [newestPath, stalePath]] {
    let events = SurgicalProcedureImport.timelineEvents(fromSRPaths: order)
    expect(events.count, 1, "a report indexed twice is one event")
    expect(events.first?["diagnosis"] as? String, "Newest diagnosis", "the timeline shows the text updated last")
}

// A report is read again when its file changes, and gone when its file is.
var rewritten = newest
rewritten.diagnosis = "Rewritten diagnosis"
try SurgicalProcedureImport.encodeBasicTextSR(rewritten).write(to: URL(fileURLWithPath: newestPath))
try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: newestPath)
expect(SurgicalProcedureImport.timelineEvents(fromSRPaths: [newestPath]).first?["diagnosis"] as? String,
       "Rewritten diagnosis", "a changed report is read again")
try FileManager.default.removeItem(atPath: newestPath)
expect(SurgicalProcedureImport.timelineEvents(fromSRPaths: [newestPath]).isEmpty, true, "a report that is gone leaves the timeline")

// An accented name: the report says what it is written in, and that is what a
// reader goes by. The bytes are checked by the DICOM reader's own rules below.
let accented = "Jo\u{E3}o da Concei\u{E7}\u{E3}o"
var accentedRecord = store[0]
accentedRecord.matchedPatientName = accented
accentedRecord.sopInstanceUID = ""
let accentedReport = sessionFolder + "/accented.dcm"
try SurgicalProcedureImport.encodeBasicTextSR(accentedRecord).write(to: URL(fileURLWithPath: accentedReport))
try FileManager.default.copyItem(atPath: accentedReport, toPath: CommandLine.arguments[1])
expect(try SurgicalProcedureImport.decodeBasicTextSR(Data(contentsOf: URL(fileURLWithPath: accentedReport))).matchedPatientName,
       accented, "the record keeps the name")

// A report filed before says who the patient was in its own spelling. Its own
// study neither makes the match ambiguous nor sends the line to review.
let realStudy = SurgicalProcedurePatient(name: accented, patientID: "4242", patientUID: "JOAO-4242-19700101",
    birthDate: SurgicalProcedureImport.date(from: "1970-01-01"), studyInstanceUID: "1.2.3.real")
let accentedLog = try SurgicalProcedureImport.parseCSV(
    "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "2024-03-21,\"\(accented)\",4242,Craniotomia,,,,\n")
var accentedStore: [SurgicalProcedureRecord] = []
_ = try SurgicalProcedureImport.commit(SurgicalProcedureImport.preview(table: accentedLog, patients: [realStudy], existing: []),
                                       into: &accentedStore, now: Date(timeIntervalSince1970: 1_700_000_000))
let filedAccented = try SurgicalProcedureImport.decodeBasicTextSR(SurgicalProcedureImport.encodeBasicTextSR(accentedStore[0]))
let misread = SurgicalProcedurePatient(name: "Jo\u{C3}\u{A3}o da Concei\u{C3}\u{A7}\u{C3}\u{A3}o", patientID: "4242", patientUID: "JOâO-4242-19700101",
    birthDate: SurgicalProcedureImport.date(from: "1970-01-01"), studyInstanceUID: filedAccented.studyInstanceUID)
let withOwnStudy = SurgicalProcedureImport.preview(table: accentedLog, patients: [misread, realStudy], existing: [filedAccented])
expect(withOwnStudy.rows[0].action, .unchanged, "a report's own study does not send the line to review")
// The study of the report is all there is of a patient whose images were deleted.
expect(SurgicalProcedureImport.preview(table: accentedLog, patients: [misread], existing: [filedAccented]).rows[0].action,
       .unchanged, "a report's own study still answers when no other does")

// New UIDs have no leading zero, in any component, whatever the event.
func uidsAreValid(_ uid: String) -> Bool {
    uid.count <= 64 && uid.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { $0 == "0" || ($0.first != "0" && $0.isEmpty == false) }
}
var hadLeadingZero = 0
for number in 0..<300 {
    var fresh = store[0]
    fresh.eventID = "event-\(number)"
    (fresh.sopInstanceUID, fresh.seriesInstanceUID, fresh.studyInstanceUID) = ("", "", "")
    let made = try SurgicalProcedureImport.decodeBasicTextSR(SurgicalProcedureImport.encodeBasicTextSR(fresh))
    for uid in [made.sopInstanceUID, made.seriesInstanceUID, made.studyInstanceUID] {
        if uidsAreValid(uid) == false { fail("invalid UID \(uid)") }
        if uid.count < 41 { hadLeadingZero += 1 }
    }
}
if hadLeadingZero == 0 { fail("no event gave the case of a leading zero") }

// A report filed with such a UID keeps it: its identity in the database is that UID.
var legacy = store[0]
legacy.sopInstanceUID = "2.25.012034056078090012034056078090123456"
legacy.seriesInstanceUID = "2.25.012034056078090012034056078090123457"
legacy.studyInstanceUID = "2.25.012034056078090012034056078090123458"
let legacyFiled = try SurgicalProcedureImport.decodeBasicTextSR(SurgicalProcedureImport.encodeBasicTextSR(legacy))
expect(legacyFiled.sopInstanceUID, legacy.sopInstanceUID, "the file keeps the UID it was filed with")
let legacySame = SurgicalProcedureImport.preview(table: updatedTable, patients: patients, existing: [legacyFiled])
expect(legacySame.rows[0].action, .unchanged, "a report with the former UID is found, not added again")
let legacyChanged = SurgicalProcedureImport.preview(table: table, patients: patients, existing: [legacyFiled])
expect(legacyChanged.rows[0].action, .update, "a changed line updates it")
expect(legacyChanged.rows[0].record?.sopInstanceUID, legacy.sopInstanceUID, "the update keeps the former SOP Instance UID")
expect(legacyChanged.rows[0].record?.studyInstanceUID, legacy.studyInstanceUID, "the update keeps the former Study Instance UID")

// An update under another patient makes another study of the database: the
// commit says which files the new ones replace, the only ones and all of them,
// the copy of the same report under the former patient included.
let moving = sessionFolder + "/moving"
try FileManager.default.createDirectory(atPath: moving, withIntermediateDirectories: true)
var keptRecord = filed
keptRecord.eventID = "another-event"
keptRecord.operation = "Another operation"
let reportPath = moving + "/report.dcm", copyPath = moving + "/copy.dcm", keptPath = moving + "/kept.dcm"
try SurgicalProcedureImport.encodeBasicTextSR(filed).write(to: URL(fileURLWithPath: reportPath))
try SurgicalProcedureImport.encodeBasicTextSR(filed).write(to: URL(fileURLWithPath: copyPath))
try SurgicalProcedureImport.encodeBasicTextSR(keptRecord).write(to: URL(fileURLWithPath: keptPath))
let corrected = moving + "/log.csv"
try updatedCSV.write(toFile: corrected, atomically: true, encoding: .utf8)
let bothStudies: [[AnyHashable: Any]] = [
    ["name": "Test, Patient", "patientID": "001234", "patientUID": "TEST-001234-", "studyInstanceUID": "1.2.3.study-c"],
    ["name": "Test, Patient", "patientID": "001234", "patientUID": "TEST-001234-19700101",
     "studyInstanceUID": "1.2.3.study-a", "dateOfBirth": SurgicalProcedureImport.date(from: "1970-01-01")!],
]
let correction = SurgicalProcedureImportSession()
try correction.prepareCSV(atPath: corrected, patients: bothStudies, existingPaths: [reportPath, copyPath, keptPath])
expect(correction.changeCount, 1, "the changed line is one update")
expect(correction.formerReportPaths, [], "nothing is replaced before the commit")
let newFiles = try correction.commit(toDirectory: moving + "/new")
expect(newFiles.count, 1, "one file for the update")
expect(correction.formerReportPaths.sorted(), [copyPath, reportPath].sorted(), "the files of that report, and no other")
let unchangedAgain = SurgicalProcedureImportSession()
try unchangedAgain.prepareCSV(atPath: logPath, patients: rows, existingPaths: firstFiles)
_ = try unchangedAgain.commit(toDirectory: moving + "/none")
expect(unchangedAgain.formerReportPaths, [], "an import that updates nothing replaces nothing")

let numbersJSON = """
{"sheet":"Surgical Log","table":"Table 0","headerRow":1,"rows":[["Date","Name","ID","Operation","Diagnosis","Results","Optics","Assistants"],["2024-03-21","Test, Patient","001234","Endoscopic surgery","","","",""]]}
"""
let numbersTable = try SurgicalProcedureImport.table(fromNumbersJSON: numbersJSON, sourcePath: "/tmp/log.numbers")
expect(numbersTable.rows.count, 1, "Numbers JSON becomes one log row")
expect(numbersTable.rows[0].name, "Test, Patient", "Numbers name")
expect(numbersTable.rows[0].patientID, "001234", "Numbers ID")
if SurgicalProcedureImport.numbersReaderScript.contains("document.close({saving: 'no'})") == false {
    fail("Numbers reader must close the disposable copy without saving")
}

try? FileManager.default.removeItem(atPath: sessionFolder)
print("PASS: surgical CSV preview, identity, idempotency, timeline and Numbers table")
'''

with tempfile.TemporaryDirectory(prefix='horos-surgical-sr-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(code)
    compiled = subprocess.run(
        ['xcrun', 'swiftc', '-O', str(source), str(path / 'main.swift'), '-o', str(path / 'test')],
        capture_output=True, text=True)
    if compiled.returncode:
        print(compiled.stderr)
        raise SystemExit('FAIL: SurgicalProcedureImport.swift did not compile')
    accented_file = path / 'accented.dcm'
    ran = subprocess.run([str(path / 'test'), str(accented_file)], capture_output=True, text=True)
    if ran.returncode:
        print(ran.stderr or ran.stdout)
        raise SystemExit(ran.returncode)
    print(ran.stdout.strip())

    # The file as the database reads it: the DICOM reader's own rules, from the
    # bytes of the two elements, in the order the standard wants them.
    report = accented_file.read_bytes()

    def element(group, number):
        at = report.index(struct.pack('<HH', group, number), report.index(b'1.2.840.10008.1.2.1'))
        length = struct.unpack('<H', report[at + 6:at + 8])[0]
        return at, report[at + 8:at + 8 + length]

    charset_at, charset = element(0x0008, 0x0005)
    if charset_at + 8 + len(charset) != element(0x0008, 0x0016)[0]:
        raise SystemExit('FAIL: Specific Character Set does not come right before the SOP Class UID')
    if charset.strip() != b'ISO_IR 192':
        raise SystemExit('FAIL: the report does not say it is UTF-8: %r' % charset)
    name = element(0x0010, 0x0010)[1]
    (path / 'read.swift').write_text(r'''
import Foundation
import IsiXDICOMFile

let settings = ImportSettings()
let charset = String(decoding: Data(hex: CommandLine.arguments[1]), as: UTF8.self).trimmingCharacters(in: .whitespaces)
let bytes = [UInt8](Data(hex: CommandLine.arguments[2])).map { CChar(bitPattern: $0) } + [0]
let encodings = DICOMCharacterSet.encodings(forSpecificCharacterSet: charset)
let decoded = DICOMTextDecoding.decode(bytes, encodings: encodings) { DICOMCharacterSet.encoding(forDICOMCharacterSet: $0) }
let expected = "Jo\u{E3}o da Concei\u{E7}\u{E3}o"
let read = (decoded as String).trimmingCharacters(in: .whitespaces)
guard read == expected else { fatalError("the name reads \\(read)") }
let uid = { (name: String) in PatientUIDRule.uid(name: name as NSString, patientID: "001234", birthDate: "19700101", settings: settings) }
guard uid(read) == uid(expected) else { fatalError("the name makes another patient") }
print("PASS: an accented name reads back the same, in the same patient")

extension Data {
    init(hex: String) {
        self.init(stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex.dropFirst($0).prefix(2), radix: 16)!
        })
    }
}
''')
    modules = path / 'modules'
    flags = isix_modules.module_flags('IsiXDICOMFile', modules, ['-target', 'arm64-apple-macos15.0'])
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target', 'arm64-apple-macos15.0', *flags,
                            str(path / 'read.swift'), '-o', str(path / 'read')], capture_output=True, text=True)
    if built.returncode:
        print(built.stderr[-3000:])
        raise SystemExit('FAIL: the reader of the accented name did not compile')
    ran = subprocess.run([str(path / 'read'), charset.hex(), name.hex()], capture_output=True, text=True)
    if ran.returncode:
        print(ran.stderr or ran.stdout)
        raise SystemExit('FAIL: an accented name does not read back the same')
    print(ran.stdout.strip())

# Numbers JXA is exercised against a mock table. No Numbers.app, no database.
import json
text = source.read_text()
script = text.split('static let script = #"""', 1)[1].split('"""#', 1)[0]
headers = ["Date", "Name", "ID", "Operation", "Diagnosis", "Results", "Optics", "Assistants"]


def read_tables(tables):
    mock = r"""
    var fixture = __FIXTURE__;
    var closed = false;
    function MockPath(path) { return path; }
    function cells(values) {
        return {
            value: function () { return values.map(function (v) {
                return v && v.date ? new Date(Date.UTC(v.date[0], v.date[1] - 1, v.date[2], 0, 0, 0))
                    : (v && typeof v === 'object' ? v.value : v);
            }); },
            formattedValue: function () { return values.map(function (v) {
                return v && typeof v === 'object' ? v.formatted : v;
            }); }
        };
    }
    function MockApplication(path) {
        return {open: function (file) { return {
            sheets: function () { return [{
                name: function () { return 'Surgical Log'; },
                tables: function () { return fixture.map(function (f, index) {
                    return {
                        name: function () { return 'Table ' + index; },
                        rowCount: function () { return f.rows.length; },
                        footerRowCount: function () { return f.footers || 0; },
                        rows: f.rows.map(function (row) { return {cells: cells(row)}; }),
                        columns: f.rows[0].map(function (_, c) {
                            return {cells: cells(f.rows.map(function (row) { return row[c]; }))};
                        })
                    };
                }); }
            }]; },
            close: function (options) {
                if (options.saving !== 'no') throw new Error('Reader tried to save');
                closed = true;
            }
        }; }};
    }
    """.replace("__FIXTURE__", json.dumps(tables))
    wrapper = r"""
    function run() {
        var result;
        try { result = {table: JSON.parse(readDocument(['Numbers', 'copy.numbers']))}; }
        catch (error) { result = {error: String(error)}; }
        result.closed = closed;
        return JSON.stringify(result);
    }
    """
    reader = script.replace("function run(argv)", "function readDocument(argv)", 1)
    reader = reader.replace("Application(argv[0])", "MockApplication(argv[0])")
    reader = reader.replace("Path(argv[1])", "MockPath(argv[1])")
    result = subprocess.run(
        ["/usr/bin/osascript", "-l", "JavaScript", "-e", mock + reader + wrapper],
        check=False, capture_output=True, text=True, timeout=20,
    )
    if result.returncode:
        raise SystemExit('FAIL: Numbers JXA: ' + result.stderr)
    return json.loads(result.stdout)


row = [
    {"date": [2024, 3, 21], "formatted": "21 Mar 2024"},
    "Test Patient",
    {"value": 1234, "formatted": "001234"},
    "Endoscopic surgery", "First line\nSecond line", 'Result: "benign"', "", "Assistant",
]
result = read_tables([{"rows": [headers, row]}])
if not result["closed"]:
    raise SystemExit('FAIL: Numbers reader must close without saving')
if result["table"]["rows"][1] != ["2024-03-21", "Test Patient", "001234", *row[3:]]:
    raise SystemExit('FAIL: typed Numbers dates and zero-padded IDs were lost: %r' % (result,))

shifted = read_tables([{"rows": [headers, [
    {"date": [2007, 2, 14], "formatted": "Feb 14, 2007"},
    "Anderson, Ruth", "1008254730", "RF Crani Planum Meningioma", "", "", "", "",
]]}])
if shifted["table"]["rows"][1][0] != "2007-02-14":
    raise SystemExit('FAIL: date-only Numbers cells shifted off the calendar day')

missing = read_tables([{"rows": [["Unrelated", "Table"]]}])
if "No surgical log table" not in missing.get("error", "") or missing["closed"] is not True:
    raise SystemExit('FAIL: missing surgical table is not diagnosed')

print('PASS: Numbers JXA reader on mock tables')

