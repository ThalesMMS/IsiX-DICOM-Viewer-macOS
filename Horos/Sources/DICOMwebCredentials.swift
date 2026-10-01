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
import Synchronization
import Security

/// How a DICOMweb node authenticates.
@objc(HorosDICOMwebCredentialKind)
public enum DICOMwebCredentialKind: Int, Sendable {
    case none = 0
    /// Username and password, sent as `Authorization: Basic …`.
    case basic = 1
    /// A key sent verbatim in a header the node names, such as `X-Api-Key`.
    case apiKey = 2
    /// A token sent as `Authorization: Bearer …`.
    case bearer = 3

    fileprivate var storedName: String {
        switch self {
        case .none: return "none"
        case .basic: return "basic"
        case .apiKey: return "apiKey"
        case .bearer: return "bearer"
        }
    }

    fileprivate init?(storedName: String) {
        switch storedName {
        case "basic": self = .basic
        case "apiKey": self = .apiKey
        case "bearer": self = .bearer
        default: return nil
        }
    }
}

/// The header a request carries. Never logged, never kept beyond the request.
@objc(HorosDICOMwebCredentialHeader)
public final class DICOMwebCredentialHeader: NSObject {
    @objc public let name: String
    @objc public let value: String
    init(name: String, value: String) { self.name = name; self.value = value; super.init() }
    public override var description: String { "DICOMwebCredentialHeader(\(name): <redacted>)" }
    public override var debugDescription: String { description }
}

/// What a stored credential is, without its secret: enough to fill the
/// authentication form and the Auth column.
@objc(HorosDICOMwebCredentialDescription)
public final class DICOMwebCredentialDescription: NSObject, Sendable {
    @objc public let kind: DICOMwebCredentialKind
    /// The Basic username; empty for the other kinds.
    @objc public let username: String
    /// The header the secret goes in: `Authorization` for Basic and Bearer.
    @objc public let headerName: String
    init(kind: DICOMwebCredentialKind, username: String, headerName: String) {
        self.kind = kind; self.username = username; self.headerName = headerName; super.init()
    }
    /// "None", "Basic · user", "API Key · X-Api-Key" or "Bearer". Never a secret.
    @objc public var summary: String {
        switch kind {
        case .none: return "None"
        case .basic: return username.isEmpty ? "Basic" : "Basic · " + username
        case .apiKey: return "API Key · " + headerName
        case .bearer: return "Bearer"
        }
    }
}

/// DICOMweb credentials in the Keychain (#197, #799).
///
/// Preferences hold only the item's UUID. The Keychain item keeps the header
/// value, ready to send, as its secret data, and what the credential is (kind,
/// Basic username, header name) as a non-secret attribute, so the form and the
/// Auth column can describe a credential without reading its secret.
///
/// A pilot item (#197) has only the data: a ready `Authorization` value.
/// `migrateLegacy(identifier:)` adds the attribute and leaves the value as it
/// was, so the migration cannot lose it; until then it is read as an
/// `Authorization` header all the same.
///
/// Every read is non-interactive: a locked keychain or an item another
/// executable created is an error, never a dialog.
@objc(HorosDICOMwebCredentials)
public final class DICOMwebCredentials: NSObject {
    static let service = "org.horosproject.DICOMweb.credentials"
    private static let format = 2

    /// The Keychain calls, replaceable so the format and the migration can be
    /// tested without the user's keychain.
    struct Backend {
        var read: (_ identifier: String, _ wantData: Bool) throws -> (data: Data?, generic: Data?)?
        var add: (_ identifier: String, _ data: Data, _ generic: Data) throws -> Void
        var update: (_ identifier: String, _ data: Data?, _ generic: Data) throws -> Bool
        var delete: (_ identifier: String) throws -> Void
    }
    // nonisolated(unsafe): the application only reads it. The test programs
    // replace it at their top level, before the first credential is read and
    // before any other thread starts. Remove when the tests inject the backend
    // another way.
    nonisolated(unsafe) static var backend = Backend.keychain

    // MARK: Errors

