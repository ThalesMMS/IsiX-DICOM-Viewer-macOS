#!/usr/bin/env python3
"""RIS requests reach DICOMweb nodes, and their failures are told to the user.

A `horos://?methodName=retrieve` link or an XML-RPC `Retrieve`, `CMove`,
`DisplayStudy` or `FindObject` looked its node up in the DIMSE list only, so a
PACS configured as DICOMweb was always "not found", and every failure went to
the log alone. This compiles RISRequestServers.swift and RISRequestAlert.swift
with the two app types they read replaced by stand-ins, and drives the lookup,
the PACS On-Demand matching, the messages and the refusal policy. The wiring in
XMLRPCMethods.mm, AppController.swift and the PACS On-Demand preferences is
read from the sources.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


STUBS = r'''
import Foundation

// The Locations lists, as the app gives them: SERVERS entries, then the
// DICOMweb nodes HorosDICOMwebSources builds (same keys as server(for:)).
nonisolated(unsafe) var dimseNodes: [Any] = []
nonisolated(unsafe) var dicomwebNodes: [[String: Any]] = []

final class DCMNetServiceDelegate {
    static func dicomServersList() -> [Any]! { dimseNodes }
}

enum DICOMwebSources {
    static let nodeKey = "DICOMwebNode"
    static func queryRetrieveServers() -> [[String: Any]] { dicomwebNodes }
    static func isDICOMwebServer(_ server: [AnyHashable: Any]?) -> Bool {
        guard let identifier = server?[nodeKey] as? String else { return false }
        return !identifier.isEmpty
    }
}
'''

MAIN = r'''
import Foundation

func expect(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: " + message); exit(1) }
}

let pacs: [String: Any] = ["Description": "Main PACS", "AETitle": "MAINPACS", "Address": "10.0.0.5",
                           "Port": NSNumber(value: 104), "retrieveMode": 0]
let cget: [String: Any] = ["Description": "Archive", "AETitle": "ARCH", "Address": "10.0.0.6",
                           "Port": NSNumber(value: 11112), "retrieveMode": 1]
// An AE title that is also another node's description: the description wins.
let clash: [String: Any] = ["Description": "Other", "AETitle": "Archive", "Address": "10.0.0.7",
                            "Port": NSNumber(value: 104)]
let web: [String: Any] = ["DICOMwebNode": "7B1F0D7A-1111-4C3B-9D7A-000000000001", "Description": "Cloud PACS",
                          "AETitle": "DICOMweb", "Address": "https://pacs.example/dicom-web", "QR": true,
                          "Send": false, "Activated": true, "retrieveMode": 3]
// A SERVERS entry left with a DICOMweb key is not listed twice.
let stray: [String: Any] = ["Description": "Stray", "AETitle": "STRAY", "DICOMwebNode": "x"]

dimseNodes = [pacs, cget, clash, stray]
dicomwebNodes = [web]

let all = RISRequestServers.candidates()
expect(all.map { $0["Description"] as? String } == ["Main PACS", "Archive", "Other", "Cloud PACS"],
       "DIMSE nodes, then DICOMweb nodes with Q&R on")

func named(_ name: String?) -> String? { RISRequestServers.server(named: name)?["Description"] as? String }
expect(named("Main PACS") == "Main PACS", "a DIMSE node by its description")
expect(named("MAINPACS") == "Main PACS", "a DIMSE node by its AE title")
expect(named("Cloud PACS") == "Cloud PACS", "a DICOMweb node by its name")
expect(named("Archive") == "Archive", "a description is preferred to another node's AE title")
expect(named("DICOMweb") == nil, "every DICOMweb node shows that AE title: it designates none")
expect(named("  cloud pacs ") == "Cloud PACS", "case and surrounding spaces do not matter")
expect(named("mainpacs") == "Main PACS", "an AE title in another case")
expect(named("Stray") == nil, "a SERVERS entry carrying a DICOMweb key is not a node")
expect(named("Nowhere") == nil && named("") == nil && named(nil) == nil, "no node, no match")
// An exact match beats one in another case.
dimseNodes = [["Description": "pacs", "AETitle": "A"], ["Description": "PACS", "AETitle": "B"]]
expect(RISRequestServers.server(named: "PACS")?["AETitle"] as? String == "B", "exact before case-folded")
dimseNodes = [pacs, cget, clash, stray]

// What the PACS On-Demand preferences show and save as the address.
expect(RISRequestServers.addressAndPort(for: pacs) == "10.0.0.5:104", "DIMSE address and port")
expect(RISRequestServers.addressAndPort(for: web) == "https://pacs.example/dicom-web", "DICOMweb URL alone")
expect(RISRequestServers.addressAndPort(for: ["Address": "h"]) == "h:(null)", "a missing port as %@ printed it")

// Saved entries, as the preferences write them.
let savedPACS: [String: Any] = ["activated": true, "name": "Main PACS", "AETitle": "MAINPACS",
                                "AddressAndPort": "10.0.0.5:104", "server": pacs]
var renamed = web
renamed["Description"] = "Cloud PACS (new name)"
renamed["Address"] = "https://new.example/dicom-web"
let savedWeb: [String: Any] = ["activated": true, "name": "Cloud PACS", "AETitle": "DICOMweb",
                               "AddressAndPort": "https://pacs.example/dicom-web", "server": web]
expect(RISRequestServers.matches(saved: savedPACS, server: pacs), "a DIMSE node by AE title, name, address")
expect(!RISRequestServers.matches(saved: savedPACS, server: cget), "another DIMSE node")
var moved = pacs
moved["Port"] = NSNumber(value: 105)
expect(!RISRequestServers.matches(saved: savedPACS, server: moved), "a DIMSE node whose port changed")
expect(RISRequestServers.matches(saved: savedWeb, server: renamed), "a DICOMweb node by identifier, renamed")
expect(!RISRequestServers.matches(saved: savedWeb, server: pacs), "a DICOMweb entry is not a DIMSE node")
expect(!RISRequestServers.matches(saved: savedPACS, server: web), "a DIMSE entry is not a DICOMweb node")
let chosen = RISRequestServers.pacsOnDemandServers(saved: [savedPACS, savedWeb], in: [pacs, cget, renamed])
expect(chosen.map { $0["Description"] as? String } == ["Main PACS", "Cloud PACS (new name)"],
       "the chosen PACS On-Demand nodes, DICOMweb included")
expect(RISRequestServers.pacsOnDemandServers(saved: [savedWeb], in: [pacs]).isEmpty, "a removed node is gone")

// Messages name what was asked for and why it failed.
let missing = RISRequestAlert.serverNotFound("Cloud")
expect(missing.contains("\"Cloud\"") && missing.contains("AE title") && missing.contains("DICOMweb"),
       "server not found: the name, and how a node is designated")
let filters = RISRequestAlert.describe(filters: ["PatientID": "P1", "AccessionNumber": "A1"])
expect(filters == "AccessionNumber = A1, PatientID = P1", "filters read in a stable order: \(filters)")
expect(RISRequestAlert.describe(filters: [:]) == "-", "no filter")
expect(RISRequestAlert.nothingFound(server: "Main PACS", filters: filters).contains("\"Main PACS\" found no study matching AccessionNumber = A1"), "nothing found")
expect(RISRequestAlert.queryFailed(server: "Main PACS", filters: filters).contains("could not be queried"), "query failed")
expect(RISRequestAlert.notInDatabase(filters: "PatientID = P1", onDemandNodes: nil) == "No study matching PatientID = P1 is in the database.", "PACS On-Demand off")
expect(RISRequestAlert.notInDatabase(filters: "PatientID = P1", onDemandNodes: []).contains("no PACS On-Demand node is chosen"), "PACS On-Demand on, no node")
expect(RISRequestAlert.notInDatabase(filters: "PatientID = P1", onDemandNodes: ["Main PACS", "Cloud PACS"]).contains("(Main PACS, Cloud PACS)"), "PACS On-Demand nodes named")
let link = RISRequestAlert.describe(method: "retrieve", parameters: ["methodName": "retrieve", "serverName": "Cloud", "filterKey": "PatientID", "filterValue": "P1"])
expect(link == "retrieve (filterKey = PatientID, filterValue = P1, serverName = Cloud)", "a link: \(link)")
expect(RISRequestAlert.notCarriedOut(link).contains(link), "XML-RPC off: the request is named")
expect(RISRequestAlert.text("m", code: -2) == "m\n\nError code: -2", "the code the caller was answered")
expect(RISRequestAlert.refusedMessage(peer: "10.0.0.9", reason: .noCredential).contains("10.0.0.9"), "refusal names the peer")
expect(RISRequestAlert.refusedMessage(peer: "10.0.0.9", reason: .wrongCredential).contains("password is wrong"), "wrong password")
expect(RISRequestAlert.refusedMessage(peer: "10.0.0.9", reason: .loopbackOnly).contains("Network Access"), "loopback only: where to change it")

// A challenge answered within the grace is an ordinary authentication; one
// left unanswered is shown, and a peer is shown at most once a minute.
var ledger = RISRequestAlert.RefusalLedger()
let t0 = Date(timeIntervalSinceReferenceDate: 1000)
ledger.challenged(peer: "10.0.0.9", at: t0)
ledger.accepted(peer: "10.0.0.9")
expect(!ledger.isDue(peer: "10.0.0.9", challengedAt: t0, at: t0 + 3), "answered challenge is not shown")
ledger.challenged(peer: "10.0.0.9", at: t0 + 10)
expect(ledger.isDue(peer: "10.0.0.9", challengedAt: t0 + 10, at: t0 + 13), "unanswered challenge is shown")
ledger.challenged(peer: "10.0.0.9", at: t0 + 20)
expect(!ledger.isDue(peer: "10.0.0.9", challengedAt: t0 + 20, at: t0 + 23), "not twice within the minute")
expect(ledger.shouldShow(peer: "10.0.0.8", at: t0 + 23), "another peer is shown")
expect(ledger.shouldShow(peer: "10.0.0.9", at: t0 + 74), "the peer again after a minute")
ledger.challenged(peer: "10.0.0.7", at: t0 + 30)
ledger.challenged(peer: "10.0.0.7", at: t0 + 31)
expect(!ledger.isDue(peer: "10.0.0.7", challengedAt: t0 + 30, at: t0 + 33), "a later challenge replaces an earlier one")
expect(ledger.isDue(peer: "10.0.0.7", challengedAt: t0 + 31, at: t0 + 34), "the later challenge is shown")

print("PASS: lookup by description and AE title, DICOMweb nodes, PACS On-Demand matching, messages, refusals")
'''


def block(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i)]


# The app's DICOMweb test the stand-in copies.
integration = (root / 'Horos/Sources/DICOMwebIntegration.swift').read_text()
check('static let nodeKey = "DICOMwebNode"' in integration, 'DICOMweb node key')
check('guard let identifier = server?[nodeKey] as? String else { return false }' in integration
      and 'return !identifier.isEmpty' in integration, 'isDICOMwebServer as the stand-in reads it')

methods = (root / 'Horos/Sources/XMLRPCMethods.mm').read_bytes().decode('utf-8')
check('DICOMServersList' not in methods, 'XMLRPCMethods no longer reads the DIMSE list alone')
retrieve = block(methods, '-(NSDictionary*)Retrieve:(NSDictionary*)paramDict', '-(void)_threadRetrieve:')
check('[HorosRISRequestServers serverNamed:serverName]' in retrieve, 'Retrieve looks the node up among all')
check(re.search(r'serverNotFoundMessage:serverName\] code:-2\];\s*ReturnWithErrorValue\(-2\)', retrieve),
      'Retrieve: not found is told and answered -2')
check('[rootNode setShowErrorMessage:NO]' in retrieve, 'one alert per failed request')
check(re.search(r'reportMessage:message code:-3\];\s*return -3;', retrieve), 'nothing found is told and answered -3')
check('lastQuerySucceeded' in retrieve, 'a node that could not be asked is not "nothing found"')
cmove = block(methods, '-(NSDictionary*)CMove:', '/**\n Method: DisplayStudyListByPatientName')
check('[HorosRISRequestServers serverNamed:serverName]' in cmove, 'CMove looks the node up among all')
check(re.search(r'code:-1\];\s*ReturnWithErrorValue\(-1\)', cmove), 'CMove: not found is told and answered -1')
check('_retrieveFromServer:source filters:filters' in cmove, 'CMove answers the query result')
for name in ('_DisplayStudy:', '_FindObject:'):
    body = block(methods, '- (NSDictionary*)' + name, '/**')
    check('[HorosRISRequestServers pacsOnDemandServers]' in body, name + ' PACS On-Demand includes DICOMweb nodes')
    check('notInDatabaseMessageForFilters:' in body, name + ' tells the user it found nothing')
find = block(methods, '- (NSDictionary*)_FindObject:', '/**')
check(re.search(r'if \(\[command isEqualToString:@"Open"\]\)\s*\[HorosRISRequestAlert reportMessage', find),
      'FindObject tells only a request to open')
access = block(methods, '-(BOOL)shouldHandleRequest:', '-(id)methodCall:')
check('noteAcceptedFromPeer:self.address' in access, 'an accepted request answers a pending challenge')
check('HorosRISRefusalWrongCredential : HorosRISRefusalNoCredential' in access, 'challenge reasons')
check('HorosRISRefusalLoopbackOnly' in access, 'loopback-only refusal')

app = source_text('AppController')
geturl = block(app, '@objc(getUrl:withReplyEvent:) func getUrl', 'if let imageSpecifier')
check(re.search(r'RISRequestAlert\.notCarriedOut\(request\)', geturl), 'URL support off: the request is named')
check(re.search(r'NSApplication\.shared\.terminate\(self\)\s*\}\s*return\s*\}', geturl),
      'URL support off: nothing is called afterwards')
check('_ = try? xmlrpcServer?.methodCall' not in geturl and 'answered error' in geturl, 'the code is logged')
check('if !launchFinished { launchedForURL = true }' in geturl, 'a link during launch is noted')
check(re.search(r'bool\(forKey: "isQueryControllerVisible"\) && !launchedForURL', app),
      'a link launch does not reopen Query/Retrieve')
check('launch.eventID == AEEventID(kAEGetURL)' in app, 'the launch event is read')

pane = (root / 'Preference Panes/OSIPACSOnDemandPreferencePane/OSIPACSOnDemandPreferencePane.swift').read_text()
check('RISRequestServers.candidates()' in pane, 'PACS On-Demand preferences offer DICOMweb nodes')
check('RISRequestServers.matches(saved:' in pane, 'PACS On-Demand preferences match as requests do')
browser = (root / 'Horos/Sources/BrowserController.m').read_bytes().decode('utf-8')
check('[HorosRISRequestServers candidates]' in block(browser, '+ (NSArray*) comparativeServers', '+ (NSString*)'),
      'comparative studies use the same nodes')

with tempfile.TemporaryDirectory(prefix='horos-ris-request-') as tmp:
    p = Path(tmp)
    (p / 'stubs.swift').write_text(STUBS)
    (p / 'main.swift').write_text(MAIN)
    build = subprocess.run(['swiftc', '-suppress-warnings', '-swift-version', '6',
                            str(root / 'Horos/Sources/RISRequestServers.swift'),
                            str(root / 'Horos/Sources/RISRequestAlert.swift'),
                            str(p / 'stubs.swift'), str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode:
        failures.append('compile:\n' + build.stderr[-3000:])
    else:
        run = subprocess.run([str(p / 'test')], capture_output=True, text=True, timeout=60)
        print(run.stdout.strip())
        if run.returncode:
            failures.append('driver: ' + run.stdout[-2000:] + run.stderr[-2000:])

if failures:
    print('\n'.join('FAIL: ' + f for f in failures))
    sys.exit(1)
print('PASS: RIS request wiring')
