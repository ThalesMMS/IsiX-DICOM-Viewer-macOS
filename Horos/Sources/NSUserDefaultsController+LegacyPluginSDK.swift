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

// The class methods NSUserDefaultsController had in the plugin SDK of Horos
// and OsiriX for the sharing and web server preferences. The application reads
// them from NSUserDefaults; a plugin built for that SDK still asks here, from
// any thread, so these answer what NSUserDefaults answers.
extension NSUserDefaultsController {
    @objc(IsBonjourSharingActive) nonisolated class func legacyIsBonjourSharingActive() -> Bool { UserDefaults.bonjourSharingIsActive() }
    @objc(IsBonjourSharingPasswordProtected) nonisolated class func legacyIsBonjourSharingPasswordProtected() -> Bool { UserDefaults.bonjourSharingIsPasswordProtected() }
    @objc(BonjourSharingPassword) nonisolated class func legacyBonjourSharingPassword() -> String? { UserDefaults.bonjourSharingPassword() }
    @objc(BonjourSharingName) nonisolated class func legacyBonjourSharingName() -> String? { UserDefaults.bonjourSharingName() }
    @objc(DefaultBonjourSharingName) nonisolated class func legacyDefaultBonjourSharingName() -> String? { UserDefaults.defaultBonjourSharingName() }
    @objc(WebServerUsesWeasis) nonisolated class func legacyWebServerUsesWeasis() -> Bool { UserDefaults.webPortalUsesWeasis() }
    @objc(WadoServerActive) nonisolated class func legacyWadoServerActive() -> Bool { UserDefaults.wadoServiceEnabled() }
    @objc(WebServerPrefersFlash) nonisolated class func legacyWebServerPrefersFlash() -> Bool { UserDefaults.webPortalPrefersFlash() }
    @objc(WebServerPrefersCustomWebPages) nonisolated class func legacyWebServerPrefersCustomWebPages() -> Bool { UserDefaults.webPortalPrefersCustomWebPages() }
}
