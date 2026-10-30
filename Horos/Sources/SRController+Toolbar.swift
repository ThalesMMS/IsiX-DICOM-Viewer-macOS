/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa

private let MIPToolbarIdentifier = "SR Toolbar Identifier"
private let QTExportToolbarItemIdentifier = "QTExport.pdf"
private let PhotosToolbarItemIdentifier = "iPhoto.icns"
private let StereoIdentifier = "Stereo.icns"
private let SRSettingsToolbarItemIdentifier = "SRSettings.tif"
private let BSRSettingsToolbarItemIdentifier = "BSRSettings.tif"
private let ToolsToolbarItemIdentifier = "Tools"
private let Export3DFileFormat = "3DExportFileFormat"
private let FlyThruToolbarItemIdentifier = "FlyThru.pdf"
private let OrientationToolbarItemIdentifier = "OrientationWidget.tif"
private let ToggleDisplay3DpointsItemIdentifier = "Point.tif"
private let PerspectiveToolbarItemIdentifier = "Perspective"
private let ResetToolbarItemIdentifier = "Reset.pdf"
private let ROIManagerToolbarItemIdentifier = "ROIManager.pdf"
private let ExportToolbarItemIdentifier = "Export.icns"
private let OrientationsViewToolbarItemIdentifier = "OrientationsView"
private let BackgroundColorViewToolbarItemIdentifier = "BackgroundColorView"

/// The surface rendering window's toolbar, and the Stereo menu's screen
/// geometry. The former #ifdef EXPORTTOOLBARITEM blocks, compiled out, are not
/// translated.
extension SRController {
    @objc func setupToolbar() {
        // Create a new toolbar instance, and attach it to our document window
        let toolbar = NSToolbar(identifier: MIPToolbarIdentifier)
        self.toolbar = toolbar

        // Set up toolbar properties: Allow customization, give a default display mode, and remember state in user defaults
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true

        // We are the delegate
        toolbar.delegate = self

        // The toolbar keeps a row of its own below the title, as the 3D MPR,
        // Volume Rendering and endoscopy toolbars do.
        self.window?.toolbarStyle = .expanded

        // Attach the toolbar to the document window
        self.window?.toolbar = toolbar
        window?.showsToolbarButton = false
        window?.toolbar?.isVisible = true
        ToolbarPolicy.adopt(toolbar: toolbar, in: window)
    }

    @IBAction func customizeViewerToolBar(_ sender: Any?) {
        toolbar?.runCustomizationPalette(sender)
    }

    /// The Stereo menu's screen geometry: OK sets the view and eye angles from
    /// the screen's height, the distance to it and the eyes' separation, and
    /// keeps them for the next time.
    @IBAction func ApplyGeometrieSettings(_ sender: Any?) {
        SRGeometrieSettingsWindow?.orderOut(sender)
        if ((sender as AnyObject?)?.tag ?? 0) == 0 { return }
        let defaults = UserDefaults.standard
        defaults.set(distanceValue?.doubleValue ?? 0, forKey: "DISTANCETOSCREEN")
        defaults.set(heightValue?.doubleValue ?? 0, forKey: "SCREENHEIGHT")
        defaults.set(eyeDistance?.doubleValue ?? 0, forKey: "EYESEPARATION")
        srView?.horosSetStereoScreen(height: heightValue?.doubleValue ?? 0, distance: distanceValue?.doubleValue ?? 0,
                                     eyeSeparation: eyeDistance?.doubleValue ?? 0)
    }

