//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The rules of the username and password of a node's WADO-URI retrieve. The
/// password lives in the Keychain, which the application reads and writes;
/// these say what each request carries and what a password still kept in the
/// preferences becomes.
public enum WADOCredentialRules {
    /// The keys of a node's entry in `SERVERS`.
    public static let usernameKey = "WADOUsername"
    public static let passwordKey = "WADOPassword"
    public static let identifierKey = "WADOCredential"

    /// `Basic base64(username:password)` in UTF-8, or nil when either is empty.
    public static func basicAuthorization(username: String?, password: String?) -> String? {
        guard let username, !username.isEmpty, let password, !password.isEmpty else { return nil }
        return "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
    }

    /// The password of a `Basic` header value, as the sheet shows it; nil
    /// when the value is not one or does not decode.
    public static func password(ofBasicAuthorization value: String) -> String? {
        guard value.lowercased().hasPrefix("basic "),
              let decoded = Data(base64Encoded: String(value.dropFirst(6))),
              let pair = String(data: decoded, encoding: .utf8), let colon = pair.firstIndex(of: ":") else { return nil }
        return String(pair[pair.index(after: colon)...])
    }

    /// Whether two URLs share scheme, host and port (the scheme's default
    /// port when none is written).
    public static func sameOrigin(_ a: URL, _ b: URL?) -> Bool {
        guard let b, let schemeA = a.scheme?.lowercased(), let schemeB = b.scheme?.lowercased(),
              let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased() else { return false }
        func port(_ url: URL, _ scheme: String) -> Int? { url.port ?? ["http": 80, "https": 443][scheme] }
        return schemeA == schemeB && hostA == hostB && port(a, schemeA) == port(b, schemeB)
    }

    /// The `Authorization` a redirect to `target` carries: the original
    /// request's when it stays on the same origin, as URL loading itself drops
    /// it, and none otherwise.
    public static func redirectAuthorization(to target: URL?, from original: URL?, carrying authorization: String?) -> String? {
        guard let target, sameOrigin(target, original) else { return nil }
        return authorization
    }

    /// What becomes of a node entry's password still in plain text.
    public enum Migration: Equatable, Sendable {
        /// Nothing to move.
        case none
        /// Moved to the Keychain as a Basic credential, then removed.
        case store(username: String, password: String)
        /// Removed: without a username it was never sent.
        case remove
    }

    /// The migration of an entry that holds `password` (nil: none) for `username`.
    public static func migration(username: String?, password: String?) -> Migration {
        guard let password else { return .none }
        let username = username ?? ""
        return !password.isEmpty && !username.isEmpty ? .store(username: username, password: password) : .remove
    }
}