    static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "HorosDICOMwebCredentials", code: Int(status), userInfo: [NSLocalizedDescriptionKey:
            "DICOMweb credentials could not be accessed. Update the credentials in Locations or unlock the keychain."])
    }
    static func invalid(_ message: String) -> NSError {
        NSError(domain: "HorosDICOMwebCredentials", code: Int(errSecParam), userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: Validation

    private static let reservedHeaders: Set<String> = [
        "accept", "accept-encoding", "connection", "content-length", "content-type", "cookie",
        "expect", "host", "keep-alive", "proxy-authorization", "proxy-connection", "te",
        "trailer", "transfer-encoding", "upgrade",
    ]

    /// An RFC 9110 field name the client may set.
    static func isValidHeaderName(_ name: String) -> Bool {
        let tchar = Set("!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".unicodeScalars)
        return !name.isEmpty && name.unicodeScalars.count <= 128 && name.unicodeScalars.allSatisfy { tchar.contains($0) }
            && !reservedHeaders.contains(name.lowercased())
    }

    /// A field value with no control characters, so nothing can be injected
    /// into the request, and nothing that only differs in blank padding.
    static func isValidHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16384
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
            && value.trimmingCharacters(in: .whitespaces) == value
    }

    // MARK: Storing

    /// Stores a credential and returns its identifier, the only thing the
    /// preferences may keep. An empty `identifier` makes a new item; an
    /// existing one is replaced in place. `.none` removes the item, if any,
    /// and returns "".
    ///
    /// - Basic: `username` (no colon) and `secret` = password.
    /// - API key: `headerName` (for example `X-Api-Key`) and `secret` = the key.
    /// - Bearer: `secret` = the token, without the `Bearer ` prefix.
    @discardableResult
    public static func store(kind: DICOMwebCredentialKind, username: String, secret: String,
                             headerName: String, identifier: String = "") throws -> String {
        if kind == .none {
            if !identifier.isEmpty { try remove(identifier: identifier) }
            return ""
        }
        let name: String, value: String, user: String
        switch kind {
        case .basic:
            guard !username.isEmpty, !username.contains(":"), isValidHeaderValue(username), !secret.isEmpty,
                  !secret.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            else { throw invalid("Enter a username and password. The username cannot contain a colon.") }
            name = "Authorization"; user = username
            value = "Basic " + Data((username + ":" + secret).utf8).base64EncodedString()
        case .apiKey:
            guard isValidHeaderName(headerName) else {
                throw invalid("Enter a header name made of letters, digits and dashes, such as X-Api-Key.")
            }
            guard isValidHeaderValue(secret) else { throw invalid("Enter an API key without line breaks.") }
            name = headerName; value = secret; user = ""
        case .bearer:
            guard isValidHeaderValue(secret), !secret.contains(" ") else {
                throw invalid("Enter a bearer token without spaces or line breaks.")
            }
            name = "Authorization"; value = "Bearer " + secret; user = ""
        case .none:
            fatalError("handled above")
        }
        let target = identifier.isEmpty ? UUID().uuidString : identifier
        guard UUID(uuidString: target) != nil else { throw failure(errSecParam) }
        let generic = try metadata(kind: kind, username: user, headerName: name)
        if try !backend.update(target, Data(value.utf8), generic) {
            try backend.add(target, Data(value.utf8), generic)
        }
        return target
    }

    @objc(storeCredentialOfKind:username:secret:headerName:identifier:error:)
    public static func objcStore(kind: DICOMwebCredentialKind, username: String, secret: String,
                                 headerName: String, identifier: String) throws -> String {
        try store(kind: kind, username: username, secret: secret, headerName: headerName, identifier: identifier)
    }

    /// The pilot's form (#197): username and password, or a bearer token.
    @objc(saveForIdentifier:username:password:bearerToken:error:)
    public static func save(identifier: String, username: String, password: String, bearerToken: String) throws {
        guard UUID(uuidString: identifier) != nil else { throw failure(errSecParam) }
        if !bearerToken.isEmpty {
            try store(kind: .bearer, username: "", secret: bearerToken, headerName: "", identifier: identifier)
        } else {
            try store(kind: .basic, username: username, secret: password, headerName: "", identifier: identifier)
        }
    }

    @objc(removeForIdentifier:error:)
    public static func remove(identifier: String) throws {
        guard UUID(uuidString: identifier) != nil else { throw failure(errSecParam) }
        try backend.delete(identifier)
    }

    // MARK: Reading

    /// The header a request to the node carries, or nil for an empty
    /// identifier (no authentication). Call it off the main thread, through
    /// `withDeadline` when a stuck keychain must not stall the caller.
    public static func header(forIdentifier identifier: String) throws -> (name: String, value: String)? {
        if identifier.isEmpty { return nil }
        guard UUID(uuidString: identifier) != nil else { throw failure(errSecParam) }
        guard let item = try backend.read(identifier, true), let data = item.data,
              let value = String(data: data, encoding: .utf8), isValidHeaderValue(value)
        else { throw failure(errSecItemNotFound) }
        guard let generic = item.generic else { return ("Authorization", value) }
        guard let described = parse(generic), isValidHeaderName(described.headerName) else { throw failure(errSecDecode) }
        return (described.headerName, value)
    }

    @objc(headerForIdentifier:error:)
    public static func objcHeader(forIdentifier identifier: String) throws -> DICOMwebCredentialHeader {
        guard let header = try header(forIdentifier: identifier) else { throw failure(errSecItemNotFound) }
        return DICOMwebCredentialHeader(name: header.name, value: header.value)
    }

    /// What the credential is, without its secret. An empty identifier is
    /// `.none`. A pilot item that was not migrated yet is described from its
    /// value, which is read but not returned.
    @objc(describeIdentifier:error:)
    public static func describe(identifier: String) throws -> DICOMwebCredentialDescription {
        if identifier.isEmpty { return DICOMwebCredentialDescription(kind: .none, username: "", headerName: "") }
        guard UUID(uuidString: identifier) != nil else { throw failure(errSecParam) }
        guard let item = try backend.read(identifier, false) else { throw failure(errSecItemNotFound) }
        if let generic = item.generic {
            guard let described = parse(generic) else { throw failure(errSecDecode) }
            return described
        }
        guard let legacy = try backend.read(identifier, true), let data = legacy.data,
              let value = String(data: data, encoding: .utf8) else { throw failure(errSecItemNotFound) }
        return inferLegacy(value)
    }

    /// "None", "Basic · user", "API Key · X-Api-Key" or "Bearer"; never a
    /// secret. "Unavailable" when the keychain does not answer within five
    /// seconds, is locked, or no longer has the item.
    @objc(summaryForIdentifier:)
    public static func summary(forIdentifier identifier: String) -> String {
        if identifier.isEmpty { return "None" }
        do {
            return try withDeadline(timeout: 5, cancelled: { false }) { try describe(identifier: identifier) }.summary
        } catch { return "Unavailable" }
    }

    // MARK: Migration

    /// Gives a pilot item (only a ready `Authorization` value) the attribute of
    /// the current format, inferring its kind from the value, which it keeps
    /// byte for byte. Returns whether anything changed; running it again, or
    /// on an item already in the current format, changes nothing.
    @discardableResult
    public static func migrateLegacy(identifier: String) throws -> Bool {
        if identifier.isEmpty { return false }
        guard UUID(uuidString: identifier) != nil else { throw failure(errSecParam) }
        guard let item = try backend.read(identifier, false) else { throw failure(errSecItemNotFound) }
        if item.generic != nil { return false }
        guard let legacy = try backend.read(identifier, true), let data = legacy.data,
              let value = String(data: data, encoding: .utf8), isValidHeaderValue(value)
        else { throw failure(errSecItemNotFound) }
        let described = inferLegacy(value)
        let generic = try metadata(kind: described.kind, username: described.username, headerName: described.headerName)
        guard try backend.update(identifier, nil, generic) else { throw failure(errSecItemNotFound) }
        return true
    }

    /// `migrateLegacy(identifier:)` for Objective-C: @YES when the item changed.
    @objc(migrateLegacyIdentifier:error:)
    public static func objcMigrateLegacy(identifier: String) throws -> NSNumber {
        NSNumber(value: try migrateLegacy(identifier: identifier))
    }

    static func inferLegacy(_ value: String) -> DICOMwebCredentialDescription {
        let lower = value.lowercased()
        if lower.hasPrefix("basic ") {
            var username = ""
            if let decoded = Data(base64Encoded: String(value.dropFirst(6))),
               let pair = String(data: decoded, encoding: .utf8), let colon = pair.firstIndex(of: ":") {
                username = String(pair[..<colon])
            }
            return DICOMwebCredentialDescription(kind: .basic, username: username, headerName: "Authorization")
        }
        if lower.hasPrefix("bearer ") {
            return DICOMwebCredentialDescription(kind: .bearer, username: "", headerName: "Authorization")
        }
        return DICOMwebCredentialDescription(kind: .apiKey, username: "", headerName: "Authorization")
    }

    // MARK: Deadline

    /// The worker's answer: set once before `finished` is signalled.
    private final class Pending<T: Sendable>: Sendable {
        let finished = DispatchSemaphore(value: 0)
        let value = Mutex<Result<T, Error>?>(nil)
    }

    /// Runs a keychain read on another thread and gives up after `timeout`
    /// seconds or as soon as `cancelled` says so, so a keychain service that
    /// stops answering cannot hold a query, a retrieve or the Locations pane.
    static func withDeadline<T: Sendable>(timeout: TimeInterval, cancelled: () -> Bool, _ read: @escaping @Sendable () throws -> T) throws -> T {
        let cancelledError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                     userInfo: [NSLocalizedDescriptionKey: "DICOMweb operation cancelled."])
        if cancelled() { throw cancelledError }
        let result = Pending<T>()
        DispatchQueue.global(qos: .userInitiated).async {
            let value = Result { try read() }
            result.value.withLock { $0 = value }
            result.finished.signal()
        }
        let deadline = DispatchTime.now() + timeout
        while result.finished.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() { throw cancelledError }
            if DispatchTime.now() >= deadline {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey:
                    "DICOMweb credential access timed out. Check the keychain and retry."])
            }
        }
        if cancelled() { throw cancelledError }
        return try result.value.withLock { $0 }!.get()
    }

    // MARK: Format

    private static func metadata(kind: DICOMwebCredentialKind, username: String, headerName: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": format, "kind": kind.storedName,
                                                    "username": username, "header": headerName], options: [.sortedKeys])
    }

    private static func parse(_ generic: Data) -> DICOMwebCredentialDescription? {
        guard let object = try? JSONSerialization.jsonObject(with: generic) as? [String: Any],
              (object["format"] as? Int) == format,
              let kind = DICOMwebCredentialKind(storedName: object["kind"] as? String ?? ""),
              let header = object["header"] as? String else { return nil }
        return DICOMwebCredentialDescription(kind: kind, username: object["username"] as? String ?? "", headerName: header)
    }
}

