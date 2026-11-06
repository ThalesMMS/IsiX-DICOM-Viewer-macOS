//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Security

/// What to do with an XML-RPC request before any method is dispatched.
@objc(HorosXMLRPCAccessDecision)
public enum XMLRPCAccessDecision: Int {
    /// Dispatch the request.
    case allow
    /// Answer `401` with a `WWW-Authenticate` challenge: the interface wants a
    /// credential and the request either carried none or carried a wrong one.
    case challenge
    /// Answer `403` and dispatch nothing: other computers are not answered.
    case refuse
    /// Answer `403` and dispatch nothing: other computers are answered, but
    /// only from the local network, and this peer is outside it.
    case refuseOutsideLocalNetwork
    /// Answer `403` and dispatch nothing: other computers have to send a
    /// password, and none is set to check it against.
    case refuseNoPasswordSet
}

/// Which other computers the XML-RPC interface answers. This Mac is always
/// answered, whichever of its addresses a call is sent to.
@objc(HorosXMLRPCAccessScope)
public enum XMLRPCAccessScope: Int {
    case thisMac = 0
    /// Private addresses only, as the intranet option of OsiriX.
    case localNetwork = 1
    case anyAddress = 2
}

/// Who the XML-RPC interface answers.
///
/// The interface publishes `KillOsiriX`, `Retrieve`, `DownloadURL` and
/// `dbwindowfind` - the last one returns the contents of the database, patient
/// names and identifiers included. Horos answered every host that could reach
/// the machine and asked for no credential at all, so turning the preference on
/// for a local script published the database to the network.
///
/// The rules, in the order they are applied to a call:
///
/// 1. A call made on this Mac is answered without a credential, as Horos and
///    OsiriX answer it, whichever of the Mac's addresses it is sent to. A RIS on
///    the same Mac often calls the machine's network address rather than
///    `127.0.0.1`, so the socket listens on every interface and the peer address
///    decides, not the interface the call arrived on.
/// 2. An address in the user's list is answered without a credential, whatever
///    the other settings: a RIS on another computer that cannot send a password
///    is let in without opening the interface to the rest of the network.
/// 3. Other computers are answered only within the scope the user chose: none,
///    the local network, or any address.
/// 4. Within it, they send the user name and password, unless the user turned
///    that off, which is what Horos and OsiriX do for every caller. While a
///    password is required and none is set, they are refused.
@objc(HorosXMLRPCServerAccess)
public final class XMLRPCServerAccess: NSObject {
    /// The `XMLRPCAccessScope` other computers are answered within.
    @objc public static let accessScopeKey = "httpXMLRPCServerAccessScope"
    /// Whether other computers send the user name and password. Off by default,
    /// as in Horos and OsiriX.
    @objc public static let requirePasswordKey = "httpXMLRPCServerRequirePassword"
    /// Addresses and blocks answered without a credential, as typed by the user.
    @objc public static let allowedAddressesKey = "httpXMLRPCServerAllowedAddresses"
    /// Whether the interface speaks HTTPS instead of HTTP.
    @objc public static let httpsKey = "httpXMLRPCServerHTTPS"
    /// Whether an order is answered with an empty `200` at once, before it runs,
    /// instead of with its result.
    @objc public static let doNotRespondKey = "httpXMLRPCServerDoNotRespond"
    /// How many seconds an order to open a study waits for it to arrive when it
    /// is not in the database yet. 0, the default, answers at once, as Horos.
    @objc public static let waitForStudyKey = "httpXMLRPCServerWaitForStudy"

    /// Earlier versions kept the scope in two switches: remote access on or
    /// off, and, once on, the local network only or not.
    static let allowRemoteKey = "httpXMLRPCServerAllowRemote"
    static let localNetworkOnlyKey = "httpXMLRPCServerLocalNetworkOnly"

    /// The realm quoted in the challenge, and the account the credential is
    /// stored under.
    @objc public static let realm = "Isis DICOM Viewer XML-RPC"

