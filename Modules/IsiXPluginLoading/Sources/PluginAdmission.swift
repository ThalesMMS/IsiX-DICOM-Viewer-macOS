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

/// Which plugin bundles the application takes, at every entry: discovery,
/// `--LoadPlugin`, installation, opening a file, a catalog download or update,
/// and recovery after a crash; and which loader each one goes to.
///
/// Three formats are taken. A `.isixplugin` bundle, built with IsiXPluginKit,
/// goes to the version 1 loader. A plugin made for Horos or OsiriX
/// (`.horosplugin`, `.osirixplugin`) goes, unchanged, to the loader of the
/// former API. The extension alone decides: a `.isixplugin` that the version 1
/// inspection refuses, a former plugin renamed among them, stays refused and is
/// never tried as a former plugin.
public enum PluginAdmission {
    public enum Kind: Sendable, Equatable {
        /// A `.isixplugin` bundle: the plugin API version 1, if it inspects clean.
        case version1
        /// A plugin of the former API, by its extension.
        case formerAPI
        /// Anything else.
        case other
    }

    /// The loader a plugin bundle goes to.
    public enum Loader: Sendable, Equatable {
        /// IsiXPluginKit's: the bundle's entry class registers its commands in code.
        case version1
        /// The former API's: the bundle's Info.plist declares its role and menu
        /// items, and its principal class answers the messages of PluginFilter.
        case formerAPI
    }

    /// The extensions of the plugins made for Horos and OsiriX.
    public static let formerExtensions: Set<String> = ["horosplugin", "osirixplugin"]

    /// What a bundle is, by the extension of its path or file name. The case of
    /// the extension does not matter: the Finder and APFS ignore it too.
    public static func kind(of path: String) -> Kind {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if pathExtension == PluginContract.bundleExtension { return .version1 }
        if formerExtensions.contains(pathExtension) { return .formerAPI }
        return .other
    }

    /// The loader the bundle at this path, or with this file name, goes to; nil
    /// for what is not a plugin bundle.
    public static func loader(for path: String) -> Loader? {
        switch kind(of: path) {
        case .version1: return .version1
        case .formerAPI: return .formerAPI
        case .other: return nil
        }
    }

    /// Whether the bundle at this path, or with this file name, is a plugin the
    /// application loads, installs, activates, deactivates, moves, deletes and
    /// recovers: one of the three formats.
    public static func isManaged(_ path: String) -> Bool {
        loader(for: path) != nil
    }

    /// Whether the plugin manager may act on the bundle at this URL. Every
    /// plugin bundle in its folders is the user's to deactivate or delete, also
    /// one that does not inspect clean: another architecture, a missing
    /// capability, or a former plugin renamed to `.isixplugin`.
    public static func mayManage(bundleAt url: URL) -> Bool {
        isManaged(url.path)
    }

    /// Whether a path the application is asked to open is a plugin bundle.
    /// Such a path goes to the plugin installation, which takes or refuses it,
    /// and never to the database import.
    public static func isPluginBundle(_ path: String) -> Bool {
        kind(of: path) != .other
    }

    /// Why the bundle may not be installed or loaded, read from its files only;
    /// nil when it may. Each format is inspected by the rules of its loader.
    public static func refusal(forBundleAt url: URL, inspector: PluginInspector = PluginInspector()) -> PluginInspection? {
        let inspection = inspector.inspect(bundleAt: url)
        return inspection.isLoadable ? nil : inspection
    }
}
