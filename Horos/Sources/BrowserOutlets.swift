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

import AppKit

// The browser's views as MainMenu.xib connects them. The nib sets each outlet
// on the browser by its former instance variable's name (databaseOutline,
// _sourcesTableView...), through a setter of that name (at the end of this
// file), which stores the view in the holder of the window's views or in that
// of the sheets and auxiliary views; key-value coding reads them by the same
// names (BrowserController+KeyValueCoding.swift). An outlet is nil until the
// nib is loaded: -initWithWindow: runs part of the browser before.

/// The views of the database window.
final class BrowserWindowOutlets: NSObject, @unchecked Sendable {
    @objc var databaseDescription: NSTextField?
    @objc var databaseOutline: MyOutlineView?
    @objc var oMatrix: BrowserMatrix?
    @objc var albumTable: NSTableView?
    @objc var bonjourSourcesBox: NSBox?
    @objc var sourcesArrayController: NSArrayController?
    @objc var sourcesTableView: NSTableView?
    @objc var activityTableView: NSTableView?
    @objc var animationSlider: NSSlider?
    @objc var animationCheck: NSButton?
    @objc var bottomSplit: NSSplitView?
    @objc var imageView: PreviewView?
    @objc var matrixView: NSView?
    @objc var comparativeScrollView: NSView?
    @objc var comparativeTable: NSTableView?
    @objc var thumbnailsScrollView: NSScrollView?
    @objc var splitViewHorz: NSSplitView?
    @objc var splitViewVert: NSSplitView?
    @objc var splitAlbums: NSSplitView?
    @objc var splitDrawer: NSSplitView?
    /// Replaced by -awakeFromNib when the history is above the thumbnails.
    @objc var splitComparative: NSSplitView?
    @objc var bannerSplit: NSSplitView?
    @objc var banner: NSButton?
    @objc var timeIntervalView: NSView?
    @objc var modalityFilterMenu: NSPopUpButton?
    @objc var modalityFilterView: NSView?
    @objc var searchView: NSView?
    @objc var searchField: NSSearchField?
    @objc var searchInEntireDBResult: NSButton?
    @objc var imageTileMenu: NSMenu?
    @objc var pluginManagerController: PluginManagerController?
}

/// The sheets, panels and accessory views the browser shows.
final class BrowserSheetOutlets: NSObject, @unchecked Sendable {
    // Opening a sub-selection of a series, or reparsing it in 3D or 4D.
    @objc var subOpenWindow: NSWindow?
    @objc var subOpenMatrix3D: NSMatrix?
    @objc var subOpenMatrix4D: NSMatrix?
    @objc var supOpenButtons: NSMatrix?
    @objc var subSeriesWindow: NSWindow?
    @objc var subSeriesOKButton: NSButton?
    @objc var memoryMessage: NSTextField?
    @objc var leftIcon: NSImageView?
    @objc var rightIcon: NSImageView?
    @objc var warningBox: NSBox?
    // The password of a shared database.
    @objc var bonjourPasswordWindow: NSWindow?
    @objc var password: NSTextField?
    // A new album.
    @objc var newAlbum: NSWindow?
    @objc var newAlbumName: NSTextField?
    // Rebuilding the database.
    @objc var rebuildWindow: NSWindow?
    @objc var rebuildType: NSMatrix?
    @objc var estimatedTime: NSTextField?
    @objc var noOfFilesToRebuild: NSTextField?
    @objc var warning: NSTextField?
    // Adding a URL, the passwords of a CD and of a ZIP file.
    @objc var urlWindow: NSWindow?
    @objc var urlString: NSTextField?
    @objc var CDpasswordWindow: NSWindow?
    @objc var ZIPpasswordWindow: NSWindow?
    // Importing raw data.
    @objc var rdPatientForm: HorosFormView?
    @objc var rdPixelForm: HorosFormView?
    @objc var rdVoxelForm: HorosFormView?
    @objc var rdOffsetForm: HorosFormView?
    @objc var rdPixelTypeMatrix: NSMatrix?
    @objc var rdAccessory: NSView?
    // Exporting.
    @objc var exportQuicktimeView: NSView?
    @objc var exportHTMLButton: NSButton?
    @objc var exportAccessoryView: NSView?
    @objc var compressionMatrix: NSMatrix?
    @objc var folderTree: NSMatrix?
    // Reports.
    @objc var reportTemplatesView: NSView?
    @objc var reportTemplatesImageView: NSImageView?
    @objc var reportTemplatesListPopUpButton: NSPopUpButton?
    // The web portal's users.
    @objc var addStudiesToUserWindow: NSWindow?
    @objc var notificationEmailWindow: NSWindow?
    @objc var notificationEmailArrayController: NSArrayController?
}