    /// Moves the scope kept by earlier versions to `accessScopeKey`, once.
    ///
    /// Remote access left off becomes this Mac only; turned on, it becomes the
    /// local network unless that limit was turned off too. A user who had never
    /// touched either keeps the default.
    @objc(migrateLegacyPreferencesIn:)
    public static func migrateLegacyPreferences(in defaults: UserDefaults) {
        let remote = defaults.object(forKey: allowRemoteKey)
        let localOnly = defaults.object(forKey: localNetworkOnlyKey)
        guard remote != nil || localOnly != nil else { return }
        if let scope = migratedScope(allowRemote: remote, localNetworkOnly: localOnly) {
            defaults.set(scope.rawValue, forKey: accessScopeKey)
        }
        defaults.removeObject(forKey: allowRemoteKey)
        defaults.removeObject(forKey: localNetworkOnlyKey)
    }

    static func migratedScope(allowRemote: Any?, localNetworkOnly: Any?) -> XMLRPCAccessScope? {
        guard let remote = allowRemote else { return nil }
        guard boolValue(remote) else { return .thisMac }
        return localNetworkOnly.map(boolValue) ?? true ? .localNetwork : .anyAddress
    }

    static func boolValue(_ value: Any) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? NSString { return text.boolValue }
        return false
    }

    /// Whether a peer is on a private network: RFC 1918, link-local, the
    /// shared `100.64.0.0/10` block VPNs such as Tailscale hand out, and IPv6
    /// unique local and link-local addresses. These cannot be routed from the
    /// internet, which is what the intranet option of OsiriX checks too.
    @objc(isPrivateNetworkAddress:)
    public static func isPrivateNetworkAddress(_ address: String?) -> Bool {
        guard let address = address, let bytes = addressBytes(address) else { return false }
        if bytes.count == 4 {
            return bytes[0] == 10
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 169 && bytes[1] == 254)
                || (bytes[0] == 100 && (64...127).contains(bytes[1]))
        }
        return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
    }

    /// Whether an accepted peer is this computer, through loopback or through
    /// one of the addresses its interfaces hold right now.
    ///
    /// A TCP peer cannot claim one of this computer's own addresses from
    /// elsewhere: the handshake's reply to such an address never leaves the
    /// machine, so the connection is never established.
    @objc(isLocalAddress:)
    public static func isLocalAddress(_ address: String?) -> Bool {
        return isLocalAddress(address, interfaceAddresses: currentInterfaceAddresses())
    }

    static func isLocalAddress(_ address: String?, interfaceAddresses: Set<[UInt8]>) -> Bool {
        if isLoopbackAddress(address) { return true }
        guard let address = address, let bytes = addressBytes(address) else { return false }
        return interfaceAddresses.contains(bytes)
    }

    /// The raw bytes of a textual address, four for IPv4 and for an IPv4-mapped
    /// IPv6 address, sixteen otherwise, so that one address written two ways
    /// compares equal.
    static func addressBytes(_ text: String) -> [UInt8]? {
        var address = text
        if let percent = address.firstIndex(of: "%") {
            address = String(address[address.startIndex..<percent])
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return Array(bytes[12..<16])
        }
        return bytes
    }

    /// The addresses this computer's interfaces hold, read for every request so
    /// that an address taken after launch, by DHCP or a VPN, counts too.
    static func currentInterfaceAddresses() -> Set<[UInt8]> {
        var result = Set<[UInt8]>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sockaddr = entry.pointee.ifa_addr else { continue }
            switch Int32(sockaddr.pointee.sa_family) {
            case AF_INET:
                sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var address = sin.pointee.sin_addr
                    result.insert(withUnsafeBytes(of: &address) { Array($0) })
                }
            case AF_INET6:
                sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    var address = sin6.pointee.sin6_addr
                    result.insert(withUnsafeBytes(of: &address) { Array($0) })
                }
            default:
                continue
            }
        }
        return result
    }

    /// Whether an accepted peer is the machine itself.
    ///
    /// The listener reports the peer as the textual form of its address
    /// (`XMLRPCTransport.peerAddress`), so this reads the same forms `inet_ntop` writes, including the
    /// IPv4-mapped IPv6 addresses a dual-stack accept produces.
    @objc(isLoopbackAddress:)
    public static func isLoopbackAddress(_ address: String?) -> Bool {
        guard var address = address, !address.isEmpty else { return false }
        if let percent = address.firstIndex(of: "%") {
            address = String(address[address.startIndex..<percent])
        }
        if address == "::1" || address == "0:0:0:0:0:0:0:1" { return true }
        for prefix in ["::ffff:", "::FFFF:", "::"] where address.hasPrefix(prefix) {
            let mapped = String(address.dropFirst(prefix.count))
            if mapped.contains(".") { return isLoopbackIPv4(mapped) }
        }
        return isLoopbackIPv4(address)
    }

    /// The whole `127.0.0.0/8` block, not just `127.0.0.1`.
    static func isLoopbackIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3, let value = UInt(part), value <= 255 else { return false }
        }
        return parts[0] == "127"
    }

    /// The value of the `WWW-Authenticate` header sent with a `401`.
    @objc public static var challengeHeaderValue: String {
        return "Basic realm=\"\(realm)\", charset=\"UTF-8\""
    }

    /// Compares the two headers without letting the time taken depend on how
    /// many leading bytes agree.
    static func matches(_ offered: String, _ expected: String) -> Bool {
        let offeredBytes = Array(offered.utf8)
        let expectedBytes = Array(expected.utf8)
        var difference = UInt8(offeredBytes.count == expectedBytes.count ? 0 : 1)
        for index in 0..<expectedBytes.count {
            let byte = index < offeredBytes.count ? offeredBytes[index] : 0
            difference |= byte ^ expectedBytes[index]
        }
        return difference == 0
    }

    /// The `Authorization` header value a user name and password produce, or
    /// `nil` when either cannot be carried in one.
    @objc(basicHeaderForUsername:password:)
    public static func basicHeader(username: String, password: String) -> String? {
        guard !username.isEmpty, !password.isEmpty, !username.contains(":") else { return nil }
        let joined = username + ":" + password
        guard !joined.contains("\r"), !joined.contains("\n") else { return nil }
        return "Basic " + Data(joined.utf8).base64EncodedString()
    }

    /// What the interface exposes to other computers without a password.
    @objc public static var unauthenticatedExposureWarning: String {
        return NSLocalizedString(
            "Without a password, any computer that can reach this machine can list the database, including patient names and identifiers, retrieve studies, open URLs and quit IsiX DICOM Viewer, as with Horos and OsiriX.",
            comment: "XML-RPC remote access warning without a password")
    }

    /// What the interface exposes once it answers other computers, in the words
    /// used by the preference pane and by the documentation.
    @objc public static var exposureWarning: String {
        return NSLocalizedString(
            "While the XML-RPC interface answers other interfaces, any host that can reach this "
                + "machine and knows the password can list the database, including patient names and "
                + "identifiers, retrieve studies, open URLs and quit IsiX DICOM Viewer.",
            comment: "XML-RPC remote access warning")
    }
}

