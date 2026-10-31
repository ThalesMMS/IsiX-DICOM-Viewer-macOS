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
@testable import IsiXPreferences

/// The web portal's and email keys: in the catalog once, with the names the
/// portal, the Web Sharing pane and the exported `Osirix…DefaultsKey` constants
/// use, no registered value, and each read as the accessor the portal used read
/// what the pane or the portal stored.
@Suite struct WebPortalPreferencesTests {
    @Test func theKeysKeepTheirNamesAndAreInTheCatalogOnce() {
        let names = WebPortalPreferences.catalog.map(\.name)
        #expect(names.sorted() == [
            "ActivatePACSOnDemandForWebPortalAlbums", "ActivatePACSOnDemandForWebPortalOtherStudies",
            "ActivatePACSOnDemandForWebPortalSearch", "WebPortalTitle", "customWebPages", "encryptedWebServer",
            "lastNotificationsDate", "logWebServer", "notificationsEmailsSender", "passwordWebServer",
            "preferStudyWithMoreImages", "smartAlbumStudiesDICOMNodes", "wadoOnlyServer", "wadoOnlyServerPort",
            "wadoOnlyServerURL", "webPortalAdminCanDeleteStudies", "webServerAddress",
        ])
        let catalog = DefaultPreferences.catalog.map(\.name)
        for name in names {
            #expect(catalog.filter { $0 == name }.count == 1, "\(name)")
        }
        #expect(WebPortalPreferences.catalog.allSatisfy { $0.registration == nil })
        // The portal's keys NetworkPreferences declares are read from there.
        for name in ["httpWebServer", "httpWebServerPort", "notificationsEmails", "WebServerUseMailAppForEmails",
                     "wadoServer", "searchForComparativeStudiesOnDICOMNodes"] {
            #expect(!names.contains(name), "\(name)")
        }
    }

    @Test func absentKeysReadAsTheAccessorsGaveThem() {
        let store = MemoryPreferences()
        #expect(store[WebPortalPreferences.requiresAuthentication] == false)
        #expect(store[WebPortalPreferences.wadoOnlyServerPort] == 0)
        #expect(store[WebPortalPreferences.wadoOnlyServerURL] == nil)
        #expect(store[WebPortalPreferences.notificationsEmailsSender] == nil)
        #expect(store[WebPortalPreferences.lastNotificationsDate] == 0)
        #expect(store[WebPortalPreferences.smartAlbumStudiesDICOMNodes] == nil)
    }

    @Test func theLastCheckIsTextReadAsANumber() throws {
        // The portal writes String(format: "%lf", seconds) and reads it back with double(forKey:).
        let written = MemoryPreferences()
        let key = WebPortalPreferences.lastNotificationsDate
        written.set(String(format: "%lf", 815_000_000.25), for: key.reading(as: String?.self))
        #expect(written.object(forKey: key.name) as? String == "815000000.250000")
        #expect(written[key] == 815_000_000.25)
        // A number stored by another writer still reads.
        #expect(MemoryPreferences([key.name: NSNumber(value: 12.5)])[key] == 12.5)
    }

    @Test func theSenderIsReadAsText() {
        let key = WebPortalPreferences.notificationsEmailsSender
        #expect(MemoryPreferences([key.name: "Portal <portal@example.test>"])[key] == "Portal <portal@example.test>")
        #expect(MemoryPreferences([key.name: ""])[key] == "")
        // A number stored by hand reads as its text, as string(forKey:) reads it.
        #expect(MemoryPreferences([key.name: NSNumber(value: 7)])[key] == "7")
        #expect(MemoryPreferences([key.name: ["not", "text"]])[key] == nil)
    }

    @Test func switchesAndPortsReadAsThePaneStoresThem() {
        #expect(MemoryPreferences(["wadoOnlyServer": "1"])[WebPortalPreferences.wadoOnlyServer])
        #expect(MemoryPreferences(["passwordWebServer": true])[WebPortalPreferences.requiresAuthentication])
        #expect(MemoryPreferences(["wadoOnlyServerPort": "8090"])[WebPortalPreferences.wadoOnlyServerPort] == 8090)
        #expect(MemoryPreferences(["wadoOnlyServerPort": NSNumber(value: 8091)])[WebPortalPreferences.wadoOnlyServerPort] == 8091)
        #expect(MemoryPreferences(["WebPortalTitle": "Teaching"])[WebPortalPreferences.title] == "Teaching")
    }

    @Test func theSmartAlbumFiltersKeepTheirEntries() throws {
        let stored: [Any] = [
            ["name": "CT", "activated": true, "modality": "CT"] as [String: Any],
            ["name": "Off", "activated": NSNumber(value: 0)] as [String: Any],
        ]
        let key = WebPortalPreferences.smartAlbumStudiesDICOMNodes
        let entries = try #require(MemoryPreferences([key.name: stored])[key])
        #expect(entries.count == 2)
        let first = try #require(entries.first?.object as? [String: Any])
        #expect(first["name"] as? String == "CT")
        #expect((first["activated"] as? NSNumber)?.boolValue == true)
        let written = MemoryPreferences()
        written.set(entries, for: key)
        #expect(PropertyListValue(try #require(written.object(forKey: key.name))) == PropertyListValue(stored))
        #expect(MemoryPreferences([key.name: "text"])[key] == nil)
    }
}
