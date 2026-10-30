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

/// The plugin manager's entries for `.isixplugin` bundles, the plugin API
/// version 1 and the only plugins the application loads. Discovery,
/// `DoNotLoad.txt`, duplicates, `--LoadPlugin`, the isolated development
/// folders, protected mode, the signature check and the crash marker are the
/// plugin manager's; what the bundle is, and whether it may run or be
/// installed, is decided by IsiXPluginLoading before any of its code is
/// loaded, and IsiXPluginHost runs it.
extension PluginManager {
    @objc(loadIsiXPluginAtPath:)
    class func loadIsiXPlugin(atPath path: String!) {
        #if !MACAPPSTORE
        let diagnosticPath = (path as NSString?)?.resolvingAlias()
        guard DCMPix.isRunOsiriXInProtectedModeActivated() == false else {
            PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Blocked", comment: ""), NSLocalizedString("Loading is disabled by protected mode or the plugin signature policy. Check protected mode and obtain a compatible plugin from its author.", comment: ""))
            return
        }
        // Records its own refusal.
        guard PluginManager.isPluginBundleSignatureValid(path) else { return }
        let resolved = (path as NSString).resolvingAlias() as String
        PluginManager.startProtectForCrash(withPath: resolved)
        defer { PluginManager.endProtectForCrash() }
        var outcome: IsiXPluginHost.Outcome?
        // Loading the bundle runs its initializers: an Objective-C or C++
        // exception that escapes them is caught here, as one that escapes the
        // plugin's activation is in the host.
        do {
            try IsiXPluginExceptionGuard.perform {
                outcome = onMainActorSync { IsiXPluginHost.shared.loadPlugin(at: URL(fileURLWithPath: resolved)) }
            }
        } catch {
            let exception = IsiXPluginException(error as NSError)
            PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Load failed", comment: ""),
                                        String(format: NSLocalizedString("Plugin initialization failed: %@. Obtain an updated plugin from its author.", comment: ""),
                                               exception.description as NSString))
            NSLog("******** IsiX plugin loading exception: %@", exception.description)
            return
        }
        guard let outcome else { return }
        switch outcome.state {
        case .loaded:
            PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Loaded", comment: ""),
                                        NSLocalizedString("The bundle and its principal class loaded and registration completed in this session.", comment: ""))
        case .incompatible:
            PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Incompatible", comment: ""), outcome.reason)
            NSLog("IsiX plugin not loaded: %@: %@", resolved, outcome.reason)
        case .failed:
            PluginManagerCAPIRecordLoad(diagnosticPath, NSLocalizedString("Load failed", comment: ""), outcome.reason)
            NSLog("IsiX plugin load failed: %@: %@", resolved, outcome.reason)
        }
        #endif
    }

    /// Whether the bundle's metadata and executable make it loadable, read
    /// without loading it.
    class func isIsiXPluginCompatible(atPath path: String) -> Bool {
        PluginInspector().inspect(bundleAt: URL(fileURLWithPath: path)).isLoadable
    }

    /// Why a bundle cannot be installed, or nil when it can: a former plugin,
    /// a former plugin renamed to `.isixplugin`, or a version 1 bundle that does
    /// not inspect clean. Read from its files only.
    class func pluginInstallRefusal(atPath path: String!) -> String? {
        guard let path, !path.isEmpty else { return NSLocalizedString("Check the plugin bundle, architecture and signature.", comment: "") }
        return PluginAdmission.refusal(forBundleAt: URL(fileURLWithPath: path))?.summary
    }

    /// Whether the plugin manager may activate, deactivate, move or delete the
    /// bundle `name` of `folder`: a version 1 bundle, not a former plugin
    /// under the version 1 extension.
    class func mayManagePlugin(inFolder folder: Any?, named name: String) -> Bool {
        guard let folder = folder as? String else { return false }
        return PluginAdmission.mayManage(bundleAt: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }

    /// Whether a catalog's download is a version 1 plugin package: a former
    /// plugin is neither offered as an update nor downloaded for one.
    class func isVersion1Download(_ downloadURL: Any?) -> Bool {
        guard let text = downloadURL as? String, let url = URL(string: text) else { return false }
        var name = url.lastPathComponent
        if (name as NSString).pathExtension.lowercased() == "zip" { name = (name as NSString).deletingPathExtension }
        return PluginAdmission.isManaged(name)
    }

    class func addIsiXPluginMenuItems(_ filtersMenu: NSMenu?, _ roisMenu: NSMenu?, _ othersMenu: NSMenu?, _ dbMenu: NSMenu?) {
        nonisolated(unsafe) let menus = (filtersMenu, roisMenu, othersMenu, dbMenu)
        onMainActorSync {
            IsiXPluginHost.shared.addMenuItems(filters: menus.0, rois: menus.1, others: menus.2, database: menus.3)
        }
    }
}