/// One address, or a block of them written as `address/prefix length`.
struct XMLRPCAddressRange: Equatable {
    let bytes: [UInt8]
    let prefixLength: Int

    init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let bytes = XMLRPCServerAccess.addressBytes(String(parts[0])) else { return nil }
        let bits = bytes.count * 8
        // An IPv4-mapped block written as IPv6 counts its prefix in IPv6 bits.
        let offset = bytes.count == 4 && parts[0].contains(":") ? 96 : 0
        var length = bits
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber), let value = Int(parts[1]),
                  (offset...(offset + bits)).contains(value) else { return nil }
            length = value - offset
        }
        self.bytes = XMLRPCAddressRange.masked(bytes, length)
        self.prefixLength = length
    }

    static func masked(_ bytes: [UInt8], _ length: Int) -> [UInt8] {
        return bytes.enumerated().map { index, byte in
            let kept = min(8, max(0, length - index * 8))
            return kept == 8 ? byte : byte & UInt8(truncatingIfNeeded: 0xff << (8 - kept))
        }
    }

    func contains(_ address: [UInt8]) -> Bool {
        return address.count == bytes.count && XMLRPCAddressRange.masked(address, prefixLength) == bytes
    }
}

/// The addresses the user listed as answered without a credential: single
/// addresses or blocks, separated by commas, semicolons, spaces or new lines.
@objc(HorosXMLRPCAllowedAddresses)
public final class XMLRPCAllowedAddresses: NSObject {
    let ranges: [XMLRPCAddressRange]
    /// What the user typed that is not an address or a block, in order.
    @objc public let invalidEntries: [String]

