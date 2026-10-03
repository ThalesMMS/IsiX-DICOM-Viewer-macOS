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

/// The username and password of a node's WADO-URI retrieve.
///
/// The password lives in the Keychain, as a Basic credential of
/// `DICOMwebCredentials`; the node's entry in `SERVERS` keeps the username,
/// for the sheet, and the item's UUID under `WADOCredential`. Every request of
/// a retrieve carries `Authorization: Basic base64(username:password)`, UTF-8,
/// and no WADO URL holds the credential: a password with `@`, `:` or `/` does
/// not change the URL, and the URL can be logged.
///
/// A password the preferences still hold in plain text, as `WADOPassword`, is
/// moved to the Keychain at launch and whenever a retrieve reads it, and
/// removed from the preferences.
@objc(HorosWADOCredentials)
public final class WADOCredentials: NSObject {
    /// The key of the Keychain item's UUID in a node's entry.
    @objc public static let identifierKey = "WADOCredential"
    static let usernameKey = "WADOUsername"
    static let passwordKey = "WADOPassword"
    /// How long a retrieve, or the sheet, waits for the Keychain.
    static let keychainTimeout: TimeInterval = 10
    private static let lock = NSLock()

    // MARK: Header

    /// `Basic base64(username:password)` in UTF-8, or nil when either is empty.
    @objc(basicAuthorizationForUsername:password:)
    public static func basicAuthorization(username: String?, password: String?) -> String? {
        guard let username, !username.isEmpty, let password, !password.isEmpty else { return nil }
        return "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
    }

    /// The `Authorization` value of a retrieve from `server`, or "" when the
    /// node has no credential. A password still in plain text is used as it
    /// is and moved to the Keychain on the main thread. Reads the Keychain:
    /// call it off the main thread.
    @objc(authorizationForServer:error:)
    public static func authorization(forServer server: NSDictionary?) throws -> String {
        guard let server else { return "" }
        if let plain = server[passwordKey] as? String, !plain.isEmpty {
            DispatchQueue.main.async { migrateServers() }
            return basicAuthorization(username: server[usernameKey] as? String, password: plain) ?? ""
        }
        guard let identifier = server[identifierKey] as? String, !identifier.isEmpty else { return "" }
        let header = try DICOMwebCredentials.withDeadline(timeout: keychainTimeout, cancelled: { Thread.current.isCancelled }) {
            try DICOMwebCredentials.header(forIdentifier: identifier)
        }
        guard let header, header.name.caseInsensitiveCompare("Authorization") == .orderedSame else {
            throw DICOMwebCredentials.failure(errSecDecode)
        }
        return header.value
    }

    /// The password the sheet shows: the plain one if it was not moved yet,
    /// else the Keychain's. Nil when there is none or the Keychain does not
    /// answer; `unavailable` says which.
    public static func password(forServer server: NSDictionary?) -> (password: String?, unavailable: Bool) {
        guard let server else { return (nil, false) }
        if let plain = server[passwordKey] as? String, !plain.isEmpty { return (plain, false) }
        guard let identifier = server[identifierKey] as? String, !identifier.isEmpty else { return (nil, false) }
        guard let header = try? DICOMwebCredentials.withDeadline(timeout: keychainTimeout, cancelled: { false }, {
                  try DICOMwebCredentials.header(forIdentifier: identifier)
              }),
              header.value.lowercased().hasPrefix("basic "),
              let decoded = Data(base64Encoded: String(header.value.dropFirst(6))),
              let pair = String(data: decoded, encoding: .utf8), let colon = pair.firstIndex(of: ":")
        else { return (nil, true) }
        return (String(pair[pair.index(after: colon)...]), false)
    }

    // MARK: Storing

    /// What the WADO sheet saves: a username and a password make, or replace,
    /// the node's Keychain item; an empty password removes it, unless the
    /// sheet could not read the stored one (`keepStoredPassword`), which then
    /// stays as it is. `WADOPassword` never stays in the entry.
    @objc(saveUsername:password:inServer:keepStoredPassword:error:)
    public static func save(username: String?, password: String?, in server: NSMutableDictionary,
                            keepStoredPassword: Bool) throws {
        let existing = server[identifierKey] as? String ?? ""
        let reusable = UUID(uuidString: existing) != nil ? existing : ""
        if let username, !username.isEmpty, let password, !password.isEmpty {
            let identifier = try DICOMwebCredentials.store(kind: .basic, username: username, secret: password,
                                                           headerName: "", identifier: reusable)
            server[identifierKey] = identifier
            server.removeObject(forKey: passwordKey)
            return
        }
        server.removeObject(forKey: passwordKey)
        if keepStoredPassword { return }
        if !reusable.isEmpty { try DICOMwebCredentials.remove(identifier: reusable) }
        server.removeObject(forKey: identifierKey)
    }

    // MARK: Migration

    /// Moves every plain `WADOPassword` of `SERVERS` to the Keychain and
    /// removes it from the preferences. A password the Keychain cannot take
    /// now (a locked keychain) stays and is tried again at the next read; one
    /// without a username, never sent, or that Basic cannot carry, is removed.
    /// A `SERVERS` given as an argument of the launch is not the preferences'
    /// and is not written. Returns how many entries changed.
    @discardableResult
    static func migrateServers(in defaults: UserDefaults) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard defaults.volatileDomain(forName: UserDefaults.argumentDomain)["SERVERS"] == nil,
              let servers = defaults.array(forKey: "SERVERS") else { return 0 }
        var changed = 0
        let migrated: [Any] = servers.map { entry in
            guard let server = entry as? NSDictionary, let plain = server[passwordKey] as? String else { return entry }
            let node = server.mutableCopy() as! NSMutableDictionary
            let username = server[usernameKey] as? String ?? ""
            if !plain.isEmpty && !username.isEmpty {
                do {
                    try save(username: username, password: plain, in: node, keepStoredPassword: true)
                } catch let error as NSError where error.code == Int(errSecParam) {
                    NSLog("WADO: a node's password cannot be sent as Basic credentials and was removed; enter it again in Locations")
                    node.removeObject(forKey: passwordKey)
                } catch {
                    NSLog("WADO: a node's password could not be moved to the Keychain yet; it will be tried again")
                    return entry
                }
            } else {
                node.removeObject(forKey: passwordKey)
            }
            changed += 1
            return node
        }
        guard changed > 0 else { return 0 }
        defaults.set(migrated, forKey: "SERVERS")
        NSLog("WADO: moved %ld node password(s) from SERVERS to the Keychain", changed)
        return changed
    }

    /// Run at launch, after the defaults are registered, and when a retrieve
    /// meets a password still in plain text.
    @objc public static func migrateServers() {
        migrateServers(in: .standard)
    }

    // MARK: Redirects

    /// The request a redirect leads to: with the original request's
    /// `Authorization` when it stays on the same origin (scheme, host and
    /// port), as URL loading itself drops it, and without it otherwise.
    static func redirect(_ request: URLRequest, from original: URLRequest?) -> URLRequest {
        var next = request
        if let target = request.url, sameOrigin(target, original?.url),
           let authorization = original?.value(forHTTPHeaderField: "Authorization") {
            next.setValue(authorization, forHTTPHeaderField: "Authorization")
        } else {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }

    static func sameOrigin(_ a: URL, _ b: URL?) -> Bool {
        guard let b, let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased(),
              let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased() else { return false }
        func port(_ url: URL, _ scheme: String) -> Int? { url.port ?? ["http": 80, "https": 443][scheme] }
        return schemeA == schemeB && hostA == hostB && port(a, schemeA) == port(b, schemeB)
    }
}
