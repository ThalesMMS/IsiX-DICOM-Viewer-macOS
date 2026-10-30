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
/// and recovery after a crash.
///
/// Only version 1 bundles (`.isixplugin`, built with IsiXPluginKit) are loaded,
/// installed, activated, deactivated, moved, deleted or recovered. A plugin of
/// the former API (`.horosplugin`, `.osirixplugin`) is recognised by its
/// extension and refused with a reason: none of its code runs, and the bundle
/// is left where it is, as it is. A former plugin renamed to `.isixplugin` is
/// refused by `PluginInspector`, from its metadata and the frameworks it links.
public enum PluginAdmission {
    public enum Kind: Sendable, Equatable {
        /// A `.isixplugin` bundle: the plugin API version 1, if it inspects clean.
        case version1
        /// A plugin of the former API, by its extension.
        case formerAPI
        /// Anything else.
        case other
    }

    /// The extensions of the plugins made for Horos and OsiriX.
    public static var formerExtensions: Set<String> { LegacyPluginInventory.extensions }

    /// What a bundle is, by the extension of its path or file name. The case of
    /// the extension does not matter: the Finder and APFS ignore it too.
    public static func kind(of path: String) -> Kind {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if pathExtension == PluginContract.bundleExtension { return .version1 }
        if formerExtensions.contains(pathExtension) { return .formerAPI }
        return .other
    }

    /// Whether the bundle at this path, or with this file name, takes the
    /// version 1 path: loading and installation, which inspect it before
    /// anything else. A former plugin in the same folder, or with the same
    /// name, is not touched. `mayManage(bundleAt:)` also tells a former plugin
    /// renamed to `.isixplugin` apart.
    public static func isManaged(_ path: String) -> Bool {
        kind(of: path) == .version1
    }

    /// Whether the bundle is a former plugin: by its extension, or, under the
    /// version 1 extension, by the former keys it declares or the former SDK it
    /// links. Read from its files only.
    public static func isFormerPlugin(bundleAt url: URL, inspector: PluginInspector = PluginInspector()) -> Bool {
        switch kind(of: url.path) {
        case .formerAPI: return true
        case .version1: return inspector.inspect(bundleAt: url).isRenamedLegacyPlugin
        case .other: return false
        }
    }

    /// Whether the plugin manager may act on the bundle at this URL: a version 1
    /// bundle that is not a former plugin renamed. A bundle that does not
    /// inspect clean for another reason, a missing capability or another
    /// architecture, stays the user's to deactivate or delete.
    public static func mayManage(bundleAt url: URL, inspector: PluginInspector = PluginInspector()) -> Bool {
        kind(of: url.path) == .version1 && !isFormerPlugin(bundleAt: url, inspector: inspector)
    }

    /// Whether a path the application is asked to open is a plugin bundle of
    /// either API. Such a path goes to the plugin installation, which takes or
    /// refuses it, and never to the database import.
    public static func isPluginBundle(_ path: String) -> Bool {
        kind(of: path) != .other
    }

    /// Why the bundle may not be installed or loaded, read from its files only;
    /// nil when it may. A former plugin gets one diagnostic, from its
    /// extension, without its Info.plist or executable being read.
    public static func refusal(forBundleAt url: URL, inspector: PluginInspector = PluginInspector()) -> PluginInspection? {
        let inspection = inspector.inspect(bundleAt: url)
        return inspection.isLoadable ? nil : inspection
    }
}
