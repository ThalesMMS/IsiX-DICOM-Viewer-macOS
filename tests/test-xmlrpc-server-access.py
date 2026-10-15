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

// The preference alone never lets another computer in: while a password is
// required, a credential is a precondition. Without the password, as in Horos
// and OsiriX, the preference is enough.
assert(!XMLRPCServerAccess.answersOtherComputers(allowRemote: false, requirePassword: true, hasCredential: false))
assert(!XMLRPCServerAccess.answersOtherComputers(allowRemote: false, requirePassword: true, hasCredential: true))
assert(!XMLRPCServerAccess.answersOtherComputers(allowRemote: true, requirePassword: true, hasCredential: false))
assert(XMLRPCServerAccess.answersOtherComputers(allowRemote: true, requirePassword: true, hasCredential: true))
assert(!XMLRPCServerAccess.answersOtherComputers(allowRemote: false, requirePassword: false, hasCredential: false))
assert(XMLRPCServerAccess.answersOtherComputers(allowRemote: true, requirePassword: false, hasCredential: false))

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

// This computer is answered with no credential at all, through any of its
// addresses, and another computer is refused outright unless remote access is on.
@MainActor func decide(_ peer: String?, _ authorization: String?, _ credential: String?, _ others: Bool,
                       requirePassword: Bool = true, localNetworkOnly: Bool = true) -> XMLRPCAccessDecision {
    return XMLRPCServerAccess.decision(isLocal: XMLRPCServerAccess.isLocalAddress(peer, interfaceAddresses: interfaces),
                                       isPrivate: XMLRPCServerAccess.isPrivateNetworkAddress(peer),
                                       authorization: authorization,
                                       credential: credential, answersOtherComputers: others,
                                       requirePassword: requirePassword, localNetworkOnly: localNetworkOnly)
}
assert(decide("127.0.0.1", nil, nil, false) == .allow)
assert(decide("::1", nil, credential, false) == .allow)
assert(decide("192.168.1.20", nil, nil, false) == .allow)
assert(decide("::ffff:192.168.1.20", nil, nil, false) == .allow)
assert(decide("100.89.33.90", nil, nil, false) == .refuse)
assert(decide("100.89.33.90", credential, credential, false) == .refuse)
assert(decide(nil, nil, nil, false) == .refuse)

// Answering other computers: every call from them is authenticated, and this
// computer still needs none.
assert(decide("100.89.33.90", nil, credential, true) == .challenge)
assert(decide("100.89.33.90", "", credential, true) == .challenge)
assert(decide("100.89.33.90", "Basic cmlzOndyb25n", credential, true) == .challenge)
assert(decide("100.89.33.90", credential.lowercased(), credential, true) == .challenge)
assert(decide("100.89.33.90", credential + " ", credential, true) == .challenge)
assert(decide("100.89.33.90", credential, credential, true) == .allow)
assert(decide("127.0.0.1", nil, credential, true) == .allow)
assert(decide("192.168.1.20", nil, credential, true) == .allow)
assert(decide("127.0.0.1", "Basic cmlzOndyb25n", credential, true) == .allow)
// A listener that lost its credential refuses rather than falling open.
assert(decide("100.89.33.90", credential, nil, true) == .refuse)
assert(decide("100.89.33.90", credential, "", true) == .refuse)

// Local network only, the default: an internet address is refused before any
// credential is looked at; turned off, it is asked for the password as usual.
assert(decide("8.8.8.8", credential, credential, true) == .refuseOutsideLocalNetwork)
assert(decide("8.8.8.8", nil, nil, true, requirePassword: false) == .refuseOutsideLocalNetwork)
assert(decide("8.8.8.8", nil, credential, true, localNetworkOnly: false) == .challenge)
assert(decide("8.8.8.8", credential, credential, true, localNetworkOnly: false) == .allow)
// Without a password, as Horos and OsiriX: other computers are answered with
// none, from the local network or, with that option off too, from anywhere.
assert(decide("192.168.1.21", nil, nil, true, requirePassword: false) == .allow)
assert(decide("192.168.1.21", "Basic cmlzOndyb25n", nil, true, requirePassword: false) == .allow)
assert(decide("8.8.8.8", nil, nil, true, requirePassword: false, localNetworkOnly: false) == .allow)
// Remote access off still refuses every other computer, whatever the options.
assert(decide("192.168.1.21", nil, nil, false, requirePassword: false, localNetworkOnly: false) == .refuse)
assert(decide("192.168.1.20", nil, nil, false, requirePassword: false, localNetworkOnly: false) == .allow)

assert(XMLRPCServerAccess.challengeHeaderValue.contains("Basic realm=\"Isis DICOM Viewer XML-RPC\""))
assert(XMLRPCServerAccess.exposureWarning.contains("patient names"))
assert(XMLRPCServerAccess.unauthenticatedExposureWarning.contains("patient names"))
assert(XMLRPCServerAccess.unauthenticatedExposureWarning.contains("Without a password"))

