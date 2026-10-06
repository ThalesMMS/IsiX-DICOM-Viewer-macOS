#!/usr/bin/env python3
"""DICOMweb nodes have a list of their own, and the pilot's nodes move to it.

Object level, with the model compiled against a stand-in for the Keychain half
(`DICOMwebCredentials`), so the user's Keychain is never touched, and with
preferences in defaults domains of this check's own name, removed when it
ends (cfprefsd does not honour CFFIXED_USER_HOME), so the user's own
preferences are not touched either:

- a node validates its address (HTTPS, or HTTP explicitly allowed per node or to this computer; no user,
  password, query or fragment), its relative WADO and QIDO paths, its name and
  its transfer syntaxes, and composes the QIDO, WADO and STOW endpoints;
- Implicit VR Little Endian is offered neither to retrieve nor to send, and a
  node saved with it reads as "As stored";
- `DICOMWEB_SERVERS` round-trips through the preferences with keys this
  version does not know, and holds no secret;
- the lookups part 3 uses give the valid nodes with Q&R on, and with Send on;
- the migration moves every `SERVERS` entry with retrieveMode 3 into a node
  (URL to Address, description to Name, credential kept, Q&R on, Send off),
  leaves the DIMSE entries in order, and changes nothing more when run again,
  also after an interruption between its two writes; the pilot's credentials
  are converted, and one that cannot be read yet is tried at the next run;
- the authentication sheet's decision keeps, replaces or removes a credential,
  and a replaced credential is stored before the old one is removed;
- `HorosDICOMNodeService`, behind `DCMNetServiceDelegate`, gives plugins and
  the DIMSE code neither a DICOMweb entry nor one without an AE title, and a
  synced node list does not bring them back.

Source level: the DIMSE Retrieve pop-up offers C-MOVE, C-GET and WADO only; the
new area of both the English and the Japanese xib has the nine columns and the
add, remove and test buttons wired to the controller; the xibs compile; the
migration runs in +[AppController initialize] after the defaults are
registered (AppController is Swift: +initialize, in
AppController+CAPI.m, sends +initializeAppController, its Swift body); the new strings are in the Italian and Spanish catalogs.

Pass a git revision to run the source checks against that revision instead
(one that predates the DICOMweb nodes fails them).
"""
from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_path  # noqa: E402
revision = sys.argv[1] if len(sys.argv) > 1 else None
failures = []


def check(ok, message):
    if not ok:
        failures.append(message)
        print('FAIL: ' + message)


def text(path):
    if revision:
        result = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return result.stdout.decode('latin1') if result.returncode == 0 else None
    full = root / path
    return full.read_bytes().decode('latin1') if full.exists() else None


if shutil.which('xcrun') is None:
    print('SKIP: xcrun is needed to compile the model')
    sys.exit(2)

CREDENTIALS_DOUBLE = r'''
import Foundation
// A stand-in for the Keychain half (DICOMwebCredentials): the same calls,
// recorded, with the secrets kept in memory only.
public typealias DICOMwebCredentialKind = DICOMwebCredentials.Kind
public final class DICOMwebCredentials: NSObject {
    public enum Kind { case basic, apiKey, bearer }
    static var items: [String: (kind: Kind, username: String, secret: String, header: String)] = [:]
    static var legacy: Set<String> = []
    static var unreadable: Set<String> = []
    static var calls: [String] = []
    public static func store(kind: Kind, username: String, secret: String, headerName: String) throws -> String {
        let identifier = UUID().uuidString
        items[identifier] = (kind, username, secret, headerName)
        calls.append("store")
        return identifier
    }
    public static func summary(forIdentifier identifier: String) -> String {
        guard let item = items[identifier] else { return legacy.contains(identifier) ? "Basic" : "None" }
        switch item.kind {
        case .basic: return "Basic \u{00B7} " + item.username
        case .apiKey: return "API Key \u{00B7} " + item.header
        case .bearer: return "Bearer"
        }
    }
    public static func remove(identifier: String) throws {
        items.removeValue(forKey: identifier); legacy.remove(identifier)
        calls.append("remove " + identifier)
    }
    public static func migrateLegacy(identifier: String) throws {
        if unreadable.contains(identifier) { throw NSError(domain: "double", code: -25308) }
        calls.append("migrate " + identifier)
        legacy.remove(identifier)
        items[identifier] = (.basic, "pilot", "pilot-secret-marker", "")
    }
}
'''

