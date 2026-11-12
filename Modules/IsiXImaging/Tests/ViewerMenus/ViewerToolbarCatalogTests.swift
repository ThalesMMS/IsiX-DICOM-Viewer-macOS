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
@testable import IsiXImaging

@Suite struct ViewerToolbarCatalogTests {

    typealias Catalog = ViewerToolbarCatalog

    @Test func identifiersKeepTheirSavedTexts() {
        #expect(Catalog.toolbarIdentifier == "Viewer Toolbar Identifier")
        #expect(Catalog.flexibleSpace == "NSToolbarFlexibleSpaceItem")
        #expect(Catalog.movieExport == "QTExport.pdf")
        #expect(Catalog.play == "Play.pdf")
        #expect(Catalog.thickSlab == "Fusion")
        #expect(Catalog.blending == "2DBlending")
        #expect(Catalog.tileWindows == "windows.tif")
        #expect(Catalog.vrPanel == "MIP.tif")
        #expect(Catalog.studyNote == "StudyNote")
    }

    @Test func defaultItemsInTheirOrder() {
        #expect(Catalog.defaultIdentifiers == [
            "DatabaseWindow.icns", "WindowsTiling", "SeriesPopup", "Annotations", "Patient", "Tools", "WLWW",
            "Reconstruction", "Orientation", "Fusion", "QTExport.pdf", "Sync.pdf",
            "PropagateSettings", "Play.pdf", "Speed", "MIP.tif", "XML.icns",
        ])
        // No space among them: the items run on from the first to the last.
        #expect(!Catalog.defaultIdentifiers.contains(Catalog.flexibleSpace))
    }

    @Test func allowedItemsInTheirOrder() {
        let space = "NSToolbarSpaceItem"
        let allowed = Catalog.allowedIdentifiers(space: space, canDisplay12Bit: false)
        #expect(Array(allowed.prefix(10)) == ["NSToolbarFlexibleSpaceItem", space, "Mail.icns", "Send.icns", "Print.tiff",
                                              "Export.icns", "iPhoto2", "QTExport.pdf", "XML.icns", "Reconstruction"])
        #expect(Array(allowed[10..<17]) == Catalog.threeDShortcuts.map(\.identifier))
        #expect(allowed[17] == "2DBlending")
        #expect(allowed.last == "StudyNote")
        #expect(allowed.count == 55)
        #expect(Set(allowed).count == allowed.count)
        #expect(!allowed.contains("LUT12Bit"))
        let with12Bit = Catalog.allowedIdentifiers(space: space, canDisplay12Bit: true)
        #expect(with12Bit == allowed + ["LUT12Bit"])
    }

    @Test func everyDefaultItemIsOffered() {
        let allowed = Set(Catalog.allowedIdentifiers(space: "space", canDisplay12Bit: true))
        for identifier in Catalog.defaultIdentifiers {
            #expect(allowed.contains(identifier))
        }
        for shortcut in Catalog.threeDShortcuts {
            #expect(!Catalog.defaultIdentifiers.contains(shortcut.identifier))
        }
    }

    @Test func threeDShortcutsSendTheMenusActions() {
        #expect(Catalog.threeDShortcuts.map(\.tag) == [10, 1, 8, 3, 4, 5, 9])
        #expect(Catalog.threeDShortcut("Shortcut3DMIP")?.action == "VRViewer:")
        #expect(Catalog.threeDShortcut("Shortcut3DMIP")?.marksMIP == true)
        #expect(Catalog.threeDShortcut("Shortcut3DVR")?.marksMIP == false)
        #expect(Catalog.threeDShortcut("Shortcut3DCPR")?.action == "cprViewer:")
        #expect(Catalog.threeDShortcut("Play.pdf") == nil)
        #expect(Catalog.threeDShortcut(nil) == nil)
    }

    @Test func pluginItems() {
        let plugins = [
            Catalog.PluginEntry(name: "Filter", pluginType: "imageFilter", allowsToolbarIcon: true, toolbarNames: nil),
            Catalog.PluginEntry(name: "Tool", pluginType: "roiTool", allowsToolbarIcon: true, toolbarNames: ["Tool", "Other"]),
            Catalog.PluginEntry(name: "Listed", pluginType: "other", allowsToolbarIcon: true, toolbarNames: ["Another"]),
            Catalog.PluginEntry(name: "NoIcon", pluginType: "imageFilter", allowsToolbarIcon: false, toolbarNames: nil),
            Catalog.PluginEntry(name: "Unsaid", pluginType: "imageFilter", allowsToolbarIcon: nil, toolbarNames: nil),
            Catalog.PluginEntry(name: "Report", pluginType: "report", allowsToolbarIcon: true, toolbarNames: nil),
            Catalog.PluginEntry(name: "(-", pluginType: "imageFilter", allowsToolbarIcon: true, toolbarNames: nil),
            Catalog.PluginEntry(name: "Filter", pluginType: "imageFilter", allowsToolbarIcon: true, toolbarNames: nil),
        ]
        #expect(Set(Catalog.pluginItems(plugins)) == ["Filter", "Tool"])
        #expect(Catalog.pluginItems(plugins).count == 2)
        #expect(Catalog.pluginItems([]).isEmpty)
    }

    @Test func whatEachItemNeeds() {
        #expect(Catalog.enablement(of: "Report.icns") == .writableDatabase)
        for identifier in ["Play.pdf", "Speed", "Reconstruction", "Shortcut3DMPR", "Shortcut3DEndoscopy"] {
            #expect(Catalog.enablement(of: identifier) == .severalImages)
        }
        #expect(Catalog.enablement(of: "Sync.pdf") == .severalViewers)
        #expect(Catalog.enablement(of: "Movie") == .severalPhases)
        #expect(Catalog.enablement(of: "QTExport.pdf") == .movieToExport)
        #expect(Catalog.enablement(of: "SUV.tif") == .suvValues)
        #expect(Catalog.enablement(of: "LUT12Bit") == .twelveBitDisplay)
        #expect(Catalog.enablement(of: "Mail.icns") == .always)
        #expect(Catalog.enablement(of: "SomePlugin") == .always)
        #expect(Catalog.enablement(of: nil) == .always)
    }

    @Test func enablementOverTheViewer() {
        var facts = Catalog.ViewerFacts()
        #expect(Catalog.isEnabled(.always, facts))
        #expect(Catalog.isEnabled(.writableDatabase, facts))
        #expect(Catalog.isEnabled(.severalImages, facts))
        #expect(!Catalog.isEnabled(.severalViewers, facts))
        #expect(!Catalog.isEnabled(.severalPhases, facts))
        #expect(Catalog.isEnabled(.movieToExport, facts))
        #expect(!Catalog.isEnabled(.suvValues, facts))
        #expect(!Catalog.isEnabled(.twelveBitDisplay, facts))

        facts.databaseIsReadOnly = true
        facts.singleImageOfOneFrame = true
        #expect(!Catalog.isEnabled(.writableDatabase, facts))
        #expect(!Catalog.isEnabled(.severalImages, facts))
        // A single image still exports a movie of its phases or its fusion.
        #expect(!Catalog.isEnabled(.movieToExport, facts))
        facts.phaseCount = 3
        #expect(Catalog.isEnabled(.movieToExport, facts))
        #expect(Catalog.isEnabled(.severalPhases, facts))
        facts.phaseCount = 1
        facts.hasFusion = true
        #expect(Catalog.isEnabled(.movieToExport, facts))

        facts.viewerCount = 2
        facts.hasSUV = true
        facts.canDisplay12Bit = true
        #expect(Catalog.isEnabled(.severalViewers, facts))
        #expect(Catalog.isEnabled(.suvValues, facts))
        #expect(Catalog.isEnabled(.twelveBitDisplay, facts))
    }
}
