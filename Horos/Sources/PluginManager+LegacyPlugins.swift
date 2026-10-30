//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXPluginLoading
import IsiXStorage

/// The plugins of the folders earlier versions used, and which plugins are
/// this app's own to activate, deactivate, delete or recover.
extension PluginManager {
    /// The key of a plugin list row that comes from an earlier version's
    /// folder: the plugin manager offers no action on it.
    @objc public static let legacyPluginKey = "legacy"

    /// Whether a plugin is in one of this app's own plugins folders, active or
    /// disabled. Only these are activated, deactivated, deleted or recovered.
    @objc(isInOwnPluginsFolder:)
    public class func isInOwnPluginsFolder(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        func resolved(_ folder: String) -> String {
            URL(fileURLWithPath: folder).resolvingSymlinksInPath().standardizedFileURL.path
        }
        let parent = resolved((path as NSString).deletingLastPathComponent)
        let own = ((PluginManager.activeDirectories() ?? []) + (PluginManager.inactiveDirectories() ?? [])).compactMap { $0 as? String }
        return own.contains { resolved($0) == parent }
    }

    /// Rows for the plugins list: the Horos and OsiriX plugins in the folders
    /// earlier versions used, read from their Info.plist only and shown as
    /// incompatible. They are not loaded, and nothing in them is changed.
    class func legacyPluginRows() -> [NSDictionary] {
        #if MACAPPSTORE
        return []
        #else
        let system = PluginManager.systemPluginsDomain()
        let systemFolder = StorageLocations.legacySupportFolder(inDomain: system)
        let folders = StorageLocations.legacyPluginsFolders(userDomain: PluginManager.userPluginsDomain(), systemDomain: system)
        let reason = NSLocalizedString("This plugin was made for Horos or OsiriX and is in %@, the folder earlier versions used. IsiX DICOM Viewer does not load plugins from that folder, and it did not open, move or change this one.", comment: "")
        return LegacyPluginInventory.list(folders: folders).map { entry in
            let allUsers = entry.folder.hasPrefix(systemFolder + "/")
            let osirix = entry.url.pathExtension.lowercased() == "osirixplugin"
            return [
                "name": entry.url.deletingPathExtension().lastPathComponent,
                "version": entry.version ?? "",
                "active": NSNumber(value: false),
                "allUsers": NSNumber(value: allUsers),
                "availability": PluginManager.availabilities()[allUsers ? 1 : 0],
                "typeIcon": NSImage(named: osirix ? "osirixplugin" : "horosplugin") as Any,
                "HorosCompatiblePlugin": "NO",
                "loadState": NSLocalizedString("Incompatible", comment: ""),
                "loadReason": String(format: reason, (entry.folder as NSString).abbreviatingWithTildeInPath),
                legacyPluginKey: NSNumber(value: true),
                "path": entry.url.path,
            ] as NSDictionary
        }
        #endif
    }
}