MODEL_DRIVER = r'''
import Foundation
let suite = CommandLine.arguments[1]
let defaults = UserDefaults(suiteName: suite)!
func cleanUp() { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
func expect(_ ok: Bool, _ reason: String) { if !ok { print("FAIL: " + reason); cleanUp(); exit(1) } }
func throwsError(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
defaults.removePersistentDomain(forName: suite)
DICOMwebNode.credentialStore = KeychainDICOMwebCredentialStore()

// A new node: a source, not a destination, "As stored" both ways, no address yet.
let fresh = DICOMwebNode()
expect(fresh.queryRetrieve && !fresh.send, "a new node is a source and not a destination")
expect(fresh.retrieveSyntax == "*" && fresh.sendSyntax == "*", "As stored is transfer-syntax=*")
expect(DICOMwebNode.transferSyntaxes.first == "*" && DICOMwebNode.transferSyntaxes.contains("1.2.840.10008.1.2.4.90"), "the syntax list starts with As stored")
expect(!fresh.isValid && fresh.qidoEndpoint.isEmpty, "a node without an address is not offered")
expect(!DICOMwebNode.transferSyntaxes.contains("1.2.840.10008.1.2"), "Implicit VR Little Endian is not offered")
let implicitNode = DICOMwebNode(dictionary: ["RetrieveSyntax": "1.2.840.10008.1.2", "SendSyntax": "1.2.840.10008.1.2"])
expect(implicitNode.retrieveSyntax == "*" && implicitNode.sendSyntax == "*", "a node saved with Implicit VR Little Endian reads as As stored")

// Addresses.
for good in ["https://pacs.example/dicom-web", "https://pacs.example:8443/dicom-web/", "http://127.0.0.1:18042/dicom-web",
             "http://localhost/dicom-web", "http://[::1]:8042/dicom-web"] {
    expect(!throwsError { _ = try DICOMwebNode.normalizedAddress(good) }, "accepted: " + good)
}
expect(try! DICOMwebNode.normalizedAddress(" https://pacs.example/dicom-web// ") == "https://pacs.example/dicom-web", "trailing slashes and spaces go")
for bad in ["", "pacs.example", "http://pacs.example/dicom-web", "ftp://pacs.example/", "https://user:pw@pacs.example/dicom-web",
            "https://user@pacs.example/", "https://pacs.example/dicom-web?token=x", "https://pacs.example/dicom-web#x", "https:///x"] {
    expect(throwsError { _ = try DICOMwebNode.normalizedAddress(bad) }, "refused: " + bad)
}

// Remote HTTP is an explicit persisted decision, never inferred from a private IP.
expect(!fresh.allowInsecureHTTP, "new nodes require HTTPS outside loopback")
// A trusted certificate is stored with the node, and only when there is one.
expect(fresh.trustedCertificateSHA256.isEmpty && fresh.dictionaryRepresentation["TrustedCertificateSHA256"] == nil,
       "a new node trusts the system's anchors only")
let pinnedNode = DICOMwebNode(dictionary: ["Identifier": UUID().uuidString, "Address": "https://pacs.example/dicom-web",
                                           "Name": "Pinned", "TrustedCertificateSHA256": String(repeating: "ab", count: 32)])
expect(pinnedNode.trustedCertificateSHA256 == String(repeating: "ab", count: 32)
       && pinnedNode.dictionaryRepresentation["TrustedCertificateSHA256"] as? String == String(repeating: "ab", count: 32),
       "the trusted certificate round-trips")
pinnedNode.trustedCertificateSHA256 = ""
expect(pinnedNode.dictionaryRepresentation["TrustedCertificateSHA256"] == nil, "clearing it removes the key")
// OpenID Connect settings and a client certificate reference are stored with
// the node; its tokens and the certificate's key never are.
let reference = Data([1, 2, 3, 4])
let signedIn = DICOMwebNode(dictionary: ["Identifier": UUID().uuidString, "Address": "https://pacs.example/dicom-web", "Name": "OIDC",
                                         "OIDCIssuer": "https://idp.example/realms/pacs", "OIDCClientID": "isis",
                                         "OIDCAudience": "pacs", "ClientIdentity": reference, "ClientIdentityName": "Workstation"])
expect(signedIn.usesOIDC && signedIn.oidcClientID == "isis" && signedIn.oidcScopes.isEmpty && signedIn.oidcAudience == "pacs"
       && signedIn.clientIdentityReference == reference && signedIn.clientIdentityName == "Workstation",
       "OpenID Connect settings and the client certificate reference are read")
let signedInStored = signedIn.dictionaryRepresentation
expect(signedInStored["OIDCIssuer"] as? String == "https://idp.example/realms/pacs" && signedInStored["OIDCScopes"] == nil
       && signedInStored["ClientIdentity"] as? Data == reference && signedInStored["ClientIdentityName"] as? String == "Workstation",
       "they round-trip, empty ones left out")
expect(DICOMwebNode(dictionary: ["ClientIdentity": reference.base64EncodedString()]).clientIdentityReference == reference,
       "a reference given as base64 text is read")
signedIn.oidcSettings = nil
signedIn.clientIdentityReference = nil
let cleared = signedIn.dictionaryRepresentation
expect(!signedIn.usesOIDC && cleared.keys.allSatisfy { !$0.hasPrefix("OIDC") && !$0.hasPrefix("ClientIdentity") },
       "a node that stops signing in or drops its certificate keeps none of their keys")
let remote = DICOMwebNode(dictionary: ["Address": "http://10.20.30.40:8080/dicom-web", "Name": "VPN", "Send": true])
expect(!remote.allowInsecureHTTP && !remote.isValid, "old remote HTTP nodes remain refused")
remote.allowInsecureHTTP = true
expect(remote.isValid && remote.qidoEndpoint == remote.address && remote.wadoEndpoint == remote.address
       && remote.stowEndpoint == remote.address, "explicit HTTP is accepted by all endpoint builders")
DICOMwebNode.save([remote], to: defaults)
let reopened = DICOMwebNode.nodes(in: defaults)[0]
expect(reopened.allowInsecureHTTP && reopened.isValid, "HTTP choice survives saving and reopening")
reopened.allowInsecureHTTP = false
DICOMwebNode.save([reopened], to: defaults)
let blocked = DICOMwebNode.nodes(in: defaults)[0]
expect(!blocked.isValid && blocked.qidoEndpoint.isEmpty && blocked.wadoEndpoint.isEmpty && blocked.stowEndpoint.isEmpty,
       "disabling the choice blocks every HTTP endpoint after reopening")
expect(DICOMwebNode.queryRetrieveNodes(in: defaults).isEmpty && DICOMwebNode.sendNodes(in: defaults).isEmpty,
       "blocked HTTP nodes are unavailable for Query/Retrieve and Send")
for unsafe in ["ftp://10.20.30.40/dw", "http://user:secret@10.20.30.40/dw", "http://10.20.30.40/dw?token=secret"] {
 expect(throwsError { _ = try DICOMwebNode.normalizedAddress(unsafe, allowInsecureHTTP: true) }, "HTTP permission does not allow credentials or other schemes")
}
expect(!DICOMwebNode(dictionary: ["Address": "https://pacs.example/dicom-web", "Name": "Old HTTPS"]).allowInsecureHTTP,
       "old HTTPS nodes keep their secure default")

// Paths.
expect(try! DICOMwebNode.normalizedPath("") == "", "an empty path is the address")
expect(try! DICOMwebNode.normalizedPath(" /rs/qido/ ") == "rs/qido", "slashes around a path go")
expect(try! DICOMwebNode.normalizedPath("a%41b/qido") == "a%41b/qido", "an escape such as %41 stays as written")
for bad in ["../x", "a/../b", "./a", "a?x=1", "a#b", "https://other/x", "//other/x", "a b", "%2e%2e/x", "a%2Fb", "%zz"] {
    expect(throwsError { _ = try DICOMwebNode.normalizedPath(bad) }, "path refused: " + bad)
}

// A complete node and its endpoints.
let node = DICOMwebNode()
node.address = "https://pacs.example/dicom-web"
node.qidoPath = "rs/qido"
node.wadoPath = ""
node.name = "Main"
expect(node.isValid, "a node with an address and a name is valid")
expect(node.qidoEndpoint == "https://pacs.example/dicom-web/rs/qido", "QIDO: address + QIDO path")
expect(node.wadoEndpoint == "https://pacs.example/dicom-web", "WADO: an empty path is the address")
expect(node.stowEndpoint == "https://pacs.example/dicom-web", "STOW: the address")
node.retrieveSyntax = "1.2.3"
expect(throwsError { try node.validate() }, "a syntax outside the list is refused")
node.retrieveSyntax = "1.2.840.10008.1.2.1"
node.credentialIdentifier = "not-a-uuid"
expect(throwsError { try node.validate() }, "a credential reference is a UUID")
node.credentialIdentifier = ""
node.name = "  "
expect(throwsError { try node.validate() }, "a node needs a name")
node.name = "Main"

// Persistence, unknown keys kept, lookups.
var stored = DICOMwebNode(dictionary: node.dictionaryRepresentation.merging(["FutureKey": "kept"]) { a, _ in a })
let sender = DICOMwebNode(); sender.address = "https://stow.example/dw"; sender.name = "Archive"; sender.send = true; sender.queryRetrieve = false
let incomplete = DICOMwebNode(); incomplete.name = "Draft"; incomplete.send = true
DICOMwebNode.save([stored, sender, incomplete], to: defaults)
let loaded = DICOMwebNode.nodes(in: defaults)
expect(loaded.map { $0.identifier } == [stored.identifier, sender.identifier, incomplete.identifier], "the nodes come back in order")
expect(loaded[0].dictionaryRepresentation["FutureKey"] as? String == "kept", "unknown keys are saved back")
expect(loaded[0].qidoPath == "rs/qido" && loaded[0].retrieveSyntax == "1.2.840.10008.1.2.1", "the values come back")
expect(DICOMwebNode.queryRetrieveNodes(in: defaults).map { $0.name } == ["Main"], "Q&R lookup: valid nodes with Q&R on")
expect(DICOMwebNode.sendNodes(in: defaults).map { $0.name } == ["Archive"], "Send lookup: valid nodes with Send on")
expect(DICOMwebNode.node(withIdentifier: sender.identifier, in: defaults)?.name == "Archive", "a node is found by identifier")
expect(DICOMwebNode.uniqueName("Main", among: loaded) == "Main 2", "a taken name gets a number")
expect(DICOMwebNode.uniqueName("Main", among: loaded, excluding: stored.identifier) == "Main", "a node keeps its own name")
stored = loaded[0]

// Migration of the pilot's nodes.
defaults.removePersistentDomain(forName: suite)
let pilotCredential = UUID().uuidString
DICOMwebCredentials.legacy = [pilotCredential]
let dimseA: [String: Any] = ["AETitle": "PACS", "Address": "10.0.0.4", "Port": "11112", "Description": "Main PACS", "retrieveMode": 0, "QR": true, "Send": true]
let dimseB: [String: Any] = ["AETitle": "ARCH", "Address": "10.0.0.5", "Port": "104", "Description": "Archive", "retrieveMode": 2, "WADOUrl": "wado"]
let pilot: [String: Any] = ["AETitle": "UNUSED", "Address": "0.0.0.0", "Port": "1", "Description": "Orthanc web", "retrieveMode": 3,
                            "DICOMwebURL": "http://127.0.0.1:18042/dicom-web/", "DICOMwebCredentialID": pilotCredential, "Send": false]
let pilotOpen: [String: Any] = ["AETitle": "X", "Address": "1.1.1.1", "Port": "1", "Description": "", "retrieveMode": NSNumber(value: 3),
                                "DICOMwebURL": "https://open.example/dw"]
defaults.set([dimseA, pilot, dimseB, pilotOpen], forKey: "SERVERS")
expect(DICOMwebNode.migrateLegacyServers(in: defaults) == 2, "both pilot entries move")
let servers = defaults.array(forKey: "SERVERS") as! [[String: Any]]
expect(servers.map { $0["AETitle"] as! String } == ["PACS", "ARCH"], "the DIMSE nodes stay, in order")
expect(!servers.contains { ($0["retrieveMode"] as? Int) == 3 }, "no pilot entry is left in SERVERS")
var migrated = DICOMwebNode.nodes(in: defaults)
expect(migrated.count == 2, "two DICOMweb nodes")
let web = migrated[0]
expect(web.address == "http://127.0.0.1:18042/dicom-web" && web.name == "Orthanc web", "URL to Address, description to Name")
expect(web.credentialIdentifier == pilotCredential && web.hasLegacyCredential, "the credential is kept, marked for conversion")
expect(web.queryRetrieve && !web.send && web.retrieveSyntax == "*" && web.sendSyntax == "*", "Q&R on, Send off, As stored")
expect(web.qidoPath.isEmpty && web.wadoPath.isEmpty, "paths empty: the address")
expect(migrated[1].name == "open.example" && migrated[1].credentialIdentifier.isEmpty && !migrated[1].hasLegacyCredential, "no description: the host names it")
let identifiers = migrated.map { $0.identifier }
expect(DICOMwebNode.migrateLegacyServers(in: defaults) == 0, "a second run moves nothing")
expect(DICOMwebNode.nodes(in: defaults).map { $0.identifier } == identifiers, "and changes no node")
// Interrupted after the new list was written, before SERVERS was: no duplicate.
defaults.set([dimseA, pilot, dimseB, pilotOpen], forKey: "SERVERS")
expect(DICOMwebNode.migrateLegacyServers(in: defaults) == 2, "the leftovers leave SERVERS")
expect(DICOMwebNode.nodes(in: defaults).map { $0.identifier } == identifiers, "without a second node for either")
expect((defaults.array(forKey: "SERVERS") as! [[String: Any]]).count == 2, "SERVERS has the DIMSE nodes only")

// The pilot's credentials are converted; one that cannot be read waits.
DICOMwebCredentials.unreadable = [pilotCredential]
expect(DICOMwebNode.migrateLegacyCredentials(in: defaults, store: DICOMwebNode.credentialStore) == 0, "a locked credential is not converted")
expect(DICOMwebNode.nodes(in: defaults)[0].hasLegacyCredential, "and keeps its mark for the next launch")
DICOMwebCredentials.unreadable = []
expect(DICOMwebNode.migrateLegacyCredentials(in: defaults, store: DICOMwebNode.credentialStore) == 1, "then it is converted")
migrated = DICOMwebNode.nodes(in: defaults)
expect(!migrated[0].hasLegacyCredential && migrated[0].credentialIdentifier == pilotCredential, "same identifier, mark cleared")
expect(DICOMwebCredentials.calls.filter { $0.hasPrefix("migrate") } == ["migrate " + pilotCredential], "converted once")

// Authentication decisions.
typealias Auth = DICOMwebAuthentication
expect(try! Auth.resolve(existingSummary: nil, kind: .none, username: "", secret: "", headerName: "") == .keep, "None without a credential: nothing")
expect(try! Auth.resolve(existingSummary: "Bearer", kind: .none, username: "", secret: "", headerName: "") == .remove, "None removes the credential")
expect(try! Auth.resolve(existingSummary: "Basic \u{00B7} alice", kind: .basic, username: "alice", secret: "", headerName: "") == .keep,
       "Basic, same user, empty password: the stored one stays")
expect(throwsError { _ = try Auth.resolve(existingSummary: "Basic \u{00B7} alice", kind: .basic, username: "bob", secret: "", headerName: "") },
       "another user needs the password")
expect(throwsError { _ = try Auth.resolve(existingSummary: nil, kind: .basic, username: "a:b", secret: "x", headerName: "") }, "a colon in the user")
expect(try! Auth.resolve(existingSummary: nil, kind: .basic, username: " alice ", secret: "pw", headerName: "")
       == .store(kind: .basic, username: "alice", secret: "pw", headerName: ""), "Basic stores the user and password")
expect(try! Auth.resolve(existingSummary: "API Key \u{00B7} X-Api-Key", kind: .apiKey, username: "", secret: "", headerName: "x-api-key") == .keep,
       "API key, same header: the stored key stays")
expect(throwsError { _ = try Auth.resolve(existingSummary: nil, kind: .apiKey, username: "", secret: "k", headerName: "Bad Header") }, "a header name is a token")
expect(throwsError { _ = try Auth.resolve(existingSummary: nil, kind: .apiKey, username: "", secret: "k", headerName: "Accept") }, "the client's own headers are refused")
expect(try! Auth.resolve(existingSummary: nil, kind: .apiKey, username: "", secret: "k", headerName: "X-Api-Key")
       == .store(kind: .apiKey, username: "", secret: "k", headerName: "X-Api-Key"), "API key stores the header and key")
expect(throwsError { _ = try Auth.resolve(existingSummary: "Basic \u{00B7} alice", kind: .bearer, username: "", secret: "", headerName: "") },
       "switching to Bearer needs the token")
expect(throwsError { _ = try Auth.resolve(existingSummary: nil, kind: .bearer, username: "", secret: "a\r\nX-Evil: 1", headerName: "") },
       "no line break in a secret")
expect(Auth.parse(summary: "Legacy thing") == nil, "an unknown summary is not guessed")

// Applying: the new credential is stored before the old one is removed.
DICOMwebCredentials.calls = []
let edited = migrated[0]
let old = edited.credentialIdentifier
try! Auth.apply(.store(kind: .bearer, username: "", secret: "token-secret-marker", headerName: ""), to: edited, store: DICOMwebNode.credentialStore)
expect(edited.credentialIdentifier != old && UUID(uuidString: edited.credentialIdentifier) != nil, "a new reference")
expect(DICOMwebCredentials.calls == ["store", "remove " + old], "stored first, then the old one removed")
DICOMwebNode.save(migrated, to: defaults)
let saved = DICOMwebNode.nodes(in: defaults)[0].dictionaryRepresentation
expect(saved["CredentialID"] as? String == edited.credentialIdentifier, "the node keeps only the reference")
let bearer = edited.credentialIdentifier
try! Auth.apply(.remove, to: edited, store: DICOMwebNode.credentialStore)
expect(edited.credentialIdentifier.isEmpty && DICOMwebCredentials.items[bearer] == nil, "None removes the credential and the reference")
expect(edited.dictionaryRepresentation["CredentialID"] == nil, "and the key")
DICOMwebNode.save(migrated, to: defaults)
defaults.synchronize()
// What the preferences hold, for the check for secrets.
let written = defaults.persistentDomain(forName: suite) ?? [:]
(written as NSDictionary).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), atomically: true)
cleanUp()
print("PASS: model")
'''

