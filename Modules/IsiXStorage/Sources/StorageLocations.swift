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

/// Where the app keeps its own files under Application Support: the plugins
/// folders, the Web Portal's accounts and custom pages, and the Weasis
/// customization.
///
/// The direct build keeps them in `Application Support/IsiX`. Earlier versions
/// kept them in `Application Support/Horos`, a folder that Horos itself also
/// uses: it is only read, by `LegacySupportImport` when the user asks to import
/// from it and by the plugin manager to list the plugins there as incompatible.
/// The App Store build is sandboxed and keeps its `Horos App` folder inside its
/// own container.
///
/// Every path is relative to a domain: the home folder (or the root of the
/// disk, for all users), or, in an isolated development launch, their stand-ins
/// inside the isolated folder, so that such a launch never reads or writes the
/// files of the installed application.
@objc(IsiXStorageLocations)
public final class StorageLocations: NSObject {
    /// The build that is running. The App Store build is sandboxed and keeps
    /// its files in a folder of its own.
    @objc(IsiXDistributionChannel)
    public enum Channel: Int, Sendable {
        case direct = 0
        case appStore = 1
    }

    /// The folder in Application Support the given build writes to.
    @objc(supportFolderNameForChannel:)
    public static func supportFolderName(for channel: Channel) -> String {
        switch channel {
        case .direct: return "IsiX"
        case .appStore: return "Horos App"
        }
    }

    /// The folder in Application Support that earlier versions of the direct
    /// build wrote to, and that Horos writes to.
    @objc public static let legacySupportFolderName = "Horos"

    private static func supportFolder(named name: String) -> String {
        "Library/Application Support/\(name)/"
    }

    /// The support folder of a build in a domain.
    @objc(supportFolderForChannel:inDomain:)
    public static func supportFolder(for channel: Channel, inDomain domain: String) -> String {
        (domain as NSString).appendingPathComponent(supportFolder(named: supportFolderName(for: channel)))
    }

    /// The folder earlier versions of the direct build wrote to, in a domain.
    @objc(legacySupportFolderInDomain:)
    public static func legacySupportFolder(inDomain domain: String) -> String {
        (domain as NSString).appendingPathComponent(supportFolder(named: legacySupportFolderName))
    }

    // MARK: domains

    /// The only bundle identifier that honours `isolatedPluginsFolderArgument`:
    /// the development build that `script/build_and_run.sh` prepares.
    @objc public static let developmentBundleIdentifier = "thalesmms.isis.workstation.local-development"

    /// `-IsolatedPluginsFolder <folder>` on the command line of the development
    /// bundle stands that folder in for the user's and the computer's folders:
    /// the plugins, the Web Portal's accounts and pages, and Weasis.
    @objc public static let isolatedPluginsFolderArgument = "IsolatedPluginsFolder"

