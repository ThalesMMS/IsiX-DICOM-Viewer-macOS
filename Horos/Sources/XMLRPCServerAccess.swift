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
    /// Answer `403` and dispatch nothing: this peer is not served at all.
    case refuse
    /// Answer `403` and dispatch nothing: other computers are answered, but
    /// only from the local network, and this peer is outside it.
    case refuseOutsideLocalNetwork
}

/// Who the XML-RPC interface answers.
///
/// The interface publishes `KillOsiriX`, `Retrieve`, `DownloadURL` and
/// `dbwindowfind` - the last one returns the contents of the database, patient
/// names and identifiers included. Horos answered every host that could reach
/// the machine and asked for no credential at all, so turning the preference on
/// for a local script published the database to the network.
///
/// The policy here is deliberately one the user can state in a sentence:
///
/// - A call made on this computer is answered without a credential, as Horos
///   and OsiriX answer it, whichever of the computer's addresses it is sent to.
///   A RIS on the same Mac often calls the machine's network address rather than
///   `127.0.0.1`, so the socket listens on every interface and the peer address
///   decides, not the interface the call arrived on.
/// - Answering other computers is an explicit choice (`httpXMLRPCServerAllowRemote`).
/// - By default it then asks them for a password, and only takes effect once
///   one exists. Without a password the computers are refused rather than
///   served by an unauthenticated port, unless the user also turned the
///   password off (`httpXMLRPCServerRequirePassword`), which is what Horos and
///   OsiriX do for every caller.
/// - By default it answers them only from private addresses
///   (`httpXMLRPCServerLocalNetworkOnly`), as the intranet option of OsiriX
///   does, so a port forwarded to the internet is still refused.
@objc(HorosXMLRPCServerAccess)
public final class XMLRPCServerAccess: NSObject {
    /// The preference that lets the interface leave loopback.
    @objc public static let allowRemoteKey = "httpXMLRPCServerAllowRemote"
    /// The preference that asks other computers for the password. On by default.
    @objc public static let requirePasswordKey = "httpXMLRPCServerRequirePassword"
    /// The preference that limits other computers to private addresses. On by default.
    @objc public static let localNetworkOnlyKey = "httpXMLRPCServerLocalNetworkOnly"

    /// The realm quoted in the challenge, and the account the credential is
    /// stored under.
    @objc public static let realm = "Isis DICOM Viewer XML-RPC"

    /// Whether calls from other computers are answered at all.
    ///
    /// While a password is required, the credential is a precondition, not a
    /// separate setting to forget: the preference alone never lets another
    /// computer in.
    @objc(answersOtherComputersAllowRemote:requirePassword:hasCredential:)
    public static func answersOtherComputers(allowRemote: Bool, requirePassword: Bool, hasCredential: Bool) -> Bool {
        return allowRemote && (hasCredential || !requirePassword)
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
    /// `N2ConnectionListener` reports the peer as the textual form of its
    /// address, so this reads the same forms `inet_ntop` writes, including the
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

    /// The verdict on one request, reached before the body is parsed and before
    /// any method runs.
    ///
    /// `credential` is the expected `Authorization` header value, as stored by
    /// `XMLRPCServerCredential`; `authorization` is the one the request carried.
    @objc(decisionForPeerAddress:authorization:credential:answersOtherComputers:requirePassword:localNetworkOnly:)
    public static func decision(peerAddress: String?,
                                authorization: String?,
                                credential: String?,
                                answersOtherComputers: Bool,
                                requirePassword: Bool,
                                localNetworkOnly: Bool) -> XMLRPCAccessDecision {
        return decision(isLocal: isLocalAddress(peerAddress),
                        isPrivate: isPrivateNetworkAddress(peerAddress),
                        authorization: authorization,
                        credential: credential,
                        answersOtherComputers: answersOtherComputers,
                        requirePassword: requirePassword,
                        localNetworkOnly: localNetworkOnly)
    }

    static func decision(isLocal: Bool,
                         isPrivate: Bool,
                         authorization: String?,
                         credential: String?,
                         answersOtherComputers: Bool,
                         requirePassword: Bool,
                         localNetworkOnly: Bool) -> XMLRPCAccessDecision {
        if isLocal { return .allow }
        guard answersOtherComputers else { return .refuse }
        if localNetworkOnly && !isPrivate { return .refuseOutsideLocalNetwork }
        guard requirePassword else { return .allow }
        guard let credential = credential, !credential.isEmpty else { return .refuse }
        guard let authorization = authorization, !authorization.isEmpty else { return .challenge }
        return matches(authorization, credential) ? .allow : .challenge
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
