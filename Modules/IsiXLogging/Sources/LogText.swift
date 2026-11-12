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

/// What the log may be told of a value that is not the application's own text.
///
/// The unified system log is readable by every process of the user and
/// travels in sysdiagnose reports, and the standard error is on screen or in a
/// transcript when the application is started from a terminal. Text that comes
/// from elsewhere - what a person typed, what a peer answered, the description
/// the system gives an error, an address someone handed over - can hold a
/// patient's name or identifier, the name of a file or a credential. The log
/// is told what such a value is, not what it says: its length, the domain and
/// code of an error, the name of an exception, the origin and path of a URL.
public enum LogText {
    /// `<12 characters>`: that there is a text and how long it is; `<none>`
    /// for no text.
    public static func shape(of text: String?) -> String {
        guard let text else { return "<none>" }
        return "<\(text.count) character\(text.count == 1 ? "" : "s")>"
    }

    /// A notice - what a person reads in the notices panel or in an alert -
    /// by its title and the length of its text: `WADO Retrieve Incomplete (a
    /// notice of 46 characters)`. The title is the application's own. The text
    /// can end with what a node said of a request, name the studies that did
    /// not arrive whole or give the path of a manifest, and a notice that is
    /// not shown, because the person asked for none, is no reason to write it.
    public static func notice(title: String, text: String) -> String {
        "\(title) (a notice of \(text.count) character\(text.count == 1 ? "" : "s"))"
    }

    /// An error by its domain and code, with those of the errors under it:
    /// `NSCocoaErrorDomain 260 (NSPOSIXErrorDomain 2)`. Never its description:
    /// the one of a file error names the file, the one of a URL error can
    /// quote the URL with its query string, and the one an HTTP client makes
    /// can end with what the server said. An exception an error carries is
    /// told by its name.
    public static func error(_ error: (any Error)?) -> String {
        guard let error else { return "<no error>" }
        var parts: [String] = []
        var current: NSError? = error as NSError
        while let each = current, parts.count < 4 {
            var part = "\(each.domain) \(each.code)"
            if let raised = each.userInfo.values.lazy.compactMap({ $0 as? NSException }).first {
                part += " " + raised.name.rawValue
            }
            parts.append(part)
            current = each.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts[0] + (parts.count > 1 ? " (" + parts.dropFirst().joined(separator: ", ") + ")" : "")
    }

    /// An exception by its name and the length of its reason:
    /// `NSInvalidArgumentException <a reason of 57 characters>`. The reason of
    /// an exception raised over a value someone sent quotes that value: a
    /// predicate that cannot be parsed or evaluated is quoted whole, with the
    /// name or the identifier it compares.
    public static func exception(_ exception: NSException?) -> String {
        guard let exception else { return "<no exception>" }
        guard let reason = exception.reason else { return exception.name.rawValue }
        return "\(exception.name.rawValue) <a reason of \(reason.count) character\(reason.count == 1 ? "" : "s")>"
    }

    /// Writes an exception caught in `function` to the log as `exception(_:)`
    /// tells it, with the stack it was raised on when `stack` asks: the line
    /// of the application's exception log without the reason, for the sources
    /// that catch what is raised over values someone sent or typed.
    public static func log(_ exception: NSException?, stack: Bool, in function: String) {
        let trace = stack ? (exception?.callStackSymbols ?? []).joined(separator: "\n") : ""
        unifiedLogv("exception in %@: %@%@", [function as NSString, LogText.exception(exception) as NSString,
                                             (trace.isEmpty ? "" : "\n" + trace) as NSString])
    }

    /// A URL by its scheme, host, port and path: `https://pacs.example:8443/wado`.
    /// Its user and password, its query string and its fragment are left out,
    /// and said to have been there: the query of a WADO or QIDO request
    /// carries matching keys and can carry a token. The path of a file URL is
    /// a file an owner named, so only its length is told.
    public static func url(_ url: URL?) -> String {
        guard let url else { return "<no URL>" }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return "<a URL of \(url.absoluteString.count) characters>"
        }
        let scheme = components.scheme?.lowercased()
        var text = scheme.map { $0 + ":" } ?? ""
        if url.isFileURL || scheme == "file" {
            return text + "<a path of \(components.path.count) character\(components.path.count == 1 ? "" : "s")>"
        }
        if let host = components.host {
            // An IPv6 literal, which the system gives with or without its brackets.
            text += "//" + (host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host)
            if let port = components.port { text += ":\(port)" }
        }
        text += components.percentEncodedPath
        var left: [String] = []
        if components.user != nil || components.password != nil { left.append("a user") }
        if let query = components.percentEncodedQuery { left.append("a query of \(query.count) character\(query.count == 1 ? "" : "s")") }
        if components.fragment != nil { left.append("a fragment") }
        return text.isEmpty && left.isEmpty ? "<an empty URL>" : text + (left.isEmpty ? "" : " <with " + left.joined(separator: ", ") + ">")
    }

    /// `url(_:)` of an address given as text; one that is not a URL is told
    /// by its length.
    public static func url(string: String?) -> String {
        guard let string else { return "<no URL>" }
        guard let url = URL(string: string), url.scheme != nil || url.host != nil else {
            return "<not a URL, \(string.count) character\(string.count == 1 ? "" : "s")>"
        }
        return self.url(url)
    }
}
