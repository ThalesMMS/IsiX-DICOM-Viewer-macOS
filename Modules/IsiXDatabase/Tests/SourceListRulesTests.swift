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
import IsiXDatabase
import IsiXPreferences

@Suite struct SourceListRulesTests {

    // MARK: The local databases the preferences remember

    private func written(_ update: SourceListRules.SourcesUpdate) -> LocalDatabaseSources?? {
        if case .write(let list) = update { return .some(list) }
        return .none
    }

    @Test func aShownDatabaseIsAddedAtTheEndKeepingWhatTheListHolds() {
        let stored = LocalDatabaseSources(propertyList: .array([
            .dictionary(["Path": .string("/Volumes/A"), "Description": .string("A DB"), "federated": .boolean(true)]),
            .string("not a source"),
        ]))
        let update = SourceListRules.sources(stored, addingShownFolder: "/Users/me/Archive", name: "Archive DB", isTemporary: false)
        #expect(written(update)??.propertyList == .array([
            .dictionary(["Path": .string("/Volumes/A"), "Description": .string("A DB"), "federated": .boolean(true)]),
            .string("not a source"),
            .dictionary(["Path": .string("/Users/me/Archive"), "Description": .string("Archive DB")]),
        ]))
    }

    @Test func aTemporaryFolderIsNotRemembered() {
        let stored = LocalDatabaseSources([])
        if case .unchanged = SourceListRules.sources(stored, addingShownFolder: "/tmp/CD", name: "CD DB", isTemporary: true) {
        } else {
            Issue.record("a temporary folder was written to the list")
        }
    }

    @Test func aListThatIsNotStoredStaysNotStored() {
        let update = SourceListRules.sources(nil, addingShownFolder: "/Users/me/A", name: "A DB", isTemporary: false)
        #expect(written(update) != nil)
        #expect(written(update)?.map(\.propertyList) == nil)
    }

    @Test func aSourceIsFoundByItsFolderLiterally() {
        let stored = LocalDatabaseSources([LocalDatabaseSource(path: "/Volumes/Caf\u{e9}", name: "precomposed"),
                                           LocalDatabaseSource(path: "/Volumes/B", name: "B")])
        #expect(SourceListRules.source(of: stored, at: "/Volumes/B")?.name == "B")
        #expect(SourceListRules.source(of: stored, at: "/Volumes/Cafe\u{301}") == nil)
        #expect(SourceListRules.source(of: stored, at: nil) == nil)
        #expect(SourceListRules.source(of: nil, at: "/Volumes/B") == nil)
    }

    // MARK: Entered and detected sources

    @Test func anEnteredSourceLeavesTheListOnlyWhenNothingElseKeepsIt() {
        #expect(SourceListRules.fate(stillStored: true, detected: false) == .kept)
        #expect(SourceListRules.fate(stillStored: true, detected: true) == .kept)
        #expect(SourceListRules.fate(stillStored: false, detected: true) == .notEntered)
        #expect(SourceListRules.fate(stillStored: false, detected: false) == .removed)
    }

    @Test func bonjourListsSharedDatabasesUnlessTurnedOffAndNodesOnlyWhenTurnedOn() {
        #expect(SourceListRules.listsBonjourSources(.sharedDatabase, doNotSearchSharedDatabases: false, searchDICOMNodes: false))
        #expect(!SourceListRules.listsBonjourSources(.sharedDatabase, doNotSearchSharedDatabases: true, searchDICOMNodes: true))
        #expect(SourceListRules.listsBonjourSources(.dicomNode, doNotSearchSharedDatabases: true, searchDICOMNodes: true))
        #expect(!SourceListRules.listsBonjourSources(.dicomNode, doNotSearchSharedDatabases: false, searchDICOMNodes: false))
    }

    @Test func anEnteredNodeIsKeyedByAddressNumericPortAndAETitle() {
        #expect(SourceListRules.enteredNodeKey(address: .string("pacs"), port: .integer(104), aeTitle: .string("AE")) == "pacs104AE")
        // A port stored as text was never part of the key.
        #expect(SourceListRules.enteredNodeKey(address: .string("pacs"), port: .string("104"), aeTitle: .string("AE")) == "pacs0AE")
        #expect(SourceListRules.enteredNodeKey(address: nil, port: nil, aeTitle: nil) == "(null)0(null)")
    }

    @Test func aResolvedServiceIsListedWithItsFirstIPv4AddressThenIPv6() {
        let v6 = SourceListRules.ServiceAddress(host: "fe80::1", port: 4096, isIPv4: false)
        let v4a = SourceListRules.ServiceAddress(host: "10.0.0.2", port: 4096, isIPv4: true)
        let v4b = SourceListRules.ServiceAddress(host: "10.0.0.3", port: 4096, isIPv4: true)
        #expect(SourceListRules.preferredAddress([v6, v4a, v4b]) == v4a)
        #expect(SourceListRules.preferredAddress([v6]) == v6)
        #expect(SourceListRules.preferredAddress([]) == nil)
    }

    // MARK: Mounted volumes

    @Test func mountedVolumesAreIgnoredOnlyWhenSetSo() {
        #expect(!SourceListRules.listsMountedVolumes(mountAction: 2))
        #expect(SourceListRules.listsMountedVolumes(mountAction: -1))
        #expect(SourceListRules.listsMountedVolumes(mountAction: 0))
    }

    @Test func aVolumeIsASourceWhenItIsAMediumAnIPodOrHoldsDICOM() {
        #expect(SourceListRules.mountKind(opticalMediaType: "CD-ROM", mediaType: "iPod", holdsDICOMDIR: false, holdsDatabaseFolder: false) == .generic)
        #expect(SourceListRules.mountKind(opticalMediaType: "", mediaType: "iPod", holdsDICOMDIR: true, holdsDatabaseFolder: false) == .iPod)
        #expect(SourceListRules.mountKind(opticalMediaType: nil, mediaType: "Generic", holdsDICOMDIR: true, holdsDatabaseFolder: false) == .generic)
        #expect(SourceListRules.mountKind(opticalMediaType: nil, mediaType: nil, holdsDICOMDIR: false, holdsDatabaseFolder: true) == .generic)
        #expect(SourceListRules.mountKind(opticalMediaType: nil, mediaType: "Generic", holdsDICOMDIR: false, holdsDatabaseFolder: false) == nil)
    }

    @Test func aVolumeWithALocalDatabaseInsideIsListedAlready() {
        #expect(SourceListRules.isListedAsLocalDatabase(volume: "/Volumes/Disk", localLocations: ["/Volumes/Disk/Archive"]))
        #expect(SourceListRules.isListedAsLocalDatabase(volume: "/Volumes/Disk", localLocations: ["/Volumes/Disk"]))
        #expect(!SourceListRules.isListedAsLocalDatabase(volume: "/Volumes/Disk", localLocations: ["/Volumes/Disk 2/Archive"]))
    }

    @Test func aScannedVolumeIsSelectedByTheScanWhenAskedAndByThePreferenceOtherwise() {
        #expect(SourceListRules.selectsScannedVolume(mountAction: -1, commandDown: false, scanSelectsIt: true, autoSelectsMedia: false, deviceStillThere: false))
        #expect(!SourceListRules.selectsScannedVolume(mountAction: -1, commandDown: false, scanSelectsIt: false, autoSelectsMedia: true, deviceStillThere: true))
        #expect(SourceListRules.selectsScannedVolume(mountAction: 0, commandDown: true, scanSelectsIt: true, autoSelectsMedia: false, deviceStillThere: false))
        #expect(SourceListRules.selectsScannedVolume(mountAction: 0, commandDown: false, scanSelectsIt: false, autoSelectsMedia: true, deviceStillThere: true))
        #expect(!SourceListRules.selectsScannedVolume(mountAction: 0, commandDown: false, scanSelectsIt: true, autoSelectsMedia: true, deviceStillThere: false))
    }

    // MARK: Opening and copying

    @Test func aMissingDatabaseOnAVolumeMentionsTheDrive() {
        #expect(SourceListRules.missingDatabaseMayBeOnDrive("/Volumes/Disk/Archive"))
        #expect(!SourceListRules.missingDatabaseMayBeOnDrive("/Users/me/Archive"))
        #expect(!SourceListRules.missingDatabaseMayBeOnDrive(nil))
    }

    @Test func aCopyIsRoutedByWhereItComesFromAndGoes() {
        #expect(SourceListRules.copyRoute(fromLocalDatabase: true, to: .localDatabase) == .localToLocal)
        #expect(SourceListRules.copyRoute(fromLocalDatabase: true, to: .sharedDatabase) == .localToShared)
        #expect(SourceListRules.copyRoute(fromLocalDatabase: true, to: .dicomNode) == .localToNode)
        #expect(SourceListRules.copyRoute(fromLocalDatabase: false, to: .localDatabase) == .sharedToLocal)
        #expect(SourceListRules.copyRoute(fromLocalDatabase: false, to: .sharedDatabase) == .sharedToRemote)
        #expect(SourceListRules.copyRoute(fromLocalDatabase: false, to: .dicomNode) == .sharedToRemote)
        #expect(SourceListRules.copyRoute(fromLocalDatabase: true, to: nil) == nil)
    }

    @Test func theBonjourSearchOfSharedDatabasesIsOffUntilTurnedOn() {
        #expect(MemoryPreferences()[SourceListPreferences.doNotSearchForBonjourServices] == false)
        #expect(MemoryPreferences(["DoNotSearchForBonjourServices": true])[SourceListPreferences.doNotSearchForBonjourServices])
    }
}
