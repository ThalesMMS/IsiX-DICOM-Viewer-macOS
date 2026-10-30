/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork


import Cocoa

/// The VR window's toolbar: one set of items for the standard window, a
/// smaller one for the panel style, the items of the plugins, and the Stereo
/// menu's screen geometry.
extension VRController {


    static let qtExportItem = "QTExport.pdf"
    static let photosItem = "iPhoto.icns"
    static let stereoItem = "Stereo.icns"
    static let captureItem = "BestRendering.pdf"
    static let croppingItem = "Cropping.pdf"
    static let orientationItem = "OrientationWidget.tif"
    static let toolsItem = "Tools"
    static let wlwwItem = "WLWW"
    static let lodItem = "LOD"
    static let blendingItem = "2DBlending"
    static let movieItem = "Movie"
    static let exportItem = "Export.icns"
    static let mailItem = "Mail.icns"
    static let shadingItem = "Shading"
    static let perspectiveItem = "Perspective"
    static let resetItem = "Reset.pdf"
    static let revertItem = "Revert.tif"
    static let modeItem = "Mode"
    static let flyThruItem = "FlyThru.pdf"
    static let scissorStateItem = "ScissorState"
    static let roiManagerItem = "ROIManager.pdf"
    static let orientationsViewItem = "OrientationsView"
    static let convolutionViewItem = "ConvolutionView"
    static let backgroundColorViewItem = "BackgroundColorView"
    static let presetsPanelItem = "3DPresetsPanel.tif"
    static let clippingRangeViewItem = "ClippingRange"
    static let clutEditorsViewItem = "CLUTEditors"

    @objc(setupToolbar)
    public final func setupToolbar() {
        // Create a new toolbar instance, and attach it to our document window
        let toolbar = styleName == "standard" ? NSToolbar(identifier: "VR Toolbar Identifier")
                                              : NSToolbar(identifier: "VRPanel Toolbar Identifier")
        self.toolbar = toolbar
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        toolbar.delegate = self
        // Keep multi-row custom controls out of the compact unified titlebar.
        window?.toolbarStyle = .expanded
        window?.toolbar = toolbar
        window?.showsToolbarButton = styleName == "panel"
        window?.toolbar?.isVisible = styleName == "standard"
        ToolbarPolicy.adopt(toolbar: toolbar, in: window)
    }

    @IBAction @objc(customizeViewerToolBar:)
    public final func customizeViewerToolBar(_ sender: Any!) {
        toolbar?.runCustomizationPalette(sender)
    }

    // The Stereo menu's screen geometry: OK sets the view and eye angles from
    // the screen's height, the distance to it and the eyes' separation, and
    // keeps them for the next time.
    @IBAction @objc(ApplyGeometrieSettings:)
    public final func applyGeometrieSettings(_ sender: Any!) {
        VRGeometrieSettingsWindow?.orderOut(sender)
        if ((sender as AnyObject?)?.tag ?? 0) == 0 { return }
        let defaults = UserDefaults.standard
        defaults.set(distanceValue?.doubleValue ?? 0, forKey: "DISTANCETOSCREEN")
        defaults.set(heightValue?.doubleValue ?? 0, forKey: "SCREENHEIGHT")
        defaults.set(eyeDistance?.doubleValue ?? 0, forKey: "EYESEPARATION")
        vrView?.horosSetStereoScreenHeight(heightValue?.doubleValue ?? 0, distance: distanceValue?.doubleValue ?? 0,
                                           eyeSeparation: eyeDistance?.doubleValue ?? 0)
    }

