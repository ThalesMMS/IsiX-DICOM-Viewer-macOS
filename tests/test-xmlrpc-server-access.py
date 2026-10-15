#!/usr/bin/env python3
"""The XML-RPC interface answers this computer by default and authenticates other computers."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
main = r'''import AppKit
if NonInteractiveKeychainRead.runHelperIfRequested() { exit(0) }

// Loopback recognition covers the whole 127/8 block and the forms a dual-stack
// accept produces, since that is what N2ConnectionListener reports as the peer.
// The code under test is the main actor's.
MainActor.assumeIsolated {
for address in ["127.0.0.1", "127.1.2.3", "127.255.255.255", "::1", "0:0:0:0:0:0:0:1",
                "::ffff:127.0.0.1", "::FFFF:127.0.0.1", "::1%lo0"] {
    assert(XMLRPCServerAccess.isLoopbackAddress(address), "expected loopback: \(address)")
}
for address in ["128.0.0.1", "10.0.0.4", "100.89.33.90", "::ffff:10.0.0.4", "2001:db8::1",
                "", "127.0.0", "127.0.0.256", "localhost"] {
    assert(!XMLRPCServerAccess.isLoopbackAddress(address), "expected remote: \(address)")
}
assert(!XMLRPCServerAccess.isLoopbackAddress(nil))

// This computer is loopback or any address its interfaces hold, however the
// accept wrote it: a RIS on the same Mac often calls the machine's own network
// address, which Horos and OsiriX answer.
let interfaces: Set<[UInt8]> = Set(["192.168.1.20", "fe80::1", "2001:db8::20"].map { XMLRPCServerAccess.addressBytes($0)! })
for address in ["127.0.0.1", "::1", "192.168.1.20", "::ffff:192.168.1.20", "fe80::1%en0",
                "2001:db8::20", "2001:0db8:0:0:0:0:0:20"] {
    assert(XMLRPCServerAccess.isLocalAddress(address, interfaceAddresses: interfaces), "expected local: \(address)")
}
for address in ["192.168.1.21", "::ffff:192.168.1.21", "2001:db8::21", "fe80::2", "", "localhost"] {
    assert(!XMLRPCServerAccess.isLocalAddress(address, interfaceAddresses: interfaces), "expected other: \(address)")
}
assert(!XMLRPCServerAccess.isLocalAddress(nil, interfaceAddresses: interfaces))
// The real interface list holds loopback, so it is being read at all.
let current = XMLRPCServerAccess.currentInterfaceAddresses()
assert(current.contains([127, 0, 0, 1]))
// Every address this Mac holds right now counts as this computer.
for bytes in current where bytes.count == 4 {
    let text = bytes.map(String.init).joined(separator: ".")
    assert(XMLRPCServerAccess.isLocalAddress(text), "expected this Mac: \(text)")
}

// The local network is what cannot be routed from the internet, the intranet
// option of OsiriX, plus the block VPNs such as Tailscale hand out.
for address in ["10.0.0.4", "172.16.0.1", "172.31.255.255", "192.168.1.21", "169.254.3.4",
                "100.64.0.1", "100.89.33.90", "100.127.255.255", "::ffff:192.168.1.21",
                "fd12:3456::1", "fc00::1", "fe80::2%en0", "febf::1"] {
    assert(XMLRPCServerAccess.isPrivateNetworkAddress(address), "expected local network: \(address)")
}
for address in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "100.63.255.255", "100.128.0.1",
                "::ffff:8.8.8.8", "2001:db8::21", "fec0::1", "", "localhost"] {
    assert(!XMLRPCServerAccess.isPrivateNetworkAddress(address), "expected outside: \(address)")
}
assert(!XMLRPCServerAccess.isPrivateNetworkAddress(nil))

let credential = XMLRPCServerAccess.basicHeader(username: "ris", password: "s3cret")!
assert(credential == "Basic cmlzOnMzY3JldA==")
assert(XMLRPCServerAccess.basicHeader(username: "ris:2", password: "x") == nil)
assert(XMLRPCServerAccess.basicHeader(username: "ris", password: "") == nil)
assert(XMLRPCServerAccess.basicHeader(username: "", password: "x") == nil)
assert(XMLRPCServerAccess.basicHeader(username: "ris", password: "a\nb") == nil)

// The rules, in order: this Mac, then the listed addresses, then the scope,
// then the password. The credential is read only when it is needed.
@MainActor func decide(_ peer: String?, _ authorization: String?, _ credential: String?,
                       scope: XMLRPCAccessScope, requirePassword: Bool = true, listed: String = "") -> XMLRPCAccessDecision {
    let policy = XMLRPCAccessPolicy(scope: scope, requirePassword: requirePassword,
                                    allowedAddresses: XMLRPCAllowedAddresses(text: listed))
    return policy.decision(isLocal: XMLRPCServerAccess.isLocalAddress(peer, interfaceAddresses: interfaces),
                           isListed: policy.allowedAddresses.contains(peer),
                           isPrivate: XMLRPCServerAccess.isPrivateNetworkAddress(peer),
                           authorization: authorization, credential: { credential })
}
// This Mac, through any of its addresses, needs nothing, whatever the settings.
for scope in [XMLRPCAccessScope.thisMac, .localNetwork, .anyAddress] {
    assert(decide("127.0.0.1", nil, nil, scope: scope) == .allow)
    assert(decide("::1", "Basic cmlzOndyb25n", credential, scope: scope) == .allow)
    assert(decide("192.168.1.20", nil, nil, scope: scope) == .allow)
    assert(decide("::ffff:192.168.1.20", nil, nil, scope: scope) == .allow)
}
// This Mac only: every other computer is refused, password or not.
assert(decide("192.168.1.21", credential, credential, scope: .thisMac) == .refuse)
assert(decide("192.168.1.21", nil, nil, scope: .thisMac, requirePassword: false) == .refuse)
assert(decide(nil, nil, nil, scope: .thisMac) == .refuse)
// The local network, with the password (the default).
assert(decide("192.168.1.21", nil, credential, scope: .localNetwork) == .challenge)
assert(decide("192.168.1.21", "", credential, scope: .localNetwork) == .challenge)
assert(decide("192.168.1.21", "Basic cmlzOndyb25n", credential, scope: .localNetwork) == .challenge)
assert(decide("192.168.1.21", credential.lowercased(), credential, scope: .localNetwork) == .challenge)
assert(decide("192.168.1.21", credential + " ", credential, scope: .localNetwork) == .challenge)
assert(decide("192.168.1.21", credential, credential, scope: .localNetwork) == .allow)
assert(decide("100.89.33.90", credential, credential, scope: .localNetwork) == .allow)
assert(decide("8.8.8.8", credential, credential, scope: .localNetwork) == .refuseOutsideLocalNetwork)
// No password set yet: refused, rather than let in.
assert(decide("192.168.1.21", credential, nil, scope: .localNetwork) == .refuseNoPasswordSet)
assert(decide("192.168.1.21", credential, "", scope: .anyAddress) == .refuseNoPasswordSet)
// Any address, with and without the password.
assert(decide("8.8.8.8", nil, credential, scope: .anyAddress) == .challenge)
assert(decide("8.8.8.8", credential, credential, scope: .anyAddress) == .allow)
assert(decide("8.8.8.8", nil, nil, scope: .anyAddress, requirePassword: false) == .allow)
// Without the password, as Horos and OsiriX, within the scope only.
assert(decide("192.168.1.21", nil, nil, scope: .localNetwork, requirePassword: false) == .allow)
assert(decide("8.8.8.8", nil, nil, scope: .localNetwork, requirePassword: false) == .refuseOutsideLocalNetwork)
// A listed address needs nothing, even with this Mac only and outside the
// local network: the RIS that cannot send a password, and only it.
assert(decide("10.0.5.7", nil, nil, scope: .thisMac, listed: "10.0.5.0/24") == .allow)
assert(decide("10.0.6.7", nil, nil, scope: .thisMac, listed: "10.0.5.0/24") == .refuse)
assert(decide("8.8.8.8", nil, nil, scope: .localNetwork, listed: "192.168.1.50, 8.8.8.8") == .allow)
assert(decide("192.168.1.50", nil, credential, scope: .localNetwork, listed: "192.168.1.50") == .allow)
assert(decide("192.168.1.51", nil, credential, scope: .localNetwork, listed: "192.168.1.50") == .challenge)

// The list: addresses and blocks, IPv4 and IPv6, separated by commas,
// semicolons, spaces or new lines; what is not one is reported, not guessed.
let list = XMLRPCAllowedAddresses(text: " 192.168.1.50,10.0.5.0/24;\nfd00::/8  2001:db8::1 bogus 10.0.0.0/33 300.1.1.1 ::ffff:172.16.0.0/112 ")
assert(list.invalidEntries == ["bogus", "10.0.0.0/33", "300.1.1.1"], "\(list.invalidEntries)")
for address in ["192.168.1.50", "::ffff:192.168.1.50", "10.0.5.0", "10.0.5.255", "fd12::9", "2001:db8::1",
                "2001:0db8:0:0:0:0:0:1", "fe80::1%en0"] where address != "fe80::1%en0" {
    assert(list.contains(address), "expected listed: \(address)")
}
for address in ["192.168.1.51", "10.0.6.1", "fe80::1", "2001:db8::2", "8.8.8.8", "", "localhost"] {
    assert(!list.contains(address), "expected not listed: \(address)")
}
assert(!list.contains(nil))
assert(XMLRPCAllowedAddresses(text: "").isEmpty && XMLRPCAllowedAddresses(text: nil).isEmpty)
assert(XMLRPCAllowedAddresses(text: "0.0.0.0/0").contains("8.8.8.8"))
assert(XMLRPCAllowedAddresses(text: "10.0.0.1/8").contains("10.200.0.1"))

// What the pane says, and how loudly.
func summary(_ scope: XMLRPCAccessScope, _ password: Bool, _ credential: Bool, _ listed: String = "") -> XMLRPCAccessPolicy.Severity {
    return XMLRPCAccessPolicy(scope: scope, requirePassword: password, allowedAddresses: XMLRPCAllowedAddresses(text: listed))
        .summary(hasCredential: credential).severity
}
assert(summary(.thisMac, true, false) == .normal)
assert(summary(.localNetwork, true, false) == .caution)
assert(summary(.localNetwork, true, true) == .normal)
assert(summary(.localNetwork, false, false) == .danger)
assert(summary(.anyAddress, false, true) == .danger)
assert(summary(.thisMac, true, false, "nonsense") == .danger)
assert(XMLRPCAccessPolicy(scope: .thisMac, requirePassword: true, allowedAddresses: XMLRPCAllowedAddresses(text: "1.2.3.4"))
        .summary(hasCredential: false).text.contains("listed addresses"))
assert(!XMLRPCAccessPolicy(scope: .thisMac, requirePassword: false, allowedAddresses: XMLRPCAllowedAddresses(text: "")).answersOtherComputersWithoutPassword)
assert(XMLRPCAccessPolicy(scope: .localNetwork, requirePassword: false, allowedAddresses: XMLRPCAllowedAddresses(text: "")).answersOtherComputersWithoutPassword)

// The scope earlier versions kept in two switches.
assert(XMLRPCServerAccess.migratedScope(allowRemote: nil, localNetworkOnly: nil) == nil)
assert(XMLRPCServerAccess.migratedScope(allowRemote: nil, localNetworkOnly: false) == nil)
assert(XMLRPCServerAccess.migratedScope(allowRemote: false, localNetworkOnly: false) == .thisMac)
assert(XMLRPCServerAccess.migratedScope(allowRemote: "0", localNetworkOnly: nil) == .thisMac)
assert(XMLRPCServerAccess.migratedScope(allowRemote: true, localNetworkOnly: nil) == .localNetwork)
assert(XMLRPCServerAccess.migratedScope(allowRemote: "1", localNetworkOnly: true) == .localNetwork)
assert(XMLRPCServerAccess.migratedScope(allowRemote: true, localNetworkOnly: false) == .anyAddress)
let suiteName = "isix.tests.xmlrpc-migration." + UUID().uuidString
let suite = UserDefaults(suiteName: suiteName)!
suite.set(true, forKey: "httpXMLRPCServerAllowRemote")
suite.set(false, forKey: "httpXMLRPCServerLocalNetworkOnly")
XMLRPCServerAccess.migrateLegacyPreferences(in: suite)
assert(suite.integer(forKey: XMLRPCServerAccess.accessScopeKey) == XMLRPCAccessScope.anyAddress.rawValue)
assert(suite.object(forKey: "httpXMLRPCServerAllowRemote") == nil && suite.object(forKey: "httpXMLRPCServerLocalNetworkOnly") == nil)
suite.set(XMLRPCAccessScope.thisMac.rawValue, forKey: XMLRPCServerAccess.accessScopeKey)
XMLRPCServerAccess.migrateLegacyPreferences(in: suite)
assert(suite.integer(forKey: XMLRPCServerAccess.accessScopeKey) == XMLRPCAccessScope.thisMac.rawValue, "migrates once")
suite.removePersistentDomain(forName: suiteName)
let policy = XMLRPCAccessPolicy.policy(from: UserDefaults(suiteName: suiteName)!)
assert(policy.scope == .thisMac && !policy.requirePassword && policy.allowedAddresses.isEmpty, "unregistered defaults read as closed")
UserDefaults.standard.removePersistentDomain(forName: suiteName)

assert(XMLRPCServerAccess.challengeHeaderValue.contains("Basic realm=\"Isis DICOM Viewer XML-RPC\""))
assert(XMLRPCServerAccess.exposureWarning.contains("patient names"))
assert(XMLRPCServerAccess.unauthenticatedExposureWarning.contains("patient names"))

// The password sheet refuses a credential that cannot be carried, shows the
// stored user name and never a password read back from the keychain.
typealias Settings = XMLRPCRemoteAccessPanel.Settings
assert(Settings(username: "ris", password: "").refusal != nil)
assert(Settings(username: "", password: "s3cret").refusal != nil)
assert(Settings(username: "ris:2", password: "s3cret").refusal != nil)
assert(Settings(username: "ris", password: "s3cret").refusal == nil)
let sheet = XMLRPCRemoteAccessPanel.shared.makeSheet(settings: Settings(username: "ris", password: ""))
let fields = sheet.contentView!.subviews.compactMap { $0 as? NSTextField }
assert(fields.contains { $0.stringValue == "ris" })
assert(fields.contains { $0.stringValue.contains("patient names") })
assert(sheet.contentView!.subviews.contains { ($0 as? NSSecureTextField)?.stringValue == "" })
assert(XMLRPCRemoteAccessPanel.shared.settings == Settings(username: "ris", password: ""))

print("PASS: this Mac through any of its addresses, listed addresses, scope, optional password, migration, password sheet")
}
'''
with tempfile.TemporaryDirectory(prefix="horos-xmlrpc-access-") as tmp:
    p = Path(tmp)
    (p / "main.swift").write_text(main)
    subprocess.run(["swiftc", "-suppress-warnings",
                    str(root / "Horos/Sources/XMLRPCServerAccess.swift"),
                    str(root / "Horos/Sources/NonInteractiveKeychainRead.swift"),
                    str(root / "Horos/Sources/XMLRPCRemoteAccessPanel.swift"),
                    str(p / "main.swift"), "-o", str(p / "test")], check=True)
    subprocess.run([str(p / "test")], check=True)
