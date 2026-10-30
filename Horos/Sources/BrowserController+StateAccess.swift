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

// The state of the browser under the names the extensions use: each horos_
// accessor reads or writes the holder of its subject (BrowserState.swift) or
// of its views (BrowserOutlets.swift). The accessors read from any thread are
// nonisolated, as they were; the others are the main thread's.

extension BrowserController {

    var horos_sourcesTableView: NSTableView? { windowOutlets.sourcesTableView }
    var horos_sourcesHelper: Any! {
        get { windowState.sourcesHelper }
        set { windowState.sourcesHelper = newValue }
    }
    var horos_activityTableView: NSTableView? { windowOutlets.activityTableView }
    var horos_activityHelper: Any! {
        get { windowState.activityHelper }
        set { windowState.activityHelper = newValue }
    }
    nonisolated var horos_albumNoOfStudiesCache: NSMutableArray? { albumState.albumNoOfStudiesCache }
    var horos_bottomSplit: NSSplitView? { windowOutlets.bottomSplit }
    var horos_filterPredicate: NSPredicate? {
        get { studyListState.filterPredicate }
        set { studyListState.filterPredicate = newValue }
    }
    var horos_filterPredicateDescription: String? {
        get { studyListState.filterPredicateDescription }
        set { studyListState.filterPredicateDescription = newValue }
    }
    var horos_refreshDeferredWhileEditing: Bool {
        get { studyListState.refreshDeferredWhileEditing }
        set { studyListState.refreshDeferredWhileEditing = newValue }
    }
    nonisolated var horos_searchString: String? {
        get { studyListState.searchString }
        set { studyListState.searchString = newValue }
    }
    var horos_splitViewVertDividerRatio: CGFloat {
        get { windowState.splitViewVertDividerRatio }
        set { windowState.splitViewVertDividerRatio = newValue }
    }
    nonisolated var horos_timeIntervalOfLastLoadIconsDisplayIcons: TimeInterval {
        get { previewState.timeIntervalOfLastLoadIconsDisplayIcons }
        set { previewState.timeIntervalOfLastLoadIconsDisplayIcons = newValue }
    }
    nonisolated var horos_albumTable: NSTableView? { windowOutlets.albumTable }
    var horos_animationCheck: NSButton? { windowOutlets.animationCheck }
    var horos_animationSlider: NSSlider? { windowOutlets.animationSlider }
    var horos_banner: NSButton? { windowOutlets.banner }
    var horos_bannerSplit: NSSplitView? { windowOutlets.bannerSplit }
    nonisolated var horos_comparativeRetrieveQueue: NSMutableArray? {
        get { comparativeState.comparativeRetrieveQueue }
        set { comparativeState.comparativeRetrieveQueue = newValue }
    }
    var horos_comparativeStudies: [Any]? { comparativeState.comparativeStudies as? [Any] }
    var horos_comparativeStudyWaited: DCMTKStudyQueryNode? {
        get { comparativeState.comparativeStudyWaited }
        set { comparativeState.comparativeStudyWaited = newValue }
    }
    var horos_comparativeStudyWaitedTime: TimeInterval {
        get { comparativeState.comparativeStudyWaitedTime }
        set { comparativeState.comparativeStudyWaitedTime = newValue }
    }
    var horos_comparativeStudyWaitedToOpen: Bool {
        get { comparativeState.comparativeStudyWaitedToOpen }
        set { comparativeState.comparativeStudyWaitedToOpen = newValue }
    }
    var horos_comparativeStudyWaitedToSelect: Bool {
        get { comparativeState.comparativeStudyWaitedToSelect }
        set { comparativeState.comparativeStudyWaitedToSelect = newValue }
    }
    var horos_comparativeStudyWaitedViewer: ViewerController? {
        get { comparativeState.comparativeStudyWaitedViewer }
        set { comparativeState.comparativeStudyWaitedViewer = newValue }
    }
    var horos_comparativeTable: NSTableView? { windowOutlets.comparativeTable }
    var horos_compressionMatrix: NSMatrix? { sheetOutlets.compressionMatrix }
    var horos_DatabaseIsEdited: Bool {
        get { studyListState.DatabaseIsEdited }
        set { studyListState.DatabaseIsEdited = newValue }
    }
    var horos_databaseOutline: MyOutlineView? { windowOutlets.databaseOutline }
    nonisolated var horos_distantSearchThread: Thread? {
        get { comparativeState.distantSearchThread }
        set { comparativeState.distantSearchThread = newValue }
    }
    var horos_dontSelectStudyFromComparativeStudies: Bool {
        get { comparativeState.dontSelectStudyFromComparativeStudies }
        set { comparativeState.dontSelectStudyFromComparativeStudies = newValue }
    }
    var horos_dontUpdatePreviewPane: Bool {
        get { previewState.dontUpdatePreviewPane }
        set { previewState.dontUpdatePreviewPane = newValue }
    }
    var horos_folderTree: NSMatrix? { sheetOutlets.folderTree }
    var horos_imageView: PreviewView? { windowOutlets.imageView }
    nonisolated var horos_isNetworkLogsActive: Bool {
        get { transferState.isNetworkLogsActive }
        set { transferState.isNetworkLogsActive = newValue }
    }
    var horos_KeyImagesCache: [Any]? {
        get { selectionCache.KeyImagesCache as? [Any] }
        set { selectionCache.KeyImagesCache = newValue.map { $0 as NSArray } }
    }
    var horos_lastKeyImagesSelectedFiles: Any? {
        get { selectionCache.lastKeyImagesSelectedFiles }
        set { selectionCache.lastKeyImagesSelectedFiles = newValue }
    }
    var horos_lastROIsAndKeyImagesSelectedFiles: Any? {
        get { selectionCache.lastROIsAndKeyImagesSelectedFiles }
        set { selectionCache.lastROIsAndKeyImagesSelectedFiles = newValue }
    }
    var horos_lastROIsImagesSelectedFiles: Any? {
        get { selectionCache.lastROIsImagesSelectedFiles }
        set { selectionCache.lastROIsImagesSelectedFiles = newValue }
    }
    var horos_loadPreviewIndex: Int {
        get { previewState.loadPreviewIndex }
        set { previewState.loadPreviewIndex = newValue }
    }
    var horos_logWindowController: LogWindowController? {
        get { transferState.logWindowController }
        set { transferState.logWindowController = newValue }
    }
    var horos_matrixViewArray: [Any]? {
        get { previewState.matrixViewArray as? [Any] }
        set { previewState.matrixViewArray = newValue.map { $0 as NSArray } }
    }
    var horos_modalityFilterView: NSView? { windowOutlets.modalityFilterView }
    nonisolated var horos_notFoundImage: NSImage? { previewState.notFoundImage }
    var horos_oMatrix: BrowserMatrix? { windowOutlets.oMatrix }
    var horos_openReparsedSeriesFlag: Bool {
        get { viewerOpeningState.openReparsedSeriesFlag }
        set { viewerOpeningState.openReparsedSeriesFlag = newValue }
    }
    var horos_originalOutlineViewArray: [Any]? { studyListState.originalOutlineViewArray as? [Any] }
    var horos_outlineViewArray: [Any]? {
        get { studyListState.outlineViewArray as? [Any] }
        set { studyListState.outlineViewArray = newValue.map { $0 as NSArray } }
    }
    var horos_password: NSTextField? { sheetOutlets.password }
    nonisolated var horos_previewPix: NSMutableArray? {
        get { previewState.previewPix }
        set { previewState.previewPix = newValue }
    }
    nonisolated var horos_previewPixGeneration: UInt { previewState.previewPixGeneration }
    nonisolated var horos_previewPixThumbnails: NSMutableArray? { previewState.previewPixThumbnails }
    var horos_previewRedrawCoalescer: PreviewRedrawCoalescer? {
        get { previewState.previewRedrawCoalescer }
        set { previewState.previewRedrawCoalescer = newValue }
    }
    var horos_previewWindowPolicy: PreviewWindowPolicy? {
        get { previewState.previewWindowPolicy }
        set { previewState.previewWindowPolicy = newValue }
    }
    var horos_previousFlags: UInt {
        get { studyListState.previousFlags }
        set { studyListState.previousFlags = newValue }
    }
    var horos_reportFilesToCheck: NSMutableDictionary? { windowState.reportFilesToCheck }
    var horos_reportTemplatesImageView: NSImageView? { sheetOutlets.reportTemplatesImageView }
    var horos_reportTemplatesListPopUpButton: NSPopUpButton? { sheetOutlets.reportTemplatesListPopUpButton }
    var horos_reportTemplatesView: NSView? { sheetOutlets.reportTemplatesView }
    var horos_reportToolbarItemType: Int {
        get { windowState.reportToolbarItemType }
        set { windowState.reportToolbarItemType = newValue }
    }
    var horos_ROIsAndKeyImagesButtonAvailable: Bool {
        get { selectionCache.ROIsAndKeyImagesButtonAvailable }
        set { selectionCache.ROIsAndKeyImagesButtonAvailable = newValue }
    }
    var horos_ROIsAndKeyImagesCache: [Any]? {
        get { selectionCache.ROIsAndKeyImagesCache as? [Any] }
        set { selectionCache.ROIsAndKeyImagesCache = newValue.map { $0 as NSArray } }
    }
    var horos_ROIsAndKeyImagesCacheSameSeries: Bool {
        get { selectionCache.ROIsAndKeyImagesCacheSameSeries }
        set { selectionCache.ROIsAndKeyImagesCacheSameSeries = newValue }
    }
    var horos_ROIsImagesCache: [Any]? {
        get { selectionCache.ROIsImagesCache as? [Any] }
        set { selectionCache.ROIsImagesCache = newValue.map { $0 as NSArray } }
    }
    var horos_ROIsImagesCacheSameSeries: Bool {
        get { selectionCache.ROIsImagesCacheSameSeries }
        set { selectionCache.ROIsImagesCacheSameSeries = newValue }
    }
    var horos_searchField: NSSearchField? { windowOutlets.searchField }
    nonisolated var horos_searchType: Int32 {
        get { studyListState.searchType }
        set { studyListState.searchType = newValue }
    }
    var horos_searchView: NSView? { windowOutlets.searchView }
    var horos_setDCMDone: Bool {
        get { previewState.setDCMDone }
        set { previewState.setDCMDone = newValue }
    }
    var horos_splitAlbums: NSSplitView? { windowOutlets.splitAlbums }
    var horos_splitComparative: NSSplitView? {
        get { windowOutlets.splitComparative }
        set { windowOutlets.splitComparative = newValue }
    }
    var horos_splitDrawer: NSSplitView? { windowOutlets.splitDrawer }
    var horos_splitViewHorz: NSSplitView? { windowOutlets.splitViewHorz }
    var horos_splitViewVert: NSSplitView? { windowOutlets.splitViewVert }
    var horos_thumbnailsScrollView: NSScrollView? { windowOutlets.thumbnailsScrollView }
    nonisolated var horos_timeIntervalEnd: Date? {
        get { studyListState.timeIntervalEnd }
        set { studyListState.timeIntervalEnd = newValue }
    }
    nonisolated var horos_timeIntervalStart: Date? {
        get { studyListState.timeIntervalStart }
        set { studyListState.timeIntervalStart = newValue }
    }
    var horos_timeIntervalView: NSView? { windowOutlets.timeIntervalView }
    var horos_toolbar: NSToolbar? {
        get { windowState.toolbar }
        set { windowState.toolbar = newValue }
    }
    var horos_toolbarSearchItem: NSToolbarItem? {
        get { windowState.toolbarSearchItem }
        set { windowState.toolbarSearchItem = newValue }
    }
    var horos_waitOpeningWindow: WaitRendering? {
        get { viewerOpeningState.waitOpeningWindow }
        set { viewerOpeningState.waitOpeningWindow = newValue }
    }
    nonisolated var horos_cachedAlbums: [Any]? {
        get { albumState.cachedAlbums as? [Any] }
        set { albumState.cachedAlbums = newValue.map { $0 as NSArray } }
    }
    nonisolated var horos_cachedAlbumsIDs: [Any]? {
        get { albumState.cachedAlbumsIDs as? [Any] }
        set { albumState.cachedAlbumsIDs = newValue.map { $0 as NSArray } }
    }
    nonisolated var horos_cachedAlbumsContext: NSManagedObjectContext? {
        get { albumState.cachedAlbumsContext }
        set { albumState.cachedAlbumsContext = newValue }
    }
    nonisolated var horos_distantAlbumNoOfStudiesCache: NSMutableDictionary? { albumState.distantAlbumNoOfStudiesCache }
    var horos_matrixLoadIconsThread: Thread? {
        get { previewState.matrixLoadIconsThread }
        set { previewState.matrixLoadIconsThread = newValue }
    }
    nonisolated var horos_smartAlbumDistantArray: [Any]? {
        get { comparativeState.smartAlbumDistantArray as? [Any] }
        set { comparativeState.smartAlbumDistantArray = newValue.map { $0 as NSArray } }
    }
    var horos_cachedFilesForDatabaseOutlineSelectionSelectedFiles: NSMutableArray? {
        get { selectionCache.cachedFilesForDatabaseOutlineSelectionSelectedFiles }
        set { selectionCache.cachedFilesForDatabaseOutlineSelectionSelectedFiles = newValue }
    }
    var horos_cachedFilesForDatabaseOutlineSelectionCorrespondingObjects: NSMutableArray? {
        get { selectionCache.cachedFilesForDatabaseOutlineSelectionCorrespondingObjects }
        set { selectionCache.cachedFilesForDatabaseOutlineSelectionCorrespondingObjects = newValue }
    }
    var horos_cachedFilesForDatabaseOutlineSelectionTreeObjects: NSMutableSet? {
        get { selectionCache.cachedFilesForDatabaseOutlineSelectionTreeObjects }
        set { selectionCache.cachedFilesForDatabaseOutlineSelectionTreeObjects = newValue }
    }
    var horos_cachedFilesForDatabaseOutlineSelectionIndex: IndexSet? {
        get { selectionCache.cachedFilesForDatabaseOutlineSelectionIndex }
        set { selectionCache.cachedFilesForDatabaseOutlineSelectionIndex = newValue }
    }
    var horos_timeIntervalTypeValue: Int32 {
        get { studyListState.timeIntervalType }
        set { studyListState.timeIntervalType = newValue }
    }
    var horos_modalityFilterValue: String? {
        get { studyListState.modalityFilter }
        set { studyListState.modalityFilter = newValue }
    }
    var horos_modalityFilterMenu: NSPopUpButton? { windowOutlets.modalityFilterMenu }
    var horos_urlWindow: NSWindow? { sheetOutlets.urlWindow }
    var horos_urlString: NSTextField? { sheetOutlets.urlString }
    var horos_rebuildWindow: NSWindow? { sheetOutlets.rebuildWindow }
    var horos_rebuildType: NSMatrix? { sheetOutlets.rebuildType }
    var horos_noOfFilesToRebuild: NSTextField? { sheetOutlets.noOfFilesToRebuild }
    var horos_estimatedTime: NSTextField? { sheetOutlets.estimatedTime }
    var horos_newAlbum: NSWindow? { sheetOutlets.newAlbum }
    var horos_newAlbumName: NSTextField? { sheetOutlets.newAlbumName }
    nonisolated var horos_deleteQueueArray: NSMutableArray? {
        get { transferState.deleteQueueArray }
        set { transferState.deleteQueueArray = newValue }
    }
    nonisolated var horos_deleteQueue: NSRecursiveLock? {
        get { transferState.deleteQueue }
        set { transferState.deleteQueue = newValue }
    }
    nonisolated var horos_deleteInProgress: NSRecursiveLock? {
        get { transferState.deleteInProgress }
        set { transferState.deleteInProgress = newValue }
    }
    var horos_processorsLock: NSConditionLock? { transferState.processorsLock }
    var horos_CDpasswordWindow: NSWindow? { sheetOutlets.CDpasswordWindow }
    var horos_addStudiesToUserWindow: NSWindow? { sheetOutlets.addStudiesToUserWindow }
    var horos_notificationEmailArrayController: NSArrayController? { sheetOutlets.notificationEmailArrayController }
    var horos_rdPatientForm: NSView? { sheetOutlets.rdPatientForm }
    var horos_rdPixelForm: NSView? { sheetOutlets.rdPixelForm }
    var horos_rdVoxelForm: NSView? { sheetOutlets.rdVoxelForm }
    var horos_rdOffsetForm: NSView? { sheetOutlets.rdOffsetForm }
    var horos_rdPixelTypeMatrix: NSMatrix? { sheetOutlets.rdPixelTypeMatrix }
    var horos_rdAccessory: NSView? { sheetOutlets.rdAccessory }
    var horos_exportQuicktimeView: NSView? { sheetOutlets.exportQuicktimeView }
    var horos_exportHTMLButton: NSButton? { sheetOutlets.exportHTMLButton }
    var horos_exportAccessoryView: NSView? { sheetOutlets.exportAccessoryView }
    var horos_ZIPpasswordWindow: NSWindow? { sheetOutlets.ZIPpasswordWindow }
    var horos_notificationEmailWindow: NSWindow? { sheetOutlets.notificationEmailWindow }
    nonisolated var horos_passwordForExportEncryption: String? {
        get { self.passwordForExportEncryption }
        set { self.passwordForExportEncryption = newValue }
    }
    var horos_openSubSeriesFlag: Bool {
        get { viewerOpeningState.openSubSeriesFlag }
        set { viewerOpeningState.openSubSeriesFlag = newValue }
    }
    var horos_subFrom: Int32 {
        get { viewerOpeningState.subFrom }
        set { viewerOpeningState.subFrom = newValue }
    }
    var horos_subTo: Int32 {
        get { viewerOpeningState.subTo }
        set { viewerOpeningState.subTo = newValue }
    }
    var horos_subInterval: Int32 {
        get { viewerOpeningState.subInterval }
        set { viewerOpeningState.subInterval = newValue }
    }
    var horos_subSeriesWindowIsOn: Bool {
        get { viewerOpeningState.subSeriesWindowIsOn }
        set { viewerOpeningState.subSeriesWindowIsOn = newValue }
    }
    var horos_subOpenWindow: NSWindow? { sheetOutlets.subOpenWindow }
    var horos_subOpenMatrix3D: NSMatrix? { sheetOutlets.subOpenMatrix3D }
    var horos_subOpenMatrix4D: NSMatrix? { sheetOutlets.subOpenMatrix4D }
    var horos_supOpenButtons: NSMatrix? { sheetOutlets.supOpenButtons }
    var horos_subSeriesWindow: NSWindow? { sheetOutlets.subSeriesWindow }
    var horos_subSeriesOKButton: NSButton? { sheetOutlets.subSeriesOKButton }
    var horos_memoryMessage: NSTextField? { sheetOutlets.memoryMessage }
    var horos_leftIcon: NSImageView? { sheetOutlets.leftIcon }
    var horos_rightIcon: NSImageView? { sheetOutlets.rightIcon }
    var horos_searchInEntireDBResult: NSButton? { windowOutlets.searchInEntireDBResult }
    var horos_databaseDescription: NSTextField? { windowOutlets.databaseDescription }
    nonisolated var horos_distantEntireDBResultCount: Int32 {
        get { studyListState.distantEntireDBResultCount }
        set { studyListState.distantEntireDBResultCount = newValue }
    }
    nonisolated var horos_localEntireDBResultCount: Int32 {
        get { studyListState.localEntireDBResultCount }
        set { studyListState.localEntireDBResultCount = newValue }
    }
    nonisolated var horos_autoretrievingPACSOnDemandSmartAlbum: Bool {
        get { comparativeState.autoretrievingPACSOnDemandSmartAlbum }
        set { comparativeState.autoretrievingPACSOnDemandSmartAlbum = newValue }
    }
    nonisolated var horos_computingNumberOfStudiesForAlbums: Bool {
        get { albumState.computingNumberOfStudiesForAlbums }
        set { albumState.computingNumberOfStudiesForAlbums = newValue }
    }
    nonisolated var horos_lastComputeAlbumsForDistantStudies: TimeInterval {
        get { albumState.lastComputeAlbumsForDistantStudies }
        set { albumState.lastComputeAlbumsForDistantStudies = newValue }
    }
    nonisolated var horos_lastRefreshComparativeStudies: TimeInterval {
        get { comparativeState.lastRefreshComparativeStudies }
        set { comparativeState.lastRefreshComparativeStudies = newValue }
    }
    nonisolated var horos_lastRefreshSmartAlbumDistantStudies: TimeInterval {
        get { comparativeState.lastRefreshSmartAlbumDistantStudies }
        set { comparativeState.lastRefreshSmartAlbumDistantStudies = newValue }
    }
    nonisolated var horos_searchForComparativeStudiesLock: NSRecursiveLock? {
        get { comparativeState.searchForComparativeStudiesLock }
        set { comparativeState.searchForComparativeStudiesLock = newValue }
    }
    nonisolated var horos_smartAlbumDistantSearchArray: NSMutableArray? {
        get { comparativeState.smartAlbumDistantSearchArray }
        set { comparativeState.smartAlbumDistantSearchArray = newValue }
    }
    nonisolated var horos_comparativeStudySearchArray: NSMutableArray? {
        get { comparativeState.comparativeStudySearchArray }
        set { comparativeState.comparativeStudySearchArray = newValue }
    }
    nonisolated var horos_comparativePatientUID: String? { self.comparativePatientUID }
    nonisolated var horos_smartAlbumDistantName: String? {
        get { self.smartAlbumDistantName }
        set { self.smartAlbumDistantName = newValue }
    }
    nonisolated var horos_distantSearchString: String? {
        get { self.distantSearchString }
        set { self.distantSearchString = newValue }
    }
    nonisolated var horos_distantSearchType: Int32 {
        get { self.distantSearchType }
        set { self.distantSearchType = newValue }
    }
    nonisolated var horos_distantTimeIntervalStart: Date? {
        get { self.distantTimeIntervalStart }
        set { self.distantTimeIntervalStart = newValue }
    }
    nonisolated var horos_distantTimeIntervalEnd: Date? {
        get { self.distantTimeIntervalEnd }
        set { self.distantTimeIntervalEnd = newValue }
    }
    var horos_previousItem: Any? {
        get { studyListState.previousItem }
        set { studyListState.previousItem = newValue }
    }
    var horos_previousNoOfFiles: Int {
        get { studyListState.previousNoOfFiles }
        set { studyListState.previousNoOfFiles = newValue }
    }
    var horos_columnsMenu: NSMenu? {
        get { studyListState.columnsMenu }
        set { studyListState.columnsMenu = newValue }
    }
    var horos_refreshTimer: Timer? { windowState.refreshTimer }
    var horos_lastImportListRefresh: TimeInterval {
        get { albumState.lastImportListRefresh }
        set { albumState.lastImportListRefresh = newValue }
    }
    var horos_lastImportAlbumsRefresh: TimeInterval {
        get { albumState.lastImportAlbumsRefresh }
        set { albumState.lastImportAlbumsRefresh = newValue }
    }
    var horos_importListRefreshPending: Bool {
        get { albumState.importListRefreshPending }
        set { albumState.importListRefreshPending = newValue }
    }
    var horos_importAlbumsRefreshPending: Bool {
        get { albumState.importAlbumsRefreshPending }
        set { albumState.importAlbumsRefreshPending = newValue }
    }
    var horos_comparativeScrollView: NSView? { windowOutlets.comparativeScrollView }
    var horos_matrixView: NSView? { windowOutlets.matrixView }
    var horos_activeSends: NSMutableDictionary? {
        get { transferState.activeSends }
        set { transferState.activeSends = newValue }
    }
    var horos_sendLog: NSMutableArray? {
        get { transferState.sendLog }
        set { transferState.sendLog = newValue }
    }
    var horos_activeReceives: NSMutableDictionary? {
        get { transferState.activeReceives }
        set { transferState.activeReceives = newValue }
    }
    var horos_receiveLog: NSMutableArray? {
        get { transferState.receiveLog }
        set { transferState.receiveLog = newValue }
    }
    var horos_bonjourBrowser: BonjourBrowser? {
        get { windowState.bonjourBrowser }
        set { windowState.bonjourBrowser = newValue }
    }
    var horos_databaseWindowedFrame: NSRect {
        get { windowState.databaseWindowedFrame }
        set { windowState.databaseWindowedFrame = newValue }
    }
    var horos_pressedKeys: NSMutableString? { studyListState.pressedKeys }
    var horos_bonjourPasswordWindow: NSWindow? { sheetOutlets.bonjourPasswordWindow }
    var horos_imageTileMenu: NSMenu? { windowOutlets.imageTileMenu }
    var horos_timeFormat: DateFormatter? {
        get { windowState.TimeFormat }
        set { windowState.TimeFormat = newValue }
    }
    var horos_timeWithSecondsFormat: DateFormatter? {
        get { windowState.TimeWithSecondsFormat }
        set { windowState.TimeWithSecondsFormat = newValue }
    }
    var horos_dateTimeWithSecondsFormat: DateFormatter? {
        get { windowState.DateTimeWithSecondsFormat }
        set { windowState.DateTimeWithSecondsFormat = newValue }
    }

