/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork


import AppKit
import IsiXImaging
import IsiXPreferences

// The 2D viewer's toolbar: its items, the lists of the items shown by default
// and offered in Customize Toolbar, their enablement, the toolbar set on the
// window, the detached toolbar panel and the floating thumbnails lists shown
// for the front viewer, the Tools item (the tool palette and the mouse button
// radios), the Shutter item, the Cobb angle and the 12-bit display item. The
// identifiers, the lists and what each item needs to be enabled are
// IsiXImaging's ViewerToolbarCatalog; this makes the AppKit side.
//
// The viewer stays the toolbar's delegate, and the target of its items and
// of the actions of its controls: it keeps the selectors AppKit, the nib and
// the former plugins send, and hands each of them here with itself. This
// keeps no reference to the viewer, made from the viewer's graph when asked.
// A message to nil answered nil, 0 or NO: the optional chains below answer
// the same.

private typealias Catalog = ViewerToolbarCatalog

/// `[object tag]` sent to an `id`: 0 for nil, as a message to nil answered, and
/// the object's own -tag otherwise (an object without -tag raises
/// "unrecognized selector", as the message did).
private func objcTag(_ object: Any?) -> Int {
    guard let object = object as? NSObject else { return 0 }
    typealias TagIMP = @convention(c) (AnyObject, Selector) -> Int
    let selector = NSSelectorFromString("tag")
    return unsafeBitCast(object.method(for: selector), to: TagIMP.self)(object, selector)
}

/// `[object selectedCell]` sent to an `id`: nil for nil, and the object's own
/// answer otherwise (or "unrecognized selector", as before).
private func objcSelectedCell(_ object: Any?) -> AnyObject? {
    guard let object = object as? NSObject else { return nil }
    return object.perform(NSSelectorFromString("selectedCell"))?.takeUnretainedValue()
}

/// `[object title]` sent to an `id`, for a string.
private func objcTitle(_ object: Any?) -> String? {
    guard let object = object as? NSObject else { return nil }
    return object.perform(NSSelectorFromString("title"))?.takeUnretainedValue() as? String
}

/// `[value intValue]` of an NSNumber or an NSString; nil answers 0.
private func objcIntValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

/// `[value boolValue]` of an Info.plist value: an NSNumber or an NSString.
private func objcBoolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// The 3D Panel item shows the MIP picture too: the MIP shortcut says MIP on it.
@MainActor private func threeDShortcutImage(_ shortcut: Catalog.ThreeDShortcut) -> NSImage? {
    guard let base = NSImage.toolbarImageNamed(shortcut.image) else { return nil }
    guard shortcut.marksMIP else { return base }
    return NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        let text = "MIP" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: rect.height * 0.32), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        let box = NSMakeRect(rect.midX - size.width / 2 - 2, rect.minY, size.width + 4, size.height)
        NSColor(calibratedWhite: 0, alpha: 0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 2, yRadius: 2).fill()
        text.draw(at: NSMakePoint(box.minX + 2, box.minY), withAttributes: attributes)
        return true
    }
}

/// MAXSCREENS of ViewerController.m: the thumbnails list panels, one per screen.
private let maxScreens = 10

/// The plugin bundles of the toolbar, by the name of their item.
@MainActor private func pluginBundle(_ name: String) -> Bundle? {
    PluginManager.pluginsDict()?.object(forKey: name) as? Bundle
}

/// The loaded plugins' principal objects, in the order of their register.
@MainActor private func pluginFilters() -> [AnyObject] {
    let plugins = PluginManager.plugins()
    return (plugins?.allKeys ?? []).compactMap { plugins?.object(forKey: $0) as AnyObject? }
}

@MainActor struct ViewerToolbarItemFactory {

    /// Tags of the mouse button radios in the toolbar: the left button is 0,
    /// the right button 1 and the middle button 2.
    static let leftButtonTag = 0
    static let rightButtonTag = 1
    static let middleButtonTag = 2

    private let graph: ViewerSessionGraph

    /// The toolbar of the viewer whose graph is `graph`.
    init(_ graph: ViewerSessionGraph) {
        self.graph = graph
    }

    private var preferences: any PreferenceStore { graph.preferences }

    // MARK: - Items