SERVICE_DRIVER = r'''
import Foundation
// The standard domain of this uniquely named executable, removed at the end.
let defaults = UserDefaults.standard
let domain = ProcessInfo.processInfo.processName
func cleanUp() { defaults.removePersistentDomain(forName: domain); defaults.synchronize() }
func expect(_ ok: Bool, _ reason: String) { if !ok { print("FAIL: " + reason); cleanUp(); exit(1) } }
defaults.set(false, forKey: "searchDICOMBonjour")
defaults.set(false, forKey: "syncDICOMNodes")
let dimse: [String: Any] = ["AETitle": "PACS", "Address": "10.0.0.4", "Port": "11112", "Description": "Main", "retrieveMode": 0, "Activated": true, "Send": true, "QR": true]
let pilot: [String: Any] = ["AETitle": "UNUSED", "Address": "0.0.0.0", "Port": "1", "Description": "Web", "retrieveMode": 3, "DICOMwebURL": "https://x.example/dw", "Activated": true]
let noTitle: [String: Any] = ["Address": "10.0.0.9", "Port": "104", "Description": "No AE", "retrieveMode": 0, "Activated": true]
defaults.set([dimse, pilot, noTitle], forKey: "SERVERS")
for (send, qr) in [(false, false), (true, false), (false, true)] {
    let listed = DICOMNodeService.serversList(sendOnly: send, queryRetrieveOnly: qr).compactMap { ($0 as? [String: Any])?["Description"] as? String }
    expect(listed == ["Main"], "DIMSE readers see only the DIMSE node (send \(send), Q&R \(qr)): \(listed)")
}
expect(DICOMNodeService.isDIMSEServer(dimse) && !DICOMNodeService.isDIMSEServer(pilot) && !DICOMNodeService.isDIMSEServer(noTitle), "the predicate")
// A synced list does not bring a DICOMweb entry back into SERVERS.
let listURL = URL(fileURLWithPath: CommandLine.arguments[1])
(([dimse, pilot, noTitle] as NSArray)).write(to: listURL, atomically: true)
defaults.set(listURL.absoluteString, forKey: "syncDICOMNodesURL")
DICOMNodeService.syncDICOMNodes()
let synced = (defaults.array(forKey: "SERVERS") as? [[String: Any]] ?? []).compactMap { $0["Description"] as? String }
expect(synced == ["Main"], "a synced list keeps only DIMSE nodes: \(synced)")
cleanUp()
print("PASS: node service")
'''


