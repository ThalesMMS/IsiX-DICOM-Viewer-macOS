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

/// Where the URL of a download link points: whether the connection is
/// encrypted, the host and the port.
///
/// The host is compared as the system's URL parser gives it, in lower case and
/// in its ASCII form: an internationalized name is its `xn--` form, so a name
/// that only looks like another one is another host. A URL the parser may read
/// in more than one way names no origin, and its link asks first: one with a
/// user or a password before the host, with a space, a control character or a
/// backslash, or of a scheme other than http and https.
public struct XMLRPCLinkOrigin: Equatable, Sendable {
    public let isSecure: Bool
    public let host: String
    public let port: Int

    public static let securePort = 443
    public static let plainPort = 80

    public init?(url text: String) {
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { Self.isAmbiguous($0) }),
              URL(string: text) != nil, let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil,
              let host = Self.normalized(host: components.encodedHost) else { return nil }
        let secure = scheme == "https"
        let port = components.port ?? (secure ? Self.securePort : Self.plainPort)
        guard (1...65535).contains(port) else { return nil }
        self.isSecure = secure
        self.host = host
        self.port = port
    }

    /// The host as the list names it: with its port when that is not the
    /// port of the scheme, an IPv6 address between brackets.
    public var entry: String {
        let name = host.contains(":") ? "[" + host + "]" : host
        return port == (isSecure ? Self.securePort : Self.plainPort) ? name : name + ":\(port)"
    }

    /// A space, a control character or a backslash, which parsers of URLs do
    /// not agree about.
    static func isAmbiguous(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\\" || scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
    }

    /// A host in lower case, without the brackets of an IPv6 address and
    /// without the dot that ends a fully qualified name; `nil` when nothing
    /// is left, or when it is not written in ASCII.
    static func normalized(host: String?) -> String? {
        guard var name = host?.lowercased(), !name.isEmpty else { return nil }
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII }), !name.contains("%"), !name.contains("*") else { return nil }
        return name
    }
}

/// A host whose download links are carried out unasked: its name, the port
/// when the entry gives one, and whether a link that is not encrypted is
/// accepted too.
///
/// An entry names one host exactly: no pattern, and a subdomain is another
/// host. One without a port stands for the port of the link's scheme, 443 for
/// https and 80 for http; one with a port stands for that port alone.
public struct XMLRPCLinkTrustedHost: Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int?
    public var allowsHTTP: Bool

    /// The key of the host and of the HTTP mark in the stored form.
    public static let hostKey = "Host"
    public static let allowsHTTPKey = "AllowsHTTP"

    /// From what the user types: `pacs.example.com`, `pacs.example.com:8443`,
    /// or a URL, of which the host and the port are kept. `nil` when the text
    /// names no host.
    public init?(entry: String, allowsHTTP: Bool = false) {
        let text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.unicodeScalars.contains(where: { XMLRPCLinkOrigin.isAmbiguous($0) }) else { return nil }
        let address = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.user == nil, components.password == nil,
              let host = XMLRPCLinkOrigin.normalized(host: components.encodedHost) else { return nil }
        if let port = components.port, !(1...65535).contains(port) { return nil }
        self.host = host
        self.port = components.port
        self.allowsHTTP = allowsHTTP
    }

    /// The host of a link, as its alert offers to trust it: with the port
    /// when it is not the port of the scheme, and with HTTP accepted when the
    /// link is not encrypted.
    public init(trusting origin: XMLRPCLinkOrigin) {
        host = origin.host
        port = origin.port == (origin.isSecure ? XMLRPCLinkOrigin.securePort : XMLRPCLinkOrigin.plainPort) ? nil : origin.port
        allowsHTTP = !origin.isSecure
    }

    /// The entry as the list shows it.
    public var entry: String {
        let name = host.contains(":") ? "[" + host + "]" : host
        return port.map { name + ":\($0)" } ?? name
    }

    public func matches(_ origin: XMLRPCLinkOrigin) -> Bool {
        guard origin.isSecure || allowsHTTP, host == origin.host else { return false }
        return (port ?? (origin.isSecure ? XMLRPCLinkOrigin.securePort : XMLRPCLinkOrigin.plainPort)) == origin.port
    }

    // MARK: The stored list

    /// The list from its stored form, an array of dictionaries; an entry
    /// that names no host is left out, and so is a host named again.
    public static func list(stored: [Any]?) -> [XMLRPCLinkTrustedHost] {
        var list: [XMLRPCLinkTrustedHost] = []
        for item in stored ?? [] {
            guard let fields = item as? [String: Any], let entry = fields[hostKey] as? String,
                  let host = XMLRPCLinkTrustedHost(entry: entry, allowsHTTP: (fields[allowsHTTPKey] as? Bool) ?? false) else { continue }
            list = adding(host, to: list)
        }
        return list
    }

    /// The stored form of `list`.
    public static func stored(_ list: [XMLRPCLinkTrustedHost]) -> [[String: Any]] {
        list.map { [hostKey: $0.entry, allowsHTTPKey: $0.allowsHTTP] }
    }

    /// `list` with `host`: a host already there keeps its place, and accepts
    /// HTTP when either does.
    public static func adding(_ host: XMLRPCLinkTrustedHost, to list: [XMLRPCLinkTrustedHost]) -> [XMLRPCLinkTrustedHost] {
        var list = list
        if let index = list.firstIndex(where: { $0.host == host.host && $0.port == host.port }) {
            list[index].allowsHTTP = list[index].allowsHTTP || host.allowsHTTP
        } else {
            list.append(host)
        }
        return list
    }
}