    /// The item `itemIdent`: one of the viewer's, a plugin's item or one a
    /// plugin makes for it; nil for an identifier nobody knows.
    func item(for itemIdent: String, in viewer: ViewerController) -> NSToolbarItem? {
        if let spaceItem = ToolbarPolicy.spaceItem(for: itemIdent) {
            return spaceItem
        }

        let newItem = NSToolbarItem(itemIdentifier: NSToolbarItem.Identifier(itemIdent))
        var toolbarItem: NSToolbarItem? = newItem

        /// The view keeps its designed dimensions in the bar and palette.
        func setView(_ view: NSView?) {
            let size = ToolbarPolicy.designedSize(of: view)
            newItem.view = view
            ToolbarPolicy.constrainView(of: newItem, minimum: size, maximum: size)
        }

        /// An item with a picture that sends `action` to `target`; the texts
        /// are localized, and the palette's label is the label unless given.
        func button(_ label: String, palette: String? = nil, toolTip: String?, image: NSImage?, target: AnyObject?, action: Selector) {
            newItem.label = label
            newItem.paletteLabel = palette ?? label
            if let toolTip { newItem.toolTip = toolTip }
            newItem.image = image
            newItem.target = target
            newItem.action = action
        }

        /// An item that shows one of the viewer's views.
        func control(_ label: String, palette: String? = nil, toolTip: String?, view: NSView?) {
            newItem.label = label
            newItem.paletteLabel = palette ?? label
            if let toolTip { newItem.toolTip = toolTip }
            setView(view)
        }

        switch itemIdent {
        case Catalog.movieExport:
            button(NSLocalizedString("Movie Export", comment: ""), toolTip: NSLocalizedString("Export this series in a Movie file", comment: ""), image: NSImage.toolbarImageNamed(Catalog.movieExport),
                   target: viewer, action: #selector(ViewerController.exportQuicktime(_:)))
        case Catalog.print:
            button(NSLocalizedString("Print", comment: ""), toolTip: NSLocalizedString("Print selected study/series to a DICOM printer", comment: ""), image: NSImage.toolbarImageNamed(Catalog.print),
                   target: viewer, action: #selector(ViewerController.printDICOM(_:)))
        case Catalog.photos:
            button(NSLocalizedString("Photos", comment: ""), toolTip: NSLocalizedString("Export this image to Photos", comment: ""), image: NSImage.toolbarImageNamed("Photos"),
                   target: viewer, action: #selector(ViewerController.export2iPhoto(_:)))
        case Catalog.mail:
            button(NSLocalizedString("Email", comment: ""), toolTip: NSLocalizedString("Email this image", comment: ""), image: NSImage.toolbarImageNamed(Catalog.mail),
                   target: viewer, action: #selector(ViewerController.sendMail(_:)))
        case Catalog.export:
            button(NSLocalizedString("DICOM File", comment: ""), palette: NSLocalizedString("Export as DICOM File", comment: ""), toolTip: NSLocalizedString("Export this image/series in a DICOM file", comment: ""),
                   image: NSImage.toolbarImageNamed(Catalog.export), target: viewer, action: #selector(ViewerController.exportDICOMFile(_:)))
        case Catalog.send:
            button(NSLocalizedString("Send", comment: ""), toolTip: NSLocalizedString("Send this series to a DICOM node", comment: ""), image: NSImage.toolbarImageNamed(Catalog.send),
                   target: viewer, action: #selector(ViewerController.export2PACS(_:)))
        case Catalog.metaData:
            button(NSLocalizedString("Meta-Data", comment: ""), toolTip: NSLocalizedString("View meta-data of this image", comment: ""), image: NSImage.toolbarImageNamed(Catalog.metaData),
                   target: viewer, action: NSSelectorFromString("viewXML:"))
        case Catalog.play:
            button(NSLocalizedString("Browse", comment: ""), toolTip: NSLocalizedString("Browse this series", comment: ""), image: NSImage.toolbarImageNamed(Catalog.play),
                   target: viewer, action: #selector(ViewerController.playStop(_:)))
        case Catalog.syncSeries:
            let image = ViewerController.horos_SYNCSERIES() ? "SyncLock.pdf" : Catalog.syncSeries
            button(NSLocalizedString("Sync", comment: ""), toolTip: NSLocalizedString("Syncronize slice position", comment: ""), image: NSImage.toolbarImageNamed(image),
                   target: viewer, action: #selector(ViewerController.syncSeries(_:)))
        case Catalog.reset:
            button(NSLocalizedString("Reset", comment: ""), toolTip: NSLocalizedString("Reset image to original view", comment: ""), image: NSImage.toolbarImageNamed(Catalog.reset),
                   target: viewer, action: #selector(ViewerController.resetImage(_:)))
        case Catalog.revert:
            button(NSLocalizedString("Revert", comment: ""), toolTip: NSLocalizedString("Revert series by re-loading images from disk", comment: ""), image: NSImage.toolbarImageNamed(Catalog.revert),
                   target: viewer, action: #selector(ViewerController.revertSeries(_:)))
        case Catalog.flipData:
            button(NSLocalizedString("Flip", comment: ""), toolTip: NSLocalizedString("Flip series", comment: ""), image: NSImage.toolbarImageNamed(Catalog.flipData),
                   target: viewer, action: #selector(ViewerController.flipDataSeries(_:)))
        case Catalog.databaseWindow:
            button(NSLocalizedString("Database", comment: ""), toolTip: NSLocalizedString("Close viewers and open Database window", comment: ""), image: NSImage.toolbarImageNamed(Catalog.databaseWindow),
                   target: viewer, action: #selector(ViewerController.databaseWindow(_:)))
        case Catalog.roiManager:
            button(NSLocalizedString("ROI Manager", comment: ""), toolTip: nil, image: NSImage.toolbarImageNamed(Catalog.roiManager),
                   target: viewer, action: #selector(ViewerController.roiGetManager(_:)))
        case Catalog.suv:
            button(NSLocalizedString("SUV", comment: ""), toolTip: NSLocalizedString("Display SUVbw values", comment: ""), image: NSImage.toolbarImageNamed(Catalog.suv),
                   target: viewer, action: #selector(ViewerController.displaySUV(_:)))
        case Catalog.report:
            newItem.label = NSLocalizedString("Report", comment: "")
            newItem.paletteLabel = NSLocalizedString("Report", comment: "")
            newItem.toolTip = NSLocalizedString("Create/Open a report for selected study", comment: "")
            viewer.setToolbarReportIconFor(newItem)
            newItem.target = viewer
            newItem.action = #selector(ViewerController.generateReport(_:))
        case Catalog.tileWindows:
            // The application tiles the viewers' windows.
            button(NSLocalizedString("Tile", comment: ""), toolTip: NSLocalizedString("Tile Windows", comment: ""), image: NSImage.toolbarImageNamed(Catalog.tileWindows),
                   target: graph.processGraph.appController, action: #selector(AppController.tileWindows(_:)))
        case Catalog.speed:
            newItem.label = NSLocalizedString("Slice Cine Rate", comment: "")
            newItem.paletteLabel = NSLocalizedString("Slice Cine Rate", comment: "")
            newItem.toolTip = NSLocalizedString("Change the number of slices displayed per second within the current series", comment: "")
            // Wider than designed, within limits: the rate's slider stretches.
            let speedView = viewer.horos_speedView
            newItem.view = speedView
            let height = ToolbarPolicy.designedSize(of: speedView).height
            ToolbarPolicy.constrainView(of: newItem, minimum: NSSize(width: 100, height: height), maximum: NSSize(width: 200, height: height))
        case Catalog.movie:
            control(NSLocalizedString("4D Player", comment: ""), toolTip: NSLocalizedString("Play temporal phases and change phases per second independently of slice cine", comment: ""), view: viewer.horos_movieView)
        case Catalog.series:
            control(NSLocalizedString("Series", comment: ""), toolTip: NSLocalizedString("Next/Previous Series", comment: ""), view: viewer.horos_serieView)
        case Catalog.patient:
            control(NSLocalizedString("Patient", comment: ""), toolTip: NSLocalizedString("Next/Previous Patient", comment: ""), view: viewer.horos_patientView)
        case Catalog.subtraction:
            control(NSLocalizedString("Subtraction", comment: ""), toolTip: NSLocalizedString("Subtraction module", comment: ""), view: viewer.horos_subCtrlView)
        case Catalog.windowLevel:
            control(NSLocalizedString("WL/WW & CLUT", comment: ""), toolTip: NSLocalizedString("Modify WL/WW & CLUT", comment: ""), view: viewer.horos_WLWWView)
            // A pull-down that does not change the item.
            (viewer.horos_wlwwPopup?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        case Catalog.filters:
            control(NSLocalizedString("Convolution Filters", comment: ""), toolTip: NSLocalizedString("Apply a convolution filter", comment: ""), view: viewer.horos_ConvView)
            (viewer.horos_convPopup?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        case Catalog.thickSlab:
            // A fixed width, like the other items with controls: the popup shows
            // the mode's short name and the slider does not stretch.
            control(NSLocalizedString("Thick Slab", comment: ""), toolTip: NSLocalizedString("Change Thick Slab mode and number", comment: ""), view: viewer.horos_FusionView)
        case Catalog.status:
            control(NSLocalizedString("Status & Comments", comment: ""), toolTip: nil, view: viewer.horos_StatusView)
        case Catalog.blending:
            control(NSLocalizedString("Fusion", comment: ""), toolTip: NSLocalizedString("Fusion Mode and Percentage", comment: ""), view: viewer.horos_BlendingView)
        case Catalog.rgbFactors:
            control(NSLocalizedString("RGB Factors", comment: ""), toolTip: nil, view: viewer.horos_RGBFactorsView)
        case Catalog.orientation:
            control(NSLocalizedString("Orientation", comment: ""), toolTip: nil, view: viewer.horos_orientationView)
        case Catalog.seriesPopup:
            control(NSLocalizedString("Series", comment: ""), palette: NSLocalizedString("Series Selection", comment: ""), toolTip: NSLocalizedString("Series Selection", comment: ""), view: viewer.horos_seriesPopupView)
        case Catalog.windowsTiling:
            // Template grids drawn in code, legible in light and dark.
            WindowsTilingImage.install(in: viewer.horos_windowsTiling)
            control(NSLocalizedString("Windows", comment: ""), palette: NSLocalizedString("Windows Tiling", comment: ""), toolTip: NSLocalizedString("Windows Tiling", comment: ""), view: viewer.horos_windowsTiling)
        case Catalog.annotations:
            // A popup of the levels, as wide as they ask for in the running language.
            AnnotationsPopUpButton.install(in: viewer.horos_annotations)
            control(NSLocalizedString("Annotations", comment: ""), toolTip: nil, view: viewer.horos_annotations)
        case Catalog.shutter:
            control(NSLocalizedString("Shutter", comment: ""), toolTip: nil, view: viewer.horos_shutterView)
        case Catalog.propagateSettings:
            PropagateSettingsOptions.install(in: viewer.horos_propagateSettingsView)
            control(NSLocalizedString("Propagate", comment: ""), toolTip: NSLocalizedString("Propagate settings (WL/WW, zoom, ...)", comment: ""), view: viewer.horos_propagateSettingsView)
        case Catalog.reconstruction:
            control(NSLocalizedString("2D/3D", comment: ""), toolTip: NSLocalizedString("2D/3D Reconstruction Tools", comment: ""), view: viewer.horos_ReconstructionView)
        case Catalog.keyImages:
            control(NSLocalizedString("Key Images", comment: ""), toolTip: nil, view: viewer.horos_keyImages)
        case Catalog.tools:
            newItem.label = NSLocalizedString("Mouse button function", comment: "")
            newItem.paletteLabel = NSLocalizedString("Mouse button function", comment: "")
            newItem.toolTip = NSLocalizedString("Change the mouse button function", comment: "")
            // The mouse button radios carry translated titles: the item is as
            // wide as they ask for in the running language, and never narrower
            // than the tool palette above them.
            titleMouseButtonRadios(in: viewer)
            let size = ToolbarPolicy.localizedSize(of: viewer.horos_toolsView)
            newItem.view = viewer.horos_toolsView
            ToolbarPolicy.constrainView(of: newItem, minimum: size, maximum: size)
        case Catalog.flipVertical:
            button(NSLocalizedString("Flip Vertical", comment: ""), toolTip: NSLocalizedString("Flip image vertically", comment: ""), image: NSImage.toolbarImageNamed(Catalog.flipVertical),
                   target: nil, action: #selector(DCMView.flipVertical(_:)))
        case Catalog.setPixelValue:
            button(NSLocalizedString("Set Pixels", comment: ""), toolTip: NSLocalizedString("Set Pixels Values to...", comment: ""), image: NSImage.toolbarImageNamed(Catalog.setPixelValue),
                   target: nil, action: #selector(ViewerController.roiSetPixelsSetup(_:)))
        case Catalog.growingRegion:
            button(NSLocalizedString("Growing", comment: ""), toolTip: NSLocalizedString("Growing Region", comment: ""), image: NSImage.toolbarImageNamed(Catalog.growingRegion),
                   target: nil, action: #selector(ViewerController.segmentationTest(_:)))
        case Catalog.vrPanel:
            button(NSLocalizedString("3D Panel", comment: ""), toolTip: nil, image: NSImage.toolbarImageNamed(Catalog.vrPanel),
                   target: nil, action: #selector(ViewerController.panel3D(_:)))
        case Catalog.flipHorizontal:
            button(NSLocalizedString("Flip Horizontal", comment: ""), toolTip: NSLocalizedString("Flip image horizontallly", comment: ""), image: NSImage.toolbarImageNamed(Catalog.flipHorizontal),
                   target: nil, action: #selector(DCMView.flipHorizontal(_:)))
        case Catalog.lut12Bit where AppController.canDisplay12Bit():
            control(NSLocalizedString("Display", comment: ""), palette: NSLocalizedString("Display type", comment: ""), toolTip: NSLocalizedString("Display type", comment: ""), view: viewer.horos_display12bitToolbarItemView)
        case Catalog.cobbAngle:
            button(NSLocalizedString("Cobb", comment: ""), toolTip: NSLocalizedString("Cobb's Angle", comment: ""), image: NSImage.toolbarImageNamed("CobbAngle.tif"),
                   target: nil, action: #selector(ViewerController.switchCobbAngle(_:)))
        case Catalog.threeDPosition:
            button(NSLocalizedString("3D Pos", comment: ""), toolTip: nil, image: NSImage.toolbarImageNamed("OrientationWidget.tif"),
                   target: nil, action: #selector(ViewerController.threeDPanel(_:)))
        case Catalog.studyNote:
            newItem.label = NSLocalizedString("Note", comment: "the note of a study")
            newItem.paletteLabel = NSLocalizedString("Note", comment: "the note of a study")
            newItem.toolTip = NSLocalizedString("Display the Note Editor", comment: "")
            newItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: NSLocalizedString("Note", comment: "the note of a study"))
            newItem.target = nil
            newItem.action = #selector(ViewerController.showStudyNoteEditor(_:))
        case Catalog.navigator:
            button(NSLocalizedString("Navigator", comment: ""), toolTip: nil, image: NSImage.toolbarImageNamed(Catalog.navigator),
                   target: nil, action: #selector(ViewerController.navigator(_:)))
        default:
            if let shortcut = Catalog.threeDShortcut(itemIdent) {
                newItem.label = NSLocalizedString(shortcut.label, comment: "Toolbar shortcut to a 3D viewer")
                newItem.paletteLabel = NSLocalizedString(shortcut.title, comment: "")
                newItem.toolTip = NSLocalizedString(shortcut.title, comment: "")
                newItem.image = threeDShortcutImage(shortcut)
                newItem.tag = shortcut.tag
                newItem.target = nil
                newItem.action = NSSelectorFromString(shortcut.action)
            } else if let bundle = pluginBundle(itemIdent) {
                // A plugin's item.
                let info = bundle.infoDictionary
                newItem.label = itemIdent
                newItem.paletteLabel = itemIdent
                if let toolTips = info?["ToolbarToolTips"] as? [String: Any] {
                    newItem.toolTip = toolTips[itemIdent] as? String
                } else {
                    newItem.toolTip = itemIdent
                }

                var image = (info?["ToolbarIcon"] as? String)
                    .flatMap { bundle.pathForImageResource($0) }
                    .flatMap { NSImage(contentsOfFile: $0) }
                if image == nil {
                    image = NSWorkspace.shared.icon(forFile: bundle.bundlePath)
                }
                newItem.image = ToolbarImage.fitting(image)

                newItem.target = viewer
                newItem.action = #selector(ViewerController.executeFilterFromToolbar(_:))
            } else {
                toolbarItem = nil
            }
        }

        // A plugin may make the item itself, its own or one of the viewer's.
        let pluginToolbarItemSelector = #selector(HorosPluginFilterMessages.toolbarItem(forItemIdentifier:forViewer:))
        for plugin in pluginFilters() where plugin.responds(to: pluginToolbarItemSelector) {
            if let item = plugin.toolbarItem?(forItemIdentifier: itemIdent, forViewer: viewer) ?? nil {
                toolbarItem = item
            }
        }

        // Plugins supply their own items, so prepare after they had their turn.
        if let toolbarItem {
            ToolbarPolicy.prepare(toolbarItem) // +[HorosToolbarPolicy prepareItem:]
        }

        return toolbarItem
    }

    // MARK: - Lists

    /// The items shown by default, when no customization was saved or after
    /// the person reverts to it.
    func defaultIdentifiers() -> [NSToolbarItem.Identifier] {
        Catalog.defaultIdentifiers.map { NSToolbarItem.Identifier($0) }
    }

    /// The items offered in Customize Toolbar: the viewer's, the plugins'
    /// items, and those the plugins add for this viewer.
    func allowedIdentifiers(in viewer: ViewerController) -> [NSToolbarItem.Identifier] {
        var identifiers: [Any] = Catalog.allowedIdentifiers(space: ToolbarPolicy.spaceItemIdentifier,
                                                            canDisplay12Bit: AppController.canDisplay12Bit())

        let entries = (PluginManager.pluginsDict()?.allKeys ?? []).compactMap { key -> Catalog.PluginEntry? in
            guard let name = key as? String else { return nil }
            let info = pluginBundle(name)?.infoDictionary
            let allowsIcon = info?["allowToolbarIcon"].map { objcBoolValue($0) }
            return Catalog.PluginEntry(name: name, pluginType: info?["pluginType"] as? String, allowsToolbarIcon: allowsIcon,
                                       toolbarNames: (info?["ToolbarNames"] as? [Any])?.compactMap { $0 as? String })
        }
        identifiers += Catalog.pluginItems(entries) as [Any]

        let pluginAllowedIdentifiersSelector = #selector(HorosPluginFilterMessages.toolbarAllowedIdentifiers(forViewer:))
        for plugin in pluginFilters() where plugin.responds(to: pluginAllowedIdentifiersSelector) {
            if let added = plugin.toolbarAllowedIdentifiers?(forViewer: viewer) ?? nil {
                identifiers += added
            }
        }

        // The toolbar only takes strings: anything else a plugin returned is left out.
        return identifiers.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    /// An item is about to enter the toolbar: the viewer keeps each, against a
    /// bug of the separated toolbar window, until it is freed.
    func willAddItem(_ notification: Notification, in viewer: ViewerController) {
        let item = notification.userInfo?["item"] as? NSToolbarItem
        if let item, viewer.horos_retainedToolbarItems?.contains(item) == false { viewer.horos_retainedToolbarItems?.add(item) }
    }

    // MARK: - Enablement

    /// Whether `toolbarItem` is enabled: never while the viewer shows no image
    /// of the database, otherwise as the catalog says for its identifier.
    func validate(_ toolbarItem: NSToolbarItem?, in viewer: ViewerController) -> Bool {
        if !(viewer.horos_fileList(at: 0)?.lastObject is NSManagedObject) {
            return false
        }

        let itemIdentifier = toolbarItem?.itemIdentifier.rawValue
        let enablement = Catalog.enablement(of: itemIdentifier)
        var facts = Catalog.ViewerFacts()
        let curMovieIndex = Int(viewer.horos_curMovieIndex)

        /// The current series is one image of at most one frame.
        func singleImageOfOneFrame() -> Bool {
            let list = viewer.horos_fileList(at: curMovieIndex)
            guard (list?.count ?? 0) == 1 else { return false }
            return objcIntValue((list?.object(at: 0) as? DicomImage)?.numberOfFrames) <= 1
        }

        // Only what the item needs is read.
        switch enablement {
        case .always:
            break
        case .writableDatabase:
            facts.databaseIsReadOnly = viewer.database?.isReadOnly ?? false
        case .severalImages:
            facts.singleImageOfOneFrame = singleImageOfOneFrame()
        case .severalViewers:
            facts.viewerCount = Int(ViewerController.numberOf2DViewer())
        case .severalPhases:
            facts.phaseCount = Int(viewer.horos_maxMovieIndex)
        case .movieToExport:
            facts.singleImageOfOneFrame = singleImageOfOneFrame()
            facts.phaseCount = Int(viewer.horos_maxMovieIndex)
            facts.hasFusion = viewer.horos_blending != nil
        case .suvValues:
            facts.hasSUV = viewer.horos_imageView?.curDCM?.hasSUV ?? false
        case .twelveBitDisplay:
            facts.canDisplay12Bit = AppController.canDisplay12Bit()
        }
        return Catalog.isEnabled(enablement, facts)
    }

    // MARK: - The toolbar

    /// Makes the viewer's toolbar, customizable and saved under its
    /// identifier, and sets it on the window unless the detached toolbar panel
    /// shows it.
    func setUpToolbar(in viewer: ViewerController) {
        // The previous toolbar, nil when -init calls this, used to leak if there was one.
        let toolbar = OsiriXToolbar(identifier: Catalog.toolbarIdentifier)
        viewer.horos_toolbar = toolbar

        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.delegate = viewer

        // 2D Viewer > Annotations lists Custom, toolbar item or not.
        AnnotationsMenu.installInMainMenu()

        if AppController.usetoolbarpanel() == false && preferences[ViewerPreferences.alwaysUsesToolbarPanel] == false {
            viewer.window?.toolbar = toolbar
            viewer.window?.showsToolbarButton = false
            viewer.window?.toolbar?.isVisible = true
            ToolbarPolicy.adopt(toolbar: toolbar, in: viewer.window)
        }
    }

    /// Shows the detached toolbar panel for the front viewer and lends the
    /// floating thumbnails list of this viewer's screen.
    func redrawToolbar(in viewer: ViewerController) {
        let window = viewer.window
        if AppController.usetoolbarpanel() {
            if ViewerController.isFrontMost2DViewer(window) && ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen: viewer.horos_FullScreenOn) {
                if !(viewer.horos_toolbarPanel?.window?.toolbar?.customizationPaletteIsRunning ?? false) {
                    viewer.horos_toolbarPanel?.window?.orderBack(viewer)
                }
            } else {
                viewer.horos_toolbarPanel?.window?.orderOut(viewer)
            }
        }

        let floatingLists = preferences[ViewerPreferences.useFloatingThumbnailsList]
        if floatingLists {
            for i in 0..<min(maxScreens, NSScreen.screens.count) {
                if AppControllerCAPIThumbnailsListPanel(i)?.thumbnailsView === viewer.horos_previewMatrixScrollView && window?.screen !== NSScreen.screens[i] {
                    AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(nil, viewer: nil)
                }
            }

            // Only the front viewer of a screen lends its list to that screen's panel.
            // Viewers also redraw in the background (the next series applied to every
            // viewer, a study opened into the viewers on screen): a list taken then
            // would load a clicked series into that viewer, not into the one in use.
            let front = ViewerController.frontMostDisplayed2DViewer(for: window?.screen)
            var found = false
            for i in 0..<min(maxScreens, NSScreen.screens.count) {
                if window?.screen === NSScreen.screens[i] {
                    if front == nil || front === viewer {
                        AppControllerCAPIThumbnailsListPanel(i)?.setThumbnailsView(viewer.horos_previewMatrixScrollView, viewer: viewer)
                    }
                    found = true
                }
                // Other screens own independent thumbnail panels. Do not hide them
                // when this viewer redraws or moves between displays.
            }
            if !found {
                N2LogStackTraceMessage("Toolbar NOT found")
            }
        }

        if !AppController.usetoolbarpanel() {
            viewer.horos_toolbarPanel?.window?.orderOut(viewer)
        }

        if !floatingLists || !preferences[ViewerPreferences.seriesListVisible] {
            for i in 0..<min(maxScreens, NSScreen.screens.count) {
                AppControllerCAPIThumbnailsListPanel(i)?.window?.orderOut(viewer)
            }
        }
    }

    /// Redraws the toolbar, selects the image shown in the browser and updates
    /// the Sync button.
    func refreshToolbar(in viewer: ViewerController) {
        viewer.autoHideMatrix()

        redrawToolbar(in: viewer)

        if viewer.window?.isVisible ?? false, let files = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex)) {
            // A file whose object was deleted under the viewer, or whose fault
            // cannot be fulfilled, raises in Core Data: the browser is then
            // left as it is.
            do {
                try HorosObjCException.perform {
                    let first = files.count > 0 ? files.object(at: 0) as? DicomImage : nil
                    let isPlaceholder = (first?.completePath() as NSString?)?.lastPathComponent == "Empty.tif"
                    let image = Int(viewer.horos_imageView?.curImage ?? 0)
                    if files.count > 0, !isPlaceholder, image >= 0 {
                        _ = graph.processGraph.currentBrowser?.findAndSelectFile(nil, image: files.object(at: image) as? DicomImage, shouldExpand: false)
                    }
                }
            } catch {
                NSLog("***** exception in %@: %@", "-[ViewerController refreshToolbar]", error as NSError)
            }
        }

        viewer.setSyncButtonBehavior(viewer)
    }

    /// Shows or hides the Cobb angle; showing it shows every ROI's information.
    func switchCobbAngle() {
        let shown = !preferences[ViewerPreferences.displayCobbAngle]
        preferences.set(shown, for: ViewerPreferences.displayCobbAngle)

        if preferences[ViewerPreferences.roiTextIfSelected] && shown {
            preferences.set(false, for: ViewerPreferences.roiTextIfSelected) // To display the Cobbs value -> show all ROIs information
        }
    }

    /// The 12-bit toolbar item: its first cell turns the 12-bit LUT on.
    func enable12Bit(_ sender: Any?, in viewer: ViewerController) {
        let t12Bit = ((sender as? NSControl)?.selectedCell()?.tag ?? 0) == 0
        viewer.horos_imageView?.setIsLUT12Bit(t12Bit)
        viewer.horos_imageView?.updateImage()
    }

    /// Shows in the 12-bit toolbar item whether the image view uses the 12-bit LUT.
    func verify12Bit(in viewer: ViewerController) {
        let t12Bit = viewer.horos_imageView?.isLUT12Bit() ?? false
        viewer.horos_display12bitToolbarItemMatrix?.selectCell(withTag: t12Bit ? 0 : 1)
    }

    // MARK: - The Tools item

    /// The radios name only the button: the item's label already says they
    /// are mouse buttons, and "Button" three times took the room the radios
    /// need to sit centred under the palette. The titles come from the
    /// catalogs, since the languages without a Viewer nib of their own
    /// (Italian, Spanish, Japanese) showed the English ones.
    func titleMouseButtonRadios(in viewer: ViewerController) {
        guard let matrix = viewer.horos_buttonToolMatrix, let view = matrix.superview else { return }
        let titles = [
            Self.leftButtonTag: NSLocalizedString("Left mouse button", tableName: nil, bundle: .main, value: "Left", comment: "Toolbar radio under Mouse button function"),
            Self.middleButtonTag: NSLocalizedString("Middle mouse button", tableName: nil, bundle: .main, value: "Middle", comment: "Toolbar radio under Mouse button function"),
            Self.rightButtonTag: NSLocalizedString("Right mouse button", tableName: nil, bundle: .main, value: "Right", comment: "Toolbar radio under Mouse button function"),
        ]
        for case let cell as NSButtonCell in matrix.cells {
            if let title = titles[cell.tag] { cell.title = title }
        }
        // A title ended against the next radio's circle.
        matrix.intercellSpacing = NSSize(width: 6, height: matrix.intercellSpacing.height)
        matrix.sizeToCells()

        // The nib pins the radios to the left edge; they are centred instead.
        for constraint in view.constraints where constraint.firstItem === matrix
            && constraint.firstAttribute == .leading && constraint.secondItem === view {
            constraint.isActive = false
        }
        if !view.constraints.contains(where: { $0.identifier == "HorosMouseButtonRadios.centerX" }) {
            let center = matrix.centerXAnchor.constraint(equalTo: view.centerXAnchor)
            center.identifier = "HorosMouseButtonRadios.centerX"
            center.isActive = true
            matrix.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 1).isActive = true
        }
    }

    /// Whether the toolbar's tools apply to the middle button.
    static func middleButtonSelected(in viewer: ViewerController) -> Bool {
        objcTag(viewer.horos_buttonToolMatrix?.selectedCell()) == middleButtonTag
    }

    /// The tools the palette's last cell stands for, chosen in the ROI pop-up.
    static func isROIPaletteTool(_ tool: ToolMode) -> Bool {
        switch tool {
        case .tMesure, .tAngle, .tROI, .tOval, .tText, .tArrow, .tOPolygon, .tCPolygon, .tPencil, .t2DPoint,
             .tPlain, .tRepulsor, .tROISelector, .tDynAngle, .tAxis, .tTAGT:
            return true
        default:
            return false
        }
    }

    /// Highlights a tool in the palette without choosing it for any button. A
    /// ROI tool shares the last cell, which takes that tool's tag and image.
    private func selectPaletteTool(_ tool: ToolMode, in viewer: ViewerController) {
        if Self.isROIPaletteTool(tool) {
            viewer.showROIToolInPalette(tool)
        } else {
            viewer.horos_toolsMatrix?.selectCell(withTag: Int(tool.rawValue))
        }
    }

    /// A tool of the Tools menu: the palette shows it and the left button takes it.
    func setDefaultToolMenu(_ sender: Any?, in viewer: ViewerController) {
        if objcTag(sender) >= 0 {
            viewer.horos_toolsMatrix?.selectCell(withTag: objcTag(sender))
            viewer.horos_imageView?.currentTool = ToolMode(rawValue: Int16(truncatingIfNeeded: objcTag(sender)))!
        }
    }

    /// The left button's tool changed, in this viewer or another: the palette
    /// shows it, and the image view takes it.
    func defaultToolModified(_ note: Notification?, in viewer: ViewerController) {
        let sender = note?.object
        var tag: Int

        if let sender {
            if sender is NSMatrix {
                tag = objcTag(objcSelectedCell(sender))
            } else {
                tag = objcTag(sender)
            }
        } else {
            tag = Int(objcIntValue(note?.userInfo?["toolIndex"]))
        }

        let toolMode = ToolMode(rawValue: Int16(truncatingIfNeeded: tag))!
        if Self.isROIPaletteTool(toolMode) {
            viewer.setROIToolTag(toolMode)
        } else {
            viewer.horos_toolsMatrix?.selectCell(withTag: Int(toolMode.rawValue))
        }

        if tag >= 0 {
            if tag == Int(ToolMode.tCross.rawValue) { PatientCrosshairController.shared.setVisible(true) }
            viewer.horos_imageView?.currentTool = toolMode
        }
    }

    /// The right button's tool changed.
    func defaultRightToolModified(_ note: Notification?, in viewer: ViewerController) {
        let sender = note?.object
        let tag: Int32

        if sender is NSMatrix {
            tag = Int32(truncatingIfNeeded: objcTag(objcSelectedCell(sender)))
        } else {
            tag = Int32(truncatingIfNeeded: objcTag(sender))
        }

        viewer.horos_toolsMatrix?.selectCell(withTag: Int(tag))

        if tag >= 0 { viewer.horos_imageView?.currentToolRight = ToolMode(rawValue: Int16(truncatingIfNeeded: tag))! }
    }

    /// The middle button's tool changed: the palette shows it while the middle
    /// radio is chosen.
    func defaultMiddleToolModified(_ note: Notification?, in viewer: ViewerController) {
        let tag = Int(objcIntValue(note?.userInfo?["toolIndex"]))
        guard tag >= 0 else { return }
        let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: tag))!

        viewer.horos_imageView?.currentToolMiddle = tool

        if Self.middleButtonSelected(in: viewer) { selectPaletteTool(tool, in: viewer) }
    }

    /// A mouse button radio: the palette shows that button's tool.
    func setButtonTool(_ sender: Any?, in viewer: ViewerController) {
        let button = objcTag(objcSelectedCell(sender))

        // The right button opens the contextual menu when it is released, so it
        // cannot finish a ROI; the left and middle buttons can.
        let drawsROIs = button != Self.rightButtonTag
        viewer.horos_toolsMatrix?.cell(atRow: 0, column: 5)?.isEnabled = drawsROIs
        viewer.horos_popupRoi?.isEnabled = drawsROIs

        switch button {
        case Self.rightButtonTag:
            viewer.horos_toolsMatrix?.selectCell(withTag: Int(viewer.horos_imageView?.currentToolRight.rawValue ?? 0))
        case Self.middleButtonTag:
            selectPaletteTool(viewer.horos_imageView?.currentToolMiddle ?? .tTranslate, in: viewer)
        default:
            selectPaletteTool(viewer.horos_imageView?.currentTool ?? .tWL, in: viewer)
        }
    }

    /// A tool of the palette or the menus, for the button whose radio is
    /// chosen: told to every viewer by the notification of that button, which
    /// the former plugins observe too.
    func setDefaultTool(_ sender: Any?, in viewer: ViewerController) {
        viewer.horos_imageView?.gClickCountSetReset()

        let ctag: Int32
        if sender is NSMatrix {
            ctag = Int32(truncatingIfNeeded: objcTag(objcSelectedCell(sender)))
        } else {
            ctag = Int32(truncatingIfNeeded: objcTag(sender))
        }

        let name: Notification.Name
        switch objcTag(viewer.horos_buttonToolMatrix?.selectedCell()) {
        case Self.leftButtonTag: name = .OsirixDefaultToolModified
        case Self.middleButtonTag: name = .OsirixDefaultMiddleToolModified
        default: name = .OsirixDefaultRightToolModified
        }
        NotificationCenter.default.post(name: name, object: sender, userInfo: ["toolIndex": NSNumber(value: ctag)])
    }

    // MARK: - The Shutter item

    func setShutterOnOffButton(_ on: NSNumber?, in viewer: ViewerController) {
        viewer.horos_shutterOnOff?.state = NSControl.StateValue(rawValue: (on?.boolValue ?? false) ? 1 : 0)
    }

    /// The Shutter button or menu item: on, the selected rectangular ROI
    /// becomes the shutter of every image, or the stored shutter shows again;
    /// off, no image shows its shutter.
    func shutterOnOff(_ sender: Any?, in viewer: ViewerController) {
        if objcTitle(sender) == "Shutter" {
            viewer.horos_shutterOnOff?.state = (viewer.horos_shutterOnOff?.state ?? .off) == .off ? .on : .off //from menu
        }

        let imageView = viewer.horos_imageView
        let curImage = Int(imageView?.curImage ?? 0)
        let curPix = imageView?.dcmPixList?.object(at: curImage) as? DCMPix
        let slices = (imageView?.dcmPixList as? [Any] ?? []).compactMap { $0 as? DCMPix }

        var shutterRect = NSMakeRect(0, 0, 0, 0)

        /// `rect` clipped to the image of `p`. A rectangle wholly past an edge
        /// clips to an empty one there, never to a negative width or height.
        func clipped(_ rect: NSRect, to p: DCMPix) -> NSRect {
            var shutterRect = rect
            //shutterRect inside frame?
            if shutterRect.origin.x < 0 { shutterRect.size.width += shutterRect.origin.x; shutterRect.origin.x = 0 }
            if shutterRect.origin.y < 0 { shutterRect.size.height += shutterRect.origin.y; shutterRect.origin.y = 0 }
            if shutterRect.origin.x + shutterRect.size.width > CGFloat(p.pwidth) { shutterRect.size.width = CGFloat(p.pwidth) - shutterRect.origin.x }
            if shutterRect.origin.y + shutterRect.size.height > CGFloat(p.pheight) { shutterRect.size.height = CGFloat(p.pheight) - shutterRect.origin.y }
            if shutterRect.size.width < 0 { shutterRect.size.width = 0 }
            if shutterRect.size.height < 0 { shutterRect.size.height = 0 }
            return shutterRect
        }

        if viewer.horos_shutterOnOff?.state == .on {
            // Find the first rectangular ROI selected for the current frame and copy the rectangle in shutterRect.
            // Only a rectangle, as the alert below asks: an oval or a polygon is no shutter.
            var selectedROI: ROI? = nil
            let rois = (viewer.horos_roiList(at: Int(viewer.horos_curMovieIndex))?.object(at: curImage) as? [Any] ?? []).compactMap { $0 as? ROI }
            for r in rois {
                if r.type == .tROI && (r.roImode == ROI_selected || r.roImode == ROI_selectedModify || r.roImode == ROI_drawing) {
                    shutterRect = r.rect
                    selectedROI = r
                    break
                }
            }

            // A ROI that leaves nothing of the current image is no rectangle
            // for the shutter: it stays, and the stored shutter or the alert
            // below answers as when no ROI is selected.
            if let curPix {
                let inside = clipped(shutterRect, to: curPix)
                if inside.size.width <= 0 || inside.size.height <= 0 { selectedROI = nil }
            }

            //using valid shutterRect
            if let selectedROI, shutterRect.size.width > 0 {
                viewer.delete(selectedROI)

                // Each image gets the ROI clipped to itself: a smaller image
                // no longer shrinks the shutter of the images after it.
                for p in slices {
                    p.shutterRect = clipped(shutterRect, to: p)
                    p.shutterEnabled = true // NSControlStateValueOn
                }
            } else {
                //using stored shutterRect?
                let storedRect = curPix?.shutterRect ?? .zero
                if (storedRect.size.width == 0 || (storedRect.size.width == CGFloat(curPix?.pwidth ?? 0) && storedRect.size.height == CGFloat(curPix?.pheight ?? 0))) && curPix?.shutterPolygonal == nil {
                    viewer.horos_shutterOnOff?.state = .off

                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Shutter", comment: ""), message: NSLocalizedString("Please first define a rectangle with a rectangular ROI.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                } else { //reuse preconfigured shutterRect
                    for p in slices { p.shutterEnabled = true } // NSControlStateValueOn
                }
            }
        } else {
            for p in slices { p.shutterEnabled = false } // NSControlStateValueOff
        }
        imageView?.setIndex(imageView?.curImage ?? 0) //refresh viewer only
    }
}
