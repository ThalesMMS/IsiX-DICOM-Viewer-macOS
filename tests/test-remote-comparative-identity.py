#!/usr/bin/env python3
"""Execute production remote-history selection against controlled query responses.

+queryStudiesForPatient:... of the Query window is Swift: its source is taken
from QueryController+Network.swift and compiled with stand-ins for the query
of the nodes, the local study and the query node, then run.
"""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[1]
s=(root/'Horos/Sources/QueryController+Network.swift').read_text(encoding='utf-8')
signature='    @objc(queryStudiesForPatient:usePatientID:usePatientName:usePatientBirthDate:servers:showErrors:)\n'
a=s.index(signature)
b=s.index('    // MARK: Verification', a)
method=s[a:b]
assert 'QueryController.queryStudies(forFilters:' in method, 'the history no longer asks the nodes through queryStudiesForFilters'
harness=r'''
import Foundation
public class DicomStudy: NSObject {
 @objc public var name: String?
 @objc public var patientID: String?
 @objc public var dateOfBirth: Date?
 @objc public var studyInstanceUID: String?
}
final class DCMTKStudyQueryNode: NSObject {
 var nameValue: String?, patientIDValue: String?, birth: Date?
 var comparativeIdentity: ComparativePatientIdentity?
 @objc func name() -> String! { nameValue }
 @objc func patientID() -> String! { patientIDValue }
 @objc func dateOfBirth() -> Date! { birth }
}
enum DicomFile { static func nSreplaceBadCharacter(_ value: String!) -> String! { value } }
nonisolated(unsafe) var responses: [Any] = []
nonisolated(unsafe) var sentFilters: [AnyHashable: Any] = [:]
nonisolated(unsafe) var queryCount = 0
@MainActor public final class QueryController: NSObject {
 nonisolated class func queryStudies(forFilters filters: [AnyHashable: Any]!, servers serversList: [Any]!, showErrors: Bool) -> NSMutableArray! {
  queryCount += 1; sentFilters = filters ?? [:]; return NSMutableArray(array: responses)
 }
}
extension QueryController {
METHOD
}
'''.replace('METHOD',method)
driver=r'''
import Foundation
func check(_ condition: Bool, _ what: String, line: Int = #line) { if !condition { print("FAIL line \(line): \(what)"); exit(1) } }
NSTimeZone.default = TimeZone(secondsFromGMT: 0)!
let birth = Date(timeIntervalSince1970: 946684800)
let other = birth.addingTimeInterval(86400)
func node(_ id: String?, _ name: String?, _ date: Date?) -> DCMTKStudyQueryNode {
 let n = DCMTKStudyQueryNode(); n.patientIDValue = id; n.nameValue = name; n.birth = date; return n
}
func study(_ id: String?, _ name: String?, _ date: Date?) -> DicomStudy {
 let s = DicomStudy(); s.patientID = id; s.name = name; s.dateOfBirth = date; return s
}
func query(_ s: DicomStudy, _ i: Bool, _ n: Bool, _ b: Bool) -> [Any]? {
 QueryController.queryStudies(forPatient: s, usePatientID: i, usePatientName: n, usePatientBirthDate: b, servers: [], showErrors: false)
}
func same(_ found: [Any]?, _ expected: [AnyObject]) -> Bool {
 guard let found, found.count == expected.count else { return false }
 return zip(found, expected).allSatisfy { ($0 as AnyObject) === $1 }
}
let target = study("QA*?", "QA Patient", birth)
let good = node("QA*?", "QA Patient", birth)
let wrongID = node("QA123", "QA Patient", birth)
let missingID = node(nil, "QA Patient", birth)
let wrongBirth = node("QA*?", "QA Patient", other)
let missingBirth = node("QA*?", "QA Patient", nil)
let wrongName = node("QA*?", "Other Patient", birth)
responses = [good, wrongID, missingID, wrongBirth, missingBirth, wrongName]
check(same(query(target, true, true, true), [good]), "every field checked")
check((sentFilters["PatientID"] as? String) == "QA*?" && (sentFilters["PatientBirthDate"] as? Date) == birth, "the filters sent")
check(same(query(target, true, false, true), [good, wrongName]), "name not checked")
check(same(query(target, true, true, false), [good, wrongBirth, missingBirth]), "birth date not checked")
check(same(query(target, false, true, true), [good, wrongID, missingID]), "identifier not checked")
let before = queryCount
check(query(target, false, false, false) == nil, "nothing to identify the patient")
check(query(target, false, true, false) == nil, "a name alone")
check(query(study(nil, target.name, birth), true, true, true) == nil, "no identifier")
check(query(study(target.patientID, nil, birth), true, true, true) == nil, "no name")
check(query(study(target.patientID, target.name, nil), true, true, true) == nil, "no birth date")
check(queryCount == before, "a refused history asks no node")
let sameDay = node(target.patientID, target.name, birth.addingTimeInterval(3600))
responses = [sameDay]; check(same(query(target, true, true, true), [sameDay]), "the same day")
responses = []; check(query(target, true, true, true)?.count == 0, "no answer")
let indexed = study("QA1", "SAMPLE^JO^A", birth)
let identity = ComparativePatientIdentity(patientID: "QA1", issuer: "PACS1", universalIssuer: nil, name: indexed.name, birthDate: birth)
func identified(_ name: String, _ date: Date?, _ issuer: String?) -> DCMTKStudyQueryNode {
 let result = node("QA1", name, date)
 result.comparativeIdentity = ComparativePatientIdentity(patientID: "QA1", issuer: issuer, universalIssuer: nil, name: name, birthDate: date)
 return result
}
let variation = identified("SAMPLE^JO^B", birth, "PACS1")
let unknownBirth = identified("SAMPLE^JO^A", nil, "PACS1")
let foreignIssuer = identified("SAMPLE^JO^A", birth, "PACS2")
let conflictingBirth = identified("SAMPLE^JO^A", other, "PACS1")
let unknownIssuer = identified("SAMPLE^JO^B", birth, nil)
responses = [variation, unknownBirth, foreignIssuer, conflictingBirth, unknownIssuer]
let matched = QueryController.queryStudies(forPatient: indexed, usePatientID: true, usePatientName: true,
    usePatientBirthDate: true, servers: [], showErrors: false, identity: identity)
check(same(matched, [variation, unknownBirth]), "corroborate same-issuer history and exclude conflicts")
check(sentFilters["PatientBirthDate"] == nil, "allow a same-issuer result with no birth date")
check(same(query(indexed, true, true, true), [foreignIssuer]), "legacy callers retain exact demographic matching")
print("PASS: remote history validates enabled identity fields; wrong/missing IDs and birthdates, wildcard IDs, optional name/birthdate, empty responses and invalid query guards")
'''
with tempfile.TemporaryDirectory(prefix='horos-remote-comparative-') as t:
 p=Path(t);(p/'Harness.swift').write_text(harness);(p/'main.swift').write_text(driver)
 subprocess.run(['xcrun','swiftc',str(root/'Horos/Sources/PatientIdentity.swift'),str(p/'Harness.swift'),str(p/'main.swift'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True,timeout=60)
