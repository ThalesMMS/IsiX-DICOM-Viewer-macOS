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

// What a plugin answers when the application asks it for the events of a
// viewer and for the items it adds to a toolbar. The application asks every
// plugin that answers these selectors; the former SDK left them to the
// plugins that had something to say, and later headers of the plugin SDK
// declare them for the class itself, so that a plugin built with those
// headers may send them to super. The class answers what a plugin with
// nothing to say would: the event is not its own, and it adds no item.
extension PluginFilter {
    @objc(handleEvent:forViewer:) func laterSDKHandle(_ event: NSEvent?, forViewer viewer: Any?) -> Bool { false }
    @objc(handleEvent:forVRViewer:) func laterSDKHandle(_ event: NSEvent?, forVRViewer viewer: Any?) -> Bool { false }
    @objc(toolbarAllowedIdentifiersForViewer:) func laterSDKToolbarIdentifiers(forViewer viewer: Any?) -> [Any]? { nil }
    @objc(toolbarAllowedIdentifiersForVRViewer:) func laterSDKToolbarIdentifiers(forVRViewer viewer: Any?) -> [Any]? { nil }
    @objc(toolbarAllowedIdentifiersForBrowserController:) func laterSDKToolbarIdentifiers(forBrowserController browser: Any?) -> [Any]? { nil }
    @objc(toolbarItemForItemIdentifier:forViewer:) func laterSDKToolbarItem(_ identifier: String?, forViewer viewer: Any?) -> NSToolbarItem? { nil }
    @objc(toolbarItemForItemIdentifier:forVRViewer:) func laterSDKToolbarItem(_ identifier: String?, forVRViewer viewer: Any?) -> NSToolbarItem? { nil }
    @objc(toolbarItemForItemIdentifier:forBrowserController:)
    func laterSDKToolbarItem(_ identifier: String?, forBrowserController browser: Any?) -> NSToolbarItem? { nil }
}
