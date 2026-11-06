#!/usr/bin/env python3
"""SURG timeline rows join the database outline without hiding ordinary SR."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
importer = root / 'Horos/Sources/SurgicalProcedureImport.swift'
outline = root / 'Horos/Sources/SurgicalProcedureOutline.swift'
if not importer.is_file():
    raise SystemExit('FAIL: Horos/Sources/SurgicalProcedureImport.swift is missing')
if not outline.is_file():
    raise SystemExit('FAIL: Horos/Sources/SurgicalProcedureOutline.swift is missing')

code = r'''
import Foundation

func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
}

func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected { fail("\(message): \(actual) != \(expected)") }
}

expect(SurgicalProcedureOutline.hidesOrdinaryStructuredReports(), false,
       "outline merge must not hide vendor SR")

let patients = [
    SurgicalProcedurePatient(name: "Test, Patient", patientID: "001234",
        patientUID: "TEST-001234-19700101", birthDate: SurgicalProcedureImport.date(from: "1970-01-01"),
        studyInstanceUID: "1.2.3.study-a"),
]
let csv = "Date,Name,ID,Operation,Diagnosis,Results,Optics,Assistants\n"
    + "2024-03-21,\"Test, Patient\",001234,Endoscopic surgery,Updated diagnosis,Result benign,,Assistant\n"
var store: [SurgicalProcedureRecord] = []
let preview = SurgicalProcedureImport.preview(table: try SurgicalProcedureImport.parseCSV(csv),
                                               patients: patients, existing: store)
_ = try SurgicalProcedureImport.commit(preview, into: &store, now: Date(timeIntervalSince1970: 1_700_000_000))
let events = SurgicalProcedureImport.timeline(surgical: store, otherSR: [
    try SurgicalProcedureImport.encodeGenericStructuredReport(
        sopClassUID: SurgicalProcedureImport.comprehensiveSRSOPClassUID,
        seriesDescription: "Vendor Comprehensive SR",
        text: "Unrelated findings"),
])
expect(events.count, 1, "vendor SR stays out of the SURG index")
expect(events[0].displayModality, "SURG", "SURG modality")

let dicts = SurgicalProcedureImport.timelineEvents(fromSRPaths: [])
expect(dicts.isEmpty, true, "no files means no outline rows")

let studies: [Any] = [
    ["name": "CT Head", "patientID": "001234", "modality": "CT",
     "studyInstanceUID": "1.2.3.study-a", "type": "Study"],
    ["name": "Vendor Comprehensive SR", "patientID": "001234", "modality": "SR",
     "studyInstanceUID": "1.2.3.sr-foreign", "type": "Study"],
    ["name": "MR Other", "patientID": "999", "modality": "MR",
     "studyInstanceUID": "1.2.3.other", "type": "Study"],
]
let eventDicts: [[String: Any]] = [
    ["eventID": store[0].eventID, "operation": "Endoscopic surgery",
     "diagnosis": "Updated diagnosis", "patientName": "Test, Patient",
     "patientID": "001234", "displayModality": "SURG", "dicomModality": "SR",
     "date": store[0].procedureDate],
    ["eventID": store[0].eventID, "operation": "Endoscopic surgery",
     "diagnosis": "Updated diagnosis", "patientName": "Test, Patient",
     "patientID": "001234", "displayModality": "SURG", "dicomModality": "SR",
     "date": store[0].procedureDate],
]
let merged = SurgicalProcedureOutline.array(insertingEvents: eventDicts, intoStudies: studies)
expect(merged.count, 4, "one SURG row, no duplicate event, vendor SR kept")

let modalities = merged.map { item -> String in
    (item as? NSObject)?.value(forKey: "modality") as? String
        ?? (item as? [String: Any])?["modality"] as? String ?? ""
}
expect(modalities.contains("CT"), true, "CT study remains")
expect(modalities.contains("SR"), true, "ordinary SR remains listed")
expect(modalities.contains("MR"), true, "other patient remains")
expect(modalities.filter { $0 == "SURG" }.count, 1, "exactly one SURG row")

let surg = merged.compactMap { $0 as? SurgicalProcedureOutlineRow }
expect(surg.count, 1, "outline row type")
expect(surg[0].type, "Study", "presented as a study-level row")
expect(surg[0].modality, "SURG", "SURG not SR")
expect(surg[0].noFiles.intValue, 0, "not an image series")
expect(surg[0].isExpandable, false, "timeline rows do not expand into images")
if surg[0].name.contains("Endoscopic surgery") == false {
    fail("outline name must show the operation: \(surg[0].name)")
}

let ctIndex = modalities.firstIndex(of: "CT")!
let srIndex = modalities.firstIndex(of: "SR")!
let surgIndex = modalities.firstIndex(of: "SURG")!
expect(ctIndex < surgIndex, true, "SURG follows the matching patient studies")
expect(srIndex < surgIndex, true, "SURG does not replace the vendor SR row")

// A filtered list shows the records of the patients it lists, no others.
func event(_ identifier: String, _ patientID: String, _ patientName: String) -> [String: Any] {
    ["eventID": identifier, "operation": "Surgery " + identifier, "patientID": patientID,
     "patientName": patientName, "date": Date(timeIntervalSince1970: 0)]
}
let onePatient: [Any] = [["name": "Other, Patient", "patientID": "999"]]
let filtered = SurgicalProcedureOutline.array(
    insertingEvents: [event("a", "001234", "Test, Patient"), event("b", "999", "Other, Patient"), event("c", "", "Nameless ID")],
    intoStudies: onePatient)
expect(filtered.count, 2, "records of patients out of the list stay out")
expect((filtered.last as? SurgicalProcedureOutlineRow)?.eventID, "b", "the listed patient keeps the record")

// A patient with no ID is found by name, so the record stays beside the study.
let noIDStudies: [Any] = [["name": "No, Identifier", "patientID": ""], ["name": "Another, Person", "patientID": ""]]
let noIDMerged = SurgicalProcedureOutline.array(
    insertingEvents: [event("d", "", "No, Identifier"), event("h", "", "Absent, Patient")], intoStudies: noIDStudies)
expect(noIDMerged.count, 3, "a record of a patient with no ID, out of the list, stays out")
expect((noIDMerged[1] as? SurgicalProcedureOutlineRow)?.eventID, "d", "a patient with no ID keeps the record after the study")

// Records of one patient stay in the order given, after that patient's last study.
let ordered = SurgicalProcedureOutline.array(
    insertingEvents: [event("e", "999", "Other, Patient"), event("f", "999", "Other, Patient")],
    intoStudies: [["name": "Other, Patient", "patientID": "999"], ["name": "Other, Patient", "patientID": "999"],
                  ["name": "Test, Patient", "patientID": "001234"]] as [Any])
expect(ordered.compactMap { ($0 as? SurgicalProcedureOutlineRow)?.eventID }, ["e", "f"], "events keep their order")
expect(ordered[2] is SurgicalProcedureOutlineRow, true, "after the last study of the patient")
expect(ordered[3] is SurgicalProcedureOutlineRow, true, "before the next patient")

// The study made for a report is not a study more: its SURG row stands for it,
// and it is gone only where that row has a place. An ordinary SR stays.
func reportEvent(_ identifier: String, _ study: String, _ patientID: String, _ patientName: String) -> [String: Any] {
    var made = event(identifier, patientID, patientName)
    made["reportStudyInstanceUID"] = study
    return made
}
let listed: [Any] = [
    ["name": "Test, Patient", "patientID": "001234", "studyInstanceUID": "1.2.3.ct"],
    ["name": "Test, Patient", "patientID": "001234", "studyInstanceUID": "2.25.report-a"],
    ["name": "Test, Patient", "patientID": "001234", "studyInstanceUID": "1.2.3.vendor-sr"],
    ["name": "Only, Report", "patientID": "555", "studyInstanceUID": "2.25.report-b"],
    // A report written without a character set: another spelling, the same ID.
    ["name": "Teste\u{C3}\u{A3}o", "patientID": "001234", "studyInstanceUID": "2.25.report-c"],
    ["name": "No, Identifier", "patientID": "", "studyInstanceUID": "1.2.3.no-id"],
    ["name": "No, Identifier", "patientID": "", "studyInstanceUID": "2.25.report-d"],
]
let reportEvents = [reportEvent("r-a", "2.25.report-a", "001234", "Test, Patient"), reportEvent("r-b", "2.25.report-b", "555", "Only, Report"),
                    reportEvent("r-c", "2.25.report-c", "001234", "Test, Patient"), reportEvent("r-d", "2.25.report-d", "", "No, Identifier")]
let uidsOf = { (studies: [Any]) in studies.map { ($0 as? [String: Any])?["studyInstanceUID"] as? String ?? "" } }
let hidden = SurgicalProcedureOutline.studies(listed, hidingReportsOf: reportEvents)
expect(uidsOf(hidden), ["1.2.3.ct", "1.2.3.vendor-sr", "2.25.report-b", "1.2.3.no-id"],
       "report studies leave where their record has a row; the rest stays")
let shown = SurgicalProcedureOutline.array(insertingEvents: reportEvents, intoStudies: hidden)
expect(shown.compactMap { ($0 as? SurgicalProcedureOutlineRow)?.eventID }.sorted(), ["r-a", "r-b", "r-c", "r-d"], "every record keeps its row")
expect(SurgicalProcedureOutline.studies(listed, hidingReportsOf: [event("old", "001234", "Test, Patient")]).count, listed.count,
       "an event that names no study hides nothing")
expect(SurgicalProcedureOutline.studies(listed, hidingReportsOf: []).count, listed.count, "no events, nothing to hide")

// The list is read once, however many events there are: this runs on the main
// thread at every refresh.
final class CountedStudy: NSObject {
    nonisolated(unsafe) static var reads = 0
    @objc var patientID: String { CountedStudy.reads += 1; return "999" }
}
let counted = (0..<1000).map { _ in CountedStudy() }
_ = SurgicalProcedureOutline.array(insertingEvents: (0..<200).map { event("g\($0)", "999", "") }, intoStudies: counted)
expect(CountedStudy.reads, counted.count, "each study is read once")

print("PASS: SURG outline rows sit beside studies and leave ordinary SR listed")
'''

with tempfile.TemporaryDirectory(prefix='horos-surgical-outline-') as directory:
    path = Path(directory)
    (path / 'main.swift').write_text(code)
    compiled = subprocess.run(
        ['xcrun', 'swiftc', '-O', str(importer), str(outline), str(path / 'main.swift'),
         '-o', str(path / 'test')],
        capture_output=True, text=True)
    if compiled.returncode:
        print(compiled.stderr[-3000:])
        raise SystemExit('FAIL: SurgicalProcedureOutline.swift did not compile')
    ran = subprocess.run([str(path / 'test')], capture_output=True, text=True)
    if ran.returncode:
        print(ran.stderr or ran.stdout)
        raise SystemExit(ran.returncode)
    print(ran.stdout.strip())