// The sheet refuses to enable remote access without a usable credential, and
// never asks for one to turn it off.
typealias Settings = XMLRPCRemoteAccessPanel.Settings
assert(Settings(allowRemote: false, username: "", password: "").refusal == nil)
assert(Settings(allowRemote: false, username: "ris", password: "").refusal == nil)
assert(Settings(allowRemote: true, username: "ris", password: "").refusal != nil)
assert(Settings(allowRemote: true, username: "", password: "s3cret").refusal != nil)
assert(Settings(allowRemote: true, username: "ris:2", password: "s3cret").refusal != nil)
assert(Settings(allowRemote: true, username: "ris", password: "s3cret").refusal == nil)
// No password required: nothing to type.
assert(Settings(allowRemote: true, requirePassword: false, username: "", password: "").refusal == nil)
assert(Settings(allowRemote: true, requirePassword: false, localNetworkOnly: false, username: "", password: "").refusal == nil)

// The button goes in the empty space beside the port field, found through the
// binding rather than through a nib outlet, and never over another control.
let parent = NSView(frame: NSRect(x: 0, y: 0, width: 587, height: 213))
let port = NSTextField(frame: NSRect(x: 361, y: 53, width: 96, height: 19))
port.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.httpXMLRPCServerPort", options: nil)
let other = NSTextField(frame: NSRect(x: 15, y: 53, width: 200, height: 19))
parent.addSubview(other)
parent.addSubview(port)

let button = XMLRPCRemoteAccessPanel.install(in: parent)!
assert(button.frame.minX > port.frame.maxX)
assert(button.frame.maxX <= parent.bounds.width)
assert(!button.frame.intersects(port.frame) && !button.frame.intersects(other.frame))
assert(button.superview === parent)
// Installing twice keeps one button.
assert(XMLRPCRemoteAccessPanel.install(in: parent) === button)
assert(parent.subviews.filter { $0 is NSButton }.count == 1)

// A pane without the field, or without room, gets no button drawn over it.
assert(XMLRPCRemoteAccessPanel.install(in: NSView(frame: NSRect(x: 0, y: 0, width: 587, height: 213))) == nil)
let narrow = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 213))
let narrowPort = NSTextField(frame: NSRect(x: 361, y: 53, width: 96, height: 19))
narrowPort.bind(.value, to: NSUserDefaultsController.shared, withKeyPath: "values.httpXMLRPCServerPort", options: nil)
narrow.addSubview(narrowPort)
assert(XMLRPCRemoteAccessPanel.install(in: narrow) == nil)

// The sheet shows the stored user name and the exposure warning, never a
// password read back from the keychain.
let sheet = XMLRPCRemoteAccessPanel.shared.makeSheet(
    settings: Settings(allowRemote: true, username: "ris", password: ""))
let fields = sheet.contentView!.subviews.compactMap { $0 as? NSTextField }
assert(fields.contains { $0.stringValue == "ris" })
assert(fields.contains { $0.stringValue.contains("patient names") })
assert(sheet.contentView!.subviews.contains { ($0 as? NSSecureTextField)?.stringValue == "" })
assert(XMLRPCRemoteAccessPanel.shared.settings == Settings(allowRemote: true, username: "ris", password: ""))

// Without the password the sheet says so in red, and the credential fields are
// off; with remote access off, the options that only apply to it are off too.
let open = XMLRPCRemoteAccessPanel.shared.makeSheet(
    settings: Settings(allowRemote: true, requirePassword: false, localNetworkOnly: false, username: "", password: ""))
assert(XMLRPCRemoteAccessPanel.shared.settings == Settings(allowRemote: true, requirePassword: false, localNetworkOnly: false, username: "", password: ""))
let openFields = open.contentView!.subviews.compactMap { $0 as? NSTextField }
assert(openFields.contains { $0.stringValue == XMLRPCServerAccess.unauthenticatedExposureWarning && $0.textColor == .systemRed })
assert(open.contentView!.subviews.compactMap { $0 as? NSSecureTextField }.allSatisfy { !$0.isEnabled })
let off = XMLRPCRemoteAccessPanel.shared.makeSheet(settings: Settings(allowRemote: false, username: "", password: ""))
let offBoxes = off.contentView!.subviews.compactMap { $0 as? NSButton }.filter { $0.action == #selector(XMLRPCRemoteAccessPanel.optionsChanged(_:)) }
assert(offBoxes.count == 3)
assert(offBoxes.filter { $0.isEnabled }.count == 1)
assert(off.contentView!.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue == XMLRPCServerAccess.exposureWarning })

print("PASS: this computer through any of its addresses, remote access with optional password and local-network limit, refusal before dispatch, pane button")
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