    @objc public init(text: String?) {
        var ranges: [XMLRPCAddressRange] = []
        var invalid: [String] = []
        let separators = CharacterSet(charactersIn: ",;").union(.whitespacesAndNewlines)
        for token in (text ?? "").components(separatedBy: separators) where !token.isEmpty {
            if let range = XMLRPCAddressRange(token) { ranges.append(range) } else { invalid.append(token) }
        }
        self.ranges = ranges
        self.invalidEntries = invalid
        super.init()
    }

    @objc public var isEmpty: Bool { return ranges.isEmpty }

    @objc(containsAddress:)
    public func contains(_ address: String?) -> Bool {
        guard let address = address, let bytes = XMLRPCServerAccess.addressBytes(address) else { return false }
        return ranges.contains { $0.contains(bytes) }
    }
}

/// The settings the interface applies to a call, read from the preferences
/// when the call arrives, so a change in the pane applies to the next call.
@objc(HorosXMLRPCAccessPolicy)
public final class XMLRPCAccessPolicy: NSObject {
    @objc public let scope: XMLRPCAccessScope
    @objc public let requirePassword: Bool
    @objc public let allowedAddresses: XMLRPCAllowedAddresses

    @objc public init(scope: XMLRPCAccessScope, requirePassword: Bool, allowedAddresses: XMLRPCAllowedAddresses) {
        self.scope = scope
        self.requirePassword = requirePassword
        self.allowedAddresses = allowedAddresses
        super.init()
    }

    @objc(policyFromDefaults:)
    public static func policy(from defaults: UserDefaults) -> XMLRPCAccessPolicy {
        return XMLRPCAccessPolicy(
            scope: XMLRPCAccessScope(rawValue: defaults.integer(forKey: XMLRPCServerAccess.accessScopeKey)) ?? .thisMac,
            requirePassword: defaults.bool(forKey: XMLRPCServerAccess.requirePasswordKey),
            allowedAddresses: XMLRPCAllowedAddresses(text: defaults.string(forKey: XMLRPCServerAccess.allowedAddressesKey)))
    }

    /// Whether this policy lets some other computer in without a credential,
    /// beyond the addresses the user listed one by one.
    @objc public var answersOtherComputersWithoutPassword: Bool {
        return scope != .thisMac && !requirePassword
    }

    /// The verdict on one request, reached before the body is parsed and before
    /// any method runs. The stored credential is read only when it is needed.
    @objc(decisionForPeerAddress:authorization:)
    public func decision(peerAddress: String?, authorization: String?) -> XMLRPCAccessDecision {
        return decision(isLocal: XMLRPCServerAccess.isLocalAddress(peerAddress),
                        isListed: allowedAddresses.contains(peerAddress),
                        isPrivate: XMLRPCServerAccess.isPrivateNetworkAddress(peerAddress),
                        authorization: authorization,
                        credential: { XMLRPCServerCredential.header })
    }

    func decision(isLocal: Bool, isListed: Bool, isPrivate: Bool,
                  authorization: String?, credential: () -> String?) -> XMLRPCAccessDecision {
        if isLocal || isListed { return .allow }
        switch scope {
        case .thisMac: return .refuse
        case .localNetwork where !isPrivate: return .refuseOutsideLocalNetwork
        default: break
        }
        guard requirePassword else { return .allow }
        guard let credential = credential(), !credential.isEmpty else { return .refuseNoPasswordSet }
        guard let authorization = authorization, !authorization.isEmpty else { return .challenge }
        return XMLRPCServerAccess.matches(authorization, credential) ? .allow : .challenge
    }

    /// How serious what the policy lets in is, for the line under the switch.
    public enum Severity: Int {
        case normal, caution, danger
    }

