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
import Testing
@testable import IsiXStorage

// The direct build's folders are in Application Support/IsiX; the App Store
// build keeps Horos App inside its container; Application Support/Horos is
// only named as the folder earlier versions used.
@Suite struct StorageLocationsTests {
    let home = NSHomeDirectory()

    @Test func pluginsFolders() {
        #expect(StorageLocations.pluginsFolder(inDomain: home, active: true) == home + "/Library/Application Support/IsiX/Plugins")
        #expect(StorageLocations.pluginsFolder(inDomain: home, active: false) == home + "/Library/Application Support/IsiX/Plugins Disabled")
        #expect(StorageLocations.pluginsFolder(inDomain: "/", active: true) == "/Library/Application Support/IsiX/Plugins")
        #expect(StorageLocations.pluginsFolder(inDomain: "/", active: false) == "/Library/Application Support/IsiX/Plugins Disabled")
        #expect(StorageLocations.discoveryFolders(userDomain: home, systemDomain: "/") == [
            home + "/Library/Application Support/IsiX/Plugins",
            home + "/Library/Application Support/Horos App/Plugins",
            "/Library/Application Support/IsiX/Plugins",
        ])
        #expect(StorageLocations.legacyPluginsFolders(userDomain: home, systemDomain: "/") == [
            home + "/Library/Application Support/Horos/Plugins",
            home + "/Library/Application Support/Horos/Plugins Disabled",
            "/Library/Application Support/Horos/Plugins",
            "/Library/Application Support/Horos/Plugins Disabled",
        ])
    }

    @Test func supportFolders() {
        #expect(StorageLocations.supportFolderName(for: .direct) == "IsiX")
        #expect(StorageLocations.supportFolderName(for: .appStore) == "Horos App")
        #expect(StorageLocations.supportFolder(for: .direct, inDomain: home) == home + "/Library/Application Support/IsiX")
        #expect(StorageLocations.legacySupportFolder(inDomain: home) == home + "/Library/Application Support/Horos")
        #expect(StorageLocations.legacySupportFolder(inDomain: "/i/User") == "/i/User/Library/Application Support/Horos")
    }

    @Test func isolatedDevelopmentLaunch() {
        let development = StorageLocations.developmentBundleIdentifier
        #expect(StorageLocations.isolatedPluginsFolder(bundleIdentifier: "thalesmms.isis.workstation", argument: "/tmp/x") == nil)
        #expect(StorageLocations.isolatedPluginsFolder(bundleIdentifier: development, argument: nil) == nil)
        #expect(StorageLocations.isolatedPluginsFolder(bundleIdentifier: development, argument: "") == nil)
        #expect(StorageLocations.isolatedPluginsFolder(bundleIdentifier: development, argument: "/tmp/a/../b/") == "/tmp/b")
        #expect(StorageLocations.isolatedPluginsFolder(bundleIdentifier: development, argument: "~/P") == home + "/P")
        #expect(StorageLocations.userPluginsDomain(isolatedFolder: nil) == home)
        #expect(StorageLocations.systemPluginsDomain(isolatedFolder: nil) == "/")
        #expect(StorageLocations.userPluginsDomain(isolatedFolder: "/i") == "/i/User")
        #expect(StorageLocations.systemPluginsDomain(isolatedFolder: "/i") == "/i/System")
        // The test runner is not the development bundle: it is never isolated.
        #expect(StorageLocations.runningIsolatedFolder == nil)
        #expect(StorageLocations.runningUserDomain == home)
        #expect(StorageLocations.runningSystemDomain == "/")
    }

    @Test func webPortalAndWeasis() {
        #expect(StorageLocations.webPortalAccountsPath(for: .direct) == home + "/Library/Application Support/IsiX/WebUsers.sql")
        #expect(StorageLocations.webPortalAccountsPath(for: .appStore) == home + "/Library/Application Support/Horos App/WebUsers.sql")
        #expect(StorageLocations.customWebPagesPath(for: .direct) == home + "/Library/Application Support/IsiX/WebServicesHTML")
        #expect(StorageLocations.customWebPagesPath(for: .appStore) == home + "/Library/Application Support/Horos App/WebServicesHTML")
        #expect(StorageLocations.weasisCustomizationPaths() == [
            home + "/Library/Application Support/IsiX/Weasis",
            "/Library/Application Support/IsiX/Weasis",
        ])
        // An isolated launch keeps all of them inside its folder.
        #expect(StorageLocations.webPortalAccountsPath(for: .direct, userDomain: "/i/User") == "/i/User/Library/Application Support/IsiX/WebUsers.sql")
        #expect(StorageLocations.customWebPagesPath(for: .direct, userDomain: "/i/User") == "/i/User/Library/Application Support/IsiX/WebServicesHTML")
        #expect(StorageLocations.weasisCustomizationPaths(userDomain: "/i/User", systemDomain: "/i/System") == [
            "/i/User/Library/Application Support/IsiX/Weasis",
            "/i/System/Library/Application Support/IsiX/Weasis",
        ])
    }
}
