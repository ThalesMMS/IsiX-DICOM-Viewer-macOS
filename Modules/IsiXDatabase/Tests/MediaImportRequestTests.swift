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
import IsiXContracts
import IsiXPreferences
import Testing
import IsiXDatabase

@Suite struct MediaImportRequestTests {

    @Test func readsTheDictionaryOfCopyFilesThread() {
        let options: [AnyHashable: Any] = ["filesInput": ["/b", "/a"], "copyFiles": NSNumber(value: true), "mountedVolume": NSNumber(value: false),
                                           "onlyDICOM": NSNumber(value: true), "addToAlbum": NSNumber(value: true),
                                           "selectStudy": NSNumber(value: true), "ejectCDDVD": NSNumber(value: true)]
        let request = MediaImportRequest(options: options)
        #expect(request.files == ["/b", "/a"])
        #expect(request.copyFiles && !request.mountedVolume && request.onlyDICOM)
        #expect(request.addToAlbum && request.selectStudy && request.ejectCDDVD)
    }

    @Test func aSwitchThatIsAbsentOrNotANumberIsOff() {
        let request = MediaImportRequest(options: ["copyFiles": "yes"])
        #expect(!request.copyFiles && !request.mountedVolume && !request.onlyDICOM)
        #expect(!request.addToAlbum && !request.selectStudy && !request.ejectCDDVD)
        #expect(request.files.isEmpty)
    }

    /// One element that is not a path must not lose the batch.
    @Test func whatIsNotAPathIsLeftOutAndOnlyThat() {
        let files: [Any] = ["/a", NSNumber(value: 1), "/b", NSNull()]
        let request = MediaImportRequest(options: ["filesInput": files])
        #expect(request.files == ["/a", "/b"])
    }

    @Test func readsFilesInTheOrderOfCompare() {
        let request = MediaImportRequest(files: ["/d/10", "/d/9", "/D/1", "/d/a"], copyFiles: true, mountedVolume: true)
        #expect(request.orderedFiles == ["/D/1", "/d/10", "/d/9", "/d/a"])
        #expect(request.files == ["/d/10", "/d/9", "/D/1", "/d/a"])
    }

    @Test func thePresetSaysWhereItCameFromAndWhatItTakes() {
        func preset(mounted: Bool, onlyDICOM: Bool) -> IngestPreset {
            MediaImportRequest(files: [], copyFiles: true, mountedVolume: mounted, onlyDICOM: onlyDICOM).preset
        }
        #expect(preset(mounted: true, onlyDICOM: true) == .mediaCopyDICOM)
        #expect(preset(mounted: true, onlyDICOM: false) == .mediaCopyAnything)
        #expect(preset(mounted: false, onlyDICOM: true) == .dragAndDropDICOM)
        #expect(preset(mounted: false, onlyDICOM: false) == .dragAndDropAnything)
    }

    /// The preference only registered (a new domain holds the text "1") and
    /// then written by the preferences pane (a number): the same request.
    @Test func aDropTakesOnlyDICOMWhetherThePaneWroteItOrNot() throws {
        let environment = PreferenceEnvironment(viewer: true, appStore: false, hostName: "host", graphicsMemory: 0)
        let registered = try #require(DatabasePreferences.onlyDICOM.registration?.value(in: environment))
        let preferences = MemoryPreferences(registered: [DatabasePreferences.onlyDICOM.name: registered])
        #expect(preferences.object(forKey: DatabasePreferences.onlyDICOM.name) is String)

        func request() -> MediaImportRequest {
            MediaImportRequest(options: MediaImportRequest.dropOptions(preferences: preferences))
        }
        #expect(request().onlyDICOM && request().preset == .dragAndDropDICOM)
        #expect(request().addToAlbum && request().selectStudy && !request().copyFiles)

        preferences.set(NSNumber(value: true), forKey: DatabasePreferences.onlyDICOM.name)
        #expect(request().onlyDICOM && request().preset == .dragAndDropDICOM)

        preferences.set(NSNumber(value: false), forKey: DatabasePreferences.onlyDICOM.name)
        #expect(!request().onlyDICOM && request().preset == .dragAndDropAnything)
    }

    @Test func aDropWithoutAnyOnlyDICOMValueHasNoOptions() {
        #expect(MediaImportRequest.dropOptions(preferences: MemoryPreferences()).isEmpty)
    }

    @Test func usesTheBrowserOnlyForTheAlbumOrTheSelection() {
        #expect(!MediaImportRequest(files: [], copyFiles: true, mountedVolume: false).usesBrowser)
        #expect(MediaImportRequest(files: [], copyFiles: true, mountedVolume: false, addToAlbum: true).usesBrowser)
        #expect(MediaImportRequest(files: [], copyFiles: true, mountedVolume: false, selectStudy: true).usesBrowser)
    }
}
