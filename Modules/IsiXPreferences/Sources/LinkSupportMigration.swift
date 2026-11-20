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

/// What the first launch that tells the links from the XML-RPC server writes.
///
/// One switch used to turn on both the isix://, horos:// and osirix:// links
/// and the server, which answered any address without a password unless the
/// Listener pane narrowed it. The links now have a switch of their own, off
/// until chosen, and a server newly turned on answers this Mac only. Settings
/// kept from before, of an earlier version or carried over from Horos, go on
/// as they were:
///
/// - with the server on, the links are on too, and the server keeps the scope
///   it had: the one stored, or any address when none was, which is what it
///   answered;
/// - with the server off, the links are off, and stored so: a server turned
///   on later does not turn them on at the launch after it.
///
/// It is told what the user's own preferences hold, not what a launch was
/// given as an argument or what is registered: a launch given the server
/// stores nothing for the launches after it.
public enum LinkSupportMigration {
    /// The scope the server answered while none was stored: any address.
    public static let formerScope = 2

    public struct Writes: Equatable, Sendable {
        /// The switch of the links, always stored: it marks the migration as made.
        public var linkSupport: Bool
        /// The scope to store; nil leaves what is stored, or the registered one.
        public var accessScope: Int?

        public init(linkSupport: Bool, accessScope: Int?) {
            self.linkSupport = linkSupport
            self.accessScope = accessScope
        }
    }

    /// What to store, given the user's own values of the switch of the links,
    /// of the server and of its scope; nil once the switch of the links is
    /// stored, whatever it says.
    public static func writes(storedLinkSupport: Any?, storedServer: Any?, storedAccessScope: Any?) -> Writes? {
        guard storedLinkSupport == nil else { return nil }
        let serverOn = isOn(storedServer)
        return Writes(linkSupport: serverOn, accessScope: serverOn && storedAccessScope == nil ? formerScope : nil)
    }

    /// A switch as the preferences store it: a number, or a text as an earlier version wrote it.
    static func isOn(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? NSString { return text.boolValue }
        return false
    }
}
