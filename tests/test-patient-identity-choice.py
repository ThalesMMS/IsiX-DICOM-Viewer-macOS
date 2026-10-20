#!/usr/bin/env python3
"""Unify Patient Identity: the alert's menu of identities, and its wiring.

Compiles PatientIdentityChoice.swift and checks the list it makes of the
selected studies' identities: one entry per name + ID + birth date, in row
order, counted, with the name between guillemets so "ANON" and "ANON " differ,
starting on the last selected row's identity and keeping that study as its
representative; and the list, under the menu, of the studies the chosen
identity changes. Also checks that -[BrowserController unifyStudies:] asks
the alert, skips the studies that already have the identity, and asks no
confirmation per study.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

from sources import source_text

root = Path(__file__).resolve().parents[1]
choice = source_text('PatientIdentityChoice')

stubs = r'''
import Foundation
enum HorosAlertPanel {
    static let defaultResponse = 1
    static let alternateResponse = 0
    static let otherResponse = -1
}
'''

driver = r'''
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); failures += 1 }
}
typealias C = PatientIdentityChoice
func identity(_ name: String, _ id: String = "123", _ birth: Date? = nil) -> C.Identity {
    C.Identity(name: name, patientID: id, birthDate: birth)
}
let birth = Date(timeIntervalSince1970: 0)
func text(_ date: Date) -> String { "BIRTH" }

// The five names of the request, selected in this order: the last one is preferred.
let names = ["ANON.", "ANON", "ANON ", "ANON A", "ANON^"]
var result = C.entries(for: names.map { identity($0) }, preferred: 4)
check(result.entries.map { $0.identity.name } == names, "one entry per name, in row order: \(result.entries.map { $0.identity.name })")
check(result.selected == 4, "the menu starts on the last selected row's identity, not \(result.selected)")
check(result.entries.map { $0.representative } == [0, 1, 2, 3, 4], "each entry stands for its own study")
let labels = result.entries.map { C.label(for: $0, birthDateText: text) }
check(Set(labels).count == 5, "the five labels differ: \(labels)")
check(labels[1].hasPrefix("«ANON»") && labels[2].hasPrefix("«ANON »"), "a trailing space shows inside the guillemets: \(labels[1]) / \(labels[2])")
check(labels[4].hasPrefix("«ANON^»"), "the caret is kept: \(labels[4])")
check(labels[0] == "«ANON.»  ·  123  ·  —  ·  1 study", "label layout: \(labels[0])")

// Repeated identities are listed once and counted; the preferred study stands
// for its own identity even when an earlier row has it too.
result = C.entries(for: [identity("A"), identity("B"), identity("A"), identity("C"), identity("B")], preferred: 2)
check(result.entries.map { $0.identity.name } == ["A", "B", "C"], "repeated identities listed once")
check(result.entries.map { $0.count } == [2, 2, 1], "counts \(result.entries.map { $0.count })")
check(result.entries.map { $0.representative } == [2, 1, 3], "representatives \(result.entries.map { $0.representative })")
check(result.selected == 0, "starts on A")
check(C.label(for: result.entries[0], birthDateText: text).hasSuffix("2 studies"), "plural count: \(C.label(for: result.entries[0], birthDateText: text))")

// One name with two IDs, or two birth dates, is two identities.
result = C.entries(for: [identity("SAME", "1"), identity("SAME", "2"), identity("SAME", "2", birth), identity("", "")], preferred: 1)
check(result.entries.count == 4 && result.selected == 1, "name with other ID or birth date is another identity")
let detailed = result.entries.map { C.label(for: $0, birthDateText: text) }
check(detailed[2] == "«SAME»  ·  2  ·  BIRTH  ·  1 study", "birth date shown: \(detailed[2])")
check(detailed[3] == "«»  ·  —  ·  —  ·  1 study", "empty name and ID: \(detailed[3])")
check(Set(detailed).count == 4, "labels of different identities differ")

// A preferred index outside the list falls back to the first entry.
check(C.entries(for: [identity("X")], preferred: 7).selected == 0, "out-of-range preferred row")

// Studies that already have the kept identity, in the fields unification writes.
final class Study: NSObject {
    @objc dynamic var name: String?
    @objc dynamic var patientID: String?
    @objc dynamic var patientUID: String?
    @objc dynamic var studyName: String?
    init(_ name: String?, _ id: String?, _ uid: String?, _ description: String? = nil) {
        self.name = name; patientID = id; patientUID = uid; studyName = description
    }
}
let kept = Study("ANON", "123", "ANON-123")
check(C.study(Study("ANON", "123", "ANON-123"), hasIdentityOf: kept), "same name, ID and UID")
check(!C.study(Study("ANON ", "123", "ANON-123"), hasIdentityOf: kept), "trailing space is another name")
check(!C.study(Study("ANON", "124", "ANON-123"), hasIdentityOf: kept), "other ID")
check(!C.study(Study("ANON", "123", "OTHER"), hasIdentityOf: kept), "other patient UID")
check(C.study(Study(nil, nil, nil), hasIdentityOf: Study("", "", "")), "nil and empty fields are equal")

// The list under the menu: every study but the kept one and those that have its identity.
let studies = [Study("Anon.", "1", "U1", "CT 1"), Study("Anon", "1", "U2", "CT 2"), Study("Anon", "1", "U2", ""), Study("Anon A", "", "U3", "MR")]
check(C.changes(of: studies, to: studies[1]) == ["«Anon.»  ·  1  ·  CT 1", "«Anon A»  ·  —  ·  MR"], "changes to Anon: \(C.changes(of: studies, to: studies[1]))")
check(C.changes(of: studies, to: studies[3]).count == 3, "changes to Anon A: \(C.changes(of: studies, to: studies[3]))")
check(C.changes(of: [studies[1], studies[2]], to: studies[1]).isEmpty, "nothing changes when all have the identity")

if failures > 0 { exit(1) }
print("PASS: identities listed once in row order, counted, told apart, starting on the last selected row")
'''

failures = []
with tempfile.TemporaryDirectory(prefix='horos-identity-choice-') as directory:
    work = Path(directory)
    (work / 'PatientIdentityChoice.swift').write_text(choice)
    (work / 'stubs.swift').write_text(stubs)
    (work / 'main.swift').write_text(driver)
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-module-cache-path', str(work / 'cache'),
                            str(work / 'stubs.swift'), str(work / 'PatientIdentityChoice.swift'), str(work / 'main.swift'),
                            '-o', str(work / 'test')], capture_output=True, text=True, timeout=300)
    if build.returncode:
        print(build.stdout + build.stderr)
        sys.exit(1)
    run = subprocess.run([str(work / 'test')], capture_output=True, text=True, timeout=30)
    print(run.stdout.strip())
    if run.returncode:
        failures.append('identity list')

browser = source_text('BrowserController')
unify = browser[browser.index('- (IBAction) unifyStudies:(id) sender'):browser.index('- (IBAction) mergeStudies:(id) sender')]
if 'runUnifyAlertForStudies: selectedStudies preferredStudy: destStudy chosenStudy: &chosenStudy' not in unify:
    failures.append('unifyStudies: does not ask HorosPatientIdentityChoice for the identity')
if 'to the last selected study' in unify or 'Unify Patient Identity to: %@' in unify:
    failures.append('unifyStudies: still runs the alert that kept the last selected study')
if unify.count('study != destStudy && [HorosPatientIdentityChoice study: study hasIdentityOf: destStudy] == NO') != 2:
    failures.append('unifyStudies: does not skip, in both passes, the studies that already have the kept identity')
if 'Do you confirm' in unify or unify.count('HorosRunInformationalAlertPanel') != 0:
    failures.append('unifyStudies: still asks a confirmation per study')
if unify.index('destStudy = (DicomStudy *) chosenStudy;') > unify.index('NSIndexSet *selectedRows'):
    failures.append('unifyStudies: changes the kept study after the passes start')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print('PASS: unifyStudies: keeps the identity chosen in the alert and skips studies that already have it')
