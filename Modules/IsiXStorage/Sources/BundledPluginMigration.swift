//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Darwin
import Foundation

/// Takes the plugins that were installed inside the application out of it, into
/// the user's plugins folders.
///
/// The plugin manager used to offer the application's own `Contents/PlugIns` as
/// a place to install a plugin. A plugin there is lost every time the
/// application is replaced, by an update or by hand, and its presence breaks
/// the seal of the application's signature: the signed bundle lists every file
/// it has, and a file it does not list makes it invalid. Taking the plugin out
/// again makes the seal valid again, so a plugin found there is *moved*, not
/// copied: to the user's active folder from `PlugIns`, to the disabled one from
/// the folder beside it.
///
/// Nothing of the user's is replaced or removed: a plugin whose name the user's
/// folders already have stays where it is. When the application is not the
/// user's to change, the plugin is copied, so that it survives the next update,
/// and its copy inside stays.
public struct BundledPluginMigration {
    public enum Outcome: Equatable, Sendable {
        /// Now in the user's folder, and no longer inside the application.
        case moved(to: URL)
        /// Copied to the user's folder; the one inside could not be removed,
        /// for the reason given.
        case copied(to: URL, String)
        /// The user's folders have a plugin of this name, at the URL given.
        /// `sameBuild` says it is this very plugin, as an earlier launch that
        /// could only copy it left things.
        case nameTaken(by: URL, sameBuild: Bool)
        /// Left where it was, for the reason given.
        case failed(String)
    }

    public struct Entry: Equatable, Sendable {
        public let source: URL
        public let outcome: Outcome
    }

    private let folders: [(source: URL, active: Bool)]
    private let userDomain: String
    private var staging: URL {
        URL(fileURLWithPath: StorageLocations.supportFolder(for: .direct, inDomain: userDomain), isDirectory: true)
            .appendingPathComponent(".BundledPlugins-staging", isDirectory: true)
    }

    /// `bundled` is the application's folder of active plugins and
    /// `bundledDisabled` the one of the plugins disabled from it.
    public init(bundled: URL?, bundledDisabled: URL?, userDomain: String) {
        folders = [(bundled, true), (bundledDisabled, false)].compactMap { folder, active in folder.map { ($0, active) } }
        self.userDomain = userDomain
    }

    /// Moves every plugin bundle found inside the application, and answers
    /// what became of each. `isPlugin` says whether a file name is a plugin
    /// bundle's: whatever else the application keeps in that folder, its own
    /// extensions among it, is not looked at.
    public func run(isPlugin: (String) -> Bool) -> [Entry] {
        let files = FileManager.default
        var entries: [Entry] = []
        defer { try? files.removeItem(at: staging) }
        for (folder, active) in folders {
            for source in Self.bundles(in: folder, isPlugin: isPlugin) {
                entries.append(Entry(source: source, outcome: take(source, active: active, isPlugin: isPlugin)))
            }
        }
        // The disabled folder was made inside the application for these plugins.
        for (folder, active) in folders where !active {
            if (try? files.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? files.removeItem(at: folder) }
        }
        return entries
    }

    /// The plugins still inside the application that the user's folder has as
    /// they are: the loader passes over them instead of reporting a duplicate.
    public static func duplicatesLeftInside(_ entries: [Entry]) -> [URL] {
        entries.compactMap { entry in
            switch entry.outcome {
            case .copied: return entry.source
            case .nameTaken(_, let sameBuild): return sameBuild ? entry.source : nil
            case .moved, .failed: return nil
            }
        }
    }

    private static func bundles(in folder: URL, isPlugin: (String) -> Bool) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                       options: .skipsHiddenFiles)) ?? [])
            .filter { url in
                guard isPlugin(url.lastPathComponent),
                      let attributes = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
                return attributes.isDirectory == true && attributes.isSymbolicLink == false
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func nameKey(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func take(_ source: URL, active: Bool, isPlugin: (String) -> Bool) -> Outcome {
        let files = FileManager.default
        let key = Self.nameKey(source)
        for folder in [true, false].map({ URL(fileURLWithPath: StorageLocations.pluginsFolder(inDomain: userDomain, active: $0)) }) {
            if let existing = Self.bundles(in: folder, isPlugin: isPlugin).first(where: { Self.nameKey($0) == key }) {
                return .nameTaken(by: existing, sameBuild: existing.lastPathComponent == source.lastPathComponent
                                  && PluginBundleFiles.sameBuild(existing, source))
            }
        }
        let folder = URL(fileURLWithPath: StorageLocations.pluginsFolder(inDomain: userDomain, active: active))
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            // On one volume, with an application the user may change, this is
            // the whole move, and it never leaves half a bundle anywhere.
            if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return .moved(to: destination) }
            guard errno != EEXIST else { return .nameTaken(by: destination, sameBuild: false) }

            // Another volume, or an application that is not the user's to
            // change: a complete copy first, published under its name at once.
            try files.createDirectory(at: staging, withIntermediateDirectories: true)
            let staged = staging.appendingPathComponent(source.lastPathComponent)
            if files.fileExists(atPath: staged.path) { try files.removeItem(at: staged) }
            defer { try? files.removeItem(at: staged) }
            try files.copyItem(at: source, to: staged)
            guard renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { return .nameTaken(by: destination, sameBuild: false) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
        // Removing a bundle from a folder that cannot be changed would empty the
        // bundle and leave its shell behind: it is not attempted.
        guard files.isWritableFile(atPath: source.deletingLastPathComponent().path) else {
            return .copied(to: destination, CocoaError(.fileWriteNoPermission).localizedDescription)
        }
        do {
            try files.removeItem(at: source)
            return .moved(to: destination)
        } catch {
            return .copied(to: destination, error.localizedDescription)
        }
    }
}

/// What two plugin bundles have on disk.
enum PluginBundleFiles {
    /// Whether two bundles are one plugin as it was built: the same Info.plist
    /// and the same executables.
    static func sameBuild(_ first: URL, _ second: URL) -> Bool {
        let files = FileManager.default
        func info(_ bundle: URL) -> Data? { try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) }
        func executables(_ bundle: URL) -> [String] {
            ((try? files.contentsOfDirectory(atPath: bundle.appendingPathComponent("Contents/MacOS").path)) ?? []).sorted()
        }
        guard let information = info(first), information == info(second) else { return false }
        let names = executables(first)
        guard names == executables(second) else { return false }
        return names.allSatisfy { name in
            files.contentsEqual(atPath: first.appendingPathComponent("Contents/MacOS/\(name)").path,
                                andPath: second.appendingPathComponent("Contents/MacOS/\(name)").path)
        }
    }
}
