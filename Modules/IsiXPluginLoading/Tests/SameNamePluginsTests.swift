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

@Suite struct SameNamePluginsTests {
    private func candidate(_ path: String, _ version: String?, rank: Int = 0) -> SameNamePlugins.Candidate {
        SameNamePlugins.Candidate(path: path, version: version, folderRank: rank)
    }

    @Test func versionsCompareAsReleases() {
        #expect(PluginBundleVersion.compare("1.0", "2.0") == .orderedAscending)
        #expect(PluginBundleVersion.compare("3.3", "3.0") == .orderedDescending)
        #expect(PluginBundleVersion.compare("3.0", "3") == .orderedSame)
        #expect(PluginBundleVersion.compare("1.10", "1.9") == .orderedDescending)
        #expect(PluginBundleVersion.compare("01.2", "1.2") == .orderedSame)
        #expect(PluginBundleVersion.compare("1.0rc1", "1.0") == .orderedAscending)
        #expect(PluginBundleVersion.compare("1.0-beta", "1.0-rc") == .orderedAscending)
        #expect(PluginBundleVersion.compare("1.2b2", "1.2b10") == .orderedAscending)
        #expect(PluginBundleVersion.compare("1.0+build7", "1.0") == .orderedSame)
    }

    @Test func whatIsNotAVersionIsNotCompared() {
        #expect(PluginBundleVersion.compare(nil, "1.0") == nil)
        #expect(PluginBundleVersion.compare("1.0", nil) == nil)
        #expect(PluginBundleVersion.compare("", "1.0") == nil)
        #expect(PluginBundleVersion.compare("three", "1.0") == nil)
        #expect(PluginBundleVersion.compare("1.0 (final)", "1.0") == nil)
    }

