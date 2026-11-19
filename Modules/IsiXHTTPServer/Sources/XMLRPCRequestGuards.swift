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

/// How much one peer of the XML-RPC interface may make it hold.
///
/// The interface judges a request by its peer once the header is complete, so
/// whoever reaches the port could make it keep bytes and threads before any
/// rule had its say: the header is held to the web portal's limits by the
/// listener, and the rest by these.
public enum XMLRPCRequestLimits {
    /// The longest body of a call, in bytes. A call is a method name and a few
    /// parameters; the longest the interface is sent, a predicate or a URL,
    /// stays far below.
    public static let body = 1024 * 1024
    /// How many connections the interface serves at once, each on a thread of
    /// its own. One more is closed as it is accepted.
    public static let connections = 64

    /// Whether the body a request announces, or the body received so far
    /// when it announces none or a length that is never reached, is more than
    /// the interface takes. Content-Length is read as a number of any size, so
    /// that one of gigabytes is refused before a byte of it is kept.
    public static func bodyIsTooLong(contentLengthField: String?, received: Int) -> Bool {
        if received > body { return true }
        guard let field = contentLengthField else { return false }
        let digits = field.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return false }
        // More digits than a length within the limit can have is over it,
        // whatever the number: it may not fit an integer.
        let significant = digits.drop { $0 == "0" }
        if significant.count > String(body).count { return true }
        return (Int(significant) ?? 0) > body
    }
}

/// What tells a request that a web page sent, or that names another site, from
/// one a program sent to the XML-RPC interface.
///
/// The interface answers calls made on this Mac without a credential, and a
/// page open in a browser on this Mac makes its requests from this Mac. A
/// browser marks what a page sends: every POST carries `Origin`, current
/// browsers add the `Sec-Fetch-` fields, and most requests carry `Referer`.
/// The clients the interface is for (a RIS, a script, curl, an XML-RPC
/// library) send none of them. A page that reaches this Mac under a name of
/// its own (a DNS name made to resolve to a local address) names that site in
/// `Host`.
public enum XMLRPCWebPageRequest {
    public enum Refusal: Equatable, Sendable {
        /// Not a POST: an XML-RPC call is one.
        case notAPost(String)
        /// The request carries a field only a browser sends for a page.
        case fromWebPage(field: String)
        /// A request made on this Mac to a name that is not this Mac's.
        case foreignHost(String)

        /// The HTTP status the request is answered.
        public var status: Int {
            if case .notAPost = self { return 405 }
            return 403
        }
    }

    /// The fields a browser adds to what a page sends.
    static let browserFields = ["Origin", "Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-Dest"]

    /// Why the request is not answered, or nil for one a program sent.
    /// `method` is the request line's, `field` answers a header field, and
    /// `isOwnHost` whether a host name or address is this Mac's (see
    /// `isOwnHost(_:names:isOwnAddress:)`). The host is judged for a peer on
    /// this Mac only: a RIS on another computer may know this Mac by a name
    /// this Mac does not know, and is judged by the access rules.
    public static func refusal(method: String?, field: (String) -> String?, peerIsThisComputer: Bool,
                               isOwnHost: (String) -> Bool) -> Refusal? {
        let method = method ?? ""
        guard method.uppercased() == "POST" else { return .notAPost(method) }
        for name in browserFields where field(name) != nil {
            return .fromWebPage(field: name)
        }
        if let referer = field("Referer")?.lowercased(), referer.hasPrefix("http://") || referer.hasPrefix("https://") {
            return .fromWebPage(field: "Referer")
        }
        if peerIsThisComputer, let host = field("Host").map(hostName(ofHostField:)), !host.isEmpty, !isOwnHost(host) {
            return .foreignHost(host)
        }
        return nil
    }

    /// The host a `Host` field names: without its port, the brackets of an
    /// IPv6 address and a final dot, in lower case.
    public static func hostName(ofHostField field: String) -> String {
        var host = field.trimmingCharacters(in: .whitespaces).lowercased()
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.lastIndex(of: ":"), host.firstIndex(of: ":") == colon {
            host = String(host[..<colon])
        }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// Whether `host`, as `hostName(ofHostField:)` gives it, is this Mac:
    /// `localhost`, one of `names` (this Mac's names, in lower case and
    /// without a final dot), or an address `isOwnAddress` knows as one of this
    /// Mac's, loopback included.
    public static func isOwnHost(_ host: String, names: Set<String>, isOwnAddress: (String) -> Bool) -> Bool {
        host == "localhost" || names.contains(host) || isOwnAddress(host)
    }
}

/// What a `horos://` or `osirix://` link may have the interface do without
/// asking the user.
///
/// A link runs a method of the XML-RPC interface with no caller to answer and
/// no credential: whoever can put a link in front of the user (a web page, an
/// e-mail, a document) can have it opened. The methods a RIS puts in its links
/// show, find, retrieve and close; the others change or end what the user is
/// doing, and are carried out only after the user agrees.
public enum XMLRPCLinkPolicy {
    public enum Verdict: Equatable, Sendable {
        case run
        /// The user is asked first.
        case confirm
    }

    /// The published methods a link runs unasked, in lower case.
    public static let unattended: Set<String> = [
        "displaystudy", "displayseries", "findobject", "dbwindowfind", "selectalbum", "switchtodefaultdbifneeded",
        "displaystudylistbypatientname", "displaystudylistbypatientid", "retrieve", "cmove",
        "closeallwindows", "close2dviewerwithseriesuid", "close2dviewerwithstudyuid",
        "getdisplayed2dviewerseries", "getdisplayed2dviewerstudies", "pathtofrontdcm",
    ]

    /// What a link that names `methodName` with `parameters` gets: a method
    /// outside `unattended` (ending the application, opening another
    /// database, downloading a URL, a method a plugin added) asks first, and
    /// so does a search told to delete what it finds.
    public static func verdict(methodName: String, parameters: [String: String]) -> Verdict {
        let name = methodName.lowercased()
        guard unattended.contains(name) else { return .confirm }
        if name == "findobject" || name == "dbwindowfind", deletes(parameters) { return .confirm }
        return .run
    }

    /// Whether the parameters of a search tell it to delete what it finds.
    public static func deletes(_ parameters: [String: String]) -> Bool {
        parameters.contains { $0.key.lowercased() == "execute" && $0.value.trimmingCharacters(in: .whitespaces).lowercased() == "delete" }
    }
}
