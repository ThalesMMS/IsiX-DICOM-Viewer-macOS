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

// The vocabulary of the 2D viewer's toolbar: the identifier of the toolbar and
// of each item, the items shown by default and those offered in Customize
// Toolbar, the items the plugins add, the one-click shortcuts to the 3D
// viewers, and what each item needs of the viewer to be enabled. The app makes
// the items (ViewerToolbarItemFactory); this module decides without AppKit.
//
// The identifiers are the texts the toolbar always used: a person's saved
// customization is kept under them, and the toolbar's under its identifier.

/// The identifiers and lists of the 2D viewer's toolbar.
public struct ViewerToolbarCatalog: Sendable {

    /// The identifier of the toolbar, under which NSToolbar saves its customization.
    public static let toolbarIdentifier = "Viewer Toolbar Identifier"

    /// AppKit's flexible space (NSToolbarFlexibleSpaceItemIdentifier).
    public static let flexibleSpace = "NSToolbarFlexibleSpaceItem"

    // MARK: - Item identifiers

    public static let movieExport = "QTExport.pdf"
    public static let photos = "iPhoto2"
    public static let play = "Play.pdf"
    public static let metaData = "XML.icns"
    public static let speed = "Speed"
    public static let tools = "Tools"
    public static let windowLevel = "WLWW"
    public static let thickSlab = "Fusion"
    public static let filters = "Filters"
    public static let blending = "2DBlending"
    public static let movie = "Movie"
    public static let series = "Series"
    public static let patient = "Patient"
    public static let subtraction = "Subtraction"
    public static let send = "Send.icns"
    public static let reconstruction = "Reconstruction"
    public static let rgbFactors = "RGB"
    public static let export = "Export.icns"
    public static let mail = "Mail.icns"
    public static let status = "status"
    public static let syncSeries = "Sync.pdf"
    public static let reset = "Reset.pdf"
    public static let revert = "Revert.tif"
    public static let flipData = "FlipData.tif"
    public static let databaseWindow = "DatabaseWindow.icns"
    public static let keyImages = "keyImages"
    public static let tileWindows = "windows.tif"
    public static let suv = "SUV.tif"
    public static let roiManager = "ROIManager.pdf"
    public static let report = "Report.icns"
    public static let flipVertical = "FlipVertical.pdf"
    public static let flipHorizontal = "FlipHorizontal.pdf"
    public static let vrPanel = "MIP.tif"
    public static let shutter = "Shutter"
    public static let propagateSettings = "PropagateSettings"
    public static let orientation = "Orientation"
    public static let windowsTiling = "WindowsTiling"
    public static let seriesPopup = "SeriesPopup"
    public static let annotations = "Annotations"
    public static let print = "Print.tiff"
    public static let lut12Bit = "LUT12Bit"
    public static let navigator = "Navigator"
    public static let threeDPosition = "3DPosition"
    public static let cobbAngle = "CobbAngle"
    public static let setPixelValue = "SetPixelValue.pdf"
    public static let growingRegion = "GrowingRegion.png"
    public static let studyNote = "StudyNote"

    // MARK: - The 3D shortcuts

    /// One click to each entry of the 2D/3D menu, which takes two: the menu's
    /// action (its selector's text) and tag (the VR viewer tells MIP from VR
    /// by the tag, and the slice thickness sheet reopens the viewer by it), a
    /// short label and the menu's icon.
    public struct ThreeDShortcut: Sendable, Equatable {
        public let identifier: String
        public let label: String
        public let title: String
        public let action: String
        public let tag: Int
        public let image: String

        /// The 3D panel item shows the MIP picture too: the MIP shortcut says
        /// MIP over it.
        public var marksMIP: Bool { tag == 3 }
    }

    public static let threeDShortcuts = [
        ThreeDShortcut(identifier: "Shortcut3DMPR", label: "MPR", title: "3D MPR", action: "mprViewer:", tag: 10, image: "MPR.tif"),
        ThreeDShortcut(identifier: "Shortcut3DCPR", label: "CPR", title: "3D Curved-MPR", action: "cprViewer:", tag: 1, image: "curvedPath.icns"),
        ThreeDShortcut(identifier: "Shortcut2DOrthoMPR", label: "Ortho", title: "2D Orthogonal MPR", action: "orthogonalMPRViewer:", tag: 8, image: "orthogonalReslice.tif"),
        ThreeDShortcut(identifier: "Shortcut3DMIP", label: "MIP", title: "3D MIP", action: "VRViewer:", tag: 3, image: "MIP.tif"),
        ThreeDShortcut(identifier: "Shortcut3DVR", label: "VR", title: "3D Volume Rendering", action: "VRViewer:", tag: 4, image: "VolumeRendering.tif"),
        ThreeDShortcut(identifier: "Shortcut3DSR", label: "Surface", title: "3D Surface Rendering", action: "SRViewer:", tag: 5, image: "Surface.tif"),
        ThreeDShortcut(identifier: "Shortcut3DEndoscopy", label: "Endo", title: "3D Endoscopy", action: "endoscopyViewer:", tag: 9, image: "Endoscopy.tif"),
    ]

    /// The shortcut of `identifier`, nil for any other item.
    public static func threeDShortcut(_ identifier: String?) -> ThreeDShortcut? {
        threeDShortcuts.first { $0.identifier == identifier }
    }

    // MARK: - Lists