# One name for this check's domains, so a run never leaves a new one behind.
UNIQUE = 'org.horos.test.dicomweb-nodes'


def run_swift(temporary, name, sources, driver, arguments=()):
    """Compiles and runs a driver; returns True when it passed."""
    folder = temporary / name
    folder.mkdir()
    (folder / 'main.swift').write_text(driver)
    executable = folder / f'{UNIQUE}-{name}'
    build = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(temporary / 'module-cache'),
                            *map(str, sources), str(folder / 'main.swift'), '-o', str(executable)],
                           capture_output=True, text=True)
    if build.returncode:
        check(False, f'{name}: the sources do not compile\n{build.stderr[-3000:]}')
        return False
    try:
        result = subprocess.run([str(executable), *arguments], capture_output=True, text=True, timeout=120)
    finally:
        # cfprefsd writes a removed domain back as an empty file some seconds
        # later; only this check's domains are named so.
        for _ in range(40):
            time.sleep(0.25)
            for leftover in (Path.home() / 'Library/Preferences').glob(UNIQUE + '*.plist'):
                leftover.unlink(missing_ok=True)
    sys.stdout.write(result.stdout)
    check(result.returncode == 0, f'{name}: the checks failed\n{result.stderr[-2000:]}')
    return result.returncode == 0


