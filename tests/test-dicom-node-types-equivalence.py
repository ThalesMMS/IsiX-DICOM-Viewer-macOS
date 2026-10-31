#!/usr/bin/env python3
"""The typed DICOM and DICOMweb nodes list and store what the dictionaries did.

The node list of `SERVERS` (HorosDICOMNodeService) and the DICOMweb nodes of
`DICOMWEB_SERVERS` (HorosDICOMwebNode) were read and written as dictionaries;
they now go through DICOMNode, DICOMwebNodeRecord and DICOMNodeStore of
IsiXDICOMNetwork. The same driver is compiled with DICOMNodeService.swift and
DICOMwebNode.swift of the revision before that change and of this tree, and
run over the same preferences:

- the DIMSE list for every combination of "send only" and "query/retrieve
  only", over entries as Locations, earlier versions, the DICOMweb pilot and
  hand-written lists leave them (strings and numbers, Booleans and integers,
  missing keys, unknown keys, a blank AE title, nodes turned off);
- what `SERVERS` holds after the list normalized it, and the DIMSE predicate;
- the DICOMweb nodes read from dictionaries and written back, valid and
  hand-written, and the stored list read and saved again.

Every value is printed with its kind, so a Boolean that became an integer, or
a port that became a number, is a difference. The one difference expected is
that an entry of `SERVERS` that is not a dictionary is no longer listed; it is
checked on its own, and it stays in `SERVERS` when the list is written back.

Exits 2 when the history does not reach the revision before the change.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import history_reference  # noqa: E402
import isix_modules  # noqa: E402
import harness_defaults  # noqa: E402  the harness's preferences stay in its own process
import process_graph_stand_in  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
SERVICE = 'Horos/Sources/DICOMNodeService.swift'
MARK = 'static func nodes(sendOnly send: Bool, queryRetrieveOnly queryRetrieve: Bool) -> [Any]'
# HEAD while the change is not committed; then the parent of the commit that
# took the dictionary list away.
reference = ('HEAD' if MARK in history_reference.show('HEAD', SERVICE).decode('utf-8')
             else history_reference.before_text_removed(SERVICE, MARK))
if reference is None:
    print('skipped: the history does not reach the revision before the typed nodes')
    sys.exit(2)
if MARK in (ROOT / SERVICE).read_text(encoding='utf-8'):
    print('skipped: this tree still lists the nodes as dictionaries')
    sys.exit(2)

UNIQUE = 'org.horos.test.dicom-node-types'

CREDENTIALS = r'''
import Foundation
public typealias DICOMwebCredentialKind = DICOMwebCredentials.Kind
public final class DICOMwebCredentials: NSObject {
    public enum Kind { case basic, apiKey, bearer }
    public static func store(kind: Kind, username: String, secret: String, headerName: String) throws -> String { UUID().uuidString }
    public static func summary(forIdentifier identifier: String) -> String { "Bearer" }
    public static func remove(identifier: String) throws {}
    public static func migrateLegacy(identifier: String) throws {}
}
'''

DRIVER = r'''
import CoreFoundation
import Foundation

/// A value with its kind: b Boolean, i integer, r real, s text, d data, t date.
func kind(_ value: Any) -> String {
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "b:\(number.boolValue)" }
        if CFNumberIsFloatType(number) { return "r:\(number.doubleValue)" }
        return "i:\(number.intValue)"
    }
    if let text = value as? String { return "s:" + text }
    if let data = value as? Data { return "d:" + data.base64EncodedString() }
    if let date = value as? Date { return "t:\(date.timeIntervalSince1970)" }
    if let list = value as? [Any] { return "[" + list.map(kind).joined(separator: ",") + "]" }
    if let entry = value as? [String: Any] {
        return "{" + entry.keys.sorted().map { "\($0)=" + kind(entry[$0]!) }.joined(separator: ";") + "}"
    }
    return "?:" + String(describing: type(of: value))
}

/// A DICOMweb entry, with an identifier the node made up written as such.
func web(_ entry: [String: Any], given: [String: Any]) -> String {
    var entry = entry
    let stored = (given["Identifier"] as? String).flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if stored == nil, let made = entry["Identifier"] as? String, UUID(uuidString: made) != nil { entry["Identifier"] = "<made>" }
    return kind(entry)
}

let defaults = UserDefaults.standard
let domain = ProcessInfo.processInfo.processName
defaults.removePersistentDomain(forName: domain)
defaults.set(false, forKey: "searchDICOMBonjour")
defaults.set(false, forKey: "syncDICOMNodes")

let locations: [String: Any] = ["AETitle": "PACS", "Address": "pacs.example", "Port": "104", "Description": "Archive", "QR": true,
    "Send": true, "Activated": true, "TransferSyntax": NSNumber(value: Int32(0)), "retrieveMode": NSNumber(value: Int32(0)),
    "WADOTransferSyntax": NSNumber(value: Int32(-1)), "TLSEnabled": false, "TLSCipherSuites": [["Cipher": "X", "Supported": true]],
    "SendControllerConcurrentThreads": 2]
let wado: [String: Any] = ["AETitle": "WADO", "Address": "wado.example", "Port": 8080, "Description": "WADO", "retrieveMode": 2,
    "WADOUrl": "wado", "WADOPort": "8080", "WADOhttps": 1, "WADOExcludeSeries": ["scout"], "Activated": 1, "Send": false, "QR": true]
let getting: [String: Any] = ["AETitle": "OLDGET", "Address": "old.example", "Port": 104, "Description": "Old C-GET", "CGET": true,
    "CMOVE": false, "WADO": false, "TransferSyntax": 9]
let moving: [String: Any] = ["AETitle": "OLDMOVE", "Address": "old.example", "Port": "105", "Description": "Old C-MOVE", "CMOVE": "YES",
    "Activated": "1"]
let pilot: [String: Any] = ["AETitle": "WEB", "Address": "web.example", "Port": 80, "retrieveMode": 3, "Description": "Pilot",
    "DICOMwebURL": "https://web.example/dicom-web"]
let pilotText: [String: Any] = ["AETitle": "WEB2", "Address": "web.example", "Port": 80, "retrieveMode": "3", "Activated": true]
let noTitle: [String: Any] = ["Address": "10.0.0.9", "Port": "104", "Description": "No AE", "retrieveMode": 0, "Activated": true]
let blank: [String: Any] = ["AETitle": "  ", "Address": "10.0.0.9", "Port": "104", "Description": "Blank", "Activated": true]
let numberTitle: [String: Any] = ["AETitle": 5, "Address": "10.0.0.9", "Port": "104", "Description": "Number", "Activated": true]
let off: [String: Any] = ["AETitle": "OFF", "Address": "10.0.0.4", "Port": "104", "Description": "Off", "Activated": false, "retrieveMode": 0]
let offText: [String: Any] = ["AETitle": "OFF2", "Address": "10.0.0.4", "Port": "104", "Activated": "NO", "retrieveMode": 1]
let sendOff: [String: Any] = ["AETitle": "QRONLY", "Address": "10.0.0.5", "Port": 11112, "Send": 0, "QR": "YES", "retrieveMode": 0,
    "Activated": true, "Added": Date(timeIntervalSince1970: 1_000), "Blob": Data([1, 2])]
let qrOff: [String: Any] = ["AETitle": "SENDONLY", "Address": "10.0.0.6", "Port": "11112", "Send": "1", "QR": false,
    "retrieveMode": 1, "Activated": true, "Ratio": 0.5]

for (name, list) in [("mixed", [locations, wado, getting, moving, pilot, pilotText, noTitle, blank, numberTitle, off, offText, sendOff, qrOff] as [Any]),
                     ("normalized", [locations, wado, sendOff] as [Any]), ("empty", [] as [Any])] {
    defaults.set(list, forKey: "SERVERS")
    for (send, qr) in [(false, false), (true, false), (false, true), (true, true)] {
        print("\(name) list send=\(send) qr=\(qr)\t" + kind(DICOMNodeService.serversList(sendOnly: send, queryRetrieveOnly: qr) as NSArray as! [Any]))
    }
    print("\(name) stored\t" + kind(defaults.array(forKey: "SERVERS") ?? []))
    print("\(name) dimse\t" + list.map { DICOMNodeService.isDIMSEServer($0) ? "1" : "0" }.joined())
}
defaults.removeObject(forKey: "SERVERS")
print("missing list\t" + kind(DICOMNodeService.serversList(sendOnly: false, queryRetrieveOnly: false) as NSArray as! [Any]))

// An entry that is not a dictionary: listed before, not now; kept in SERVERS either way.
defaults.set(["not a node", getting], forKey: "SERVERS")
let withText = DICOMNodeService.serversList(sendOnly: false, queryRetrieveOnly: false) as NSArray as! [Any]
print("text entry listed\t\(withText.contains { $0 is String })")
print("text entry stored\t" + kind(defaults.array(forKey: "SERVERS") ?? []))

let cloud: [String: Any] = ["Identifier": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "Address": "https://pacs.example/dicom-web",
    "AllowInsecureHTTP": false, "WADOPath": "wado", "QIDOPath": "", "Name": "Cloud", "QR": true, "RetrieveSyntax": "*", "Send": true,
    "SendSyntax": "1.2.840.10008.1.2.4.90", "MaxRequests": 6, "SeriesOrder": 2, "ExcludeSeries": ["scout", "localizer"],
    "AdaptiveRequests": true, "TrustedCertificateSHA256": "ab12", "CredentialID": "0E984725-C51C-4BF4-9960-E1C80E27ABA0",
    "ClientIdentity": Data([1, 2, 3]), "ClientIdentityName": "Workstation", "Comment": "kept as written"]
let signedIn: [String: Any] = ["Identifier": "A0E1B2C3-D4E5-F607-1829-3A4B5C6D7E8F", "Address": "http://127.0.0.1:8042/dicom-web",
    "AllowInsecureHTTP": true, "WADOPath": "", "QIDOPath": "", "Name": "Signed in", "QR": true, "RetrieveSyntax": "1.2.840.10008.1.2.1",
    "Send": false, "SendSyntax": "*", "MaxRequests": 4, "SeriesOrder": 0, "AdaptiveRequests": false, "OIDCIssuer": "https://id.example",
    "OIDCClientID": "isix", "OIDCScopes": "openid", "LegacyCredential": true, "CredentialID": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427"]
let handWritten: [String: Any] = ["Identifier": "not a UUID", "Address": "  https://h.example  ", "Name": 7, "QR": "NO", "Send": "YES",
    "RetrieveSyntax": "1.2.840.10008.1.2", "SendSyntax": "", "MaxRequests": " 40 ", "SeriesOrder": 9,
    "ClientIdentity": Data([1]).base64EncodedString(), "ClientIdentityName": "Mine", "OIDCClientID": "orphan",
    "ExcludeSeries": ["a", 1], "AllowInsecureHTTP": Data(), "LegacyCredential": 0, "TrustedCertificateSHA256": 12]
let sparse: [String: Any] = ["MaxRequests": 0, "ClientIdentity": Data(), "ClientIdentityName": "x", "SeriesOrder": "1",
    "AdaptiveRequests": "YES", "Name": "Sparse", "Extra": ["nested": [1, true]]]
let textual: [String: Any] = ["Identifier": " C56A4180-65AA-42EC-A945-5FD21DEC0538 ", "MaxRequests": "many", "SeriesOrder": "x",
    "QR": 0, "Send": 1.5, "Name": " Spaced ", "OIDCIssuer": "https://id.example", "OIDCAudience": " api "]
for (name, entry) in [("cloud", cloud), ("signed in", signedIn), ("hand written", handWritten), ("sparse", sparse), ("textual", textual)] {
    print("web \(name)\t" + web(DICOMwebNode(dictionary: entry).dictionaryRepresentation, given: entry))
}
defaults.set([cloud, "junk", signedIn, 7] as [Any], forKey: "DICOMWEB_SERVERS")
let nodes = DICOMwebNode.nodes(in: defaults)
print("web nodes\t\(nodes.map(\.name))")
DICOMwebNode.save(nodes, to: defaults)
print("web saved\t" + kind(defaults.array(forKey: "DICOMWEB_SERVERS") ?? []))
defaults.removePersistentDomain(forName: domain)
'''


def build_and_run(folder, service, model, name):
    folder.mkdir()
    (folder / 'DICOMNodeService.swift').write_bytes(service)
    (folder / 'DICOMwebNode.swift').write_bytes(model)
    (folder / 'Credentials.swift').write_text(CREDENTIALS)
    # The process graph and PreferencesSource the node service and its discovery read
    # their preferences from; the earlier service does not use them.
    process_graph_stand_in.source(folder)
    (folder / 'main.swift').write_text(harness_defaults.SWIFT + DRIVER)
    # The node service's Bonjour discovery, which it starts; unchanged.
    discovery = [ROOT / 'Horos/Sources/DICOMBonjourDiscovery.swift', ROOT / 'Horos/Sources/BonjourDiscovery.swift']
    executable = folder / f'{UNIQUE}-{name}'
    built = subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(folder / 'module-cache'),
                            *isix_modules.module_flags('IsiXDICOMNetwork', folder / 'modules'),
                            *(str(folder / file) for file in ('DICOMNodeService.swift', 'DICOMwebNode.swift', 'Credentials.swift',
                                                               'ProcessGraphStandIn.swift', 'main.swift')),
                            *map(str, discovery), '-o', str(executable)], capture_output=True, text=True)
    if built.returncode:
        print(f'FAIL: the {name} sources do not compile\n{built.stderr[-3000:]}')
        sys.exit(1)
    try:
        run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
    finally:
        # cfprefsd writes a removed domain back as an empty file some seconds
        # later; deleting it through cfprefsd first keeps it from coming back.
        # Only this check's domains are named so.
        subprocess.run(['defaults', 'delete', executable.name], capture_output=True)
        for _ in range(20):
            time.sleep(0.25)
            for leftover in (Path.home() / 'Library/Preferences').glob(UNIQUE + '*.plist'):
                leftover.unlink(missing_ok=True)
    if run.returncode:
        print(f'FAIL: the {name} driver failed\n{run.stdout[-1500:]}{run.stderr[-1500:]}')
        sys.exit(1)
    return dict(line.split('\t', 1) for line in run.stdout.splitlines() if '\t' in line)


with tempfile.TemporaryDirectory(prefix='horos-dicom-node-types-') as tmp:
    tmp = Path(tmp)
    before = build_and_run(tmp / 'before', history_reference.show(reference, SERVICE),
                           history_reference.show(reference, 'Horos/Sources/DICOMwebNode.swift'), 'before')
    after = build_and_run(tmp / 'after', (ROOT / SERVICE).read_bytes(), (ROOT / 'Horos/Sources/DICOMwebNode.swift').read_bytes(),
                          'after')

failures = []
expected_difference = {'text entry listed'}
for key in sorted(set(before) | set(after)):
    if key in expected_difference:
        continue
    if before.get(key) != after.get(key):
        failures.append(f'{key}:\n  before {before.get(key)}\n  after  {after.get(key)}')
if before.get('text entry listed') != 'true' or after.get('text entry listed') != 'false':
    failures.append('an entry that is not a dictionary: listed before (%s), not now (%s)'
                    % (before.get('text entry listed'), after.get('text entry listed')))
if len(before) < 20:
    failures.append(f'the driver printed {len(before)} results')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print(f'PASS: {len(before) - 1} results equal to {reference[:9]}: the DIMSE lists, what SERVERS holds after them, the DIMSE '
      'predicate, the DICOMweb nodes read and written; an entry that is not a dictionary is no longer listed and stays stored')
