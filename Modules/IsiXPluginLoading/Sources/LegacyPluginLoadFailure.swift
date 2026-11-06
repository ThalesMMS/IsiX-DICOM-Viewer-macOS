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

/// Why `-[NSBundle loadAndReturnError:]` refused a plugin made for Horos or
/// OsiriX, read from the error it gave.
///
/// The error's description only says that the bundle could not be loaded. The
/// reason dyld gave is in `NSDebugDescription`, as `dlopen(path, flags): ...`:
/// for a link error, the symbol the plugin's binary looks for in the
/// application and does not find there (a class, an ivar, a constant). That is
/// what whoever keeps the binary surface of the former SDK, and the plugin's
/// author, need to know. dyld's words are technical and are not translated.
public struct LegacyPluginLoadFailure: Sendable, Equatable {
    public let domain: String
    public let code: Int
    /// `NSDebugDescription` of the error, as dyld wrote it; nil when absent.
    public let dyldReason: String?

    public init(domain: String, code: Int, dyldReason: String?) {
        self.domain = domain
        self.code = code
        let trimmed = dyldReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dyldReason = trimmed?.isEmpty == false ? trimmed : nil
    }

    public init(_ error: NSError) {
        self.init(domain: error.domain, code: error.code,
                  dyldReason: error.userInfo[NSDebugDescriptionErrorKey] as? String)
    }

    /// The executable is for another architecture.
    public var isArchitectureMismatch: Bool {
        domain == NSCocoaErrorDomain && code == NSExecutableArchitectureMismatchError
    }

    /// dyld could not bind what the executable imports: a symbol the
    /// application or a linked library does not have, or a library that is
    /// not where the executable says.
    public var isLinkError: Bool {
        domain == NSCocoaErrorDomain && code == NSExecutableLinkError
    }

    /// The first line of dyld's reason without the `dlopen(path, flags): `
    /// that precedes it: the path is the plugin's own and the flags say nothing
    /// to the user. The lines after it (`Referenced from:`, `Expected in:`)
    /// stay in the log only.
    public var dyldMessage: String? {
        guard let reason = dyldReason else { return nil }
        var message = Substring(reason)
        if message.hasPrefix("dlopen("), let end = message.range(of: "): ") {
            message = message[end.upperBound...]
        }
        let line = message.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    /// The symbol dyld did not find, as the binary names it (`_Name`,
    /// `_OBJC_CLASS_$_Name`, `_OBJC_IVAR_$_Class.ivar`); nil when the reason
    /// names none.
    public var missingSymbol: String? {
        guard let message = dyldMessage else { return nil }
        // Flat namespace, the lookup of a plugin linked with -undefined dynamic_lookup.
        let flat = "symbol not found in flat namespace '"
        if let start = message.range(of: flat, options: .caseInsensitive) {
            let symbol = message[start.upperBound...].prefix { $0 != "'" }
            return symbol.isEmpty ? nil : String(symbol)
        }
        // Two-level namespace: "Symbol not found: _Name", then where it was expected.
        let twoLevel = "symbol not found: "
        if let start = message.range(of: twoLevel, options: .caseInsensitive) {
            let symbol = message[start.upperBound...].prefix { !$0.isWhitespace }
            return symbol.isEmpty ? nil : String(symbol)
        }
        return nil
    }

    /// What the plugin manager adds to the reason it shows for a link error:
    /// dyld's message, which names the missing symbol or library. Nil for other errors,
    /// whose description already says what happened.
    public var linkDetail: String? {
        isLinkError ? dyldMessage : nil
    }
}
