//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A plugin of API 1 whose commands let exceptions escape, for
// tests/test-plugin-command-exceptions.py and the in-app check: Objective-C,
// C++ (std::runtime_error and an int), a Swift error, a command that returns,
// and a command that needs a viewer. `description` lists the commands entered,
// in order. Two more entry classes let an exception escape from activation.

import Foundation
import IsiXPluginKit

struct ProbeSwiftError: LocalizedError {
    var errorDescription: String? { "the probe threw a Swift error" }
}

/// Registers a command, an observation and a task, then lets an exception of
/// its own code escape from its activation; the test and the in-app check
/// name these as the entry class.
@MainActor
func registerThenEscape(_ context: IsiXPluginContext, _ escape: () -> Void) throws -> IsiXObservation {
    try context.register(IsiXCommand(id: "never", title: "Exception Probe: Never Shown")) { _ in }
    let observation = try context.observe { _ in }
    try context.startTask(named: "Wait for cancellation") { _ in
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
    }
    escape()
    return observation
}

/// Its activation raises an NSException.
public final class RaisingActivationPlugin: IsiXPlugin {
    private var observation: IsiXObservation?
    public init() {}
    public func activate(with context: IsiXPluginContext) throws {
        observation = try registerThenEscape(context) { ProbeRaiseObjectiveC() }
    }
}

/// Its activation throws std::runtime_error.
public final class ThrowingActivationPlugin: IsiXPlugin {
    private var observation: IsiXObservation?
    public init() {}
    public func activate(with context: IsiXPluginContext) throws {
        observation = try registerThenEscape(context) { ProbeThrowCxx() }
    }
}

public final class ExceptionProbePlugin: IsiXPlugin, CustomStringConvertible {
    private var entered: [String] = []
    /// What `description` shows, refreshed on the main actor after each change.
    private nonisolated(unsafe) var summary = "entered"

    public init() {}

    public nonisolated var description: String { summary }

    private func enter(_ id: String) {
        entered.append(id)
        summary = "entered " + entered.joined(separator: ",")
    }

    public func activate(with context: IsiXPluginContext) throws {
        let commands: [(String, String, IsiXCommand.Requirement, () throws -> Void)] = [
            ("raise-objc", "Raise Objective-C", .none, { ProbeRaiseObjectiveC() }),
            ("throw-cxx", "Throw C++", .none, { ProbeThrowCxx() }),
            ("throw-int", "Throw Int", .none, { ProbeThrowInt() }),
            ("throw-swift", "Throw Swift", .none, { throw ProbeSwiftError() }),
            ("return", "Return", .none, {}),
            ("viewer", "Viewer Command", .viewer, {}),
        ]
        for (id, title, requirement, body) in commands {
            try context.register(IsiXCommand(id: id, title: "Exception Probe: \(title)", requirement: requirement)) { [weak self] _ in
                self?.enter(id)
                try body()
            }
        }
    }
}
