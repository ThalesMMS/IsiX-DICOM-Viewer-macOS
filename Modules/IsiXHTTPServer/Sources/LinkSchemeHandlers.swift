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

/// The schemes of the links the application declares, and what it does at
/// launch about a scheme the system hands to another application.
///
/// A link reaches the application only while the system has it as the
/// application that opens the scheme. Any application that declares the same
/// scheme can become that one, and the links of a RIS then open it instead,
/// with nothing shown here. The rule answers, for each declared scheme, with
/// the application the system names for it: nothing to do, tell the user, or
/// take the scheme back. It never answers for a scheme the application does
/// not declare, and takes one back only where the user chose that.
public enum LinkSchemeHandlers {
    /// The schemes the application declares, the one only it declares first.
    public static let declared = ["isix", "horos", "osirix"]

    /// Whether `scheme`, in any case, is one the application declares.
    public static func isDeclared(_ scheme: String) -> Bool {
        declared.contains(scheme.lowercased())
    }

    /// An application as the system names it: the identifier of its bundle
    /// and where the bundle is. Either may be unknown.
    public struct Application: Equatable, Sendable {
        public var identifier: String?
        /// The path of the bundle, with its links resolved by whoever read it.
        public var path: String?

        public init(identifier: String?, path: String?) {
            self.identifier = identifier
            self.path = path
        }
    }

    /// What the user chose to have done at launch, as the preference stores it.
    public enum StartupPolicy: Int, Sendable, CaseIterable {
        /// Tell the user and let them choose. What an absent or unknown value reads as.
        case ask = 0
        /// Take the schemes back without asking.
        case takeBack = 1
        /// Neither tell nor change anything.
        case never = 2

        public init(stored: Int) {
            self = StartupPolicy(rawValue: stored) ?? .ask
        }
    }

    public enum Action: Equatable, Sendable {
        case nothing
        /// The user is told which application opens the scheme.
        case notify
        /// The application makes itself the one that opens the scheme.
        case takeBack
    }

    /// What is done about one scheme, with the application that opens it now.
    public struct Decision: Equatable, Sendable {
        public var scheme: String
        public var handler: Application?
        public var action: Action

        public init(scheme: String, handler: Application?, action: Action) {
            self.scheme = scheme
            self.handler = handler
            self.action = action
        }
    }

    /// Whether `handler` is the application that is running, `running`.
    ///
    /// The identifiers have to be the same, whatever they are: a build for
    /// another channel has another identifier and is still itself when it
    /// runs, and an earlier copy with another identifier is another
    /// application. Where both paths are known they have to be the same too:
    /// a second copy with the same identifier, somewhere else, is the one the
    /// links would open. An application of which neither is known is not it.
    public static func isRunningApplication(_ handler: Application?, running: Application) -> Bool {
        guard let handler else { return false }
        var compared = false
        if let one = handler.identifier, let other = running.identifier {
            guard one.caseInsensitiveCompare(other) == .orderedSame else { return false }
            compared = true
        }
        if let one = handler.path, let other = running.path {
            guard trimmed(one) == trimmed(other) else { return false }
            compared = true
        }
        return compared
    }

    /// A path without the slashes a bundle's URL may end in.
    private static func trimmed(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// What to do at launch about each of `handlers`, the declared schemes
    /// with the application the system has for each (none when it has none).
    ///
    /// With the URL support off, nothing: a link would not be carried out
    /// anyway. A scheme the running application opens needs nothing. For
    /// another, the policy decides: tell the user, take it back, or nothing.
    /// A scheme that is not declared is left out of the answer.
    public static func decisions(handlers: [(scheme: String, handler: Application?)], running: Application,
                                 urlSupportOn: Bool, policy: StartupPolicy) -> [Decision] {
        handlers.compactMap { entry in
            let scheme = entry.scheme.lowercased()
            guard isDeclared(scheme) else { return nil }
            let action: Action
            if !urlSupportOn || isRunningApplication(entry.handler, running: running) {
                action = .nothing
            } else {
                switch policy {
                case .ask: action = .notify
                case .takeBack: action = .takeBack
                case .never: action = .nothing
                }
            }
            return Decision(scheme: scheme, handler: entry.handler, action: action)
        }
    }

    /// What unticking a scheme's box can do: the scheme goes back to the
    /// application that had it before this one took it, when that is known,
    /// still exists and is not this one; otherwise it stays.
    public enum Release: Equatable, Sendable {
        case giveBack(to: Application)
        case keep
    }

    public static func release(previous: Application?, previousExists: Bool, running: Application) -> Release {
        guard let previous, previous.path != nil, previousExists,
              !isRunningApplication(previous, running: running) else { return .keep }
        return .giveBack(to: previous)
    }
}