    @objc func horosFillStereoGeometry() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "DISTANCETOSCREEN") != nil { distanceValue?.doubleValue = defaults.double(forKey: "DISTANCETOSCREEN") }
        if defaults.object(forKey: "SCREENHEIGHT") != nil { heightValue?.doubleValue = defaults.double(forKey: "SCREENHEIGHT") }
        if defaults.object(forKey: "EYESEPARATION") != nil { eyeDistance?.doubleValue = defaults.double(forKey: "EYESEPARATION") }
    }

    /// An item of the toolbar whose view is one of the nib's.
    private func setView(_ view: NSView?, of item: NSToolbarItem, flexible: Bool = false) {
        item.view = view
        ToolbarPolicy.constrainView(of: item, minimum: ToolbarPolicy.designedSize(of: view),
                                    maximum: flexible ? .zero : ToolbarPolicy.designedSize(of: view))
    }

    /// An item of the toolbar that sends `action` to `target`.
    private func setAction(_ action: Selector, of target: AnyObject?, image: String, on item: NSToolbarItem) {
        item.image = NSImage(named: image)
        item.target = target
        item.action = action
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdent: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar willBeInserted: Bool) -> NSToolbarItem? {
        // Required delegate method:  Given an item identifier, this method returns an item
        // The toolbar will use this method to obtain toolbar items that can be displayed in the customization sheet, or in the toolbar itself
        if let spaceItem = ToolbarPolicy.spaceItem(for: itemIdent.rawValue) {
            return spaceItem
        }

        var toolbarItem: NSToolbarItem? = NSToolbarItem(itemIdentifier: itemIdent)
        let item = toolbarItem!
        func label(_ label: String, palette: String? = nil, toolTip: String?) {
            item.label = label
            item.paletteLabel = palette ?? label
            if let toolTip { item.toolTip = toolTip }
        }

        switch itemIdent.rawValue {
        case StereoIdentifier:
            label(NSLocalizedString("Stereo", comment: ""), toolTip: NSLocalizedString("Switch Stereo Mode ON/OFF", comment: ""))
            setAction(NSSelectorFromString("SwitchStereoMode:"), of: srView, image: StereoIdentifier, on: item)
            // The Stereo menu of the nib, when it is there.
            if let stereoIconView {
                horosFillStereoGeometry()
                setView(stereoIconView, of: item)
            }
        case QTExportToolbarItemIdentifier:
            label(NSLocalizedString("Movie Export", comment: ""), toolTip: NSLocalizedString("Export this series in a Quicktime file", comment: ""))
            setAction(NSSelectorFromString("exportQuicktime:"), of: srView, image: QTExportToolbarItemIdentifier, on: item)
        case PhotosToolbarItemIdentifier:
            label(NSLocalizedString("Photos", comment: ""), toolTip: NSLocalizedString("Export this series to Photos", comment: ""))
            setAction(#selector(export2iPhoto(_:)), of: self, image: "Photos", on: item)
        case Export3DFileFormat:
            label(NSLocalizedString("Export 3D-SR", comment: ""), toolTip: NSLocalizedString("Export this series in a 3D file format", comment: ""))
            setView(export3DView, of: item)
        case SRSettingsToolbarItemIdentifier:
            label(NSLocalizedString("Surface Settings", comment: ""), toolTip: NSLocalizedString("change Surface Settings", comment: ""))
            setAction(#selector(changeSettings(_:)), of: self, image: SRSettingsToolbarItemIdentifier, on: item)
        case BSRSettingsToolbarItemIdentifier:
            label(NSLocalizedString("Fusion Surface Settings", comment: ""), toolTip: NSLocalizedString("change Fusion Surface Settings", comment: ""))
            setAction(#selector(bChangeSettings(_:)), of: self, image: BSRSettingsToolbarItemIdentifier, on: item)
        case OrientationToolbarItemIdentifier:
            label(NSLocalizedString("Orientation", comment: ""), palette: NSLocalizedString("Orientation Cube", comment: ""), toolTip: NSLocalizedString("Show orientation cube", comment: ""))
            setAction(NSSelectorFromString("switchOrientationWidget:"), of: srView, image: OrientationToolbarItemIdentifier, on: item)
        case ToolsToolbarItemIdentifier:
            label(NSLocalizedString("Mouse button function", comment: ""), toolTip: nil)
            setView(toolsView, of: item)
        case FlyThruToolbarItemIdentifier:
            label(NSLocalizedString("Fly Thru", comment: ""), toolTip: NSLocalizedString("Fly Thru Set up", comment: ""))
            setAction(#selector(flyThruControllerInit(_:)), of: self, image: FlyThruToolbarItemIdentifier, on: item)
        case ToggleDisplay3DpointsItemIdentifier:
            label(NSLocalizedString("Show/Hide", comment: ""), palette: NSLocalizedString("Show/Hide 3D points", comment: ""), toolTip: NSLocalizedString("Show/Hide 3D points", comment: ""))
            setAction(NSSelectorFromString("toggleDisplay3DPoints"), of: srView, image: ToggleDisplay3DpointsItemIdentifier, on: item)
        case PerspectiveToolbarItemIdentifier:
            label(NSLocalizedString("Perspective", comment: ""), toolTip: NSLocalizedString("Perspective Properties", comment: ""))
            setView(perspectiveView, of: item, flexible: true)
        case ROIManagerToolbarItemIdentifier:
            label(NSLocalizedString("ROI Manager", comment: ""), toolTip: NSLocalizedString("ROI Manager", comment: ""))
            setAction(#selector(roiGetManager(_:)), of: self, image: ROIManagerToolbarItemIdentifier, on: item)
        case ResetToolbarItemIdentifier:
            label(NSLocalizedString("Reset", comment: ""), toolTip: NSLocalizedString("Reset to initial 3D view", comment: ""))
            setAction(NSSelectorFromString("resetImage:"), of: srView, image: ResetToolbarItemIdentifier, on: item)
        case BackgroundColorViewToolbarItemIdentifier:
            label(NSLocalizedString("Color", comment: ""), toolTip: NSLocalizedString("Background Color", comment: ""))
            setView(BackgroundColorView, of: item)
        case OrientationsViewToolbarItemIdentifier:
            label(NSLocalizedString("Orientations", comment: ""), toolTip: NSLocalizedString("Orientations", comment: ""))
            setView(OrientationsView, of: item)
        case ExportToolbarItemIdentifier:
            label(NSLocalizedString("DICOM File", comment: ""), palette: NSLocalizedString("Save as DICOM", comment: ""), toolTip: NSLocalizedString("Export this image in a DICOM file", comment: ""))
            setAction(NSSelectorFromString("exportDICOMFile:"), of: srView, image: ExportToolbarItemIdentifier, on: item)
        default:
            toolbarItem = nil
        }

        for (_, plugin) in (PluginManager.plugins() as NSDictionary?) ?? NSDictionary() {
            if (plugin as AnyObject).responds(to: #selector(HorosPluginFilterMessages.toolbarItem(forItemIdentifier:forViewer:))) {
                if let item = (plugin as AnyObject).toolbarItem?(forItemIdentifier: itemIdent.rawValue, forViewer: self) ?? nil {
                    toolbarItem = item
                }
            }
        }

        // Plugins supply their own items, so prepare after they had their turn.
        if toolbarItem != nil {
            ToolbarPolicy.prepare(toolbarItem)
        }

        return toolbarItem
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the ordered list of items to be shown in the toolbar by default
        // If during the toolbar's initialization, no overriding values are found in the user defaults, or if the
        // user chooses to revert to the default items this set will be used
        return [ToolsToolbarItemIdentifier,
                SRSettingsToolbarItemIdentifier,
                BSRSettingsToolbarItemIdentifier,
                StereoIdentifier,
                OrientationToolbarItemIdentifier,
                NSToolbarItem.Identifier.flexibleSpace.rawValue,
                ROIManagerToolbarItemIdentifier,
                QTExportToolbarItemIdentifier,
                ExportToolbarItemIdentifier,
                Export3DFileFormat,
                OrientationsViewToolbarItemIdentifier,
                FlyThruToolbarItemIdentifier,
                BackgroundColorViewToolbarItemIdentifier].map { NSToolbarItem.Identifier($0) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the list of all allowed items by identifier.  By default, the toolbar
        // does not assume any items are allowed, even the separator.  So, every allowed item must be explicitly listed
        // The set of allowed items is used to construct the customization palette
        let array = NSMutableArray(array: [NSToolbarItem.Identifier.flexibleSpace.rawValue,
                                           ToolbarPolicy.spaceItemIdentifier,
                                           SRSettingsToolbarItemIdentifier,
                                           BSRSettingsToolbarItemIdentifier,
                                           StereoIdentifier,
                                           OrientationToolbarItemIdentifier,
                                           QTExportToolbarItemIdentifier,
                                           PhotosToolbarItemIdentifier,
                                           Export3DFileFormat,
                                           OrientationsViewToolbarItemIdentifier,
                                           ToolsToolbarItemIdentifier,
                                           ROIManagerToolbarItemIdentifier,
                                           FlyThruToolbarItemIdentifier,
                                           ToggleDisplay3DpointsItemIdentifier,
                                           PerspectiveToolbarItemIdentifier,
                                           ResetToolbarItemIdentifier,
                                           ExportToolbarItemIdentifier,
                                           BackgroundColorViewToolbarItemIdentifier])

        for (_, plugin) in (PluginManager.plugins() as NSDictionary?) ?? NSDictionary() {
            if (plugin as AnyObject).responds(to: #selector(HorosPluginFilterMessages.toolbarAllowedIdentifiers(forViewer:))) {
                array.addObjects(from: ((plugin as AnyObject).toolbarAllowedIdentifiers?(forViewer: self) ?? nil) ?? [])
            }
        }

        return array.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    func toolbarWillAddItem(_ notification: Notification) {
    }

    func toolbarDidRemoveItem(_ notification: Notification) {
    }

    @objc(validateToolbarItem:)
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        // Optional method:  This message is sent to us since we are the target of some toolbar item actions
        // (for example:  of the save items action)
        if item.itemIdentifier.rawValue == BSRSettingsToolbarItemIdentifier {
            return blendingController() != nil
        }
        return true
    }
}