with tempfile.TemporaryDirectory(prefix='horos-dicomweb-nodes-') as folder:
    temporary = Path(folder)
    sources = temporary / 'sources'
    sources.mkdir()
    wanted = {'DICOMwebNode.swift': 'Horos/Sources/DICOMwebNode.swift',
              'DICOMNodeService.swift': 'Horos/Sources/DICOMNodeService.swift'}
    for name, path in wanted.items():
        content = text(path)
        check(content is not None, f'{path} exists')
        if content is not None:
            (sources / name).write_bytes(content.encode('latin1'))
    (sources / 'Credentials.swift').write_text(CREDENTIALS_DOUBLE)
    if not failures:
        exported = temporary / 'written.plist'
        if run_swift(temporary, 'model', [sources / 'DICOMwebNode.swift', sources / 'Credentials.swift'], MODEL_DRIVER,
                     [UNIQUE, str(exported)]):
            # No secret reaches the preferences.
            written = exported.read_bytes()
            check(b'DICOMWEB_SERVERS' in written, 'the nodes were written to the preferences')
            for marker in (b'secret-marker', b'Authorization', b'Basic ', b'Bearer ', b'password'):
                check(marker not in written, f'no {marker!r} in the preferences')
        run_swift(temporary, 'service', [sources / 'DICOMNodeService.swift'], SERVICE_DRIVER,
                  [str(temporary / 'synced-nodes.plist')])

