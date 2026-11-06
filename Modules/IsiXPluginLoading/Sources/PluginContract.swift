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

/// What a version 1 plugin bundle has to be for the host to load it.
///
/// The template and the SDK README spell out the same values; the loader reads
/// them from here. Nothing of the bundle runs before `PluginInspector` accepts
/// it against these rules.
public enum PluginContract {
    /// The bundle's extension. Only bundles with it take the version 1 path.
    public static let bundleExtension = "isixplugin"

    /// Info.plist: the integer version of the plugin API the bundle was built for.
    public static let apiVersionKey = "IsiXPluginAPIVersion"

    /// The API versions this host loads.
    public static let supportedAPIVersions: ClosedRange<Int> = 1...1

    /// Info.plist: the entry class, qualified by its Swift module
    /// (`MyModule.MyPlugin`, usually written `$(PRODUCT_MODULE_NAME).MyPlugin`),
    /// or an explicit Objective-C name. A Swift class without `@objc(Name)` is
    /// found only by its qualified name.
    public static let principalClassKey = "NSPrincipalClass"

    /// Info.plist: the capabilities the plugin uses, as strings.
    public static let capabilitiesKey = "IsiXPluginCapabilities"

    /// The capabilities a version 1 host knows. A bundle that declares another
    /// one needs a newer host and is not loaded.
    public static let knownCapabilities: Set<String> = [
        "viewer.read", "viewer.write", "roi", "database.read", "database.import", "database.write",
        "network.send", "network.query", "xmlrpc",
    ]

    /// The SDK framework a plugin links against, and that the host provides.
    public static let kitFrameworkName = "IsiXPluginKit"

    /// The lowest system a plugin can require and still be loaded by a host
    /// that runs on the product's minimum, macOS 15.
    public static let productMinimumSystem = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    /// Info.plist keys only the former plugin API read. Their presence tells a
    /// former plugin apart, whatever its extension says.
    public static let legacyInfoKeys: [String] = [
        "pluginType", "MenuTitles", "ToolbarNames", "FileFormats", "HorosCompatiblePlugin", "Requirements",
    ]

    /// Frameworks of the former plugin SDK. A bundle that links one of them is
    /// a former plugin, renamed or not.
    public static let legacyFrameworkNames: [String] = [
        "Horos", "HorosAPI", "OsiriXAPI", "OsiriX Headers", "OsiriX", "HorosDCM",
    ]
}
