#!/usr/bin/env python3
"""DICOMweb credential kinds, format and pilot migration.

Stores None, Basic, API key and Bearer credentials through the Keychain
backend's seam, replaced by an in-memory one, and checks the header each kind
produces byte for byte, the summary shown in Locations, that describing a
credential never reads its secret, that invalid header names and values that
could inject a header are refused, and that a pilot item — only a ready
Authorization value — migrates without its value changing, idempotently.

HOROS_TEST_REAL_KEYCHAIN=1 also runs one round trip through the user's login
keychain with a synthetic secret, removed at the end; without it that part is
not exercised.

Pass a git revision to compile that revision's credentials instead; one that
predates the DICOMweb nodes does not have the API and fails to build.
"""
import os, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
source = r'''
import Foundation
import Security
var failures = 0
func expect(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); failures += 1 } }
final class Memory {
    var items: [String: (data: Data, generic: Data?)] = [:]
    var dataReads = 0
}
let memory = Memory()
DICOMwebCredentials.backend = DICOMwebCredentials.Backend(
    read: { id, wantData in
        guard let item = memory.items[id] else { return nil }
        if wantData { memory.dataReads += 1 }
        return (wantData ? item.data : nil, item.generic)
    },
    add: { id, data, generic in memory.items[id] = (data, generic) },
    update: { id, data, generic in
        guard let item = memory.items[id] else { return false }
        memory.items[id] = (data ?? item.data, generic); return true
    },
    delete: { id in memory.items[id] = nil })

let password = "pw-SYNTHETIC-799", apiKey = "key-SYNTHETIC-799", token = "tok-SYNTHETIC-799"
let basic = try DICOMwebCredentials.store(kind: .basic, username: "reader", secret: password, headerName: "")
expect(UUID(uuidString: basic) != nil, "a new credential gets a UUID")
var header = try DICOMwebCredentials.header(forIdentifier: basic)!
expect(header.name == "Authorization" && header.value == "Basic " + Data("reader:\(password)".utf8).base64EncodedString(),
       "Basic sends Authorization: Basic base64(user:password)")
let key = try DICOMwebCredentials.store(kind: .apiKey, username: "", secret: apiKey, headerName: "X-Api-Key")
header = try DICOMwebCredentials.header(forIdentifier: key)!
expect(header.name == "X-Api-Key" && header.value == apiKey, "API key sends the key verbatim in the named header")
let bearer = try DICOMwebCredentials.store(kind: .bearer, username: "", secret: token, headerName: "")
header = try DICOMwebCredentials.header(forIdentifier: bearer)!
expect(header.name == "Authorization" && header.value == "Bearer " + token, "Bearer sends Authorization: Bearer token")
expect(try DICOMwebCredentials.header(forIdentifier: "") == nil, "no identifier, no header")

// Replacing in place keeps the identifier; None removes the item.
let same = try DICOMwebCredentials.store(kind: .bearer, username: "", secret: token + "b", headerName: "", identifier: basic)
expect(try same == basic && (DICOMwebCredentials.header(forIdentifier: basic)!.value) == "Bearer " + token + "b",
       "storing under an identifier replaces that credential")
expect(try DICOMwebCredentials.store(kind: .none, username: "", secret: "", headerName: "", identifier: basic) == "",
       "None returns no identifier")
expect(memory.items[basic] == nil, "None removes the stored credential")
try DICOMwebCredentials.remove(identifier: key)
expect(memory.items[key] == nil, "remove deletes the item")

// Summaries and descriptions come from the attribute, never from the secret.
let user = try DICOMwebCredentials.store(kind: .basic, username: "reader", secret: password, headerName: "")
let apiItem = try DICOMwebCredentials.store(kind: .apiKey, username: "", secret: apiKey, headerName: "X-Api-Key")
memory.dataReads = 0
expect(DICOMwebCredentials.summary(forIdentifier: "") == "None", "summary None")
expect(DICOMwebCredentials.summary(forIdentifier: user) == "Basic · reader", "summary Basic · user")
expect(DICOMwebCredentials.summary(forIdentifier: apiItem) == "API Key · X-Api-Key", "summary API Key · header")
expect(DICOMwebCredentials.summary(forIdentifier: bearer) == "Bearer", "summary Bearer")
expect(DICOMwebCredentials.summary(forIdentifier: UUID().uuidString) == "Unavailable", "a missing item is Unavailable")
let described = try DICOMwebCredentials.describe(identifier: apiItem)
expect(described.kind == .apiKey && described.headerName == "X-Api-Key" && described.username.isEmpty, "describe an API key")
expect(memory.dataReads == 0, "describing a current credential reads no secret (\(memory.dataReads) reads)")
for (_, item) in memory.items {
    let attribute = String(data: item.generic ?? Data(), encoding: .utf8) ?? ""
    expect(!attribute.contains(password) && !attribute.contains(apiKey) && !attribute.contains(token), "no secret in the attribute")
}
let printed = String(describing: try DICOMwebCredentials.objcHeader(forIdentifier: apiItem))
expect(!printed.contains(apiKey), "a header object never prints its value")

// Refused input: nothing that could add or smuggle a header.
for (kind, name, user, secret) in [
    (DICOMwebCredentialKind.apiKey, "Host", "", "k"), (.apiKey, "Content-Type", "", "k"), (.apiKey, "X Api", "", "k"),
    (.apiKey, "X-Api-Key\r\nX-Evil", "", "k"), (.apiKey, "", "", "k"), (.apiKey, "X-Api-Key", "", "k\r\nX-Evil: 1"),
    (.bearer, "", "", "tok en"), (.bearer, "", "", "t\n"), (.bearer, "", "", ""),
    (.basic, "", "a:b", "p"), (.basic, "", "", "p"), (.basic, "", "u", ""), (.basic, "", "u", "p\r\n"),
] as [(DICOMwebCredentialKind, String, String, String)] {
    let before = memory.items.count
    do { _ = try DICOMwebCredentials.store(kind: kind, username: user, secret: secret, headerName: name); expect(false, "accepted \(kind.rawValue) \(name.debugDescription)") }
    catch { expect(!(error as NSError).localizedDescription.contains(secret) || secret.count < 2, "the error does not echo the secret") }
    expect(memory.items.count == before, "a refused credential stores nothing")
}

// Pilot items: only the ready Authorization value, no attribute.
func legacy(_ value: String) -> String {
    let id = UUID().uuidString; memory.items[id] = (Data(value.utf8), nil); return id
}
let pilotBasic = legacy("Basic " + Data("pilot:\(password)".utf8).base64EncodedString())
let pilotBearer = legacy("Bearer " + token)
let pilotOther = legacy("Token " + token)
let originals = [pilotBasic, pilotBearer, pilotOther].map { memory.items[$0]!.data }
expect(try DICOMwebCredentials.header(forIdentifier: pilotBasic)!.name == "Authorization", "a pilot item is still sent as Authorization")
expect(DICOMwebCredentials.summary(forIdentifier: pilotBasic) == "Basic · pilot", "a pilot item is described from its value")
for id in [pilotBasic, pilotBearer, pilotOther] { expect(try DICOMwebCredentials.migrateLegacy(identifier: id), "the pilot item migrates") }
for (id, original) in zip([pilotBasic, pilotBearer, pilotOther], originals) {
    expect(memory.items[id]!.data == original, "migration keeps the value byte for byte")
    expect(try DICOMwebCredentials.header(forIdentifier: id)!.value == String(data: original, encoding: .utf8)!, "and sends it unchanged")
    expect(try !DICOMwebCredentials.migrateLegacy(identifier: id), "a second migration changes nothing")
}
expect(DICOMwebCredentials.summary(forIdentifier: pilotBasic) == "Basic · pilot", "migrated Basic keeps its username")
expect(DICOMwebCredentials.summary(forIdentifier: pilotBearer) == "Bearer", "migrated Bearer")
expect(DICOMwebCredentials.summary(forIdentifier: pilotOther) == "API Key · Authorization", "any other value becomes an Authorization header")
expect(try !DICOMwebCredentials.migrateLegacy(identifier: user), "a current item is left alone")
expect(try !DICOMwebCredentials.migrateLegacy(identifier: ""), "no identifier, nothing to migrate")
do { _ = try DICOMwebCredentials.migrateLegacy(identifier: UUID().uuidString); expect(false, "migrated a missing item") } catch {}
do { _ = try DICOMwebCredentials.header(forIdentifier: "not-a-uuid"); expect(false, "accepted a non-UUID identifier") } catch {}

// Security failures and cancellation preserve their existing public contracts.
let savedBackend = DICOMwebCredentials.backend
for status in [errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
    DICOMwebCredentials.backend = DICOMwebCredentials.Backend(
        read: { _, _ in throw NSError(domain: "NSOSStatusErrorDomain", code: Int(status)) },
        add: { _, _, _ in }, update: { _, _, _ in false }, delete: { _ in })
    do { _ = try DICOMwebCredentials.header(forIdentifier: user); expect(false, "accepted a failed keychain read") }
    catch { expect((error as NSError).code == Int(status), "Security failure status preserved") }
}
DICOMwebCredentials.backend = savedBackend
do {
    _ = try DICOMwebCredentials.withDeadline(timeout: 1, cancelled: { true }) { () -> String in
        fatalError("a cancelled operation must not start reading the keychain")
    }
    expect(false, "cancelled read succeeded")
} catch { expect((error as NSError).code == NSURLErrorCancelled, "cancellation remains URL cancellation") }

if ProcessInfo.processInfo.environment["HOROS_TEST_REAL_KEYCHAIN"] == "1" {
    DICOMwebCredentials.backend = .keychain
    let id = try DICOMwebCredentials.store(kind: .apiKey, username: "", secret: apiKey, headerName: "X-Api-Key")
    defer { try? DICOMwebCredentials.remove(identifier: id) }
    let real = try DICOMwebCredentials.header(forIdentifier: id)!
    expect(real.name == "X-Api-Key" && real.value == apiKey, "the login keychain returns the header")
    expect(DICOMwebCredentials.summary(forIdentifier: id) == "API Key · X-Api-Key", "and describes it")
    try DICOMwebCredentials.remove(identifier: id)
    expect(DICOMwebCredentials.summary(forIdentifier: id) == "Unavailable", "and removes it")
    print("login keychain round trip exercised")
}
if failures > 0 { exit(1) }
print("PASS: None/Basic/API key/Bearer headers, summaries without secrets, refused header injection, idempotent lossless pilot migration")
'''
with tempfile.TemporaryDirectory(prefix='horos-dicomweb-credentials-') as tmp:
    p = Path(tmp)
    (p / 'main.swift').write_text(source if revision else 'import Foundation\nif NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }\n' + source)
    name = 'DICOMwebCredentials.swift'
    if revision:
        (p / name).write_bytes(subprocess.check_output(['git', 'show', f'{revision}:Horos/Sources/{name}'], cwd=root))
        credentials = p / name
    else:
        credentials = root / 'Horos/Sources' / name
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', str(credentials), *([] if revision else [str(root / 'Horos/Sources/NonInteractiveKeychainRead.swift')]), str(p / 'main.swift'),
                    '-o', str(p / 'check')], check=True)
    subprocess.run([str(p / 'check')], check=True, timeout=60)
