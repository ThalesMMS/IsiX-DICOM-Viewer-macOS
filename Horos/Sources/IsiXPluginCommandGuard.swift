//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Calling a plugin's code - its activation and its commands - at the boundary
// between the application and the plugin. The call runs inside
// IsiXPluginExceptionGuard (Objective-C++),
// so that an Objective-C or C++ exception the plugin lets escape becomes a
// failure of the plugin instead of ending the application. This file uses only
// the plugin kit and that guard, so a test can compile it without the
// application.

import Foundation
@_spi(IsiXHost) import IsiXPluginKit

/// An exception that escaped a plugin's code and was caught at the boundary.
struct IsiXPluginException: Error, CustomStringConvertible {
    enum Kind: String { case objectiveC = "Objective-C", cxx = "C++" }

    let kind: Kind
    /// The exception's name (Objective-C) or type (C++).
    let type: String
    /// Its reason (Objective-C) or what() (C++), or the type when there is none.
    let reason: String

    init(_ error: NSError) {
        kind = error.domain == IsiXPluginCxxExceptionErrorDomain ? .cxx : .objectiveC
        type = error.localizedFailureReason ?? (kind == .cxx ? "(unknown type)" : "NSException")
        reason = error.localizedDescription
    }

    /// "an Objective-C exception NSRangeException: reason", "a C++ exception std::runtime_error: what".
    var description: String {
        let article = kind == .cxx ? "a" : "an"
        return reason == type ? "\(article) \(kind.rawValue) exception \(type)" : "\(article) \(kind.rawValue) exception \(type): \(reason)"
    }
}

/// What came of calling a plugin's code: its activation or a command.
enum IsiXCommandOutcome {
    /// The call returned.
    case ran
    /// The plugin threw, or the runtime refused the command.
    case failed(any Error)
    /// An exception escaped the plugin's code.
    case raised(IsiXPluginException)
}

/// Calls `body` inside the exception guard. The closure escapes to the guard:
/// a non-escaping one is checked by Swift on return, and an exception may
/// leave an unwound frame holding it.
@MainActor
private func IsiXGuardedCall(_ body: @escaping @MainActor () throws -> Void) -> IsiXCommandOutcome {
    var thrown: (any Error)?
    do {
        try IsiXPluginExceptionGuard.perform {
            do {
                try body()
            } catch {
                thrown = error
            }
        }
    } catch {
        return .raised(IsiXPluginException(error as NSError))
    }
    return thrown.map(IsiXCommandOutcome.failed) ?? .ran
}

extension IsiXPluginRuntime {
    /// Runs the command inside the exception guard.
    func runGuarded(commandID: String) -> IsiXCommandOutcome {
        IsiXGuardedCall { try self.run(commandID: commandID) }
    }

    /// Activates the plugin inside the exception guard. When an exception
    /// escapes, the plugin is abandoned: what it registered is removed and it
    /// is not called again.
    func activateGuarded() -> IsiXCommandOutcome {
        let outcome = IsiXGuardedCall { try self.activate() }
        if case .raised(let exception) = outcome {
            abandon(reason: exception.description)
        }
        return outcome
    }

    /// The title of the command, or its identifier when the plugin has no such command.
    func title(ofCommand commandID: String) -> String {
        commands.first { $0.id == commandID }?.title ?? commandID
    }
}
