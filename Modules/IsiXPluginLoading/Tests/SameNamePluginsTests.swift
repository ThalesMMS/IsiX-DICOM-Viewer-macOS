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

    @Test func bundlesOfOtherNamesAreNotSetAside() {
        let one = candidate("/u/Plugins/One.horosplugin", "1.0")
        let other = candidate("/u/Plugins/Other.osirixplugin", "9.0")
        #expect(SameNamePlugins.setAside(among: [one, other]).isEmpty)
        #expect(SameNamePlugins.setAside(among: []).isEmpty)
        #expect(SameNamePlugins.preferred(among: []) == nil)
    }
}