# Source level.
PANE = 'Preference Panes/OSILocationsPreferencePane'
XIBS = {'en': f'{PANE}/Base.lproj/OSILocationsPreferencePanePref.xib',
        'ja-JP': f'{PANE}/ja-JP.lproj/OSILocationsPreferencePanePref.xib'}
COLUMNS = ['Address', 'WADOPath', 'QIDOPath', 'Name', 'QR', 'RetrieveSyntax', 'Auth', 'Send', 'SendSyntax']
HEADERS = ['Address', 'WADO Path', 'QIDO Path', 'Name', 'Q&R', 'Retrieve Syntax', 'Auth', 'Send', 'Send Syntax']
AREA = 'DICOMweb Nodes for DICOM Query/Retrieve and DICOM Send'
visible = {'title', 'label', 'toolTip', 'headerToolTip', 'placeholderString', 'alternateTitle', 'stringValue'}


def structural(node):
    return (node.tag, sorted((k, v) for k, v in node.attrib.items() if k not in visible),
            [structural(child) for child in node])


trees = {}
for language, path in XIBS.items():
    content = text(path)
    if content is None:
        check(False, f'{path} exists')
        continue
    tree = ET.fromstring(content.encode('latin1'))
    trees[language] = tree
    retrieve = tree.find(".//tableColumn[@identifier='RetrieveMode']")
    titles = [item.get('title') for item in retrieve.iter('menuItem')] if retrieve is not None else []
    check(titles == ['C-MOVE', 'C-GET', 'WADO'], f'{language}: the DIMSE Retrieve pop-up is C-MOVE, C-GET, WADO: {titles}')
    check('editDICOMweb:' not in content and 'NotDICOMwebValueTransformer' not in content,
          f'{language}: no DICOMweb editor or Send switch left on the DIMSE rows')
    boxes = {box.get('title'): box for box in tree.iter('box')}
    area = boxes.get(AREA)
    dimse = boxes.get('DICOM Nodes for DICOM Query/Retrieve and DICOM Send')
    check(area is not None, f'{language}: the "{AREA}" area exists')
    if area is None or dimse is None:
        continue
    frame = lambda box: box.find("rect[@key='frame']")
    check(float(frame(area).get('y')) + float(frame(area).get('height')) <= float(frame(dimse).get('y')),
          f'{language}: the DICOMweb area is below the DIMSE one')
    table = area.find('.//tableView')
    columns = [column.get('identifier') for column in table.iter('tableColumn')] if table is not None else []
    headers = [column.find('tableHeaderCell').get('title') for column in table.iter('tableColumn')] if table is not None else []
    check(columns == COLUMNS, f'{language}: the nine columns, in order: {columns}')
    check(headers == HEADERS, f'{language}: the column titles: {headers}')
    controller = next((o for o in tree.iter('customObject') if o.get('customClass') == 'HorosDICOMwebNodesController'), None)
    check(controller is not None, f'{language}: the area has its controller')
    if controller is None or table is None:
        continue
    identifier = controller.get('id')
    outlets = {o.get('property'): o.get('destination') for o in table.iter('outlet')}
    check(outlets.get('dataSource') == identifier and outlets.get('delegate') == identifier,
          f'{language}: the table is the controller\'s')
    actions = {a.get('selector') for a in area.iter('action') if a.get('target') == identifier}
    check({'addNode:', 'removeNode:', 'testNode:'} <= actions, f'{language}: add, remove and test buttons: {actions}')
    owner = tree.find(".//customObject[@id='-2']")
    check(any(o.get('property') == 'dicomwebNodes' and o.get('destination') == identifier for o in owner.iter('outlet')),
          f'{language}: the pane reaches the controller')
    kinds = {column.get('identifier'): column.find("*[@key='dataCell']").tag for column in table.iter('tableColumn')}
    check(kinds['QR'] == kinds['Send'] == 'buttonCell' and kinds['RetrieveSyntax'] == kinds['SendSyntax'] == 'popUpButtonCell',
          f'{language}: Q&R and Send are check boxes, the syntaxes pop-ups')
    auth = next(column for column in table.iter('tableColumn') if column.get('identifier') == 'Auth').find("*[@key='dataCell']")
    check(auth.get('editable') != 'YES', f'{language}: Auth opens the sheet instead of being edited in place')