    /// One or two sentences saying who can send messages, for the pane.
    public func summary(hasCredential: Bool) -> (text: String, severity: Severity) {
        var sentences: [String] = []
        var severity = Severity.normal
        switch (scope, requirePassword) {
        case (.thisMac, _):
            sentences.append(NSLocalizedString("Only this Mac can send messages to IsiX DICOM Viewer.", comment: "XML-RPC access summary"))
        case (_, true) where !hasCredential:
            sentences.append(NSLocalizedString("No password is set: other computers are refused until one is set with Set Password….", comment: "XML-RPC access summary"))
            severity = .caution
        case (.localNetwork, true):
            sentences.append(NSLocalizedString("Computers on the local network can send messages with the user name and password.", comment: "XML-RPC access summary"))
        case (_, true):
            sentences.append(NSLocalizedString("Any computer that can reach this Mac can send messages with the user name and password.", comment: "XML-RPC access summary"))
        case (.localNetwork, false):
            sentences.append(NSLocalizedString("Computers on the local network can send messages to IsiX DICOM Viewer without authentication.", comment: "XML-RPC access summary"))
            severity = .danger
        case (_, false):
            sentences.append(NSLocalizedString("Any computer that can reach this Mac can send messages to IsiX DICOM Viewer without authentication.", comment: "XML-RPC access summary"))
            severity = .danger
        }
        if !allowedAddresses.isEmpty {
            sentences.append(NSLocalizedString("The listed addresses are always accepted without a password.", comment: "XML-RPC access summary"))
        }
        if !allowedAddresses.invalidEntries.isEmpty {
            sentences.append(String(format: NSLocalizedString("Not an address or a block of addresses: %@.", comment: "XML-RPC access summary"),
                                    allowedAddresses.invalidEntries.joined(separator: ", ")))
            severity = .danger
        }
        return (sentences.joined(separator: " "), severity)
    }
}

/// The credential the XML-RPC interface checks against, kept in the keychain
/// rather than in the preferences file.
///
/// Only the expected `Authorization` header is stored, so the password never
/// exists in the defaults and the comparison is one string against another.
@objc(HorosXMLRPCServerCredential)
public final class XMLRPCServerCredential: NSObject {
    private static let service = "org.horosproject.horos.xmlrpc"
    private static let account = "server"

    private static var query: [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account]
    }

    private static func failure(_ status: OSStatus) -> NSError {
        return NSError(domain: "HorosXMLRPCServerCredential", code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString(
                "The XML-RPC password could not be read from the keychain. Set it again in the "
                    + "Listener preferences or unlock the keychain.",
                comment: "XML-RPC keychain failure")])
    }

    /// Stores the credential for `username` and `password`.
    @objc(saveUsername:password:error:)
    public static func save(username: String, password: String) throws {
        guard let header = XMLRPCServerAccess.basicHeader(username: username, password: password) else {
            throw failure(errSecParam)
        }
        var item = query
        let value = [kSecValueData as String: Data(header.utf8)]
        let status = SecItemUpdate(item as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            item.merge(value) { _, new in new }
            item[kSecAttrSynchronizable as String] = false
            item[kSecAttrLabel as String] = XMLRPCServerAccess.realm
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess {
            throw failure(status)
        }
    }

    /// The expected `Authorization` header, or `nil` when none is stored.
    ///
    /// This is read on the connection thread for every request, so it never
    /// puts up a keychain dialog: a credential that cannot be read without one
    /// counts as absent, which keeps the listener on loopback instead of
    /// blocking a socket thread on a modal panel.
    @objc public static var header: String? {
        let (status, item) = NonInteractiveKeychainRead.read(service: service, account: account, data: true)
        guard status == errSecSuccess,
              let data = item?[kSecValueData as String] as? Data,
              let header = String(data: data, encoding: .utf8),
              !header.isEmpty else { return nil }
        return header
    }

    /// Whether a credential exists, without copying it.
    @objc public static var isConfigured: Bool {
        return header != nil
    }

    /// Forgets the credential. The listener returns to loopback on its next
    /// start.
    @objc(removeAndReturnError:)
    public static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
}
