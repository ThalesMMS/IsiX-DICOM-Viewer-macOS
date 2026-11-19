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

// The selectors of the plugin catalogue the Plugins Manager had in Horos and
// OsiriX: two tabs that listed the plugins of each project's web site and
// downloaded them. The catalogue is gone, with its tabs and web views; a plugin
// built for that SDK may still send these, so they answer: no plugin is
// available, and nothing is loaded or downloaded.
extension PluginManagerController {
    private static let reason = "the catalogue of downloadable plugins is not part of the application"

    private func inert(_ selector: String) {
        FormerSDKFacade.inert("PluginManagerController", selector, because: Self.reason)
    }

    @objc(availableHorosPlugins) func legacyAvailableHorosPlugins() -> [Any] { inert("-availableHorosPlugins"); return [] }
    @objc(availableOsiriXPlugins) func legacyAvailableOsiriXPlugins() -> [Any] { inert("-availableOsiriXPlugins"); return [] }
    @objc(generateAvailableHorosPluginsMenu) func legacyGenerateAvailableHorosPluginsMenu() { inert("-generateAvailableHorosPluginsMenu") }
    @objc(generateAvailableOsiriXPluginsMenu) func legacyGenerateAvailableOsiriXPluginsMenu() { inert("-generateAvailableOsiriXPluginsMenu") }
    @objc(setHorosPluginURL:) func legacySetHorosPluginURL(_ url: String?) { inert("-setHorosPluginURL:") }
    @objc(setOsiriXPluginURL:) func legacySetOsiriXPluginURL(_ url: String?) { inert("-setOsiriXPluginURL:") }
    @objc(setHorosPluginDownloadURL:) func legacySetHorosPluginDownloadURL(_ url: String?) { inert("-setHorosPluginDownloadURL:") }
    @objc(setOsiriXPluginDownloadURL:) func legacySetOsiriXPluginDownloadURL(_ url: String?) { inert("-setOsiriXPluginDownloadURL:") }
    @objc(setURLforHorosPluginWithName:) func legacySetURLForHorosPlugin(named name: String?) { inert("-setURLforHorosPluginWithName:") }
    @objc(setURLforOsiriXPluginWithName:) func legacySetURLForOsiriXPlugin(named name: String?) { inert("-setURLforOsiriXPluginWithName:") }
    @objc(changeHorosPluginWebView:) func legacyChangeHorosPluginWebView(_ sender: Any?) { inert("-changeHorosPluginWebView:") }
    @objc(changeOsiriXPluginWebView:) func legacyChangeOsiriXPluginWebView(_ sender: Any?) { inert("-changeOsiriXPluginWebView:") }
    @objc(downloadHorosPlugin:) func legacyDownloadHorosPlugin(_ sender: Any?) { inert("-downloadHorosPlugin:") }
    @objc(downloadOsiriXPlugin:) func legacyDownloadOsiriXPlugin(_ sender: Any?) { inert("-downloadOsiriXPlugin:") }
    @objc(loadSubmitPluginPage) func legacyLoadSubmitPluginPage() { inert("-loadSubmitPluginPage") }
}