if len(trees) == 2:
    check(structural(trees['en']) == structural(trees['ja-JP']), 'the Japanese xib has the same structure as the English one')

if not revision and shutil.which('xcrun'):
    # ibtool talks to its daemon through FIFOs it makes in the user's temporary
    # folder and leaves there after it exits; the ones this check made are removed.
    shared = Path(subprocess.run(['getconf', 'DARWIN_USER_TEMP_DIR'], capture_output=True, text=True).stdout.strip() or tempfile.gettempdir())
    before = {entry.name for entry in shared.iterdir()} if shared.is_dir() else set()
    with tempfile.TemporaryDirectory(prefix='horos-dicomweb-nib-') as folder:
        for language, path in XIBS.items():
            result = subprocess.run(['xcrun', 'ibtool', '--errors', '--output-format', 'human-readable-text', '--compile',
                                     str(Path(folder) / f'{language}.nib'), str(root / path)], capture_output=True, text=True)
            check(result.returncode == 0 and 'error' not in result.stdout.lower(), f'{language}: the xib compiles\n{result.stdout}')
    if shared.is_dir():
        for entry in shared.iterdir():
            if entry.name not in before and '-IBTOOLD-' in entry.name:
                entry.unlink(missing_ok=True)

# AppController is Swift: +initialize stayed in AppController+CAPI.m
# and sends +initializeAppController, the Swift body of the former +initialize.
app = text(str(source_path('AppController').relative_to(root))) or ''
capi = text(str(source_path('AppController+CAPI').relative_to(root))) or ''
initialize = app[app.find('class func initializeAppController()'):]
initialize = initialize[:initialize.find('\n    }\n') + 1] if 'class func initializeAppController()' in app else ''
sends = capi[capi.find('+ (void) initialize'):]
sends = sends[:sends.find('\n}') + 1] if '+ (void) initialize' in capi else ''
registered = initialize.find('UserDefaults.standard.register(defaults: (DefaultsOsiriX.getDefaults()')
migration = initialize.find('DICOMwebNode.migrateLegacyServers()')
check('[self initializeAppController];' in sends and 0 <= registered < migration,
      'the migration runs in +initialize, after the defaults are registered')
