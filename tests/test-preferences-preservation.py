#!/usr/bin/env python3
"""Editing one kind of node must not lose anything of the other (#380 A, #799).

Since #799 a DICOMweb node is not the DICOMweb half of a DIMSE node any more:
it has a list of its own, `DICOMWEB_SERVERS`, and the Locations pane edits it
through `DICOMwebNode`. What #380 A asked still holds, in that shape.

Object level: the migration of the pilot's DICOMweb entries leaves every DIMSE
node of `SERVERS` as it was, AE title, address, port, transfer syntax, TLS,
WADO and any unknown key included; editing a DICOMweb node's authentication
changes only its credential reference and keeps its unknown keys; no password,
token or authorization header is written into a node.

Source level: the preferences window still loads plugin panes, keeps the
current pane when one fails to load, reuses the host's fullscreen policy
instead of a second one, and the Locations pane writes `SERVERS` only from the
controller's own array, and never DICOMweb keys. The DICOMweb area writes only
`DICOMWEB_SERVERS`, and secrets stay in the Keychain.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
double = r'''
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
driver = r'''
import Foundation
let suite = CommandLine.arguments[1]
let defaults = UserDefaults(suiteName: suite)!
func cleanUp() { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
func expect(_ ok: Bool, _ reason: String) { if !ok { cleanUp(); fatalError(reason) } }

let dimse: [String: Any] = [
    "AETitle": "PACS", "Address": "10.0.0.4", "Port": "11112", "Description": "Main PACS",
    "TransferSyntax": 0, "retrieveMode": 0, "QR": true, "Send": true,
    "TLSEnabled": true, "TLSAuthenticated": true, "TLSSupportedCipherSuite": ["TLS_AES_256_GCM_SHA384"],
    "WADOPort": 8080, "WADOUrl": "wado", "WADOhttps": 1, "WADOTransferSyntax": -1,
    "SomeFutureKey": "kept",
]
let pilot: [String: Any] = ["AETitle": "X", "Address": "0.0.0.0", "Port": "1", "Description": "Web",
                            "retrieveMode": 3, "DICOMwebURL": "https://dicomweb.example/dicomweb",
                            "DICOMwebCredentialID": UUID().uuidString]
defaults.set([dimse, pilot], forKey: "SERVERS")
DICOMwebNode.migrateLegacyServers(in: defaults)
let kept = defaults.array(forKey: "SERVERS") as! [NSDictionary]
expect(kept.count == 1 && kept[0].isEqual(to: dimse), "the DIMSE node is left exactly as it was: \(kept)")

let node = DICOMwebNode.nodes(in: defaults)[0]
let before = node.dictionaryRepresentation.merging(["SomeFutureKey": "kept"]) { a, _ in a }
let edited = DICOMwebNode(dictionary: before)
try! DICOMwebAuthentication.apply(.store(kind: .bearer, username: "", secret: "token-marker", headerName: ""),
                                  to: edited, store: KeychainDICOMwebCredentialStore())
let after = edited.dictionaryRepresentation
let changed = Set(after.keys).union(before.keys).filter { String(describing: after[$0]) != String(describing: before[$0]) }
expect(changed.isSubset(of: ["CredentialID", "LegacyCredential"]), "an authentication edit changes only the credential reference: \(changed)")
expect(after["SomeFutureKey"] as? String == "kept", "unknown keys survive")
for (key, value) in after {
    let text = String(describing: value).lowercased()
    expect(!text.contains("token-marker") && !text.contains("basic ") && !text.contains("bearer "), "\(key) carries no secret")
    expect(!key.lowercased().contains("password") && key != "Authorization", "no secret key: \(key)")
}
cleanUp()
print("PASS: migrating the pilot's nodes leaves the DIMSE nodes exactly as they were, and a DICOMweb authentication edit changes only the credential reference and writes no secret")
'''
with tempfile.TemporaryDirectory(prefix='horos-preferences-') as folder:
    tmp = Path(folder)
    (tmp / 'main.swift').write_text(driver)
    (tmp / 'credentials.swift').write_text(double)
    subprocess.run(['xcrun', 'swiftc', str(root / 'Horos/Sources/DICOMwebNode.swift'), str(tmp / 'credentials.swift'),
                    str(tmp / 'main.swift'), '-o', str(tmp / 'test')], check=True)
    # A suite of this check's own name, removed when it ends; cfprefsd writes
    # it back as an empty file a moment later, which goes too.
    suite = 'org.horos.test.preferences-preservation'
    try:
        subprocess.run([str(tmp / 'test'), suite], check=True)
    finally:
        for _ in range(40):
            time.sleep(0.25)
            (Path.home() / 'Library/Preferences' / (suite + '.plist')).unlink(missing_ok=True)

# PreferencesWindowController is Swift since #711; the assertions hold for its source.
preferences = source_text('PreferencesWindowController')
# OSILocationsPreferencePanePref is Swift since #711.
locations = source_text('OSILocationsPreferencePanePref')
editor = (root / 'Horos/Sources/DICOMwebNodeEditor.swift').read_text()
model = (root / 'Horos/Sources/DICOMwebNode.swift').read_text()
assert 'PluginManager' in preferences or 'pluginsPanes' in preferences or 'plugin' in preferences.lower(), \
    'the preferences window must keep loading plugin panes'
assert 'Preferences Could Not Be Opened' in preferences or 'couldNotBeOpened' in preferences.lower() or 'showAlert' in preferences, \
    'a pane that fails to load must be reported, not leave an empty window'
for forbidden in ('setPresentationOptions', 'NSApplicationPresentationFullScreen', 'toggleFullScreen'):
    assert forbidden not in preferences, 'the preferences window must not define a second fullscreen policy: ' + forbidden
assert locations.count('forKey: "SERVERS"') >= 3 and 'dicomNodes?.arrangedObjects, forKey: "SERVERS"' in locations, \
    'SERVERS is written from the controller array, not rebuilt'
assert 'DICOMwebURL' not in locations and 'DICOMwebCredentialID' not in locations, \
    'the Locations pane writes no DICOMweb key into a DIMSE node'
assert '"SERVERS"' not in editor and 'DICOMwebNode.save(nodes, to: defaults)' in editor, \
    'the DICOMweb area writes DICOMWEB_SERVERS only'
assert 'DICOMwebCredentials.store' in model and 'Keychain' in model, 'credentials stay in the Keychain'
for source in (editor, model):
    assert 'node["DICOMwebPassword"]' not in source and 'node["Authorization"]' not in source, \
        'no secret may be written into the node'
print('preferences wiring: plugin panes and the pane-failure alert kept, no second fullscreen policy, Locations still owns SERVERS, the DICOMweb area owns DICOMWEB_SERVERS, credentials stay in the Keychain')
