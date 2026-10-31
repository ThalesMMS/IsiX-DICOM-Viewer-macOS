/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// What a plugin made for Horos or OsiriX declares to its host in its
/// Info.plist, read as a property list before any of its code runs, and what
/// the former plugin manager did with each declaration: the registry its
/// principal class goes into, the menu its items go into and the message they
/// send, and the order the plugins load in.
///
/// A value of the wrong type declares nothing, where the former Objective-C
/// loader raised and gave up the plugin: the Info.plist of a plugin that loaded
/// then still loads.
public struct LegacyPluginDeclaration: Sendable, Equatable {
    /// The roles `pluginType` names. The former loader looked each name up as a
    /// part of the string, so `"imageFilter, Report"` has both roles; a plugin
    /// without `pluginType` has none.
    public struct Roles: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let imageFilter = Roles(rawValue: 1 << 0)
        public static let roiTool = Roles(rawValue: 1 << 1)
        public static let fusionFilter = Roles(rawValue: 1 << 2)
        public static let database = Roles(rawValue: 1 << 3)
        public static let report = Roles(rawValue: 1 << 4)
        public static let preProcess = Roles(rawValue: 1 << 5)

        /// Each role and the text that names it in `pluginType`.
        static let names: [(Roles, String)] = [
            (.imageFilter, "imageFilter"), (.roiTool, "roiTool"), (.fusionFilter, "fusionFilter"),
            (.database, "Database"), (.report, "Report"), (.preProcess, "Pre-Process"),
        ]

        public init(pluginType: String?) {
            var roles: Roles = []
            if let pluginType {
                for (role, name) in Self.names where pluginType.contains(name) { roles.insert(role) }
            }
            self = roles
        }
    }

    /// The menu the plugin's items go into.
    public enum Menu: Sendable, Equatable {
        case imageFilters, roiTools, fusion, database, others
    }

    /// What the plugin's menu items send.
    public enum Command: Sendable, Equatable {
        /// -endBlendingType: to the first responder: a fusion of two viewers.
        case fusion
        /// -executeFilterDB: to the database window: no viewer is needed.
        case database
        /// -executeFilter: to the first responder: the front viewer.
        case viewer

        public var selectorName: String {
            switch self {
            case .fusion: return "endBlendingType:"
            case .database: return "executeFilterDB:"
            case .viewer: return "executeFilter:"
            }
        }
    }

    /// Where the principal class goes once loaded.
    public enum Registration: Sendable, Equatable {
        /// `+filter`, kept with the pre-process filters, which see every file
        /// the database imports.
        case preProcess
        /// The bundle itself, under each format: a decoder is made per file.
        case fileFormats([String])
        /// `+filter`, under each menu title and toolbar name; a separator of
        /// the plugin's submenu names no command.
        case filter(titles: [String])
        /// Nothing: the class does not answer -filterImage:.
        case none
    }

    /// A `MenuTitles` entry that stands for a separator in the plugin's submenu.
    public static let menuSeparator = "(-"

    public var roles: Roles
    /// `NSPrincipalClass`; nil leaves the class to the bundle.
    public var principalClass: String?
    public var executableName: String?
    /// The bundle's name, which another plugin's `Requirements` names.
    public var bundleName: String?
    /// nil when the plugin declares no menu items.
    public var menuTitles: [String]?
    public var toolbarNames: [String]?
    /// nil when the plugin is not a file format decoder.
    public var fileFormats: [String]?
    public var requirements: [String]

    public init(info: [String: Any]) {
        func text(_ key: String) -> String? {
            guard let value = info[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        func list(_ key: String) -> [String]? {
            switch info[key] {
            case let values as [Any]: return values.compactMap { $0 as? String }
            case let value as String: return [value]
            default: return nil
            }
        }
        roles = Roles(pluginType: info["pluginType"] as? String)
        principalClass = text("NSPrincipalClass")
        executableName = text("CFBundleExecutable")
        bundleName = text("CFBundleName")
        menuTitles = list("MenuTitles")
        toolbarNames = list("ToolbarNames")
        // The former loader enumerated the objects of FileFormats: a list's
        // elements, or a dictionary's values.
        if let formats = info["FileFormats"] as? [String: Any] {
            fileFormats = formats.keys.sorted().compactMap { formats[$0] as? String }
        } else {
            fileFormats = list("FileFormats")
        }
        requirements = list("Requirements") ?? []
    }

    /// The declaration in the bundle's Contents/Info.plist, read as a file; nil
    /// when there is none that reads.
    public init?(bundleAt url: URL) {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        self.init(info: info)
    }

    /// The menu of the plugin's items: the first role that names one, in the
    /// former manager's order.
    public var menu: Menu {
        if roles.contains(.imageFilter) { return .imageFilters }
        if roles.contains(.roiTool) { return .roiTools }
        if roles.contains(.fusionFilter) { return .fusion }
        if roles.contains(.database) { return .database }
        return .others
    }

    public var command: Command {
        if roles.contains(.fusionFilter) { return .fusion }
        if roles.contains(.database) || roles.contains(.report) { return .database }
        return .viewer
    }

    /// Whether the plugin's items go into a submenu named after its executable:
    /// it declares more than one.
    public var hasSubmenu: Bool { (menuTitles?.count ?? 0) > 1 }

    /// Where the loaded principal class goes. `answersFilterImage` is whether
    /// its instances answer -filterImage:.
    public func registration(answersFilterImage: Bool) -> Registration {
        if roles.contains(.preProcess) { return .preProcess }
        if let fileFormats { return .fileFormats(fileFormats) }
        guard answersFilterImage else { return .none }
        return .filter(titles: ((menuTitles ?? []) + (toolbarNames ?? [])).filter { $0 != Self.menuSeparator })
    }

    /// Whether the bundle is also a report plugin, kept under its executable's name.
    public var isReport: Bool { roles.contains(.report) }

    /// A plugin to be loaded, by its path, the name another plugin's
    /// `Requirements` gives it and the plugins it requires.
    public struct Pending: Sendable, Equatable {
        public var path: String
        public var name: String
        public var requirements: [String]
        public init(path: String, name: String, requirements: [String]) {
            self.path = path
            self.name = name
            self.requirements = requirements
        }
    }

    /// The order the plugins load in: each one after the plugins it requires,
    /// otherwise as found. This is the former manager's pass from the last
    /// plugin to the first, which moves a required plugin found later in front
    /// of the one that requires it. `unmet` lists each requirement no plugin
    /// answers, as (plugin, requirement); such a plugin is still loaded.
    public static func loadOrder(_ plugins: [Pending]) -> (order: [Pending], unmet: [(plugin: String, requirement: String)]) {
        var order = plugins
        var unmet: [(plugin: String, requirement: String)] = []
        var i = order.count - 1
        while i >= 0 {
            let current = order[i]
            for requirement in current.requirements {
                let indexes = order.indices.filter { order[$0].name == requirement }
                if indexes.isEmpty { unmet.append((current.name, requirement)) }
                for index in indexes where index > i {
                    let required = order.remove(at: index)
                    order.insert(required, at: i)
                    i += 1
                }
            }
            i -= 1
        }
        return (order, unmet)
    }
}
