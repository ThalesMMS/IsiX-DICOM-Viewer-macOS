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

/// Ends the application so that it opens again, for a setting that takes
/// effect only at launch.
///
/// The order is the point. The questions of the Quit command come first, and
/// a refusal schedules nothing. The reopening is scheduled next, while this
/// process is still there to be waited for, and only then does the
/// application quit. When the reopening cannot be scheduled the application
/// stays open: the caller tells the user, who is not left without it.
@MainActor struct ApplicationRestart {

    enum Outcome: Equatable {
        /// The quit was refused, by the user or by work under way.
        case refused
        /// The reopening could not be scheduled, for the reason given; the
        /// application goes on.
        case notScheduled(String)
        /// The reopening is scheduled and the application was told to quit.
        case quitting
    }

    /// Whether the application may quit now, asked as the Quit command asks.
    let agree: @MainActor () -> Bool
    /// Schedules the reopening for when this process has ended.
    let reopen: @MainActor () throws -> Void
    /// The rest of quitting, without asking again.
    let quit: @MainActor () -> Void

    /// The arguments a copy that restarts is given: those of the launch, after
    /// the executable, without the preferences named in `stale`. A preference
    /// given at the launch is a `-name value` pair, and both go. What moved a
    /// database names its location here: the one the launch was given is the
    /// folder that is no longer there.
    nonisolated static func arguments(ofLaunch launch: [String], dropping stale: Set<String> = []) -> [String] {
        var kept = [String]()
        var rest = launch.dropFirst()
        while let argument = rest.first {
            rest = rest.dropFirst()
            if argument.hasPrefix("-"), stale.contains(String(argument.dropFirst())) {
                rest = rest.dropFirst()
            } else {
                kept.append(argument)
            }
        }
        return kept
    }

    @discardableResult func run() -> Outcome {
        guard agree() else { return .refused }
        do {
            try reopen()
        } catch {
            return .notScheduled(error.localizedDescription)
        }
        quit()
        return .quitting
    }
}
