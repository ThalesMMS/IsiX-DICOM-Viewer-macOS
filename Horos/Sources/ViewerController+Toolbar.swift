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

// The "NSToolbarDelegate" block of ViewerController (the toolbar delegate, the
// tool and shutter buttons and the CLUT and opacity menus) is implemented in
// Swift since #832: a Swift extension of ViewerController, which stays
// Objective-C, with the same selectors. The instance variables it used are read
// through ViewerController (SwiftIvars), the file-scope statics SYNCSERIES and
// numberOf2DViewer through ViewerController (SwiftStatics_Toolbar).
//
// The toolbar identifiers were file-scope statics of ViewerController.m; they
// are the fileprivate constants below, with the same texts (ViewerController.m
// keeps its own PlayToolbarItemIdentifier, SyncSeriesToolbarItemIdentifier and
// ReportToolbarItemIdentifier, which it still reads). The CLUT presets menu,
// a static only this block used, is the fileprivate clutPresetsMenu below. The
// class does not declare NSToolbarDelegate in Swift any more: this file does,
// and the delegate methods take the SDK's Swift signatures. A message to nil
// answered nil, 0 or NO: the optional chains below answer the same. The
// actions Swift sees a declaration of are #selector; the others (implemented in
// ViewerController.m without a declaration, or by other responders) are named
// by their selector text, as the Objective-C named them. The
// disabled EXPORTTOOLBARITEM branches are left out.

/// `[object tag]` sent to an `id`: 0 for nil, as a message to nil answered, and
/// the object's own -tag otherwise (an object without -tag raises
/// "unrecognized selector", as the message did).
fileprivate func objcTag(_ object: Any?) -> Int {
    guard let object = object as? NSObject else { return 0 }
    typealias TagIMP = @convention(c) (AnyObject, Selector) -> Int
    let selector = NSSelectorFromString("tag")
    return unsafeBitCast(object.method(for: selector), to: TagIMP.self)(object, selector)
}

/// `[object selector]` sent to an `id` for an object result: nil for nil, and
/// the object's own answer otherwise (or "unrecognized selector", as before).
fileprivate func objcObject(_ object: Any?, _ selector: String) -> AnyObject? {
    guard let object = object as? NSObject else { return nil }
    return object.perform(NSSelectorFromString(selector))?.takeUnretainedValue()
}

/// `[value intValue]` of an NSNumber or an NSString; nil answers 0.
fileprivate func objcIntValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