extension DICOMwebCredentials.Backend {
    private static func key(_ identifier: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: DICOMwebCredentials.service, kSecAttrAccount as String: identifier]
    }

    /// Made on each use: its closures hold no state, and a stored `Backend`,
    /// whose closures are not `Sendable`, would be shared mutable state.
    static var keychain: DICOMwebCredentials.Backend { DICOMwebCredentials.Backend(
        read: { identifier, wantData in
            let (status, result) = NonInteractiveKeychainRead.read(
                service: DICOMwebCredentials.service, account: identifier, data: wantData)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let item = result else { throw DICOMwebCredentials.failure(status) }
            return (item[kSecValueData as String] as? Data, item[kSecAttrGeneric as String] as? Data)
        },
        add: { identifier, data, generic in
            var query = key(identifier)
            query[kSecValueData as String] = data
            query[kSecAttrGeneric as String] = generic
            query[kSecAttrSynchronizable as String] = false
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else { throw DICOMwebCredentials.failure(status) }
        },
        update: { identifier, data, generic in
            var changes: [String: Any] = [kSecAttrGeneric as String: generic]
            if let data = data { changes[kSecValueData as String] = data }
            let status = SecItemUpdate(key(identifier) as CFDictionary, changes as CFDictionary)
            if status == errSecItemNotFound { return false }
            guard status == errSecSuccess else { throw DICOMwebCredentials.failure(status) }
            return true
        },
        delete: { identifier in
            let status = SecItemDelete(key(identifier) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DICOMwebCredentials.failure(status) }
        }) }
}