    /// The folder an isolated development launch keeps its files in, or nil.
    ///
    /// Only the development bundle honours it, and only from the command line:
    /// `argument` is the value of `isolatedPluginsFolderArgument` in the
    /// argument domain, not a saved preference.
    @objc(isolatedPluginsFolderForBundleIdentifier:argument:)
    public static func isolatedPluginsFolder(bundleIdentifier: String?, argument: String?) -> String? {
        guard bundleIdentifier == developmentBundleIdentifier else { return nil }
        guard let folder = argument, !folder.isEmpty else { return nil }
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// The isolated folder of this process, from its bundle identifier and its
    /// command line, or nil.
    @objc public static var runningIsolatedFolder: String? {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        return isolatedPluginsFolder(bundleIdentifier: Bundle.main.bundleIdentifier,
                                     argument: arguments[isolatedPluginsFolderArgument] as? String)
    }

    /// What the current user's folders are relative to: the home folder, or its
    /// stand-in inside the isolated folder.
    @objc(userPluginsDomainWithIsolatedFolder:)
    public static func userPluginsDomain(isolatedFolder: String?) -> String {
        guard let folder = isolatedFolder else { return NSHomeDirectory() }
        return (folder as NSString).appendingPathComponent("User")
    }

    /// What all users' folders are relative to: the root of the disk, or its
    /// stand-in inside the isolated folder.
    @objc(systemPluginsDomainWithIsolatedFolder:)
    public static func systemPluginsDomain(isolatedFolder: String?) -> String {
        guard let folder = isolatedFolder else { return "/" }
        return (folder as NSString).appendingPathComponent("System")
    }

    /// The current user's domain for this process.
    @objc public static var runningUserDomain: String { userPluginsDomain(isolatedFolder: runningIsolatedFolder) }

    /// All users' domain for this process.
    @objc public static var runningSystemDomain: String { systemPluginsDomain(isolatedFolder: runningIsolatedFolder) }

    // MARK: plugins

    /// The active plugins folder, relative to a domain: the home folder or the
    /// root of the disk.
    @objc public static let activePluginsRelativePath = "Library/Application Support/IsiX/Plugins/"

    /// The disabled plugins folder, relative to a domain.
    @objc public static let inactivePluginsRelativePath = "Library/Application Support/IsiX/Plugins Disabled/"

    /// The active or disabled plugins folder of a domain.
    @objc(pluginsFolderInDomain:active:)
    public static func pluginsFolder(inDomain domain: String, active: Bool) -> String {
        (domain as NSString).appendingPathComponent(active ? activePluginsRelativePath : inactivePluginsRelativePath)
    }

    /// The folders plugin discovery lists after the application's own, in
    /// order: the user's, the user's App Store build's, and the computer's.
    @objc(discoveryFoldersWithUserDomain:systemDomain:)
    public static func discoveryFolders(userDomain: String, systemDomain: String) -> [String] {
        let user = (supportFolder(named: supportFolderName(for: .direct)) as NSString).appendingPathComponent("Plugins/")
        let userAppStore = (supportFolder(named: supportFolderName(for: .appStore)) as NSString).appendingPathComponent("Plugins/")
        return [
            (userDomain as NSString).appendingPathComponent(user),
            (userDomain as NSString).appendingPathComponent(userAppStore),
            (systemDomain as NSString).appendingPathComponent(user),
        ]
    }

    /// The plugins folders earlier versions used, in order: the user's active
    /// and disabled ones, then the computer's. Nothing is loaded from them or
    /// written to them; the plugin manager lists what they hold as
    /// incompatible.
    @objc(legacyPluginsFoldersWithUserDomain:systemDomain:)
    public static func legacyPluginsFolders(userDomain: String, systemDomain: String) -> [String] {
        [userDomain, systemDomain].flatMap { domain in
            ["Plugins", "Plugins Disabled"].map {
                (legacySupportFolder(inDomain: domain) as NSString).appendingPathComponent($0)
            }
        }
    }

    // MARK: Web Portal

    /// The Web Portal's accounts database in a domain, unless a path is
    /// configured.
    @objc(webPortalAccountsPathForChannel:userDomain:)
    public static func webPortalAccountsPath(for channel: Channel, userDomain: String) -> String {
        (supportFolder(for: channel, inDomain: userDomain) as NSString).appendingPathComponent("WebUsers.sql")
    }

    /// The Web Portal's accounts database of this process, unless a path is
    /// configured.
    @objc(webPortalAccountsPathForChannel:)
    public static func webPortalAccountsPath(for channel: Channel) -> String {
        webPortalAccountsPath(for: channel, userDomain: runningUserDomain)
    }

    /// The folder of the user's customized Web Portal pages in a domain.
    @objc(customWebPagesPathForChannel:userDomain:)
    public static func customWebPagesPath(for channel: Channel, userDomain: String) -> String {
        (supportFolder(for: channel, inDomain: userDomain) as NSString).appendingPathComponent("WebServicesHTML")
    }

    /// The folder of the user's customized Web Portal pages of this process.
    @objc(customWebPagesPathForChannel:)
    public static func customWebPagesPath(for channel: Channel) -> String {
        customWebPagesPath(for: channel, userDomain: runningUserDomain)
    }

    // MARK: Weasis

    /// The folders a Weasis customization is read from, the user's first.
    /// Both builds read the direct build's folders.
    @objc(weasisCustomizationPathsWithUserDomain:systemDomain:)
    public static func weasisCustomizationPaths(userDomain: String, systemDomain: String) -> [String] {
        [userDomain, systemDomain].map {
            (supportFolder(for: .direct, inDomain: $0) as NSString).appendingPathComponent("Weasis")
        }
    }

    /// The folders a Weasis customization is read from by this process.
    @objc public static func weasisCustomizationPaths() -> [String] {
        weasisCustomizationPaths(userDomain: runningUserDomain, systemDomain: runningSystemDomain)
    }
}