/// `[value boolValue]` of an Info.plist value: an NSNumber or an NSString.
fileprivate func objcBoolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// `[popup setTitle: title]`, which the Objective-C also sent with a nil title.
@MainActor fileprivate func objcSetTitle(_ popup: NSPopUpButton?, _ title: String?) {
    guard let popup else { return }
    if let title {
        popup.setTitle(title)
    } else {
        _ = popup.perform(#selector(NSPopUpButton.setTitle(_:)), with: nil)
    }
}

fileprivate let ViewerToolbarIdentifier = "Viewer Toolbar Identifier"
fileprivate let QTSaveToolbarItemIdentifier = "QTExport.pdf"
fileprivate let PhotosToolbarItemIdentifier = "iPhoto2"
fileprivate let PlayToolbarItemIdentifier = "Play.pdf"
fileprivate let XMLToolbarItemIdentifier = "XML.icns"
fileprivate let SpeedToolbarItemIdentifier = "Speed"
fileprivate let ToolsToolbarItemIdentifier = "Tools"
fileprivate let WLWWToolbarItemIdentifier = "WLWW"
fileprivate let FusionToolbarItemIdentifier = "Fusion"
fileprivate let FilterToolbarItemIdentifier = "Filters"
fileprivate let BlendingToolbarItemIdentifier = "2DBlending"
fileprivate let MovieToolbarItemIdentifier = "Movie"
fileprivate let SerieToolbarItemIdentifier = "Series"
fileprivate let PatientToolbarItemIdentifier = "Patient"
fileprivate let SubtractionToolbarItemIdentifier = "Subtraction"
fileprivate let Send2PACSToolbarItemIdentifier = "Send.icns"
fileprivate let ReconstructionToolbarItemIdentifier = "Reconstruction"
fileprivate let RGBFactorToolbarItemIdentifier = "RGB"
fileprivate let ExportToolbarItemIdentifier = "Export.icns"
fileprivate let MailToolbarItemIdentifier = "Mail.icns"
fileprivate let StatusToolbarItemIdentifier = "status"
fileprivate let SyncSeriesToolbarItemIdentifier = "Sync.pdf"
fileprivate let ResetToolbarItemIdentifier = "Reset.pdf"
fileprivate let RevertToolbarItemIdentifier = "Revert.tif"
fileprivate let FlipDataToolbarItemIdentifier = "FlipData.tif"
fileprivate let DatabaseWindowToolbarItemIdentifier = "DatabaseWindow.icns"
fileprivate let KeyImagesToolbarItemIdentifier = "keyImages"
fileprivate let TileWindowsToolbarItemIdentifier = "windows.tif"
fileprivate let SUVToolbarItemIdentifier = "SUV.tif"
fileprivate let ROIManagerToolbarItemIdentifier = "ROIManager.pdf"
fileprivate let ReportToolbarItemIdentifier = "Report.icns"
fileprivate let FlipVerticalToolbarItemIdentifier = "FlipVertical.pdf"
fileprivate let FlipHorizontalToolbarItemIdentifier = "FlipHorizontal.pdf"
fileprivate let VRPanelToolbarItemIdentifier = "MIP.tif"
fileprivate let ShutterToolbarItemIdentifier = "Shutter"
fileprivate let PropagateSettingsToolbarItemIdentifier = "PropagateSettings"
fileprivate let OrientationToolbarItemIdentifier = "Orientation"
fileprivate let WindowsTilingToolbarItemIdentifier = "WindowsTiling"
fileprivate let SeriesPopupToolbarItemIdentifier = "SeriesPopup"
fileprivate let AnnotationsToolbarItemIdentifier = "Annotations"
fileprivate let PrintToolbarItemIdentifier = "Print.tiff"
fileprivate let LUT12BitToolbarItemIdentifier = "LUT12Bit"
fileprivate let NavigatorToolbarItemIdentifier = "Navigator"
fileprivate let ThreeDPositionToolbarItemIdentifier = "3DPosition"
fileprivate let CobbAngleToolbarItemIdentifier = "CobbAngle"
fileprivate let SetPixelValueItemIdentifier = "SetPixelValue.pdf"
fileprivate let GrowingRegionItemIdentifier = "GrowingRegion.png"
fileprivate let StudyNoteToolbarItemIdentifier = "StudyNote"

/// The CLUT presets menu, shared by every viewer (a static of ViewerController.m
/// before #832): built by -UpdateCLUTMenu:, each viewer's popup gets a copy.
@MainActor fileprivate var clutPresetsMenu: NSMenu? = nil

extension ViewerController: NSToolbarDelegate {}

public extension ViewerController {

    // MARK: - NSToolbarDelegate

    @objc(toolbar:itemForItemIdentifier:willBeInsertedIntoToolbar:)
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Required delegate method:  Given an item identifier, this method returns an item
        // The toolbar will use this method to obtain toolbar items that can be displayed in the customization sheet, or in the toolbar itself
        let itemIdent = itemIdentifier.rawValue
        if let spaceItem = ToolbarPolicy.spaceItem(for: itemIdent) {
            return spaceItem
        }

        let newItem = NSToolbarItem(itemIdentifier: itemIdentifier)
        var toolbarItem: NSToolbarItem? = newItem

        /// The view keeps its designed dimensions in the bar and palette.
        func setView(_ view: NSView?) {
            let size = ToolbarPolicy.designedSize(of: view)
            newItem.view = view
            ToolbarPolicy.constrainView(of: newItem, minimum: size, maximum: size)
        }

        if itemIdent == QTSaveToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Movie Export", comment: "")
            newItem.paletteLabel = NSLocalizedString("Movie Export", comment: "")
            newItem.toolTip = NSLocalizedString("Export this series in a Movie file", comment: "")
            newItem.image = NSImage.toolbarImageNamed(QTSaveToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.exportQuicktime(_:))
        } else if itemIdent == PrintToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Print", comment: "")
            newItem.paletteLabel = NSLocalizedString("Print", comment: "")
            newItem.toolTip = NSLocalizedString("Print selected study/series to a DICOM printer", comment: "")
            newItem.image = NSImage.toolbarImageNamed(PrintToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.printDICOM(_:))
        } else if itemIdent == PhotosToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Photos", comment: "")
            newItem.paletteLabel = NSLocalizedString("Photos", comment: "")
            newItem.toolTip = NSLocalizedString("Export this image to Photos", comment: "")
            newItem.image = NSImage.toolbarImageNamed("Photos")
            newItem.target = self
            newItem.action = #selector(ViewerController.export2iPhoto(_:))
        } else if itemIdent == MailToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Email", comment: "")
            newItem.paletteLabel = NSLocalizedString("Email", comment: "")
            newItem.toolTip = NSLocalizedString("Email this image", comment: "")
            newItem.image = NSImage.toolbarImageNamed(MailToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.sendMail(_:))
        }
        //	else if ([itemIdent isEqual: BrushToolsToolbarItemIdentifier])
        //	{
        //		[toolbarItem setLabel: @"BrushTool"];
        //		[toolbarItem setPaletteLabel: @"BrushTool"];
        //        [toolbarItem setToolTip: @"Brush Palette for plain ROI"];
        //		[toolbarItem setImage: [NSImage imageNamed: BrushToolsToolbarItemIdentifier]];
        //		[toolbarItem setTarget: self];
        //		[toolbarItem setAction: @selector(brushTool:)];
        //    }
        else if itemIdent == ExportToolbarItemIdentifier {

            newItem.label = NSLocalizedString("DICOM File", comment: "")
            newItem.paletteLabel = NSLocalizedString("Export as DICOM File", comment: "")
            newItem.toolTip = NSLocalizedString("Export this image/series in a DICOM file", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ExportToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.exportDICOMFile(_:))
        } else if itemIdent == Send2PACSToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Send", comment: "")
            newItem.paletteLabel = NSLocalizedString("Send", comment: "")
            newItem.toolTip = NSLocalizedString("Send this series to a DICOM node", comment: "")
            newItem.image = NSImage.toolbarImageNamed(Send2PACSToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.export2PACS(_:))
        } else if itemIdent == XMLToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Meta-Data", comment: "")
            newItem.paletteLabel = NSLocalizedString("Meta-Data", comment: "")
            newItem.toolTip = NSLocalizedString("View meta-data of this image", comment: "")
            newItem.image = NSImage.toolbarImageNamed(XMLToolbarItemIdentifier)
            newItem.target = self
            newItem.action = NSSelectorFromString("viewXML:")
        } else if itemIdent == PlayToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Browse", comment: "")
            newItem.paletteLabel = NSLocalizedString("Browse", comment: "")
            newItem.toolTip = NSLocalizedString("Browse this series", comment: "")
            newItem.image = NSImage.toolbarImageNamed(PlayToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.playStop(_:))
        } else if itemIdent == SyncSeriesToolbarItemIdentifier {

            newItem.target = self
            newItem.action = #selector(ViewerController.syncSeries(_:))
            newItem.toolTip = NSLocalizedString("Syncronize slice position", comment: "")
            if ViewerController.horos_SYNCSERIES() {
                newItem.label = NSLocalizedString("Sync", comment: "")
                newItem.paletteLabel = NSLocalizedString("Sync", comment: "")
                newItem.image = NSImage.toolbarImageNamed("SyncLock.pdf")
            } else {
                newItem.label = NSLocalizedString("Sync", comment: "")
                newItem.paletteLabel = NSLocalizedString("Sync", comment: "")
                newItem.image = NSImage.toolbarImageNamed(SyncSeriesToolbarItemIdentifier)
            }
        } else if itemIdent == ResetToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Reset", comment: "")
            newItem.paletteLabel = NSLocalizedString("Reset", comment: "")
            newItem.toolTip = NSLocalizedString("Reset image to original view", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ResetToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.resetImage(_:))
        } else if itemIdent == RevertToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Revert", comment: "")
            newItem.paletteLabel = NSLocalizedString("Revert", comment: "")
            newItem.toolTip = NSLocalizedString("Revert series by re-loading images from disk", comment: "")
            newItem.image = NSImage.toolbarImageNamed(RevertToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.revertSeries(_:))
        } else if itemIdent == FlipDataToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Flip", comment: "")
            newItem.paletteLabel = NSLocalizedString("Flip", comment: "")
            newItem.toolTip = NSLocalizedString("Flip series", comment: "")
            newItem.image = NSImage.toolbarImageNamed(FlipDataToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.flipDataSeries(_:))
        } else if itemIdent == DatabaseWindowToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Database", comment: "")
            newItem.paletteLabel = NSLocalizedString("Database", comment: "")
            newItem.toolTip = NSLocalizedString("Close viewers and open Database window", comment: "")
            newItem.image = NSImage.toolbarImageNamed(DatabaseWindowToolbarItemIdentifier)
            newItem.target = self
            newItem.action = Selector(("databaseWindow:"))
        } else if itemIdent == ROIManagerToolbarItemIdentifier {
            newItem.label = NSLocalizedString("ROI Manager", comment: "")
            newItem.paletteLabel = NSLocalizedString("ROI Manager", comment: "")
            newItem.image = NSImage.toolbarImageNamed(ROIManagerToolbarItemIdentifier)
            newItem.target = self
            newItem.action = #selector(ViewerController.roiGetManager(_:))
        } else if itemIdent == SUVToolbarItemIdentifier {
            newItem.label = NSLocalizedString("SUV", comment: "")
            newItem.paletteLabel = NSLocalizedString("SUV", comment: "")
            newItem.toolTip = NSLocalizedString("Display SUVbw values", comment: "")
            newItem.image = NSImage.toolbarImageNamed(SUVToolbarItemIdentifier)
            newItem.target = self
            newItem.action = Selector(("displaySUV:"))
        }

        else if itemIdent == ReportToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Report", comment: "")
            newItem.paletteLabel = NSLocalizedString("Report", comment: "")
            newItem.toolTip = NSLocalizedString("Create/Open a report for selected study", comment: "")
            self.setToolbarReportIconFor(newItem)
            newItem.target = self
            newItem.action = Selector(("generateReport:"))
        }

        else if itemIdent == TileWindowsToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Tile", comment: "")
            newItem.paletteLabel = NSLocalizedString("Tile", comment: "")
            newItem.toolTip = NSLocalizedString("Tile Windows", comment: "")
            newItem.image = NSImage.toolbarImageNamed(TileWindowsToolbarItemIdentifier)
            newItem.target = AppController.shared()
            newItem.action = #selector(AppController.tileWindows(_:))
        }
        //	else if ([itemIdent isEqualToString: iChatBroadCastToolbarItemIdentifier]) {
        //
        //	[toolbarItem setLabel: NSLocalizedString(@"iChat", nil)];
        //	[toolbarItem setPaletteLabel: NSLocalizedString(@"iChat", nil)];
        //	[toolbarItem setToolTip: NSLocalizedString(@"iChat", nil)];
        ////	[toolbarItem setImage: [NSImage imageNamed: iChatBroadCastToolbarItemIdentifier]]; //	/Applications/iChat/Contents/Resources/Prefs_Camera.icns is maybe a better image...
        //	NSString *path = [[NSWorkspace sharedWorkspace] absolutePathForAppBundleWithIdentifier:@"com.apple.iChat"];
        //	[toolbarItem setImage: [[NSWorkspace sharedWorkspace] iconForFile:path]];
        ////	[toolbarItem setImage: [NSImage imageNamed:NSImageNameIChatTheaterTemplate]];
        //	[toolbarItem setTarget: self];
        //	[toolbarItem setAction: @selector(iChatBroadcast:)];
        //    }
        else if itemIdent == SpeedToolbarItemIdentifier {
            //	NSMenu *submenu = nil;
            //	NSMenuItem *submenuItem = nil, *menuFormRep = nil;

            // Set up the standard properties
            newItem.label = NSLocalizedString("Slice Cine Rate", comment: "")
            newItem.paletteLabel = NSLocalizedString("Slice Cine Rate", comment: "")
            newItem.toolTip = NSLocalizedString("Change the number of slices displayed per second within the current series", comment: "")

            // Use a custom view, a text field, for the search item
            let speedView = self.horos_speedView
            newItem.view = speedView
            let height = ToolbarPolicy.designedSize(of: speedView).height
            ToolbarPolicy.constrainView(of: newItem, minimum: NSSize(width: 100, height: height), maximum: NSSize(width: 200, height: height))

            // By default, in text only mode, a custom items label will be shown as disabled text, but you can provide a
            // custom menu of your own by using <item> setMenuFormRepresentation]
            /*submenu = [[[NSMenu alloc] init] autorelease];
             submenuItem = [[[NSMenuItem alloc] initWithTitle: @"Search Panel" action: @selector(searchUsingSearchPanel:) keyEquivalent: @""] autorelease];
             menuFormRep = [[[NSMenuItem alloc] init] autorelease];

             [submenu addItem: submenuItem];
             [submenuItem setTarget: self];
             [menuFormRep setSubmenu: submenu];
             [menuFormRep setTitle: [toolbarItem label]];
             [toolbarItem setMenuFormRepresentation: menuFormRep];*/
        } else if itemIdent == MovieToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("4D Player", comment: "")
            newItem.paletteLabel = NSLocalizedString("4D Player", comment: "")
            newItem.toolTip = NSLocalizedString("Play temporal phases and change phases per second independently of slice cine", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_movieView)
        } else if itemIdent == SerieToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Series", comment: "")
            newItem.paletteLabel = NSLocalizedString("Series", comment: "")
            newItem.toolTip = NSLocalizedString("Next/Previous Series", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_serieView)
        } else if itemIdent == PatientToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Patient", comment: "")
            newItem.paletteLabel = NSLocalizedString("Patient", comment: "")
            newItem.toolTip = NSLocalizedString("Next/Previous Patient", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_patientView)
        } else if itemIdent == SubtractionToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Subtraction", comment: "")
            newItem.paletteLabel = NSLocalizedString("Subtraction", comment: "")
            newItem.toolTip = NSLocalizedString("Subtraction module", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_subCtrlView)
        } else if itemIdent == WLWWToolbarItemIdentifier {
            //	NSMenu *submenu = nil;
            //	NSMenuItem *submenuItem = nil, *menuFormRep = nil;

            // Set up the standard properties
            newItem.label = NSLocalizedString("WL/WW & CLUT", comment: "")
            newItem.paletteLabel = NSLocalizedString("WL/WW & CLUT", comment: "")
            newItem.toolTip = NSLocalizedString("Modify WL/WW & CLUT", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_WLWWView)

            // Pulldown that doesnt change item
            //        [[wlwwPopup cell] setBezelStyle:NSSmallIconButtonBezelStyle];
            //        [[wlwwPopup cell] setArrowPosition:NSPopUpArrowAtBottom];

            (self.horos_wlwwPopup?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
            //        [wlwwPopup setMenu: presetsViewMenu];
            //        [wlwwPopup setPreferredEdge:NSMinXEdge];
            //        [[[wlwwPopup menu] menuRepresentation] setHorizontalEdgePadding:0.0];
        } else if itemIdent == FilterToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Convolution Filters", comment: "")
            newItem.paletteLabel = NSLocalizedString("Convolution Filters", comment: "")
            newItem.toolTip = NSLocalizedString("Apply a convolution filter", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_ConvView)

            (self.horos_convPopup?.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
            //	[convPopup setMenu: convViewMenu];
            //        [wlwwPopup setPreferredEdge:NSMinXEdge];
            //        [[[wlwwPopup menu] menuRepresentation] setHorizontalEdgePadding:0.0];

        } else if itemIdent == FusionToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Thick Slab", comment: "")
            newItem.paletteLabel = NSLocalizedString("Thick Slab", comment: "")
            newItem.toolTip = NSLocalizedString("Change Thick Slab mode and number", comment: "")

            // A fixed width, like the other items with controls: the popup shows
            // the mode's short name and the slider does not stretch.
            setView(self.horos_FusionView)
        } else if itemIdent == StatusToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Status & Comments", comment: "")
            newItem.paletteLabel = NSLocalizedString("Status & Comments", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_StatusView)
        } else if itemIdent == BlendingToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Fusion", comment: "")
            newItem.paletteLabel = NSLocalizedString("Fusion", comment: "")
            newItem.toolTip = NSLocalizedString("Fusion Mode and Percentage", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_BlendingView)
        } else if itemIdent == RGBFactorToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("RGB Factors", comment: "")
            newItem.paletteLabel = NSLocalizedString("RGB Factors", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_RGBFactorsView)
        } else if itemIdent == OrientationToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Orientation", comment: "")
            newItem.paletteLabel = NSLocalizedString("Orientation", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_orientationView)
        } else if itemIdent == SeriesPopupToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Series", comment: "")
            newItem.paletteLabel = NSLocalizedString("Series Selection", comment: "")
            newItem.toolTip = NSLocalizedString("Series Selection", comment: "")

            setView(self.horos_seriesPopupView)
        } else if itemIdent == WindowsTilingToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Windows", comment: "")
            newItem.paletteLabel = NSLocalizedString("Windows Tiling", comment: "")
            newItem.toolTip = NSLocalizedString("Windows Tiling", comment: "")

            // Template grids drawn in code, legible in light and dark.
            WindowsTilingImage.install(in: self.horos_windowsTiling)
            setView(self.horos_windowsTiling)
        } else if itemIdent == AnnotationsToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Annotations", comment: "")
            newItem.paletteLabel = NSLocalizedString("Annotations", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_annotations)
        } else if itemIdent == ShutterToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Shutter", comment: "")
            newItem.paletteLabel = NSLocalizedString("Shutter", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_shutterView)
        } else if itemIdent == PropagateSettingsToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Propagate", comment: "")
            newItem.paletteLabel = NSLocalizedString("Propagate", comment: "")
            newItem.toolTip = NSLocalizedString("Propagate settings (WL/WW, zoom, ...)", comment: "")

            setView(self.horos_propagateSettingsView)
        } else if itemIdent == ReconstructionToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("2D/3D", comment: "")
            newItem.paletteLabel = NSLocalizedString("2D/3D", comment: "")
            newItem.toolTip = NSLocalizedString("2D/3D Reconstruction Tools", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_ReconstructionView)
        } else if itemIdent == KeyImagesToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Key Images", comment: "")
            newItem.paletteLabel = NSLocalizedString("Key Images", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_keyImages)
        } else if itemIdent == ToolsToolbarItemIdentifier {
            // Set up the standard properties
            newItem.label = NSLocalizedString("Mouse button function", comment: "")
            newItem.paletteLabel = NSLocalizedString("Mouse button function", comment: "")
            newItem.toolTip = NSLocalizedString("Change the mouse button function", comment: "")

            // Use a custom view, a text field, for the search item
            setView(self.horos_toolsView)

        } else if itemIdent == FlipVerticalToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Flip Vertical", comment: "")
            newItem.paletteLabel = NSLocalizedString("Flip Vertical", comment: "")
            newItem.toolTip = NSLocalizedString("Flip image vertically", comment: "")
            newItem.image = NSImage.toolbarImageNamed(FlipVerticalToolbarItemIdentifier)
            newItem.target = nil
            newItem.action = #selector(DCMView.flipVertical(_:))
        } else if itemIdent == SetPixelValueItemIdentifier {

            newItem.label = NSLocalizedString("Set Pixels", comment: "")
            newItem.paletteLabel = NSLocalizedString("Set Pixels", comment: "")
            newItem.toolTip = NSLocalizedString("Set Pixels Values to...", comment: "")
            newItem.image = NSImage.toolbarImageNamed(SetPixelValueItemIdentifier)
            newItem.target = nil
            newItem.action = #selector(ViewerController.roiSetPixelsSetup(_:))
        } else if itemIdent == GrowingRegionItemIdentifier {

            newItem.label = NSLocalizedString("Growing", comment: "")
            newItem.paletteLabel = NSLocalizedString("Growing", comment: "")
            newItem.toolTip = NSLocalizedString("Growing Region", comment: "")
            newItem.image = NSImage.toolbarImageNamed(GrowingRegionItemIdentifier)
            newItem.target = nil
            newItem.action = Selector(("segmentationTest:"))
        } else if itemIdent == VRPanelToolbarItemIdentifier {

            newItem.label = NSLocalizedString("3D Panel", comment: "")
            newItem.paletteLabel = NSLocalizedString("3D Panel", comment: "")
            newItem.image = NSImage.toolbarImageNamed(VRPanelToolbarItemIdentifier)
            newItem.target = nil
            newItem.action = #selector(ViewerController.panel3D(_:))
        } else if itemIdent == FlipHorizontalToolbarItemIdentifier {

            newItem.label = NSLocalizedString("Flip Horizontal", comment: "")
            newItem.paletteLabel = NSLocalizedString("Flip Horizontal", comment: "")
            newItem.toolTip = NSLocalizedString("Flip image horizontallly", comment: "")
            newItem.image = NSImage.toolbarImageNamed(FlipHorizontalToolbarItemIdentifier)
            newItem.target = nil
            newItem.action = #selector(DCMView.flipHorizontal(_:))
        } else if itemIdent == LUT12BitToolbarItemIdentifier && AppController.canDisplay12Bit() {
            newItem.label = NSLocalizedString("Display", comment: "")
            newItem.paletteLabel = NSLocalizedString("Display type", comment: "")
            newItem.toolTip = NSLocalizedString("Display type", comment: "")

            setView(self.horos_display12bitToolbarItemView)
        } else if itemIdent == CobbAngleToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Cobb", comment: "")
            newItem.paletteLabel = NSLocalizedString("Cobb", comment: "")
            newItem.toolTip = NSLocalizedString("Cobb's Angle", comment: "")
            newItem.image = NSImage.toolbarImageNamed("CobbAngle.tif")
            newItem.target = nil
            newItem.action = Selector(("switchCobbAngle:"))
        } else if itemIdent == ThreeDPositionToolbarItemIdentifier {
            newItem.label = NSLocalizedString("3D Pos", comment: "")
            newItem.paletteLabel = NSLocalizedString("3D Pos", comment: "")
            newItem.image = NSImage.toolbarImageNamed("OrientationWidget.tif")
            newItem.target = nil
            newItem.action = #selector(ViewerController.threeDPanel(_:))
        } else if itemIdent == StudyNoteToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Note", comment: "the note of a study")
            newItem.paletteLabel = NSLocalizedString("Note", comment: "the note of a study")
            newItem.toolTip = NSLocalizedString("Display the Note Editor", comment: "")
            newItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: NSLocalizedString("Note", comment: "the note of a study"))
            newItem.target = nil
            newItem.action = #selector(ViewerController.showStudyNoteEditor(_:))
        } else if itemIdent == NavigatorToolbarItemIdentifier {
            newItem.label = NSLocalizedString("Navigator", comment: "")
            newItem.paletteLabel = NSLocalizedString("Navigator", comment: "")
            newItem.image = NSImage.toolbarImageNamed(NavigatorToolbarItemIdentifier)
            newItem.target = nil
            newItem.action = #selector(ViewerController.navigator(_:))
        } else {
            // Is it a plugin menu item?
            if PluginManager.pluginsDict()?.object(forKey: itemIdent) != nil {
                let bundle = PluginManager.pluginsDict()?.object(forKey: itemIdent) as? Bundle
                let info = bundle?.infoDictionary as NSDictionary?

                newItem.label = itemIdent
                newItem.paletteLabel = itemIdent
                let toolTips = info?.object(forKey: "ToolbarToolTips") as? NSDictionary
                if let toolTips {
                    newItem.toolTip = toolTips.object(forKey: itemIdent) as? String
                } else {
                    newItem.toolTip = itemIdent
                }

                var image = (info?.object(forKey: "ToolbarIcon") as? String)
                    .flatMap { bundle?.pathForImageResource($0) }
                    .flatMap { NSImage(contentsOfFile: $0) }
                if image == nil, let bundlePath = bundle?.bundlePath {
                    image = NSWorkspace.shared.icon(forFile: bundlePath)
                }
                newItem.image = ToolbarImage.fitting(image)

                newItem.target = self
                newItem.action = Selector(("executeFilterFromToolbar:"))
            } else {
                toolbarItem = nil
            }
        }

        let pluginToolbarItemSelector = #selector(PluginFilter.toolbarItem(forItemIdentifier:forViewer:))
        for key in PluginManager.plugins()?.allKeys ?? [] {
            let plugin = PluginManager.plugins()?.object(forKey: key) as AnyObject?
            if plugin?.responds(to: pluginToolbarItemSelector) == true {
                let item: NSToolbarItem? = plugin?.toolbarItem?(forItemIdentifier: itemIdent, forViewer: self) ?? nil

                if let item {
                    toolbarItem = item
                }
            }
        }

        //
        //    [toolbarItem.view setFrameSize: NSMakeSize( toolbarItem.view.frame.size.width, 53)];

        // Plugins supply their own items, so prepare after they had their turn.
        if let toolbarItem {
            ToolbarPolicy.prepare(toolbarItem) // +[HorosToolbarPolicy prepareItem:]
        }

        return toolbarItem
    }

    @objc(toolbarDefaultItemIdentifiers:)
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Required delegate method:  Returns the ordered list of items to be shown in the toolbar by default
        // If during the toolbar's initialization, no overriding values are found in the user defaults, or if the
        // user chooses to revert to the default items this set will be used
        return [
            DatabaseWindowToolbarItemIdentifier,
            WindowsTilingToolbarItemIdentifier,
            SeriesPopupToolbarItemIdentifier,
            AnnotationsToolbarItemIdentifier,
            PatientToolbarItemIdentifier,
            ToolsToolbarItemIdentifier,
            WLWWToolbarItemIdentifier,
            ReconstructionToolbarItemIdentifier,
            OrientationToolbarItemIdentifier,
            FusionToolbarItemIdentifier,
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            QTSaveToolbarItemIdentifier,
            SyncSeriesToolbarItemIdentifier,
            PropagateSettingsToolbarItemIdentifier,
            PlayToolbarItemIdentifier,
            SpeedToolbarItemIdentifier,
            VRPanelToolbarItemIdentifier,
            XMLToolbarItemIdentifier,
        ].map { NSToolbarItem.Identifier($0) }
    }

    @objc(toolbarAllowedItemIdentifiers:)
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let array = NSMutableArray(array: [
            NSToolbarItem.Identifier.flexibleSpace.rawValue,
            ToolbarPolicy.spaceItemIdentifier,
            MailToolbarItemIdentifier,
            Send2PACSToolbarItemIdentifier,
            PrintToolbarItemIdentifier,
            ExportToolbarItemIdentifier,
            PhotosToolbarItemIdentifier,
            QTSaveToolbarItemIdentifier,
            XMLToolbarItemIdentifier,
            ReconstructionToolbarItemIdentifier,
            BlendingToolbarItemIdentifier,
            SyncSeriesToolbarItemIdentifier,
            PropagateSettingsToolbarItemIdentifier,
            ResetToolbarItemIdentifier,
            RevertToolbarItemIdentifier,
            SUVToolbarItemIdentifier,
            ROIManagerToolbarItemIdentifier,
            FlipDataToolbarItemIdentifier,
            DatabaseWindowToolbarItemIdentifier,
            TileWindowsToolbarItemIdentifier,
            WindowsTilingToolbarItemIdentifier,
            SeriesPopupToolbarItemIdentifier,
            AnnotationsToolbarItemIdentifier,
            PlayToolbarItemIdentifier,
            SpeedToolbarItemIdentifier,
            MovieToolbarItemIdentifier,
            SerieToolbarItemIdentifier,
            PatientToolbarItemIdentifier,
            WLWWToolbarItemIdentifier,
            FusionToolbarItemIdentifier,
            SubtractionToolbarItemIdentifier,
            ShutterToolbarItemIdentifier,
            OrientationToolbarItemIdentifier,
            RGBFactorToolbarItemIdentifier,
            FilterToolbarItemIdentifier,
            ToolsToolbarItemIdentifier,
            //														iChatBroadCastToolbarItemIdentifier,
            StatusToolbarItemIdentifier,
            KeyImagesToolbarItemIdentifier,
            ReportToolbarItemIdentifier,
            FlipVerticalToolbarItemIdentifier,
            FlipHorizontalToolbarItemIdentifier,
            VRPanelToolbarItemIdentifier,
            NavigatorToolbarItemIdentifier,
            ThreeDPositionToolbarItemIdentifier,
            CobbAngleToolbarItemIdentifier,
            GrowingRegionItemIdentifier,
            SetPixelValueItemIdentifier,
            StudyNoteToolbarItemIdentifier,
        ])

        if AppController.canDisplay12Bit() { array.add(LUT12BitToolbarItemIdentifier) }

        let allPlugins = PluginManager.pluginsDict()?.allKeys ?? []
        let pluginsItems = NSMutableSet(capacity: allPlugins.count)

        for case let plugin as String in allPlugins {
            if plugin == "(-" {
                continue
            }

            let bundle = PluginManager.pluginsDict()?.object(forKey: plugin) as? Bundle
            let info = bundle?.infoDictionary as NSDictionary?
            let pluginType = info?.object(forKey: "pluginType") as? String

            if pluginType == "imageFilter" ||
                pluginType == "roiTool" ||
                pluginType == "other" {
                let allowToolbarIcon = info?.object(forKey: "allowToolbarIcon")

                if allowToolbarIcon != nil {
                    if objcBoolValue(allowToolbarIcon) == true {
                        let toolbarNames = info?.object(forKey: "ToolbarNames") as? NSArray
                        if let toolbarNames {
                            if toolbarNames.contains(plugin) {
                                pluginsItems.add(plugin)
                            }
                        } else {
                            pluginsItems.add(plugin)
                        }
                    }
                }
            }
        }

        if pluginsItems.count != 0 {
            array.addObjects(from: pluginsItems.allObjects)
        }

        let pluginAllowedIdentifiersSelector = #selector(PluginFilter.toolbarAllowedIdentifiers(forViewer:))
        for key in PluginManager.plugins()?.allKeys ?? [] {
            let plugin = PluginManager.plugins()?.object(forKey: key) as AnyObject?
            if plugin?.responds(to: pluginAllowedIdentifiersSelector) == true {
                let identifiers: [Any]? = plugin?.toolbarAllowedIdentifiers?(forViewer: self) ?? nil
                if let identifiers {
                    array.addObjects(from: identifiers)
                }
            }
        }

        // The toolbar only takes strings: anything else a plugin returned is left out.
        return array.compactMap { ($0 as? String).map { NSToolbarItem.Identifier($0) } }
    }

    @objc(toolbar)
    func toolbar() -> NSToolbar! {
        return self.horos_toolbar
    }

    @objc(toolbarWillAddItem:)
    func toolbarWillAddItem(_ notification: Notification) {
        // To avoid a bug related to the 'separated toolbar window' :  we need to retain each toolbar item. We release them in the dealloc function
        let item = notification.userInfo?["item"] as? NSToolbarItem
        if let item, self.horos_retainedToolbarItems?.contains(item) == false { self.horos_retainedToolbarItems?.add(item) }
    }

    @objc(toolbarDidRemoveItem:)
    func toolbarDidRemoveItem(_ notification: Notification) {
    }

    @objc(validateToolbarItem:)
    func validateToolbarItem(_ toolbarItem: NSToolbarItem!) -> Bool {
        // The EXPORTTOOLBARITEM branch (every item enabled), disabled, is left out.

        if !(self.horos_fileList(at: 0)?.lastObject is NSManagedObject) {
            return false
        }

        let itemIdentifier = toolbarItem?.itemIdentifier.rawValue

        if self.database?.isReadOnly ?? false {
            if itemIdentifier == ReportToolbarItemIdentifier {
                return false
            }
        }

        var enable = true

        let curMovieIndex = Int(self.horos_curMovieIndex)

        /// `[fileList[ curMovieIndex] count] == 1 && [[[fileList[ curMovieIndex] objectAtIndex:0] valueForKey:@"numberOfFrames"] intValue] <=  1`
        func singleImageOfOneFrame() -> Bool {
            let list = self.horos_fileList(at: curMovieIndex)
            guard (list?.count ?? 0) == 1 else { return false }
            return objcIntValue((list?.object(at: 0) as? NSObject)?.value(forKey: "numberOfFrames")) <= 1
        }

        if itemIdentifier == PlayToolbarItemIdentifier {
            if singleImageOfOneFrame() { enable = false }
        }

        if itemIdentifier == SyncSeriesToolbarItemIdentifier {
            if ViewerController.horos_numberOf2DViewer() <= 1 { enable = false }
        }

        if itemIdentifier == SpeedToolbarItemIdentifier {
            if singleImageOfOneFrame() { enable = false }
        }

        if itemIdentifier == MovieToolbarItemIdentifier {
            if self.horos_maxMovieIndex == 1 { enable = false }
        }

        if itemIdentifier == QTSaveToolbarItemIdentifier {
            if singleImageOfOneFrame() && self.horos_maxMovieIndex == 1 && self.horos_blending == nil { enable = false }
        }

        if itemIdentifier == ReconstructionToolbarItemIdentifier {
            if singleImageOfOneFrame() { enable = false }
        }

        //	if ([[toolbarItem itemIdentifier] isEqualToString: iChatBroadCastToolbarItemIdentifier])
        //	{
        //		enable = YES;
        //	}

        if itemIdentifier == SUVToolbarItemIdentifier {
            enable = self.horos_imageView?.curDCM?.hasSUV ?? false
        }

        if itemIdentifier == LUT12BitToolbarItemIdentifier {
            enable = AppController.canDisplay12Bit()
        }

        return enable
    }

    @objc(setDefaultToolMenu:)
    func setDefaultToolMenu(_ sender: Any!) {
        if objcTag(sender) >= 0 {
            self.horos_toolsMatrix?.selectCell(withTag: objcTag(sender))
            self.horos_imageView?.currentTool = ToolMode(rawValue: Int16(truncatingIfNeeded: objcTag(sender)))!
        }
    }

    @objc(buttonToolMatrix)
    func buttonToolMatrix() -> NSMatrix! { return self.horos_buttonToolMatrix }

    @objc(defaultToolModified:)
    func defaultToolModified(_ note: Notification!) {
        let sender = note?.object
        var tag: Int

        if let sender {
            if sender is NSMatrix {
                let theCell = objcObject(sender, "selectedCell")
                tag = objcTag(theCell)
            } else {
                tag = objcTag(sender)
            }
        } else {
            tag = Int(objcIntValue((note?.userInfo as NSDictionary?)?.value(forKey: "toolIndex")))
        }

        let toolMode = ToolMode(rawValue: Int16(truncatingIfNeeded: tag))!
        switch toolMode {
        case .tMesure,
             .tAngle,
             .tROI,
             .tOval,
             .tText,
             .tArrow,
             .tOPolygon,
             .tCPolygon,
             .tPencil,
             .t2DPoint,
             .tPlain,
             .tRepulsor,
             .tROISelector,
             .tDynAngle,
             .tAxis,
             .tTAGT:
            self.setROIToolTag(toolMode)

        default:
            self.horos_toolsMatrix?.selectCell(withTag: Int(toolMode.rawValue))
        }

        if tag >= 0 {
            if tag == Int(ToolMode.tCross.rawValue) { PatientCrosshairController.shared.setVisible(true) }
            self.horos_imageView?.currentTool = toolMode
        }
    }

    @objc(defaultRightToolModified:)
    func defaultRightToolModified(_ note: Notification!) {
        let sender = note?.object
        let tag: Int32

        if sender is NSMatrix {
            let theCell = objcObject(sender, "selectedCell")
            tag = Int32(truncatingIfNeeded: objcTag(theCell))
        } else {
            tag = Int32(truncatingIfNeeded: objcTag(sender))
        }

        self.horos_toolsMatrix?.selectCell(withTag: Int(tag))

        if tag >= 0 { self.horos_imageView?.currentToolRight = ToolMode(rawValue: Int16(truncatingIfNeeded: tag))! }
    }

    @IBAction @objc(setButtonTool:)
    func setButtonTool(_ sender: Any!) {
        if objcTag(objcObject(sender, "selectedCell")) == 0 {
            self.horos_toolsMatrix?.cell(atRow: 0, column: 5)?.isEnabled = true
            self.horos_popupRoi?.isEnabled = true
            self.horos_toolsMatrix?.selectCell(withTag: Int(self.horos_imageView?.currentTool.rawValue ?? 0))
        } else {
            self.horos_toolsMatrix?.cell(atRow: 0, column: 5)?.isEnabled = false
            self.horos_popupRoi?.isEnabled = false
            self.horos_toolsMatrix?.selectCell(withTag: Int(self.horos_imageView?.currentToolRight.rawValue ?? 0))
        }
    }

    @IBAction @objc(togglePatientCrosshair:)
    func togglePatientCrosshair(_ sender: Any!) {
        let crosshair = PatientCrosshairController.shared
        crosshair.setVisible(!crosshair.isVisible)
    }

    @IBAction @objc(setDefaultTool:)
    func setDefaultTool(_ sender: Any!) {
        self.horos_imageView?.gClickCountSetReset()

        var ctag: Int32 = 0

        if sender is NSMatrix {
            ctag = Int32(truncatingIfNeeded: objcTag(objcObject(sender, "selectedCell")))
        } else {
            ctag = Int32(truncatingIfNeeded: objcTag(sender))
        }

        if objcTag(self.horos_buttonToolMatrix?.selectedCell()) == 0 {
            NotificationCenter.default.post(name: .OsirixDefaultToolModified, object: sender, userInfo: ["toolIndex": NSNumber(value: ctag)])
        } else {
            NotificationCenter.default.post(name: .OsirixDefaultRightToolModified, object: sender, userInfo: ["toolIndex": NSNumber(value: ctag)])
        }
    }

    @objc(setShutterOnOffButton:)
    func setShutterOnOffButton(_ b: NSNumber!) {
        self.horos_shutterOnOff?.state = NSControl.StateValue(rawValue: (b?.boolValue ?? false) ? 1 : 0)
    }

    @IBAction @objc(shutterOnOff:)
    func shutterOnOff(_ sender: Any!) {
        //	{
        //	int i;
        //	NSArray	*rois = [self selectedROIs];
        //
        //	for( i = 0; i < 200; i++)
        //	{
        //		ROI	*c = [self roiMorphingBetween: [rois objectAtIndex: 0] and: [rois objectAtIndex: 1] ratio: (float) (i+1) / 201.];
        //
        //		if( c)
        //		{
        //			[imageView roiSet: c];
        //			[[roiList[curMovieIndex] objectAtIndex: [imageView curImage]] addObject: c];
        //		}
        //
        //		[imageView display];
        //
        //		[[roiList[curMovieIndex] objectAtIndex: [imageView curImage]] removeObject: c];
        //	}
        //	[imageView display];
        //	return;
        //	}

        if (objcObject(sender, "title") as? String) == "Shutter" {
            self.horos_shutterOnOff?.state = (self.horos_shutterOnOff?.state ?? .off) == .off ? .on : .off //from menu
        }

        let imageView = self.horos_imageView
        let curImage = Int(imageView?.curImage ?? 0)
        let curPix = imageView?.dcmPixList?.object(at: curImage) as? DCMPix

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

        if self.horos_shutterOnOff?.state == .on {
            // Find the first rectangular ROI selected for the current frame and copy the rectangle in shutterRect.
            // Only a rectangle, as the alert below asks: an oval or a polygon is no shutter.
            var selectedROI: ROI? = nil
            let rois = self.horos_roiList(at: Int(self.horos_curMovieIndex))?.object(at: curImage) as? NSArray
            for case let r as ROI in rois ?? NSArray() {
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
                self.delete(selectedROI)

                // Each image gets the ROI clipped to itself: a smaller image
                // no longer shrinks the shutter of the images after it.
                for case let p as DCMPix in imageView?.dcmPixList ?? NSMutableArray() {
                    p.shutterRect = clipped(shutterRect, to: p)
                    p.shutterEnabled = true // NSControlStateValueOn
                }
            } else {
                //using stored shutterRect?
                let storedRect = curPix?.shutterRect ?? .zero
                if (storedRect.size.width == 0 || (storedRect.size.width == CGFloat(curPix?.pwidth ?? 0) && storedRect.size.height == CGFloat(curPix?.pheight ?? 0))) && curPix?.shutterPolygonal == nil {
                    self.horos_shutterOnOff?.state = .off

                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Shutter", comment: ""), message: NSLocalizedString("Please first define a rectangle with a rectangular ROI.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                } else { //reuse preconfigured shutterRect
                    for case let p as DCMPix in imageView?.dcmPixList ?? NSMutableArray() { p.shutterEnabled = true } // NSControlStateValueOn
                }
            }
        } else {
            for case let p as DCMPix in imageView?.dcmPixList ?? NSMutableArray() { p.shutterEnabled = false } // NSControlStateValueOff
        }
        imageView?.setIndex(imageView?.curImage ?? 0) //refresh viewer only
    }

    @IBAction @objc(resetCLUT:)
    func resetCLUT(_ sender: Any!) {
        if HorosAlertPanel.runInformational(title: NSLocalizedString("Reset CLUT List", comment: ""), message: NSLocalizedString("Are you sure you want to reset the entire CLUT list to the default list?", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse {
            UserDefaults.standard.removeObject(forKey: "CLUT")
            UserDefaults.standard.set((DefaultsOsiriX.getDefaults() as NSDictionary?)?.object(forKey: "CLUT"), forKey: "CLUT")

            NotificationCenter.default.post(name: .OsirixUpdateCLUTMenu, object: self.horos_curCLUTMenu, userInfo: [:])
        }
    }

    @IBAction @objc(AddOpacity:)
    func addOpacity(_ sender: Any!) {
        var red = [UInt8](repeating: 0, count: 256)
        var green = [UInt8](repeating: 0, count: 256)
        var blue = [UInt8](repeating: 0, count: 256)

        let aCLUT = self.horos_curCLUTMenu.flatMap { (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.object(forKey: $0) as? NSDictionary }
        if let aCLUT {
            /// `(unsigned char) [[array objectAtIndex: i] longValue]`
            func component(_ array: NSArray?, _ i: Int) -> UInt8 {
                let value = array?.object(at: i)
                return UInt8(truncatingIfNeeded: (value as? NSNumber)?.intValue ?? 0)
            }

            var array = aCLUT.object(forKey: "Red") as? NSArray
            for i in 0 ..< 256 {
                red[i] = component(array, i)
            }

            array = aCLUT.object(forKey: "Green") as? NSArray
            for i in 0 ..< 256 {
                green[i] = component(array, i)
            }

            array = aCLUT.object(forKey: "Blue") as? NSArray
            for i in 0 ..< 256 {
                blue[i] = component(array, i)
            }

            self.horos_OpacityView?.setCurrentCLUT(&red, &green, &blue)
        }

        self.horos_OpacityName?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let sheet = self.horos_addOpacityWindow, let window = self.window {
            window.beginSheet(sheet, completionHandler: nil)
        }
    }


    @IBAction @objc(AddCLUT:)
    func addCLUT(_ sender: Any!) {
        self.clutAction(self)
        self.horos_clutName?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let sheet = self.horos_addCLUTWindow, let window = self.window {
            window.beginSheet(sheet, completionHandler: nil)
        }
    }


    @objc(UpdateCLUTMenu:)
    func updateCLUTMenu(_ note: Notification!) {
        if clutPresetsMenu == nil || note?.userInfo != nil {
            //*** Build the menu

            // Presets VIEWER Menu

            let keys = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?)?.allKeys as NSArray?
            let sortedKeys = keys?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

            let menu = NSMenu()
            clutPresetsMenu = menu

            menu.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: NSSelectorFromString("ApplyCLUT:"), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())

            var i: Int16 = 0
            // short compared with an NSUInteger count, as in C.
            while UInt(bitPattern: Int(i)) < UInt(sortedKeys?.count ?? 0) {
                menu.addItem(withTitle: sortedKeys?.object(at: Int(i)) as? String ?? "", action: NSSelectorFromString("ApplyCLUT:"), keyEquivalent: "")
                i &+= 1
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("8-bit CLUT Editor", comment: ""), action: #selector(ViewerController.addCLUT(_:)), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Reset CLUT List", comment: ""), action: #selector(ViewerController.resetCLUT(_:)), keyEquivalent: "")

            objcSetTitle(self.horos_clutPopup, self.horos_curCLUTMenu)
            self.horos_clutPopup?.menu = menu.copy() as? NSMenu
            self.horos_clutPopupSet = true
        } else if self.horos_clutPopupSet == false {
            self.horos_clutPopup?.menu = clutPresetsMenu?.copy() as? NSMenu
            self.horos_clutPopupSet = true
        }

        objcSetTitle(self.horos_clutPopup, self.horos_curCLUTMenu)
    }

    // ============================================================
    // NSToolbar Related Methods
    // ============================================================

    @objc(setupToolbar)
    func setupToolbar() {
        // Create a new toolbar instance, and attach it to our document window
        // (the previous toolbar, nil when -init calls this, used to leak if there was one).
        let toolbar = OsiriXToolbar(identifier: ViewerToolbarIdentifier)
        self.horos_toolbar = toolbar

        // Set up toolbar properties: Allow customization, give a default display mode, and remember state in user defaults
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true

        // We are the delegate
        toolbar.delegate = self

        if AppController.usetoolbarpanel() == false && UserDefaults.standard.bool(forKey: "USEALWAYSTOOLBARPANEL2") == false {
            self.window?.toolbar = toolbar
            self.window?.showsToolbarButton = false
            self.window?.toolbar?.isVisible = true
            ToolbarPolicy.adopt(toolbar: toolbar, in: self.window)
        }

        // The EXPORTTOOLBARITEM branch (a screenshot of every item), disabled, is left out.
    }
}
