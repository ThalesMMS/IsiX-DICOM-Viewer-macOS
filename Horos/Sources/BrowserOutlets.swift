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
// file), which stores the view in the browser's field of that instance
// variable (BrowserController.swift). The outlets still read by key are read
// by the same names (BrowserController+KeyValueCoding.swift). An outlet is
// nil until the nib is loaded: -initWithWindow: runs part of the browser
// before.

/// The four forms of the sheet that imports raw data. The former plugin SDK
/// declared them of an AppKit class the sheet no longer uses, so they are
/// kept here under the class they have.
final class BrowserSheetOutlets: NSObject, @unchecked Sendable {
    var rdPatientForm: HorosFormView?
    var rdPixelForm: HorosFormView?
    var rdVoxelForm: HorosFormView?
    var rdOffsetForm: HorosFormView?
}

extension BrowserController {
    @objc(setCDpasswordWindow:) func setCDpasswordWindow(_ outlet: NSWindow?) { _CDpasswordWindow = outlet }
    @objc(setZIPpasswordWindow:) func setZIPpasswordWindow(_ outlet: NSWindow?) { _ZIPpasswordWindow = outlet }
    @objc(set_activityTableView:) func setActivityTableViewOutlet(_ outlet: NSTableView?) { activityTableViewOutlet = outlet; _AtableView = outlet }
    @objc(set_bottomSplit:) func setBottomSplitOutlet(_ outlet: NSSplitView?) { _bottomSplit = outlet }
    @objc(set_sourcesArrayController:) func setSourcesArrayControllerOutlet(_ outlet: NSArrayController?) { _sourcesArrayController = outlet }
    @objc(set_sourcesTableView:) func setSourcesTableViewOutlet(_ outlet: NSTableView?) { _sourcesTableView = outlet; _bonjourServicesList = outlet }
    @objc(setAddStudiesToUserWindow:) func setAddStudiesToUserWindow(_ outlet: NSWindow?) { _addStudiesToUserWindow = outlet }
    @objc(setAlbumTable:) func setAlbumTable(_ outlet: NSTableView?) { _albumTable = outlet }
    @objc(setAnimationCheck:) func setAnimationCheck(_ outlet: NSButton?) { _animationCheck = outlet }
    @objc(setAnimationSlider:) func setAnimationSlider(_ outlet: NSSlider?) { _animationSlider = outlet }
    @objc(setBannerSplit:) func setBannerSplit(_ outlet: NSSplitView?) { _bannerSplit = outlet }
    @objc(setBonjourPasswordWindow:) func setBonjourPasswordWindow(_ outlet: NSWindow?) { _bonjourPasswordWindow = outlet }
    @objc(setBonjourSourcesBox:) func setBonjourSourcesBox(_ outlet: NSBox?) { _bonjourSourcesBox = outlet }
    @objc(setComparativeScrollView:) func setComparativeScrollView(_ outlet: NSView?) { _comparativeScrollView = outlet }
    @objc(setComparativeTable:) func setComparativeTable(_ outlet: NSTableView?) { _comparativeTable = outlet }
    @objc(setCompressionMatrix:) func setCompressionMatrix(_ outlet: NSMatrix?) { _compressionMatrix = outlet }
    @objc(setDatabaseDescription:) func setDatabaseDescription(_ outlet: NSTextField?) { _databaseDescription = outlet }
    @objc(setDatabaseOutline:) func setDatabaseOutline(_ outlet: MyOutlineView?) { _databaseOutline = outlet; _allColumns = outlet?.tableColumns as NSArray?; outlet?.allColumnsOfSDK = _allColumns }
    @objc(setEstimatedTime:) func setEstimatedTime(_ outlet: NSTextField?) { _estimatedTime = outlet }
    @objc(setExportAccessoryView:) func setExportAccessoryView(_ outlet: NSView?) { _exportAccessoryView = outlet }
    @objc(setExportHTMLButton:) func setExportHTMLButton(_ outlet: NSButton?) { _exportHTMLButton = outlet }
    @objc(setExportQuicktimeView:) func setExportQuicktimeView(_ outlet: NSView?) { _exportQuicktimeView = outlet }
    @objc(setFolderTree:) func setFolderTree(_ outlet: NSMatrix?) { _folderTree = outlet }
    @objc(setImageTileMenu:) func setImageTileMenu(_ outlet: NSMenu?) { _imageTileMenu = outlet }
    @objc(setImageView:) func setImageView(_ outlet: PreviewView?) { _imageView = outlet }
    @objc(setLeftIcon:) func setLeftIcon(_ outlet: NSImageView?) { _leftIcon = outlet }
    @objc(setMatrixView:) func setMatrixView(_ outlet: NSView?) { _matrixView = outlet }
    @objc(setMemoryMessage:) func setMemoryMessage(_ outlet: NSTextField?) { _memoryMessage = outlet }
    @objc(setModalityFilterMenu:) func setModalityFilterMenu(_ outlet: NSPopUpButton?) { _modalityFilterMenu = outlet }
    @objc(setModalityFilterView:) func setModalityFilterView(_ outlet: NSView?) { _modalityFilterView = outlet }
    @objc(setNewAlbum:) func setNewAlbum(_ outlet: NSWindow?) { _newAlbum = outlet }
    @objc(setNewAlbumName:) func setNewAlbumName(_ outlet: NSTextField?) { _newAlbumName = outlet }
    @objc(setNoOfFilesToRebuild:) func setNoOfFilesToRebuild(_ outlet: NSTextField?) { _noOfFilesToRebuild = outlet }
    @objc(setNotificationEmailArrayController:) func setNotificationEmailArrayController(_ outlet: NSArrayController?) { _notificationEmailArrayController = outlet }
    @objc(setNotificationEmailWindow:) func setNotificationEmailWindow(_ outlet: NSWindow?) { _notificationEmailWindow = outlet }
    @objc(setOMatrix:) func setOMatrix(_ outlet: BrowserMatrix?) { _oMatrix = outlet }
    @objc(setPassword:) func setPassword(_ outlet: NSTextField?) { _password = outlet }
    @objc(setPluginManagerController:) func setPluginManagerController(_ outlet: PluginManagerController?) { _pluginManagerController = outlet }
    @objc(setRdAccessory:) func setRdAccessory(_ outlet: NSView?) { _rdAccessory = outlet }
    @objc(setRdOffsetForm:) func setRdOffsetForm(_ outlet: HorosFormView?) { sheetOutlets.rdOffsetForm = outlet }
    @objc(setRdPatientForm:) func setRdPatientForm(_ outlet: HorosFormView?) { sheetOutlets.rdPatientForm = outlet }
    @objc(setRdPixelForm:) func setRdPixelForm(_ outlet: HorosFormView?) { sheetOutlets.rdPixelForm = outlet }
    @objc(setRdPixelTypeMatrix:) func setRdPixelTypeMatrix(_ outlet: NSMatrix?) { _rdPixelTypeMatrix = outlet }
    @objc(setRdVoxelForm:) func setRdVoxelForm(_ outlet: HorosFormView?) { sheetOutlets.rdVoxelForm = outlet }
    @objc(setRebuildType:) func setRebuildType(_ outlet: NSMatrix?) { _rebuildType = outlet }
    @objc(setRebuildWindow:) func setRebuildWindow(_ outlet: NSWindow?) { _rebuildWindow = outlet }
    @objc(setReportTemplatesImageView:) func setReportTemplatesImageView(_ outlet: NSImageView?) { _reportTemplatesImageView = outlet }
    @objc(setReportTemplatesListPopUpButton:) func setReportTemplatesListPopUpButton(_ outlet: NSPopUpButton?) { _reportTemplatesListPopUpButton = outlet }
    @objc(setReportTemplatesView:) func setReportTemplatesView(_ outlet: NSView?) { _reportTemplatesView = outlet }
    @objc(setRightIcon:) func setRightIcon(_ outlet: NSImageView?) { _rightIcon = outlet }
    @objc(setSearchField:) func setSearchField(_ outlet: NSSearchField?) { _searchField = outlet }
    @objc(setSearchInEntireDBResult:) func setSearchInEntireDBResult(_ outlet: NSButton?) { _searchInEntireDBResult = outlet }
    @objc(setSearchView:) func setSearchView(_ outlet: NSView?) { _searchView = outlet }
    @objc(setSplitAlbums:) func setSplitAlbums(_ outlet: NSSplitView?) { _splitAlbums = outlet; _sourcesSplitView = outlet }
    @objc(setSplitComparative:) func setSplitComparative(_ outlet: NSSplitView?) { _splitComparative = outlet }
    @objc(setSplitDrawer:) func setSplitDrawer(_ outlet: NSSplitView?) { _splitDrawer = outlet }
    @objc(setSplitViewHorz:) func setSplitViewHorz(_ outlet: NSSplitView?) { _splitViewHorz = outlet }
    @objc(setSplitViewVert:) func setSplitViewVert(_ outlet: NSSplitView?) { _splitViewVert = outlet }
    @objc(setSubOpenMatrix3D:) func setSubOpenMatrix3D(_ outlet: NSMatrix?) { _subOpenMatrix3D = outlet }
    @objc(setSubOpenMatrix4D:) func setSubOpenMatrix4D(_ outlet: NSMatrix?) { _subOpenMatrix4D = outlet }
    @objc(setSubOpenWindow:) func setSubOpenWindow(_ outlet: NSWindow?) { _subOpenWindow = outlet }
    @objc(setSubSeriesOKButton:) func setSubSeriesOKButton(_ outlet: NSButton?) { _subSeriesOKButton = outlet }
    @objc(setSubSeriesWindow:) func setSubSeriesWindow(_ outlet: NSWindow?) { _subSeriesWindow = outlet }
    @objc(setSupOpenButtons:) func setSupOpenButtons(_ outlet: NSMatrix?) { _supOpenButtons = outlet }
    @objc(setThumbnailsScrollView:) func setThumbnailsScrollView(_ outlet: NSScrollView?) { _thumbnailsScrollView = outlet }
    @objc(setTimeIntervalView:) func setTimeIntervalView(_ outlet: NSView?) { _timeIntervalView = outlet; _timeIntervalPopup = BrowserOlderInstanceVariables.popUpButton(in: outlet) }
    @objc(setUrlString:) func setUrlString(_ outlet: NSTextField?) { _urlString = outlet }
    @objc(setUrlWindow:) func setUrlWindow(_ outlet: NSWindow?) { _urlWindow = outlet }
    @objc(setWarningBox:) func setWarningBox(_ outlet: NSBox?) { _warningBox = outlet }
}