    /// The items shown by default, in order: what the toolbar shows when no
    /// customization was saved, or after the person reverts to it.
    public static let defaultIdentifiers = [
        databaseWindow,
        windowsTiling,
        seriesPopup,
        annotations,
        patient,
        tools,
        windowLevel,
        reconstruction,
        orientation,
        thickSlab,
        flexibleSpace,
        movieExport,
        syncSeries,
        propagateSettings,
        play,
        speed,
        vrPanel,
        metaData,
    ]

    /// The items of the viewer offered in Customize Toolbar, in order, before
    /// the plugins': `space` is the toolbar's own space item, and the 12-bit
    /// display item is offered only on a display that shows 12 bits.
    public static func allowedIdentifiers(space: String, canDisplay12Bit: Bool) -> [String] {
        var identifiers = [flexibleSpace, space, mail, send, print, export, photos, movieExport, metaData, reconstruction]
        identifiers += threeDShortcuts.map(\.identifier)
        identifiers += [
            blending, syncSeries, propagateSettings, reset, revert, suv, roiManager, flipData, databaseWindow,
            tileWindows, windowsTiling, seriesPopup, annotations, play, speed, movie, series, patient, windowLevel,
            thickSlab, subtraction, shutter, orientation, rgbFactors, filters, tools, status, keyImages, report,
            flipVertical, flipHorizontal, vrPanel, navigator, threeDPosition, cobbAngle, growingRegion,
            setPixelValue, studyNote,
        ]
        if canDisplay12Bit { identifiers.append(lut12Bit) }
        return identifiers
    }

    // MARK: - The plugins' items

    /// What a plugin's Info.plist says of its toolbar item.
    public struct PluginEntry: Sendable, Equatable {
        /// The plugin's name, which names its item too.
        public let name: String
        /// "pluginType".
        public let pluginType: String?
        /// "allowToolbarIcon", read as a boolean; nil when absent.
        public let allowsToolbarIcon: Bool?
        /// "ToolbarNames", the names of its items; nil when absent.
        public let toolbarNames: [String]?

        public init(name: String, pluginType: String?, allowsToolbarIcon: Bool?, toolbarNames: [String]?) {
            self.name = name
            self.pluginType = pluginType
            self.allowsToolbarIcon = allowsToolbarIcon
            self.toolbarNames = toolbarNames
        }
    }

    /// The plugins whose item the toolbar offers: an image filter, a ROI tool
    /// or an "other" plugin that allows a toolbar icon and, when it lists its
    /// items, lists its own name. "(-", the separator of the plugins menu, is
    /// no plugin. Each name once, in the order a set of strings sized for
    /// every plugin gives them, as the toolbar always listed them.
    public static func pluginItems(_ plugins: [PluginEntry]) -> [String] {
        let names = NSMutableSet(capacity: plugins.count)
        for plugin in plugins where plugin.name != "(-" {
            guard ["imageFilter", "roiTool", "other"].contains(plugin.pluginType ?? ""),
                  plugin.allowsToolbarIcon == true else { continue }
            if let toolbarNames = plugin.toolbarNames, !toolbarNames.contains(plugin.name) { continue }
            names.add(plugin.name)
        }
        return names.allObjects.compactMap { $0 as? String }
    }

    // MARK: - Enablement

    /// What an item needs of the viewer to be enabled, once the viewer shows
    /// images of the database.
    public enum Enablement: Sendable, Equatable {
        /// Always enabled.
        case always
        /// Disabled while the database is read-only (the report).
        case writableDatabase
        /// Disabled for a single image of one frame (play, speed, 2D/3D and the 3D shortcuts).
        case severalImages
        /// Disabled without another 2D viewer (sync).
        case severalViewers
        /// Disabled without a 4D series (the 4D player).
        case severalPhases
        /// Disabled for a single image of one frame without 4D series nor fusion (movie export).
        case movieToExport
        /// Enabled when the image has SUV values.
        case suvValues
        /// Enabled on a display that shows 12 bits.
        case twelveBitDisplay
    }

    /// What `identifier` needs to be enabled.
    public static func enablement(of identifier: String?) -> Enablement {
        switch identifier {
        case report: return .writableDatabase
        case play, speed, reconstruction: return .severalImages
        case syncSeries: return .severalViewers
        case movie: return .severalPhases
        case movieExport: return .movieToExport
        case suv: return .suvValues
        case lut12Bit: return .twelveBitDisplay
        default: return threeDShortcut(identifier) != nil ? .severalImages : .always
        }
    }

    /// What the enablement of an item reads of the viewer.
    public struct ViewerFacts: Sendable, Equatable {
        public var databaseIsReadOnly = false
        /// The current series is a single image of one frame.
        public var singleImageOfOneFrame = false
        /// The number of 2D viewers open.
        public var viewerCount = 1
        /// The number of 4D phases of the viewer.
        public var phaseCount = 1
        public var hasFusion = false
        public var hasSUV = false
        public var canDisplay12Bit = false

        public init() {}
    }

    /// Whether an item that needs `enablement` is enabled for a viewer of `facts`.
    public static func isEnabled(_ enablement: Enablement, _ facts: ViewerFacts) -> Bool {
        switch enablement {
        case .always: return true
        case .writableDatabase: return !facts.databaseIsReadOnly
        case .severalImages: return !facts.singleImageOfOneFrame
        case .severalViewers: return facts.viewerCount > 1
        case .severalPhases: return facts.phaseCount != 1
        case .movieToExport: return !(facts.singleImageOfOneFrame && facts.phaseCount == 1 && !facts.hasFusion)
        case .suvValues: return facts.hasSUV
        case .twelveBitDisplay: return facts.canDisplay12Bit
        }
    }
}