    @Test func readsTheVersionFromTheInfoPlistWithoutOpeningTheBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, _ info: [String: Any]?) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            if let info {
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: url.appendingPathComponent("Contents/Info.plist"))
            }
            return url
        }
        #expect(PluginBundleVersion.declared(byBundleAt: try bundle("A.horosplugin", ["CFBundleVersion": "3.3", "CFBundleShortVersionString": "3"])) == "3.3")
        #expect(PluginBundleVersion.declared(byBundleAt: try bundle("B.osirixplugin", ["CFBundleShortVersionString": "2.1"])) == "2.1")
        #expect(PluginBundleVersion.declared(byBundleAt: try bundle("C.horosplugin", ["CFBundleName": "C"])) == nil)
        #expect(PluginBundleVersion.declared(byBundleAt: try bundle("D.horosplugin", nil)) == nil)
    }

    @Test func oneNameWhateverTheExtensionAndTheCase() {
        #expect(SameNamePlugins.nameKey("/a/Plugins/CalciumScore.horosplugin") == SameNamePlugins.nameKey("/b/Plugins Disabled/calciumscore.OsiriXPlugin"))
        #expect(SameNamePlugins.nameKey("/a/One.horosplugin") != SameNamePlugins.nameKey("/a/Other.horosplugin"))
        // The decomposed form a file system may hand back is the same name.
        #expect(SameNamePlugins.nameKey("/a/Cafe\u{301}.horosplugin") == SameNamePlugins.nameKey("/a/Caf\u{e9}.horosplugin"))
    }

    /// The case of the two installers of one author: the older build under
    /// .horosplugin, the newer one under .osirixplugin.
    @Test func theHigherVersionStandsForThePluginWhateverTheOrder() {
        let old = candidate("/u/Plugins/QA.horosplugin", "1.0")
        let new = candidate("/u/Plugins/QA.osirixplugin", "2.0")
        #expect(SameNamePlugins.preferred(among: [old, new]) == new)
        #expect(SameNamePlugins.preferred(among: [new, old]) == new)
        #expect(SameNamePlugins.setAside(among: [old, new]) == [.init(bundle: old, preferred: new)])
        #expect(SameNamePlugins.setAside(among: [new, old]) == [.init(bundle: old, preferred: new)])
        // The other way round too: the alphabet of the extensions decides nothing.
        let oldOsiriX = candidate("/u/Plugins/QA.osirixplugin", "1.0")
        let newHoros = candidate("/u/Plugins/QA.horosplugin", "2.0")
        #expect(SameNamePlugins.preferred(among: [oldOsiriX, newHoros]) == newHoros)
        #expect(SameNamePlugins.preferred(among: [newHoros, oldOsiriX]) == newHoros)
        // And the folder decides nothing against a higher version.
        let newInLastFolder = candidate("/s/Plugins/QA.osirixplugin", "2.0", rank: 9)
        #expect(SameNamePlugins.preferred(among: [old, newInLastFolder]) == newInLastFolder)
    }

    @Test func betweenEqualVersionsTheChoiceIsStatedAndDoesNotDependOnTheOrder() {
        // The folder first: the user's before the computer's.
        let user = candidate("/u/Plugins/QA.osirixplugin", "1.0", rank: 1)
        let system = candidate("/s/Plugins/QA.horosplugin", "1.0", rank: 2)
        #expect(SameNamePlugins.preferred(among: [system, user]) == user)
        #expect(SameNamePlugins.preferred(among: [user, system]) == user)
        // Then the format: the current API, then Horos, then OsiriX.
        let v1 = candidate("/u/Plugins/QA.isixplugin", "1.0")
        let horos = candidate("/u/Plugins/QA.horosplugin", "1.0")
        let osirix = candidate("/u/Plugins/QA.osirixplugin", "1.0")
        for order in [[v1, horos, osirix], [osirix, horos, v1], [horos, osirix, v1]] {
            #expect(SameNamePlugins.preferred(among: order) == v1)
            #expect(Set(SameNamePlugins.setAside(among: order).map(\.bundle.path)) == [horos.path, osirix.path])
        }
        #expect(SameNamePlugins.preferred(among: [osirix, horos]) == horos)
        #expect(SameNamePlugins.preferred(among: [horos, osirix]) == horos)
    }

    @Test func aDeclaredVersionComesBeforeNoneAndTwoWithoutVersionFollowTheStatedOrder() {
        let versioned = candidate("/s/Plugins/QA.osirixplugin", "0.1", rank: 5)
        let unversioned = candidate("/u/Plugins/QA.horosplugin", nil, rank: 0)
        #expect(SameNamePlugins.preferred(among: [unversioned, versioned]) == versioned)
        #expect(SameNamePlugins.preferred(among: [versioned, unversioned]) == versioned)
        let other = candidate("/u/Plugins/QA.osirixplugin", "not a version", rank: 0)
        #expect(SameNamePlugins.preferred(among: [other, unversioned]) == unversioned)
        #expect(SameNamePlugins.preferred(among: [unversioned, other]) == unversioned)
    }

    /// A former plugin on disk whose executable has the slice this process
    /// runs, or only the other architecture's, as the old Intel-only build of
    /// a plugin left in a plugins folder beside its universal successor.
    private func formerBundle(in folder: URL, _ name: String, version: String?, loadsHere: Bool) throws -> SameNamePlugins.Candidate {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleExecutable": "QA", "NSPrincipalClass": "QAFilter", "pluginType": "imageFilter"]
        info["CFBundleVersion"] = version
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        let native = MachOImage.hostArchitecture == "x86_64" ? SyntheticMachO.x86_64() : SyntheticMachO()
        let foreign = MachOImage.hostArchitecture == "x86_64" ? SyntheticMachO() : SyntheticMachO.x86_64()
        try (loadsHere ? native : foreign).data().write(to: url.appendingPathComponent("Contents/MacOS/QA"))
        return SameNamePlugins.Candidate(path: url.path, version: PluginBundleVersion.declared(byBundleAt: url), folderRank: 1)
    }

    /// A bundle this Mac cannot load does not stand for the plugin in place of
    /// one it can, whatever version it declares: the loader would set the one
    /// that loads aside and then refuse the other, and the plugin would leave
    /// the menus. A build number such as 300, or a date, compares above 3.3.
    @Test func aBundleThisMacCannotLoadDoesNotStandForOneItCan() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SameNamePluginsTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let current = try formerBundle(in: folder, "QA.osirixplugin", version: "3.3", loadsHere: true)
        for (index, version) in ["300", "20240115", "3.3"].enumerated() {
            let other = try formerBundle(in: folder.appendingPathComponent("\(index)"), "QA.horosplugin", version: version, loadsHere: false)
            #expect(PluginInspector().inspect(bundleAt: URL(fileURLWithPath: other.path)).isLoadable == false)
            #expect(PluginInspector().inspect(bundleAt: URL(fileURLWithPath: current.path)).isLoadable)
            #expect(SameNamePlugins.preferred(among: [other, current]) == current, "declared \(version)")
            #expect(SameNamePlugins.preferred(among: [current, other]) == current, "declared \(version)")
            #expect(SameNamePlugins.isPreferred(current, to: other), "declared \(version)")
            #expect(SameNamePlugins.setAside(among: [other, current]) == [.init(bundle: other, preferred: current)], "declared \(version)")
        }
        // In the user's folder, against one in the computer's: the folder does not bring it back either.
        var userFolder = try formerBundle(in: folder.appendingPathComponent("user"), "QA.osirixplugin", version: "3.3", loadsHere: false)
        userFolder.folderRank = 0
        #expect(SameNamePlugins.preferred(among: [userFolder, current]) == current)
        // When none of them loads here, the stated rule still chooses, and the higher version is the one reported.
        let first = try formerBundle(in: folder.appendingPathComponent("a"), "QB.horosplugin", version: "1.0", loadsHere: false)
        let second = try formerBundle(in: folder.appendingPathComponent("b"), "QB.osirixplugin", version: "2.0", loadsHere: false)
        #expect(SameNamePlugins.preferred(among: [first, second]) == second)
        #expect(SameNamePlugins.setAside(among: [second, first]) == [.init(bundle: first, preferred: second)])
    }

    /// The caller's `canLoad` decides, as the plugin manager's adds its
    /// signature check to the inspection: a higher version whose seal no
    /// longer validates does not stand for the plugin either. Each bundle is
    /// asked once, and only bundles that share a name are asked.
    @Test func theCallersCanLoadDecides() {
        let broken = candidate("/u/Plugins/QA.horosplugin", "300")
        let intact = candidate("/u/Plugins/QA.osirixplugin", "2.0")
        let alone = candidate("/u/Plugins/Alone.horosplugin", "1.0")
        var asked: [String] = []
        let setAside = SameNamePlugins.setAside(among: [broken, alone, intact]) { path in
            asked.append(path)
            return path != broken.path
        }
        #expect(setAside == [.init(bundle: broken, preferred: intact)])
        #expect(asked.sorted() == [broken.path, intact.path].sorted())
        #expect(SameNamePlugins.preferred(among: [broken, intact], canLoad: { $0 != broken.path }) == intact)
        #expect(SameNamePlugins.isPreferred(intact, to: broken, canLoad: { $0 != broken.path }))
    }

    @Test func bundlesOfOtherNamesAreNotSetAside() {
        let one = candidate("/u/Plugins/One.horosplugin", "1.0")
        let other = candidate("/u/Plugins/Other.osirixplugin", "9.0")
        #expect(SameNamePlugins.setAside(among: [one, other]).isEmpty)
        #expect(SameNamePlugins.setAside(among: []).isEmpty)
        #expect(SameNamePlugins.preferred(among: []) == nil)
    }
}
