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
@testable import IsiXInstallation

/// Whether the application offers to move itself, where to, and its Dock
/// tile, without a file system, a Dock or a window. The move itself, on
/// disposable signed bundles, is tests/test-application-installation.py.
struct InstallationRulesTests {
    private let applications = ["/Applications", "/Users/u/Applications"]
    private let translocated = "/private/var/folders/ab/xyz/T/AppTranslocation/1F2E3D4C-0000-4000-8000-000000000000/d/IsiX DICOM Viewer.app"

    private func decide(_ running: String, original: String? = nil, appStore: Bool = false,
                        suppressed: Bool = false, inProgress: Bool = false) -> MoveOffer.Decision {
        MoveOffer.decide(isAppStore: appStore, suppressed: suppressed, inProgress: inProgress,
                         runningPath: running, originalPath: original, applicationDirectories: applications)
    }

    @Test func aCopyOutsideApplicationsIsOffered() {
        #expect(decide("/Users/u/Downloads/IsiX DICOM Viewer.app") == .offer(source: "/Users/u/Downloads/IsiX DICOM Viewer.app"))
        #expect(decide("/Applications/IsiX DICOM Viewer.app") == .skip(.installed))
        #expect(decide("/Users/u/Applications/IsiX DICOM Viewer.app") == .skip(.installed))
        // Any folder named Applications counts, by whole component only.
        #expect(decide("/Volumes/Data/Applications/IsiX DICOM Viewer.app") == .skip(.installed))
        #expect(decide("/Users/u/ApplicationsFake/IsiX DICOM Viewer.app") == .offer(source: "/Users/u/ApplicationsFake/IsiX DICOM Viewer.app"))
    }

    @Test func theAppStoreChannelNeverOffers() {
        #expect(decide("/Users/u/Downloads/IsiX DICOM Viewer.app", appStore: true) == .skip(.appStore))
        #expect(decide(translocated, original: "/Users/u/Downloads/IsiX DICOM Viewer.app", appStore: true) == .skip(.appStore))
    }

    @Test func theUsersChoiceAndAnOfferOnScreenAreKept() {
        #expect(decide("/Users/u/Downloads/IsiX DICOM Viewer.app", suppressed: true) == .skip(.suppressed))
        #expect(decide("/Users/u/Downloads/IsiX DICOM Viewer.app", inProgress: true) == .skip(.inProgress))
    }

    @Test func aTranslocatedCopyIsJudgedWhereItReallyIs() {
        #expect(ApplicationLocation.isTranslocated(translocated))
        #expect(!ApplicationLocation.isTranslocated("/Users/u/Downloads/IsiX DICOM Viewer.app"))
        #expect(decide(translocated, original: "/Users/u/Downloads/IsiX DICOM Viewer.app") == .offer(source: "/Users/u/Downloads/IsiX DICOM Viewer.app"))
        // Moved without Finder, a copy in Applications can run translocated too.
        #expect(decide(translocated, original: "/Applications/IsiX DICOM Viewer.app") == .skip(.installed))
        #expect(decide(translocated) == .skip(.translocatedOriginalUnknown))
    }

    @Test func aNestedCopyIsMovedOutEvenFromApplications() {
        let nested = "/Applications/Other.app/Contents/Resources/IsiX DICOM Viewer.app"
        #expect(ApplicationLocation.isNested(nested))
        #expect(!ApplicationLocation.isNested("/Applications/IsiX DICOM Viewer.app"))
        #expect(decide(nested) == .offer(source: nested))
    }

    @Test func theHomeApplicationsFolderIsPreferredOnlyWhenInUse() {
        #expect(ApplicationLocation.preferredDirectory(user: "/Users/u/Applications", userHasApplications: true, local: "/Applications") == "/Users/u/Applications")
        #expect(ApplicationLocation.preferredDirectory(user: "/Users/u/Applications", userHasApplications: false, local: "/Applications") == "/Applications")
        #expect(ApplicationLocation.preferredDirectory(user: nil, userHasApplications: true, local: "/Applications") == "/Applications")
    }

    @Test func dockTilesAreMatchedByTheirFileURL() throws {
        let path = "/tmp/Source's & \"quoted\".app"
        let tile = DockTile.tile(forApplicationAt: path)
        #expect(tile["tile-type"] as? String == "file-tile")
        let file = (tile["tile-data"] as? [String: Any])?["file-data"] as? [String: Any]
        #expect(file?["_CFURLString"] as? String == URL(fileURLWithPath: path).absoluteString)
        #expect(file?["_CFURLStringType"] as? Int == 15)
        // As the Dock stores it: through a property list.
        let data = try PropertyListSerialization.data(fromPropertyList: tile, format: .xml, options: 0)
        let decoded = try PropertyListSerialization.propertyList(from: data, format: nil)
        #expect(DockTile.contains([decoded], applicationAt: path))
        #expect(!DockTile.contains([decoded], applicationAt: path + "/Other"))
        #expect(!DockTile.contains([["tile-data": "invalid"]], applicationAt: path))
        #expect(DockTile.contains([["tile-data": ["file-data": ["_CFURLString": path]]]], applicationAt: path))
    }
}
