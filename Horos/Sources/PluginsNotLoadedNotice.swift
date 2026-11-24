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

/// Says, once for each bundle and version, which plugins the launch did not
/// load and why: refused before opening (code for another architecture, a
/// newer system) or failed in the dynamic loader or in their initialization.
///
/// The plugins list has said it all along, but only to whoever opens it: the
/// user who installed a plugin built for Intel Macs only, with an installer
/// made for Horos or OsiriX and then the import, sees no more than a plugin
/// missing from the menus. Which bundles were already said is
/// `RefusedPluginNotice`'s, in a record beside the plugins folders that the
/// import from the Horos and OsiriX folders also reads at the next launch
/// (`notLoadedAtLastLaunch`).
enum PluginsNotLoadedNotice {
    /// The record of the bundles the last launch did not load.
    static var notice: RefusedPluginNotice {
        let folder = (PluginManager.userActivePluginsDirectoryPath()! as NSString).deletingLastPathComponent
        return RefusedPluginNotice(recordURL: URL(fileURLWithPath: folder).appendingPathComponent(RefusedPluginNotice.recordName))
    }

    /// Whether the last launch did not load the bundle at `url`, at the
    /// version it declares now (nil for none). Paths compare with their
    /// symbolic links resolved.
    static func notLoadedAtLastLaunch(_ recorded: [String: String], bundleAt url: URL, version: String?) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return recorded.contains { key, value in
            value == (version ?? "") && URL(fileURLWithPath: key).resolvingSymlinksInPath().path == path
        }
    }

    /// Shows the bundles of a discovery not said before. The alert waits for
    /// the end of the launch, so that it does not hold a link that launched
    /// the application. Called on the main thread, as the discovery runs.
    static func say(_ refusals: [RefusedPluginNotice.Refusal]) {
        let unsaid = notice.take(refusals)
        guard !unsaid.isEmpty else { return }
        let lines = unsaid.map { refusal -> String in
            let named = "\(refusal.name) (\(refusal.version ?? NSLocalizedString("no version", comment: "A plugin that declares no version")))"
            return refusal.reason.isEmpty ? named : named + "\n" + refusal.reason
        }
        let message = NSLocalizedString("These plugins could not be loaded. They stay in the plugins folder, and Plugins Manager lists them under Loading Details.", comment: "")
            + "\n\n" + lines.joined(separator: "\n\n")
        let show: @MainActor @Sendable () -> Void = {
            let answer = HorosAlertPanel.run(title: NSLocalizedString("Plugins Not Loaded", comment: ""), message: message,
                                             defaultButton: NSLocalizedString("OK", comment: ""),
                                             alternateButton: NSLocalizedString("Open Plugins Manager", comment: ""),
                                             otherButton: nil)
            if answer == HorosAlertPanel.alternateResponse {
                ProcessGraph.process.currentBrowser?.pluginManagerController?.showWindow(nil)
            }
        }
        MainActor.assumeIsolated {
            if !LaunchEnd.keeps("PluginsNotLoadedNotice", show) { onMainRunLoop(show) }
        }
    }
}