    // MARK: Derived state

    /// The folder of the database shown.
    nonisolated var horos_databaseBaseDirPath: String? { horos_databaseIvar?.baseDirPath }

    /// The modality the modality menu filters by: the filter when an item
    /// other than the first is chosen and it is not empty; nil otherwise. Read
    /// by the search threads: the menu's choice is read by key, as the former
    /// Objective-C read it, without the main thread.
    nonisolated var horos_modalityFilterForQueries: String? {
        let chosen = (windowOutlets.modalityFilterMenu?.value(forKey: "indexOfSelectedItem") as? Int) ?? 0
        guard chosen > 0, let modality = studyListState.modalityFilter, !modality.isEmpty else { return nil }
        return modality
    }

    /// The list's rows as the NSArray itself, which the data source reads row
    /// by row: not bridged to a Swift array at each row.
    var horos_outlineViewList: Any? { studyListState.outlineViewArray }

    /// The row a reload asks for, once per row of the list; nil out of bounds.
    func horos_outlineViewRow(at index: Int) -> Any? {
        guard let rows = studyListState.outlineViewArray, index >= 0, index < rows.count else { return nil }
        return rows.object(at: index)
    }

    /// The list set to the array itself, not a Swift array bridged back.
    func horos_storeOutlineViewArray(_ array: Any?) {
        studyListState.outlineViewArray = array as? NSArray
    }

