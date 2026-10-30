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

/// The plugins made for Horos or OsiriX in the folders earlier versions used,
/// listed so that the plugin manager can show them as incompatible.
///
/// Only each bundle's `Contents/Info.plist` is read, as a property list: no
/// `Bundle` is made, so nothing in the package is loaded or run, and nothing in
/// it is written, moved or deleted. The folders are not this app's: what they
/// hold may belong to Horos.
public enum LegacyPluginInventory {
    /// The package extensions of plugins made for Horos and OsiriX.
    public static let extensions: Set<String> = ["horosplugin", "osirixplugin"]

    public struct Entry: Sendable, Equatable {
        /// The package, as found in the folder.
        public let url: URL
        /// The folder it was found in.
        public let folder: String
        /// The bundle's name, or the package's without its extension.
        public let name: String
        public let identifier: String?
        public let version: String?
    }

    /// The legacy plugins in each folder, in the order of the folders and then
    /// of their names. A folder that is missing or cannot be read lists none.
    public static func list(folders: [String]) -> [Entry] {
        folders.flatMap { folder -> [Entry] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return names
                .filter { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { entry(for: URL(fileURLWithPath: (folder as NSString).appendingPathComponent($0)), in: folder) }
        }
    }

    static func entry(for url: URL, in folder: String) -> Entry {
        let info = url.appendingPathComponent("Contents/Info.plist")
        let plist = (try? Data(contentsOf: info))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any] ?? [:]
        func text(_ key: String) -> String? {
            guard let value = plist[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return Entry(url: url, folder: folder,
                     name: text("CFBundleName") ?? url.deletingPathExtension().lastPathComponent,
                     identifier: text("CFBundleIdentifier"),
                     version: text("CFBundleVersion") ?? text("CFBundleShortVersionString"))
    }
}