// The nib connects an outlet through its setter, or an instance variable of
// its name: a key with neither is not connected. The setters have the former
// instance variables' names, with the leading underscore of four of them.
extension BrowserController {
    @objc(setCDpasswordWindow:) func setCDpasswordWindow(_ outlet: NSWindow?) { sheetOutlets.CDpasswordWindow = outlet }
    @objc(setZIPpasswordWindow:) func setZIPpasswordWindow(_ outlet: NSWindow?) { sheetOutlets.ZIPpasswordWindow = outlet }
    @objc(set_activityTableView:) func setActivityTableViewOutlet(_ outlet: NSTableView?) { windowOutlets.activityTableView = outlet }
    @objc(set_bottomSplit:) func setBottomSplitOutlet(_ outlet: NSSplitView?) { windowOutlets.bottomSplit = outlet }
    @objc(set_sourcesArrayController:) func setSourcesArrayControllerOutlet(_ outlet: NSArrayController?) { windowOutlets.sourcesArrayController = outlet }
    @objc(set_sourcesTableView:) func setSourcesTableViewOutlet(_ outlet: NSTableView?) { windowOutlets.sourcesTableView = outlet }
    @objc(setAddStudiesToUserWindow:) func setAddStudiesToUserWindow(_ outlet: NSWindow?) { sheetOutlets.addStudiesToUserWindow = outlet }
    @objc(setAlbumTable:) func setAlbumTable(_ outlet: NSTableView?) { windowOutlets.albumTable = outlet }
    @objc(setAnimationCheck:) func setAnimationCheck(_ outlet: NSButton?) { windowOutlets.animationCheck = outlet }
    @objc(setAnimationSlider:) func setAnimationSlider(_ outlet: NSSlider?) { windowOutlets.animationSlider = outlet }
    @objc(setBannerSplit:) func setBannerSplit(_ outlet: NSSplitView?) { windowOutlets.bannerSplit = outlet }
    @objc(setBonjourPasswordWindow:) func setBonjourPasswordWindow(_ outlet: NSWindow?) { sheetOutlets.bonjourPasswordWindow = outlet }
    @objc(setBonjourSourcesBox:) func setBonjourSourcesBox(_ outlet: NSBox?) { windowOutlets.bonjourSourcesBox = outlet }
    @objc(setComparativeScrollView:) func setComparativeScrollView(_ outlet: NSView?) { windowOutlets.comparativeScrollView = outlet }
    @objc(setComparativeTable:) func setComparativeTable(_ outlet: NSTableView?) { windowOutlets.comparativeTable = outlet }
    @objc(setCompressionMatrix:) func setCompressionMatrix(_ outlet: NSMatrix?) { sheetOutlets.compressionMatrix = outlet }
    @objc(setDatabaseDescription:) func setDatabaseDescription(_ outlet: NSTextField?) { windowOutlets.databaseDescription = outlet }
    @objc(setDatabaseOutline:) func setDatabaseOutline(_ outlet: MyOutlineView?) { windowOutlets.databaseOutline = outlet }
    @objc(setEstimatedTime:) func setEstimatedTime(_ outlet: NSTextField?) { sheetOutlets.estimatedTime = outlet }
    @objc(setExportAccessoryView:) func setExportAccessoryView(_ outlet: NSView?) { sheetOutlets.exportAccessoryView = outlet }
    @objc(setExportHTMLButton:) func setExportHTMLButton(_ outlet: NSButton?) { sheetOutlets.exportHTMLButton = outlet }
    @objc(setExportQuicktimeView:) func setExportQuicktimeView(_ outlet: NSView?) { sheetOutlets.exportQuicktimeView = outlet }
    @objc(setFolderTree:) func setFolderTree(_ outlet: NSMatrix?) { sheetOutlets.folderTree = outlet }
    @objc(setImageTileMenu:) func setImageTileMenu(_ outlet: NSMenu?) { windowOutlets.imageTileMenu = outlet }
    @objc(setImageView:) func setImageView(_ outlet: PreviewView?) { windowOutlets.imageView = outlet }
    @objc(setLeftIcon:) func setLeftIcon(_ outlet: NSImageView?) { sheetOutlets.leftIcon = outlet }
    @objc(setMatrixView:) func setMatrixView(_ outlet: NSView?) { windowOutlets.matrixView = outlet }
    @objc(setMemoryMessage:) func setMemoryMessage(_ outlet: NSTextField?) { sheetOutlets.memoryMessage = outlet }
    @objc(setModalityFilterMenu:) func setModalityFilterMenu(_ outlet: NSPopUpButton?) { windowOutlets.modalityFilterMenu = outlet }
    @objc(setModalityFilterView:) func setModalityFilterView(_ outlet: NSView?) { windowOutlets.modalityFilterView = outlet }
    @objc(setNewAlbum:) func setNewAlbum(_ outlet: NSWindow?) { sheetOutlets.newAlbum = outlet }
    @objc(setNewAlbumName:) func setNewAlbumName(_ outlet: NSTextField?) { sheetOutlets.newAlbumName = outlet }
    @objc(setNoOfFilesToRebuild:) func setNoOfFilesToRebuild(_ outlet: NSTextField?) { sheetOutlets.noOfFilesToRebuild = outlet }
    @objc(setNotificationEmailArrayController:) func setNotificationEmailArrayController(_ outlet: NSArrayController?) { sheetOutlets.notificationEmailArrayController = outlet }
    @objc(setNotificationEmailWindow:) func setNotificationEmailWindow(_ outlet: NSWindow?) { sheetOutlets.notificationEmailWindow = outlet }
    @objc(setOMatrix:) func setOMatrix(_ outlet: BrowserMatrix?) { windowOutlets.oMatrix = outlet }
    @objc(setPassword:) func setPassword(_ outlet: NSTextField?) { sheetOutlets.password = outlet }
    @objc(setPluginManagerController:) func setPluginManagerController(_ outlet: PluginManagerController?) { windowOutlets.pluginManagerController = outlet }
    @objc(setRdAccessory:) func setRdAccessory(_ outlet: NSView?) { sheetOutlets.rdAccessory = outlet }
    @objc(setRdOffsetForm:) func setRdOffsetForm(_ outlet: HorosFormView?) { sheetOutlets.rdOffsetForm = outlet }
    @objc(setRdPatientForm:) func setRdPatientForm(_ outlet: HorosFormView?) { sheetOutlets.rdPatientForm = outlet }
    @objc(setRdPixelForm:) func setRdPixelForm(_ outlet: HorosFormView?) { sheetOutlets.rdPixelForm = outlet }
    @objc(setRdPixelTypeMatrix:) func setRdPixelTypeMatrix(_ outlet: NSMatrix?) { sheetOutlets.rdPixelTypeMatrix = outlet }
    @objc(setRdVoxelForm:) func setRdVoxelForm(_ outlet: HorosFormView?) { sheetOutlets.rdVoxelForm = outlet }
    @objc(setRebuildType:) func setRebuildType(_ outlet: NSMatrix?) { sheetOutlets.rebuildType = outlet }
    @objc(setRebuildWindow:) func setRebuildWindow(_ outlet: NSWindow?) { sheetOutlets.rebuildWindow = outlet }
    @objc(setReportTemplatesImageView:) func setReportTemplatesImageView(_ outlet: NSImageView?) { sheetOutlets.reportTemplatesImageView = outlet }
    @objc(setReportTemplatesListPopUpButton:) func setReportTemplatesListPopUpButton(_ outlet: NSPopUpButton?) { sheetOutlets.reportTemplatesListPopUpButton = outlet }
    @objc(setReportTemplatesView:) func setReportTemplatesView(_ outlet: NSView?) { sheetOutlets.reportTemplatesView = outlet }
    @objc(setRightIcon:) func setRightIcon(_ outlet: NSImageView?) { sheetOutlets.rightIcon = outlet }
    @objc(setSearchField:) func setSearchField(_ outlet: NSSearchField?) { windowOutlets.searchField = outlet }
    @objc(setSearchInEntireDBResult:) func setSearchInEntireDBResult(_ outlet: NSButton?) { windowOutlets.searchInEntireDBResult = outlet }
    @objc(setSearchView:) func setSearchView(_ outlet: NSView?) { windowOutlets.searchView = outlet }
    @objc(setSplitAlbums:) func setSplitAlbums(_ outlet: NSSplitView?) { windowOutlets.splitAlbums = outlet }
    @objc(setSplitComparative:) func setSplitComparative(_ outlet: NSSplitView?) { windowOutlets.splitComparative = outlet }
    @objc(setSplitDrawer:) func setSplitDrawer(_ outlet: NSSplitView?) { windowOutlets.splitDrawer = outlet }
    @objc(setSplitViewHorz:) func setSplitViewHorz(_ outlet: NSSplitView?) { windowOutlets.splitViewHorz = outlet }
    @objc(setSplitViewVert:) func setSplitViewVert(_ outlet: NSSplitView?) { windowOutlets.splitViewVert = outlet }
    @objc(setSubOpenMatrix3D:) func setSubOpenMatrix3D(_ outlet: NSMatrix?) { sheetOutlets.subOpenMatrix3D = outlet }
    @objc(setSubOpenMatrix4D:) func setSubOpenMatrix4D(_ outlet: NSMatrix?) { sheetOutlets.subOpenMatrix4D = outlet }
    @objc(setSubOpenWindow:) func setSubOpenWindow(_ outlet: NSWindow?) { sheetOutlets.subOpenWindow = outlet }
    @objc(setSubSeriesOKButton:) func setSubSeriesOKButton(_ outlet: NSButton?) { sheetOutlets.subSeriesOKButton = outlet }
    @objc(setSubSeriesWindow:) func setSubSeriesWindow(_ outlet: NSWindow?) { sheetOutlets.subSeriesWindow = outlet }
    @objc(setSupOpenButtons:) func setSupOpenButtons(_ outlet: NSMatrix?) { sheetOutlets.supOpenButtons = outlet }
    @objc(setThumbnailsScrollView:) func setThumbnailsScrollView(_ outlet: NSScrollView?) { windowOutlets.thumbnailsScrollView = outlet }
    @objc(setTimeIntervalView:) func setTimeIntervalView(_ outlet: NSView?) { windowOutlets.timeIntervalView = outlet }
    @objc(setUrlString:) func setUrlString(_ outlet: NSTextField?) { sheetOutlets.urlString = outlet }
    @objc(setUrlWindow:) func setUrlWindow(_ outlet: NSWindow?) { sheetOutlets.urlWindow = outlet }
    @objc(setWarningBox:) func setWarningBox(_ outlet: NSBox?) { sheetOutlets.warningBox = outlet }
}