    final func horosFillStereoGeometry() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DISTANCETOSCREEN") != nil { distanceValue?.doubleValue = defaults.double(forKey: "DISTANCETOSCREEN") }
        if defaults.object(forKey: "SCREENHEIGHT") != nil { heightValue?.doubleValue = defaults.double(forKey: "SCREENHEIGHT") }
        if defaults.object(forKey: "EYESEPARATION") != nil { eyeDistance?.doubleValue = defaults.double(forKey: "EYESEPARATION") }
    }

    // MARK: - NSToolbarDelegate

    /// An item that sends `action` to `target`, with its labels and image.
    private func button(_ item: NSToolbarItem, label: String, palette: String, tip: String, image: NSImage?,
                        target: AnyObject?, action: Selector) {
        item.label = label
        item.paletteLabel = palette
        item.toolTip = tip
        item.image = image
        item.target = target
        item.action = action
    }

    /// An item whose content is a view of the nib, constrained to its designed size.
    private func viewItem(_ item: NSToolbarItem, label: String, palette: String, tip: String?, view: NSView?, fixedMaximum: Bool) {
        item.label = label
        item.paletteLabel = palette
        if let tip { item.toolTip = tip }
        item.view = view
        let size = ToolbarPolicy.designedSize(of: view)
        ToolbarPolicy.constrainView(of: item, minimum: size, maximum: fixedMaximum ? size : .zero)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdent: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar willBeInserted: Bool) -> NSToolbarItem? {
        let ident = itemIdent.rawValue
        if let spaceItem = ToolbarPolicy.spaceItem(for: ident) { return spaceItem }

        var toolbarItem: NSToolbarItem? = NSToolbarItem(itemIdentifier: itemIdent)
        let item = toolbarItem!
        let L = { (key: String) in NSLocalizedString(key, comment: "") }
        switch ident {
        case Self.stereoItem:
            button(item, label: L("Stereo"), palette: L("Stereo"), tip: L("Switch Stereo Mode ON/OFF"),
                   image: NSImage(named: Self.stereoItem), target: vrView, action: NSSelectorFromString("SwitchStereoMode:"))
            // The Stereo menu of the nib, when it is there.
            if let stereoIconView {
                horosFillStereoGeometry()
                item.view = stereoIconView
                let size = ToolbarPolicy.designedSize(of: stereoIconView)
                ToolbarPolicy.constrainView(of: item, minimum: size, maximum: size)
            }
        case Self.mailItem:
            button(item, label: L("Email"), palette: L("Email"), tip: L("Email this image"),
                   image: NSImage(named: Self.mailItem), target: self, action: #selector(sendMail(_:)))
        case Self.resetItem:
            button(item, label: L("Reset"), palette: L("Reset"), tip: L("Reset to initial 3D view"),
                   image: NSImage(named: Self.resetItem), target: vrView, action: #selector(VRView.resetImage(_:)))
        case Self.revertItem:
            button(item, label: L("Revert"), palette: L("Revert"), tip: L("Revert series by re-loading images from disk"),
                   image: NSImage(named: Self.revertItem), target: self, action: #selector(revertSeries(_:)))
        case Self.shadingItem:
            viewItem(item, label: L("Shading"), palette: L("Shading"), tip: L("Shading Properties"), view: shadingView, fixedMaximum: false)
        case Self.perspectiveItem:
            // The projection modes, followed by the camera's view angle.
            let projection = perspectiveView.map { ViewAngleControl.wrapping($0, host: vrView ?? NSObject()) }
            viewItem(item, label: L("Perspective"), palette: L("Perspective"), tip: L("Perspective Properties"), view: projection,
                     fixedMaximum: false)
        case Self.qtExportItem:
            button(item, label: L("Movie Export"), palette: L("Movie Export"), tip: L("Export this image in a Movie file"),
                   image: NSImage(named: Self.qtExportItem), target: vrView, action: #selector(VRView.exportQuicktime(_:)))
        case Self.photosItem:
            button(item, label: L("Photos"), palette: L("Photos"), tip: L("Export this image to Photos"),
                   image: NSImage(named: "Photos"), target: self, action: #selector(export2iPhoto(_:)))
        case Self.exportItem:
            button(item, label: L("DICOM File"), palette: L("DICOM"), tip: L("Export this image in a DICOM file"),
                   image: NSImage(named: Self.exportItem), target: self, action: #selector(exportDICOMFile(_:)))
        case Self.croppingItem:
            button(item, label: L("Crop"), palette: L("Cropping Cube"), tip: L("Show and manipulate cropping cube"),
                   image: NSImage(named: Self.croppingItem), target: vrView, action: #selector(VRView.showCropCube(_:)))
        case Self.orientationItem:
            button(item, label: L("Orientation"), palette: L("Orientation Cube"), tip: L("Show orientation cube"),
                   image: NSImage(named: Self.orientationItem), target: vrView, action: #selector(VRView.switchOrientationWidget(_:)))
        case Self.captureItem:
            button(item, label: L("Best"), palette: L("Best Rendering"), tip: L("Render this image at the best resolution"),
                   image: ToolbarImage.appearanceAdaptive(named: Self.captureItem), target: self, action: #selector(bestRendering(_:)))
        case Self.wlwwItem:
            viewItem(item, label: L("WL/WW & CLUT & Opacity"), palette: L("WL/WW & CLUT & Opacity"),
                     tip: L("Change the WL/WW & CLUT & Opacity"), view: WLWWView, fixedMaximum: false)
            (wlwwPopup()?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        case Self.movieItem:
            viewItem(item, label: L("4D Player"), palette: L("4D Player"), tip: L("4D Player"), view: movieView, fixedMaximum: true)
        case Self.orientationsViewItem:
            viewItem(item, label: L("Orientations"), palette: L("Orientations"), tip: L("Orientations"), view: OrientationsView,
                     fixedMaximum: true)
        case Self.convolutionViewItem:
            viewItem(item, label: L("Filters"), palette: L("Filters"), tip: L("Filters"), view: convolutionView, fixedMaximum: true)
        case Self.backgroundColorViewItem:
            viewItem(item, label: L("Background"), palette: L("Background"), tip: L("Background Color"), view: BackgroundColorView,
                     fixedMaximum: true)
        case Self.scissorStateItem:
            viewItem(item, label: L("Scissor State"), palette: L("Scissor State"), tip: nil, view: scissorStateView, fixedMaximum: true)
        case Self.blendingItem:
            viewItem(item, label: L("Fusion"), palette: L("Fusion"), tip: L("Fusion Mode and Percentage"), view: BlendingView,
                     fixedMaximum: false)
        case Self.modeItem:
            viewItem(item, label: L("Mode"), palette: L("Mode"), tip: L("Mode"), view: modeView, fixedMaximum: false)
        case Self.lodItem:
            viewItem(item, label: L("Level of Detail"), palette: L("Level of Detail"), tip: L("Change Level of Detail"), view: LODView,
                     fixedMaximum: false)
            (wlwwPopup()?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        case Self.toolsItem:
            viewItem(item, label: L("Mouse button function"), palette: L("Mouse button function"), tip: nil, view: toolsView,
                     fixedMaximum: true)
        case Self.flyThruItem:
            button(item, label: L("Fly Thru"), palette: L("Fly Thru"), tip: L("Fly Thru Set up"),
                   image: NSImage(named: Self.flyThruItem), target: self, action: #selector(flyThruControllerInit(_:)))
        case Self.roiManagerItem:
            button(item, label: L("ROI Manager"), palette: L("ROI Manager"), tip: L("ROI Manager"),
                   image: NSImage(named: Self.roiManagerItem), target: self, action: #selector(roiGetManager(_:)))
        case Self.presetsPanelItem:
            button(item, label: L("3D Presets"), palette: L("3D Presets"), tip: L("Show 3D Presets Panel"),
                   image: NSImage(named: Self.presetsPanelItem), target: self, action: #selector(load3DSettings(_:)))
        case Self.clippingRangeViewItem:
            viewItem(item, label: L("Clipping"), palette: L("Clipping"), tip: L("Clipping"), view: ClippingRangeView, fixedMaximum: false)
        case Self.clutEditorsViewItem:
            viewItem(item, label: L("CLUT Editor"), palette: L("CLUT Editor"), tip: L("CLUT Editor"), view: CLUTEditorsView,
                     fixedMaximum: false)
        default:
            toolbarItem = nil
        }

        for plugin in PluginManager.plugins()?.allValues ?? [] {
            let selector = NSSelectorFromString("toolbarItemForItemIdentifier:forVRViewer:")
            guard let plugin = plugin as? NSObject, plugin.responds(to: selector) else { continue }
            if let pluginItem = plugin.perform(selector, with: ident, with: self)?.takeUnretainedValue() as? NSToolbarItem {
                toolbarItem = pluginItem
            }
        }

        // Plugins supply their own items, so prepare after they had their turn.
        if let toolbarItem { ToolbarPolicy.prepare(toolbarItem) }
        return toolbarItem
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let identifiers: [String]
        if styleName == "standard" {
            identifiers = [Self.toolsItem, Self.wlwwItem, Self.clutEditorsViewItem, Self.presetsPanelItem, Self.lodItem, Self.captureItem,
                           Self.croppingItem, Self.orientationItem, Self.shadingItem, Self.perspectiveItem, Self.convolutionViewItem,
                           Self.clippingRangeViewItem, NSToolbarItem.Identifier.flexibleSpace.rawValue, Self.qtExportItem,
                           Self.orientationsViewItem, Self.resetItem, Self.revertItem, Self.exportItem, Self.flyThruItem]
        } else {
            identifiers = [Self.toolsItem, Self.modeItem, Self.wlwwItem, Self.lodItem, Self.captureItem, Self.blendingItem,
                           Self.croppingItem, Self.orientationItem, NSToolbarItem.Identifier.flexibleSpace.rawValue,
                           Self.qtExportItem, Self.orientationsViewItem, Self.resetItem, Self.exportItem]
        }
        return identifiers.map { NSToolbarItem.Identifier($0) }
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [String]
        if styleName == "standard" {
            identifiers = [NSToolbarItem.Identifier.flexibleSpace.rawValue, ToolbarPolicy.spaceItemIdentifier, Self.wlwwItem,
                           Self.clutEditorsViewItem, Self.presetsPanelItem, Self.lodItem, Self.captureItem, Self.croppingItem,
                           Self.orientationItem, Self.shadingItem, Self.perspectiveItem, Self.orientationsViewItem, Self.toolsItem,
                           Self.modeItem, Self.blendingItem, Self.movieItem, Self.stereoItem, Self.qtExportItem, Self.photosItem,
                           Self.mailItem, Self.resetItem, Self.revertItem, Self.exportItem, Self.flyThruItem, Self.scissorStateItem,
                           Self.roiManagerItem, Self.convolutionViewItem, Self.backgroundColorViewItem, Self.clippingRangeViewItem]
            let selector = NSSelectorFromString("toolbarAllowedIdentifiersForVRViewer:")
            for plugin in PluginManager.plugins()?.allValues ?? [] {
                guard let plugin = plugin as? NSObject, plugin.responds(to: selector),
                      let extra = plugin.perform(selector, with: self)?.takeUnretainedValue() as? [String] else { continue }
                identifiers.append(contentsOf: extra)
            }
        } else {
            identifiers = [NSToolbarItem.Identifier.flexibleSpace.rawValue, ToolbarPolicy.spaceItemIdentifier, Self.wlwwItem,
                           Self.clutEditorsViewItem, Self.lodItem, Self.captureItem, Self.croppingItem, Self.orientationItem,
                           Self.orientationsViewItem, Self.qtExportItem, Self.photosItem, Self.mailItem, Self.resetItem,
                           Self.revertItem, Self.exportItem, Self.blendingItem]
        }
        return identifiers.map { NSToolbarItem.Identifier($0) }
    }

    public func toolbarWillAddItem(_ notification: Notification) {
    }

    public func toolbarDidRemoveItem(_ notification: Notification) {
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if item.itemIdentifier.rawValue == Self.movieItem && maxMovieIndex == 1 { return false }
        return true
    }
}
