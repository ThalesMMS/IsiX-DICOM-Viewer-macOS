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

@Suite struct BundledPluginMigrationTests {
    private final class Folders {
        /// Spelled as the file system answers it (/private/var), which is how the entries of a folder come back.
        let root: URL = {
            let temporary = realpath(FileManager.default.temporaryDirectory.path, nil)
            defer { free(temporary) }
            return URL(fileURLWithPath: temporary.map { String(cString: $0) } ?? NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        }()
        var bundled: URL { root.appendingPathComponent("IsiX DICOM Viewer.app/Contents/PlugIns") }
        var bundledDisabled: URL { root.appendingPathComponent("IsiX DICOM Viewer.app/Contents/PlugIns Disabled") }
        var isix: URL { root.appendingPathComponent("User/Library/Application Support/IsiX") }
        var migration: BundledPluginMigration {
            BundledPluginMigration(bundled: bundled, bundledDisabled: bundledDisabled, userDomain: root.appendingPathComponent("User").path)
        }
        deinit {
            // A test that made the application unwritable gives it back first.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func isPlugin(_ name: String) -> Bool {
        ["horosplugin", "osirixplugin", "isixplugin"].contains((name as NSString).pathExtension.lowercased())
    }

    /// A bundle with an Info.plist and an executable that say `build`.
    private func makePlugin(_ url: URL, build: String) throws {
        let name = url.deletingPathExtension().lastPathComponent
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("info \(build)".utf8).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("code \(build)".utf8).write(to: url.appendingPathComponent("Contents/MacOS/\(name)"))
    }

    private func build(of url: URL) -> String? {
        try? String(contentsOf: url.appendingPathComponent("Contents/Info.plist"), encoding: .utf8)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// What became of each plugin, by paths: a URL read from a folder and one
    /// built by hand differ in their trailing slash.
    private func summary(_ entries: [BundledPluginMigration.Entry]) -> [String] {
        entries.map { entry in
            switch entry.outcome {
            case .moved(let to): return "\(entry.source.path) moved to \(to.path)"
            case .copied(let to, _): return "\(entry.source.path) copied to \(to.path)"
            case .nameTaken(let by, let sameBuild): return "\(entry.source.path) name taken by \(by.path), same build \(sameBuild)"
            case .failed(let reason): return "\(entry.source.path) failed: \(reason)"
            }
        }
    }

    @Test func movesActiveAndDisabledPluginsAndLeavesTheRestOfTheBundle() throws {
        let folders = Folders()
        try makePlugin(folders.bundled.appendingPathComponent("Active.horosplugin"), build: "a")
        try makePlugin(folders.bundledDisabled.appendingPathComponent("Off.osirixplugin"), build: "b")
        // What the application itself ships in that folder is not a plugin bundle.
        let ownExtension = folders.bundled.appendingPathComponent("QuickLook.appex")
        try makePlugin(ownExtension, build: "signed")

        let entries = folders.migration.run(isPlugin: isPlugin)

        let active = folders.isix.appendingPathComponent("Plugins/Active.horosplugin")
        let disabled = folders.isix.appendingPathComponent("Plugins Disabled/Off.osirixplugin")
        #expect(summary(entries) == ["\(folders.bundled.path)/Active.horosplugin moved to \(active.path)",
                                     "\(folders.bundledDisabled.path)/Off.osirixplugin moved to \(disabled.path)"])
        #expect(build(of: active) == "info a")
        #expect(build(of: disabled) == "info b")
        // Nothing the plugins brought is left inside, and nothing else was touched.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.bundled.path) == ["QuickLook.appex"])
        #expect(build(of: ownExtension) == "info signed")
        #expect(!exists(folders.bundledDisabled))
        #expect(!exists(folders.isix.appendingPathComponent(".BundledPlugins-staging")))
        #expect(BundledPluginMigration.duplicatesLeftInside(entries).isEmpty)
        // A second launch finds nothing to do.
        #expect(folders.migration.run(isPlugin: isPlugin).isEmpty)
    }

    @Test func neverReplacesAPluginOfTheUser() throws {
        let folders = Folders()
        let inside = folders.bundled.appendingPathComponent("Thing.osirixplugin")
        try makePlugin(inside, build: "inside")
        // Under the other extension, and disabled: still the user's plugin of that name.
        let own = folders.isix.appendingPathComponent("Plugins Disabled/Thing.horosplugin")
        try makePlugin(own, build: "own")

        let entries = folders.migration.run(isPlugin: isPlugin)

        #expect(summary(entries) == ["\(inside.path) name taken by \(own.path), same build false"])
        #expect(build(of: own) == "info own")
        #expect(build(of: inside) == "info inside")
        #expect(!exists(folders.isix.appendingPathComponent("Plugins/Thing.osirixplugin")))
        // Two different plugins of one name: the loader reports them, as it always did.
        #expect(BundledPluginMigration.duplicatesLeftInside(entries).isEmpty)
    }

    @Test func copiesWhenTheApplicationCannotBeChangedAndSaysWhatStaysInside() throws {
        guard getuid() != 0 else { return } // root may change anything
        let folders = Folders()
        let inside = folders.bundled.appendingPathComponent("Thing.horosplugin")
        try makePlugin(inside, build: "c")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folders.bundled.path)

        let first = folders.migration.run(isPlugin: isPlugin)

        let copy = folders.isix.appendingPathComponent("Plugins/Thing.horosplugin")
        #expect(summary(first) == ["\(inside.path) copied to \(copy.path)"])
        #expect(build(of: copy) == "info c")
        #expect(build(of: inside) == "info c")
        #expect(BundledPluginMigration.duplicatesLeftInside(first).map(\.path) == [inside.path])

        // The next launches find the same plugin in both places and pass over the one inside.
        let second = folders.migration.run(isPlugin: isPlugin)
        #expect(summary(second) == ["\(inside.path) name taken by \(copy.path), same build true"])
        #expect(BundledPluginMigration.duplicatesLeftInside(second).map(\.path) == [inside.path])
    }

    @Test func leavesLinksAndFilesAlone() throws {
        let folders = Folders()
        let target = folders.root.appendingPathComponent("Elsewhere/Linked.horosplugin")
        try makePlugin(target, build: "linked")
        try FileManager.default.createDirectory(at: folders.bundled, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folders.bundled.appendingPathComponent("Linked.horosplugin"), withDestinationURL: target)
        try Data("not a bundle".utf8).write(to: folders.bundled.appendingPathComponent("Loose.horosplugin"))

        #expect(folders.migration.run(isPlugin: isPlugin).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folders.bundled.path).sorted() == ["Linked.horosplugin", "Loose.horosplugin"])
        #expect(!exists(folders.isix.appendingPathComponent("Plugins")))
    }

    @Test func anApplicationWithoutAPluginsFolderHasNothingToMove() {
        let folders = Folders()
        #expect(folders.migration.run(isPlugin: isPlugin).isEmpty)
        #expect(BundledPluginMigration(bundled: nil, bundledDisabled: nil, userDomain: folders.root.path).run(isPlugin: isPlugin).isEmpty)
    }
}