    /// The list before a search of an album added the entire database's
    /// result, and its studies, set together.
    func horos_setOriginalOutlineViewArray(_ array: Any?) {
        studyListState.setOriginalOutlineViewArray(array as? NSArray)
    }

    /// Whether the list shows a patient's other studies after those it found.
    var horos_hasOriginalOutlineViewArray: Bool { studyListState.originalOutlineViewArray != nil }

    /// A study the list found rather than one of its patient's other studies.
    func horos_originalOutlineViewStudiesContains(_ object: Any?) -> Bool {
        guard let object else { return false }
        return studyListState.originalOutlineViewStudies?.contains(object) ?? false
    }

    /// previewPixGeneration++, under the lock the caller already holds.
    func horos_incrementPreviewPixGeneration() {
        previewState.previewPixGeneration &+= 1
    }

    // MARK: What the Objective-C writes for Swift

    /// The print: of the database outline, as -printDatabaseSelection: sent it
    /// when the selection may be printed: NSWindowController has no print: action.
    func horos_superPrint(_ sender: Any!) {
        windowOutlets.databaseOutline?.printView(sender)
    }

    /// An empty image for the preview (BrowserController+CAPI.m): Swift cannot
    /// send -myinitEmpty to an allocated, not yet initialized object.
    nonisolated static func horos_emptyPreviewPix() -> DCMPix! {
        return HorosBrowserEmptyPreviewPix()
    }