pbx = text('Horos.xcodeproj/project.pbxproj') or ''
check('DICOMwebNode.swift in Sources' in pbx, 'the model is in the Horos target')
editor = text('Horos/Sources/DICOMwebNodeEditor.swift') or ''
check('DispatchQueue.global' in editor and 'DICOMwebSources.configuration(for: node)' in editor
      and 'DICOMwebClient(node: configuration, timeout: 30).verify()' in editor,
      'Test verifies off the main thread at the node\'s QIDO path with its credential')
check('case Column.trustedCertificate: node.trustedCertificateSHA256 = try DICOMwebServerTrust.normalizedFingerprint(text)' in editor
      and 'column.headerToolTip = DICOMwebServerTrust.help' in editor,
      'the table edits the trusted certificate through its normalization, with its help')
check(editor is not None and 'trustedCertificateSHA256: node.trustedCertificateSHA256' in (text('Horos/Sources/DICOMwebIntegration.swift') or ''),
      'the node\'s trusted certificate reaches its client configuration')
check('DICOMwebAuthentication.apply' in editor and 'credentialStore.remove(identifier: node.credentialIdentifier)' in editor,
      'removing a node removes its credential')
check('try DICOMwebOIDC.signOut(nodeIdentifier: node.identifier)' in editor,
      'removing a node removes its OpenID Connect tokens')
integration = text('Horos/Sources/DICOMwebIntegration.swift') or ''
check('clientIdentityReference: node.clientIdentityReference, authorization: signIn' in integration
      and 'DICOMwebOIDC.authorization(for: node)' in integration,
      "the node's sign-in and client certificate reach its client configuration")
pane = text(f'{PANE}/OSILocationsPreferencePanePref.swift') or ''
check('DICOMwebNodeEditor.edit' not in pane and 'editDICOMweb' not in pane, 'the pilot\'s editor is gone from the DIMSE rows')
for source in (editor, text('Horos/Sources/DICOMwebNode.swift') or ''):
    check(not re.search(r'NSLog\([^)]*(secret|password|token)\b', source, re.I), 'no secret is logged')

if not revision:
    result = subprocess.run([sys.executable, str(root / 'tools/collect-localized-strings.py'), '--check'], capture_output=True, text=True)
    check(result.returncode == 0, 'every new string is in the Italian and Spanish catalogs\n' + result.stdout[-2000:])

if failures:
    print(f'FAIL: {len(failures)} check(s) failed')
    sys.exit(1)
print('PASS: DICOMweb nodes validate, persist without secrets and migrate idempotently with their credential; '
      'DIMSE readers see no DICOMweb entry; the Retrieve pop-up has no DICOMweb and both xibs have the nine-column area')
