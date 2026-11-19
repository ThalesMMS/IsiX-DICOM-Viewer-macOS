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

/// What the entries of the plugins folders offer to load, asked entry by entry
/// in the order the folders are read.
///
/// An entry is a bundle, or a symbolic link or a Finder alias to one, which a
/// user or an installer puts there to keep a single copy of a plugin. The
/// plugins list, the import and the commands that activate, deactivate and
/// delete a plugin all know an entry by its own name, so the name of the entry
/// decides whether it is a plugin; what it leads to must be one too, and is
/// what loads. A bundle is offered once, however many entries reach it: the
/// loader takes a second bundle of a name for a duplicate, and the same bundle
/// twice is not one. An entry that leads to nothing is answered as such, so
/// that the rest of its folder is still read.
///
/// The bundles already offered are kept from one folder to the next: make one
/// scan for a whole discovery.
public struct PluginFolderScan: Sendable {
    public enum Entry: Equatable, Sendable {
        /// Load the bundle at this path: the entry's, with the links and
        /// aliases in it resolved.
        case load(String)
        /// The entry leads to the bundle at `resolved`, which the earlier
        /// entry at `entry` already offered.
        case sameBundle(resolved: String, entry: String)
        /// A symbolic link to an item that is gone, links that lead back to
        /// one another, or an alias whose original is gone, whatever the
        /// entry's name; with what the link names, when the entry is a link.
        case leadsNowhere(destination: String?)
        /// The name of the entry is not a plugin's, or the name of what it
        /// leads to is not; with where it leads when it is a link or an alias.
        /// An entry of another name that is neither is not followed at all.
        case notAPlugin(destination: String?)
    }

    private let isPlugin: @Sendable (String) -> Bool
    /// The entry that offered each bundle, by the bundle's path and by its file.
    private var offered: [String: String] = [:]

    /// `isPlugin` answers whether a file name is a plugin bundle's.
    public init(isPlugin: @escaping @Sendable (String) -> Bool) {
        self.isPlugin = isPlugin
    }

    /// What the entry at `path` offers. An entry answered `.load` counts as
    /// offered from then on.
    public mutating func judge(entryAt path: String) -> Entry {
        guard isPlugin((path as NSString).lastPathComponent) else {
            // The folder's own files (.DS_Store, DoNotLoad.txt, the copies kept
            // of replaced plugins) are not resolved: only a link or an alias
            // is, to say where it leads.
            guard Self.isLinkOrAlias(path) else { return .notAPlugin(destination: nil) }
            guard let destination = Self.destination(ofEntryAt: path) else {
                return .leadsNowhere(destination: Self.linkDestination(path))
            }
            return .notAPlugin(destination: destination)
        }
        guard let resolved = Self.destination(ofEntryAt: path) else {
            return .leadsNowhere(destination: Self.linkDestination(path))
        }
        guard isPlugin((resolved as NSString).lastPathComponent) else { return .notAPlugin(destination: resolved) }
        let keys = Self.identities(ofBundleAt: resolved)
        for key in keys {
            if let first = offered[key] { return .sameBundle(resolved: resolved, entry: first) }
        }
        for key in keys { offered[key] = path }
        return .load(resolved)
    }

    // MARK: where an entry leads

    /// The path the entry at `path` leads to, with every symbolic link and
    /// alias in it resolved; the path itself for an item that is neither, or
    /// that does not exist. Nil when it leads nowhere: a link to an item that
    /// is gone, links that lead back to one another, or an alias whose
    /// original is gone or cannot be reached without asking the user.
    public static func destination(ofEntryAt path: String) -> String? {
        guard let resolved = (path as NSString).resolvingSymlinksAndAliases() else { return nil }
        // An alias that cannot be resolved is answered as it is, the alias
        // file. The alias flag is also set for a symbolic link, which the
        // resolution never ends on.
        let values = try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
        if values?.isAliasFile == true, values?.isSymbolicLink == false { return nil }
        return resolved
    }

    /// Whether the item at `path` is itself a symbolic link or a Finder alias.
    public static func isLinkOrAlias(_ path: String) -> Bool {
        // The alias flag covers both.
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile == true
    }

    /// What the symbolic link at `path` names, as it is written in the link;
    /// nil when the item is not a symbolic link.
    public static func linkDestination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// The form two paths to one item share: the links in the path resolved,
    /// and canonically equivalent Unicode spellings made one. It is the form
    /// the load outcomes of the plugins list are kept by.
    public static func canonical(_ path: String) -> String {
        ((path as NSString).resolvingSymlinksInPath as NSString).precomposedStringWithCanonicalMapping
    }

    /// What says two resolved paths are one bundle: the canonical path, and
    /// the file itself, which a path written in another case, or through
    /// another mount of its volume, still names.
    private static func identities(ofBundleAt path: String) -> [String] {
        var keys = ["path " + canonical(path)]
        var info = stat()
        if stat(FileManager.default.fileSystemRepresentation(withPath: path), &info) == 0 {
            keys.append("file \(info.st_dev) \(info.st_ino)")
        }
        return keys
    }
}