    /// The 10.0-style formatter -pdfPreview: names its file with, which Swift
    /// marks unavailable: DICOMCalendarDate's formatter of a calendar format
    /// (BrowserController+CAPI.m). Natural language is not used.
    static func horos_dateFormatter(withDateFormat format: String!, allowNaturalLanguage flag: Bool) -> DateFormatter! {
        return HorosBrowserCalendarFormatter(format)
    }

    /// The start of today, in the local time zone, in seconds since the
    /// reference date, computed with DICOMCalendarDate as the study list did
    /// (BrowserController+CAPI.m): Swift cannot reach NSCalendarDate's methods.
    static func horos_startOfTodayReferenceInterval() -> TimeInterval {
        return HorosBrowserStartOfTodayReferenceInterval()
    }

    /// A copy published only once complete (BrowserController+CAPI.m).
    nonisolated static func horos_copyFile(forPublication source: String?, toPath destination: String?) throws {
        var error: NSError?
        if !HorosBrowserCopyFileForPublication(source, destination, &error) { throw error ?? BrowserController.unexplainedFailure }
    }

    /// The database's compression or decompression of files, in place
    /// (BrowserController+CAPI.m): Swift sees the method under the name of its
    /// variant without an error.
    nonisolated static func horos_processFiles(atPaths paths: [Any]?, in database: DicomDatabase?, mode: Int32) throws {
        var error: NSError?
        if !HorosBrowserProcessFiles(paths, database, mode, &error) { throw error ?? BrowserController.unexplainedFailure }
    }

    /// A DICOMDIR of the folder (BrowserController+CAPI.m): Swift sees the
    /// method under the name of its variant without an error.
    nonisolated static func horos_createDicomDir(atDir path: String?) throws {
        var error: NSError?
        if !HorosBrowserCreateDicomDir(path, &error) { throw error ?? BrowserController.unexplainedFailure }
    }

    /// What Swift throws for a method that fails without saying why.
    nonisolated private static var unexplainedFailure: NSError {
        return NSError(domain: "Foundation._GenericObjCError", code: 0)
    }

    /// An alert sheet on the browser's window, with its OK button only.
    func horos_beginSourcesAlertSheet(withTitle title: String!, message: String!) {
        guard let window = self.window else { return }
        HorosAlertPanel.begin(withTitle: title, message: message ?? "", defaultButton: nil, alternateButton: nil, otherButton: nil,
                              modalFor: window, completionHandler: nil)
    }
}
