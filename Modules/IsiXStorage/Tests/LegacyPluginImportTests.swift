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

@Suite struct LegacyPluginImportTests {
    private final class Folders {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var user: URL { root.appendingPathComponent("User/Library/Application Support") }
        var system: URL { root.appendingPathComponent("System/Library/Application Support") }
        var isix: URL { user.appendingPathComponent("IsiX") }
        var importer: LegacyPluginImport {
            LegacyPluginImport(userDomain: root.appendingPathComponent("User").path,
                               systemDomain: root.appendingPathComponent("System").path)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func isPlugin(_ name: String) -> Bool {
        ["horosplugin", "osirixplugin", "isixplugin"].contains((name as NSString).pathExtension.lowercased())
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    @Test func asksOnlyWhenPluginsExistAndRemembersDecline() throws {
        let folders = Folders()
        try write("settings migration already finished", to: folders.isix.appendingPathComponent(".ImportFromHoros.json"))
        try write("loose file", to: folders.user.appendingPathComponent("Horos/Plugins/Loose.horosplugin"))
        _ = try folders.importer.offerIfNeeded(isPlugin: isPlugin) { _ in
            Issue.record("An empty plugin inventory prompted for a copy")
            return false
        }
        let plugin = folders.user.appendingPathComponent("OsiriX/Plugins/Choice.osirixplugin/Contents/Info.plist")
        try write("original", to: plugin)
        _ = try folders.importer.offerIfNeeded(isPlugin: isPlugin) { names in
            #expect(names == ["Choice.osirixplugin"])
            return false
        }
        _ = try folders.importer.offerIfNeeded(isPlugin: isPlugin) { _ in
            Issue.record("A previous decline prompted again")
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: folders.isix.appendingPathComponent("Plugins").path))
        #expect(try String(contentsOf: plugin, encoding: .utf8) == "original")
    }

    @Test func copiesToMatchingActivationFoldersAndKeepsExistingNames() throws {
        let folders = Folders()
        let active = "Plugins/Active.horosplugin/Contents/Info.plist"
        let disabled = "Plugins Disabled/Disabled.osirixplugin/Contents/Info.plist"
        let original = folders.user.appendingPathComponent("Horos/" + active)
        try write("horos", to: original)
        try write("osirix", to: folders.system.appendingPathComponent("OsiriX/" + disabled))
        try write("newer", to: folders.isix.appendingPathComponent("Plugins Disabled/Same.isixplugin/Contents/Info.plist"))
        try write("older", to: folders.user.appendingPathComponent("OsiriX/Plugins/same.osirixplugin/Contents/Info.plist"))

        let problems = try folders.importer.offerIfNeeded(isPlugin: isPlugin) { names in
            #expect(names == ["Active.horosplugin", "same.osirixplugin", "Disabled.osirixplugin"])
            return true
        }
        #expect(problems == [.alreadyInstalled("same.osirixplugin")])
        #expect(try String(contentsOf: folders.isix.appendingPathComponent(active), encoding: .utf8) == "horos")
        #expect(try String(contentsOf: folders.isix.appendingPathComponent(disabled), encoding: .utf8) == "osirix")
        #expect(try String(contentsOf: original, encoding: .utf8) == "horos")
        #expect(!FileManager.default.fileExists(atPath: folders.isix.appendingPathComponent("Plugins/same.osirixplugin").path))
        _ = try folders.importer.offerIfNeeded(isPlugin: isPlugin) { _ in
            Issue.record("A completed copy prompted again")
            return false
        }
    }

    @Test func resumesOnlyTheSelectionAlreadyApproved() throws {
        struct SavedCandidate: Encodable {
            let source: URL
            let active: Bool
        }
        let folders = Folders()
        let relative = "Plugins/Pending.horosplugin"
        let source = folders.user.appendingPathComponent("Horos/" + relative)
        try write("complete", to: source.appendingPathComponent("Contents/Info.plist"))
        try write("appeared later", to: folders.user.appendingPathComponent("Horos/Plugins/Later.horosplugin/Contents/Info.plist"))
        let staging = folders.isix.appendingPathComponent(".ImportLegacyPlugins-staging")
        try write("partial", to: staging.appendingPathComponent("Pending.horosplugin/Contents/Info.plist"))
        let choice = folders.isix.appendingPathComponent(".ImportLegacyPlugins.json")
        try JSONEncoder().encode([SavedCandidate(source: source, active: true)]).write(to: choice)

        let problems = try folders.importer.offerIfNeeded(isPlugin: isPlugin) { _ in
            Issue.record("Resuming an approved selection prompted again")
            return false
        }
        #expect(problems.isEmpty)
        #expect(try String(contentsOf: folders.isix.appendingPathComponent(relative + "/Contents/Info.plist"), encoding: .utf8) == "complete")
        #expect(!FileManager.default.fileExists(atPath: folders.isix.appendingPathComponent("Plugins/Later.horosplugin").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }
}
