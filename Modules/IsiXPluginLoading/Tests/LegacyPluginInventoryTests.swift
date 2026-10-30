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
@testable import IsiXPluginLoading

/// Legacy plugins are listed from their Info.plist alone: nothing in the
/// package is loaded, run or changed.
@Suite struct LegacyPluginInventoryTests {
    func package(_ url: URL, info: [String: Any]?) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        if let info {
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        // An executable that would leave a file behind if anything ran it.
        let ran = url.deletingLastPathComponent().appendingPathComponent("ran-\(url.lastPathComponent)")
        let script = contents.appendingPathComponent("MacOS/Plugin")
        try Data("#!/bin/sh\ntouch '\(ran.path)'\n".utf8).write(to: script)
        chmod(script.path, 0o755)
    }

    func contents(of folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(path)
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            result[path] = isFolder.boolValue ? Data() : try Data(contentsOf: url)
        }
        return result
    }

    @Test func listsLegacyPluginsByMetadataOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy plugins \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("Usuário/Plugins"), disabled = root.appendingPathComponent("Usuário/Plugins Disabled")
        try package(user.appendingPathComponent("Zeta.horosplugin"),
                    info: ["CFBundleName": "Zeta Filter", "CFBundleIdentifier": "org.example.zeta", "CFBundleVersion": "2.1",
                           "NSPrincipalClass": "ZetaFilter", "CFBundleExecutable": "Plugin"])
        try package(user.appendingPathComponent("Alpha.osirixplugin"),
                    info: ["CFBundleShortVersionString": "1.0", "CFBundleExecutable": "Plugin"])
        try package(disabled.appendingPathComponent("Broken.horosplugin"), info: nil)
        try package(user.appendingPathComponent("Own.isixplugin"), info: ["CFBundleName": "Own"])
        try Data("x".utf8).write(to: user.appendingPathComponent("notes.txt"))
        let before = try contents(of: root)
        let loaded = Bundle.allBundles.count

        let entries = LegacyPluginInventory.list(folders: [user.path, disabled.path, root.appendingPathComponent("missing").path])

        #expect(entries.map(\.name) == ["Alpha", "Zeta Filter", "Broken"])
        #expect(entries.map(\.version) == ["1.0", "2.1", nil])
        #expect(entries.map(\.identifier) == [nil, "org.example.zeta", nil])
        #expect(entries.map(\.folder) == [user.path, user.path, disabled.path])
        #expect(entries.map { $0.url.lastPathComponent } == ["Alpha.osirixplugin", "Zeta.horosplugin", "Broken.horosplugin"])
        // Nothing ran, nothing was loaded, nothing changed.
        #expect(try contents(of: root) == before)
        #expect(Bundle.allBundles.count == loaded)
        #expect(!entries.contains { Bundle.allBundles.map(\.bundleURL.path).contains($0.url.path) })
    }
}
