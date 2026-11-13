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

/// The note the application keeps on disk while the code of a plugin is on the
/// stack, and what the next launch offers when it finds one left behind.
///
/// The note is written before a plugin's bundle is opened and before one of its
/// commands or hooks is entered, and removed when that returns. An application
/// that is asked to quit removes it as well, whatever is on the stack: a plugin
/// that sits in its own modal dialog while the user quits, or while an update
/// replaces the application, did not stop anything. So a note found at launch
/// means the previous run ended without being asked to: a crash, a forced quit,
/// a kill, or the Mac going down.
///
/// What it says of the plugin depends on what the plugin was doing. One that
/// was being loaded may stop every launch at the same point, so the launch that
/// finds the note opens without plugins and proposes to put the previous copy
/// back or to switch the plugin off. One that had loaded and was running a
/// command did not stop the launch, and the end of the run may have had nothing
/// to do with it: the plugin stays unless the user says otherwise, and the
/// session opens as usual.
public struct PluginCrashMarker: Equatable, Sendable {
    /// What the plugin was doing when the note was written.
    public enum Phase: String, Sendable, CaseIterable {
        /// Its bundle was being opened, or registered with the menus at launch.
        case loading
        /// It had loaded, and one of its commands or hooks was running.
        case running
    }

    /// The bundle the note names, as it was written.
    public var pluginPath: String
    public var phase: Phase

    public init(pluginPath: String, phase: Phase) {
        self.pluginPath = pluginPath
        self.phase = phase
    }

    /// Reads what a note holds. The first line is the path. A second line
    /// names the phase; the versions that only knew of loading wrote the path
    /// alone, which reads as loading, and so does a phase this version does
    /// not know.
    public init(contents: String) {
        let lines = contents.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        pluginPath = lines.first.map(String.init) ?? ""
        let named = lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        phase = Phase(rawValue: named) ?? .loading
    }

    /// What the note holds. A loading plugin is written as the versions before
    /// the phase wrote it, the path alone, so that an earlier version that
    /// finds the note of this one still reads the path of a plugin that stops
    /// the launch.
    public var contents: String {
        switch phase {
        case .loading: return pluginPath
        case .running: return pluginPath + "\n" + phase.rawValue
        }
    }

    /// What the user may answer to the note.
    public enum Choice: Sendable, Equatable {
        /// Put back the copy an update of the plugin replaced.
        case restorePrevious
        /// Move the plugin to the disabled folder.
        case disablePlugin
        /// Leave the plugin where it is.
        case keepPlugin
    }

    /// What the launch that finds the note does.
    public struct Recovery: Sendable, Equatable {
        /// The answers offered, the default one first: at most three.
        public let choices: [Choice]
        /// Whether this session opens without loading any plugin.
        public let opensWithoutPlugins: Bool

        /// The answer a button stands for, by its position; a position that has
        /// no button leaves the plugin alone.
        public func choice(at position: Int) -> Choice {
            choices.indices.contains(position) ? choices[position] : .keepPlugin
        }
    }

    /// `canRestore` says whether a previous copy of the plugin is kept, and
    /// `canDisable` whether the plugin is in a folder that has a disabled one
    /// beside it.
    public func recovery(canRestore: Bool, canDisable: Bool) -> Recovery {
        let restore: [Choice] = canRestore ? [.restorePrevious] : []
        let disable: [Choice] = canDisable ? [.disablePlugin] : []
        switch phase {
        case .loading:
            return Recovery(choices: restore + disable + [.keepPlugin], opensWithoutPlugins: true)
        case .running:
            return Recovery(choices: [.keepPlugin] + disable + restore, opensWithoutPlugins: false)
        }
    }
}
