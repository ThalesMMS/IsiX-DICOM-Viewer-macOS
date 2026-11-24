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
import Synchronization

/// The plugins the loader did not load, said to the user once.
///
/// A plugin whose inspection finds it cannot load on this Mac (code for
/// another architecture, a newer system, files missing), or that fails in the
/// dynamic loader or in its initialization, is recorded in the plugins list
/// and left out of the menus. Without a word at launch, the user who just
/// installed it only sees that it is not there: an installer made for Horos or
/// OsiriX leaves it in their folders, the import copies it, and nothing says
/// the Intel-only build cannot load on Apple silicon.
///
/// Each bundle is said once for each version it declares. The record keeps the
/// bundles the last launch did not load, by path, with their versions, so a
/// plugin that is fixed and later fails again is said again, and one that
/// keeps failing is not said at every launch. The import from the folders of
/// Horos and OsiriX reads it (`recorded()`) to replace such a plugin by
/// another build of its name.
public struct RefusedPluginNotice: Sendable {
    /// A bundle the loader refused, with the reason the plugins list shows.
    public struct Refusal: Equatable, Sendable {
        public let path: String
        public let version: String?
        public let reason: String

        public init(path: String, version: String?, reason: String) {
            self.path = path
            self.version = version
            self.reason = reason
        }

        /// The bundle's file name, as the plugins list names it.
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// The file that keeps the refusals of the last launch.
    public let recordURL: URL

    public init(recordURL: URL) {
        self.recordURL = recordURL
    }

    /// The name of the record beside the plugins folders.
    public static let recordName = ".RefusedPlugins.json"

    /// The refusals of this launch that were not said for the same bundle and
    /// version at an earlier one, in their order; the record becomes this
    /// launch's refusals. A record that cannot be read counts as empty, and
    /// one that cannot be written is left as it was: the refusals are then
    /// said again at the next launch, which is better than never.
    public func take(_ refusals: [Refusal]) -> [Refusal] {
        let said = read()
        var now: [String: String] = [:]
        for refusal in refusals { now[refusal.path] = refusal.version ?? "" }
        let unsaid = refusals.filter { said[$0.path] != ($0.version ?? "") }
        if now != said {
            if now.isEmpty {
                try? FileManager.default.removeItem(at: recordURL)
            } else if let data = try? JSONEncoder().encode(now) {
                try? FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: recordURL, options: .atomic)
            }
        }
        return unsaid
    }

    /// The bundles the last launch did not load: path and declared version
    /// ("" for none).
    public func recorded() -> [String: String] { read() }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return record
    }
}

public extension RefusedPluginNotice {
    /// The refusals the loader records while it goes through the plugins
    /// folders at launch, for the notice at the end. Outside a discovery,
    /// and in Protected Mode, where none begins, nothing is kept.
    enum Discovery {
        private static let refusals = Mutex<[Refusal]?>(nil)

        public static func begin() { refusals.withLock { $0 = [] } }

        /// Keeps a refusal when a discovery is under way.
        public static func add(_ refusal: Refusal) { refusals.withLock { $0?.append(refusal) } }

        /// What the discovery kept, in order, or nil when none was under way.
        public static func end() -> [Refusal]? {
            refusals.withLock { kept in
                defer { kept = nil }
                return kept
            }
        }
    }
}

public extension PluginInspection {
    /// The architectures of the executable when none of them is the one this
    /// process runs as; nil when the architecture is not what stops it.
    var foreignArchitectures: [String]? {
        for diagnostic in diagnostics {
            if case .architectureMismatch(let found, _) = diagnostic { return found }
        }
        return nil
    }
}
