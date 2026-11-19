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
// accessor reads or writes the field of the former instance variable, as the
// Swift value the extensions use where the variable is an Objective-C object,
// or the holder of what the former class did not have (BrowserState.swift,
// BrowserOutlets.swift). The accessors read from any thread are nonisolated,
// as they were; the others are the main thread's.

extension BrowserController {

    var horos_sourcesTableView: NSTableView? { _sourcesTableView }
    var horos_sourcesHelper: Any! {
        get { _sourcesHelper }
        set { _sourcesHelper = newValue.map { $0 as AnyObject } }
    }
    var horos_activityTableView: NSTableView? { activityTableViewOutlet }
    var horos_activityHelper: Any! {
        get { _activityHelper }
        set { _activityHelper = newValue.map { $0 as AnyObject } }
    }
    /// The counts of the albums table, which the database switch forgets.
    nonisolated var horos_albumNoOfStudiesCache: AlbumCountsAccess? { AlbumCountsAccess(catalog: albumState.catalog) }
    var horos_bottomSplit: NSSplitView? { _bottomSplit }
    var horos_filterPredicate: NSPredicate? {
        get { _filterPredicate }
        set { _filterPredicate = newValue }
    }
    var horos_filterPredicateDescription: String? {
        get { _filterPredicateDescription as String? }
        set { _filterPredicateDescription = newValue as NSString? }
    }
    var horos_refreshDeferredWhileEditing: Bool {
        get { _refreshDeferredWhileEditing }
        set { _refreshDeferredWhileEditing = newValue }
    }
    nonisolated var horos_searchString: String? {
        get { _searchString as String? }
        set { _searchString = newValue as NSString? }
    }
    var horos_splitViewVertDividerRatio: CGFloat {
        get { _splitViewVertDividerRatio }
        set { _splitViewVertDividerRatio = newValue }
    }
    nonisolated var horos_albumTable: NSTableView? { _albumTable }
    var horos_animationCheck: NSButton? { _animationCheck }
    var horos_animationSlider: NSSlider? { _animationSlider }
    var horos_banner: NSButton? { _banner }
    var horos_bannerSplit: NSSplitView? { _bannerSplit }
    var horos_comparativeStudies: [Any]? { _comparativeStudies as? [Any] }
    var horos_comparativeStudyWaited: DCMTKStudyQueryNode? {
        get { _comparativeStudyWaited }
        set { _comparativeStudyWaited = newValue }
    }
    var horos_comparativeStudyWaitedTime: TimeInterval {
        get { _comparativeStudyWaitedTime }
        set { _comparativeStudyWaitedTime = newValue }
    }
    var horos_comparativeStudyWaitedToOpen: Bool {
        get { _comparativeStudyWaitedToOpen }
        set { _comparativeStudyWaitedToOpen = newValue }
    }
    var horos_comparativeStudyWaitedToSelect: Bool {
        get { _comparativeStudyWaitedToSelect }
        set { _comparativeStudyWaitedToSelect = newValue }
    }
    var horos_comparativeStudyWaitedViewer: ViewerController? {
        get { _comparativeStudyWaitedViewer }
        set { _comparativeStudyWaitedViewer = newValue }
    }
    var horos_comparativeTable: NSTableView? { _comparativeTable }
    var horos_compressionMatrix: NSMatrix? { _compressionMatrix }
    var horos_DatabaseIsEdited: Bool {
        get { _DatabaseIsEdited }
        set { _DatabaseIsEdited = newValue }
    }
    var horos_databaseOutline: MyOutlineView? { _databaseOutline }
    var horos_dontSelectStudyFromComparativeStudies: Bool {
        get { _dontSelectStudyFromComparativeStudies }
        set { _dontSelectStudyFromComparativeStudies = newValue }
    }
    var horos_dontUpdatePreviewPane: Bool {
        get { _dontUpdatePreviewPane }
        set { _dontUpdatePreviewPane = newValue }
    }
    var horos_folderTree: NSMatrix? { _folderTree }
    var horos_imageView: PreviewView? { _imageView }
    nonisolated var horos_isNetworkLogsActive: Bool {
        get { _isNetworkLogsActive }
        set { _isNetworkLogsActive = newValue }
    }
    var horos_KeyImagesCache: [DicomImage]? {
        get { _KeyImagesCache as? [DicomImage] }
        set { _KeyImagesCache = newValue as NSArray? }
    }
    var horos_lastKeyImagesSelectedFiles: [NSObject]? {
        get { _lastKeyImagesSelectedFiles as? [NSObject] }
        set { _lastKeyImagesSelectedFiles = newValue as NSArray? }
    }
    var horos_lastROIsAndKeyImagesSelectedFiles: [NSObject]? {
        get { _lastROIsAndKeyImagesSelectedFiles as? [NSObject] }
        set { _lastROIsAndKeyImagesSelectedFiles = newValue as NSArray? }
    }
    var horos_lastROIsImagesSelectedFiles: [NSObject]? {
        get { _lastROIsImagesSelectedFiles as? [NSObject] }
        set { _lastROIsImagesSelectedFiles = newValue as NSArray? }
    }
    var horos_loadPreviewIndex: Int {
        get { _loadPreviewIndex }
        set { _loadPreviewIndex = newValue }
    }
    var horos_logWindowController: LogWindowController? {
        get { _logWindowController }
        set { _logWindowController = newValue }
    }
    var horos_matrixViewArray: [Any]? {
        get { _matrixViewArray as? [Any] }
        set { _matrixViewArray = newValue.map { $0 as NSArray } }
    }
    var horos_modalityFilterView: NSView? { _modalityFilterView }
    nonisolated var horos_notFoundImage: NSImage? { _notFoundImage }
    var horos_oMatrix: BrowserMatrix? { _oMatrix }
    var horos_openReparsedSeriesFlag: Bool {
        get { _openReparsedSeriesFlag }
        set { _openReparsedSeriesFlag = newValue }
    }
    var horos_originalOutlineViewArray: [Any]? { _originalOutlineViewArray as? [Any] }
    var horos_outlineViewArray: [Any]? {
        get { _outlineViewArray as? [Any] }
        set { _outlineViewArray = newValue.map { $0 as NSArray } }
    }
    var horos_password: NSTextField? { _password }
    nonisolated var horos_previewPix: NSMutableArray? {
        get { _previewPix }
        set { _previewPix = newValue }
    }
    nonisolated var horos_previewPixGeneration: UInt { _previewPixGeneration }
    nonisolated var horos_previewPixThumbnails: NSMutableArray? { _previewPixThumbnails }
    var horos_previewRedrawCoalescer: PreviewRedrawCoalescer? {
        get { previewState.previewRedrawCoalescer }
        set { previewState.previewRedrawCoalescer = newValue }
    }
    var horos_previewWindowPolicy: PreviewWindowPolicy? {
        get { previewState.previewWindowPolicy }
        set { previewState.previewWindowPolicy = newValue }
    }
    var horos_previousFlags: UInt {
        get { _previousFlags }
        set { _previousFlags = newValue }
    }
    /// The reports opened in the session, which the database switch and the
    /// deletion of studies forget.
    var horos_reportFilesToCheck: OpenReports? { reports.openReports }
    var horos_reportTemplatesImageView: NSImageView? { _reportTemplatesImageView }
    var horos_reportTemplatesListPopUpButton: NSPopUpButton? { _reportTemplatesListPopUpButton }
    var horos_reportTemplatesView: NSView? { _reportTemplatesView }
    var horos_ROIsAndKeyImagesButtonAvailable: Bool {
        get { _ROIsAndKeyImagesButtonAvailable }
        set { _ROIsAndKeyImagesButtonAvailable = newValue }
    }
    var horos_ROIsAndKeyImagesCache: [DicomImage]? {
        get { _ROIsAndKeyImagesCache as? [DicomImage] }
        set { _ROIsAndKeyImagesCache = newValue as NSArray? }
    }
    var horos_ROIsAndKeyImagesCacheSameSeries: Bool {
        get { _ROIsAndKeyImagesCacheSameSeries }
        set { _ROIsAndKeyImagesCacheSameSeries = newValue }
    }
    var horos_ROIsImagesCache: [DicomImage]? {
        get { _ROIsImagesCache as? [DicomImage] }
        set { _ROIsImagesCache = newValue as NSArray? }
    }
    var horos_ROIsImagesCacheSameSeries: Bool {
        get { _ROIsImagesCacheSameSeries }
        set { _ROIsImagesCacheSameSeries = newValue }
    }
    var horos_searchField: NSSearchField? { _searchField }
    nonisolated var horos_searchType: Int32 {
        get { _searchType }
        set { _searchType = newValue }
    }
    var horos_searchView: NSView? { _searchView }
    var horos_setDCMDone: Bool {
        get { _setDCMDone }
        set { _setDCMDone = newValue }
    }
    var horos_splitAlbums: NSSplitView? { _splitAlbums }
    var horos_splitComparative: NSSplitView? {
        get { _splitComparative }
        set { _splitComparative = newValue }
    }
    var horos_splitDrawer: NSSplitView? { _splitDrawer }
    var horos_splitViewHorz: NSSplitView? { _splitViewHorz }
    var horos_splitViewVert: NSSplitView? { _splitViewVert }
    var horos_thumbnailsScrollView: NSScrollView? { _thumbnailsScrollView }
    nonisolated var horos_timeIntervalEnd: Date? {
        get { _timeIntervalEnd as Date? }
        set { _timeIntervalEnd = newValue as NSDate? }
    }
    nonisolated var horos_timeIntervalStart: Date? {
        get { _timeIntervalStart as Date? }
        set { _timeIntervalStart = newValue as NSDate? }
    }
    var horos_timeIntervalView: NSView? { _timeIntervalView }
    var horos_toolbar: NSToolbar? {
        get { _toolbar }
        set { _toolbar = newValue }
    }
    var horos_toolbarSearchItem: NSToolbarItem? {
        get { _toolbarSearchItem }
        set { _toolbarSearchItem = newValue }
    }
    var horos_waitOpeningWindow: WaitRendering? {
        get { _waitOpeningWindow }
        set { _waitOpeningWindow = newValue }
    }
    /// The context the albums were fetched in: none is kept, and setting it
    /// (to nil) makes the next request fetch them again.
    nonisolated var horos_cachedAlbumsContext: NSManagedObjectContext? {
        get { nil }
        set { albumState.catalog.forgetAlbums() }
    }
    /// The smart albums' distant studies, forgotten with the counts.
    nonisolated var horos_distantAlbumNoOfStudiesCache: AlbumCountsAccess? { AlbumCountsAccess(catalog: albumState.catalog) }
    /// The load of the thumbnails in progress, which a new selection and the
    /// database switching cancel; under its former name, as the thread it was.
    var horos_matrixLoadIconsThread: ThumbnailLoad? {
        get { previewState.thumbnailLoad }
        set { previewState.thumbnailLoad = newValue }
    }
    var horos_cachedFilesForDatabaseOutlineSelectionSelectedFiles: NSMutableArray? {
        get { _cachedFilesForDatabaseOutlineSelectionSelectedFiles }
        set { _cachedFilesForDatabaseOutlineSelectionSelectedFiles = newValue }
    }
    var horos_cachedFilesForDatabaseOutlineSelectionCorrespondingObjects: NSMutableArray? {
        get { _cachedFilesForDatabaseOutlineSelectionCorrespondingObjects }
        set { _cachedFilesForDatabaseOutlineSelectionCorrespondingObjects = newValue }
    }
    var horos_cachedFilesForDatabaseOutlineSelectionTreeObjects: NSMutableSet? {
        get { _cachedFilesForDatabaseOutlineSelectionTreeObjects }
        set { _cachedFilesForDatabaseOutlineSelectionTreeObjects = newValue }
    }
    var horos_cachedFilesForDatabaseOutlineSelectionIndex: IndexSet? {
        get { _cachedFilesForDatabaseOutlineSelectionIndex as IndexSet? }
        set { _cachedFilesForDatabaseOutlineSelectionIndex = newValue as NSIndexSet? }
    }
    var horos_timeIntervalTypeValue: Int32 {
        get { _timeIntervalType }
        set { _timeIntervalType = newValue }
    }
    var horos_modalityFilterValue: String? {
        get { _modalityFilter as String? }
        set { _modalityFilter = newValue as NSString? }
    }
    var horos_modalityFilterMenu: NSPopUpButton? { _modalityFilterMenu }
    var horos_urlWindow: NSWindow? { _urlWindow }
    var horos_urlString: NSTextField? { _urlString }
    var horos_rebuildWindow: NSWindow? { _rebuildWindow }
    var horos_rebuildType: NSMatrix? { _rebuildType }
    var horos_noOfFilesToRebuild: NSTextField? { _noOfFilesToRebuild }
    var horos_estimatedTime: NSTextField? { _estimatedTime }
    var horos_newAlbum: NSWindow? { _newAlbum }
    var horos_newAlbumName: NSTextField? { _newAlbumName }
    var horos_processorsLock: NSConditionLock? { _processorsLock }
    var horos_CDpasswordWindow: NSWindow? { _CDpasswordWindow }
    var horos_addStudiesToUserWindow: NSWindow? { _addStudiesToUserWindow }
    var horos_notificationEmailArrayController: NSArrayController? { _notificationEmailArrayController }
    var horos_rdPatientForm: NSView? { sheetOutlets.rdPatientForm }
    var horos_rdPixelForm: NSView? { sheetOutlets.rdPixelForm }
    var horos_rdVoxelForm: NSView? { sheetOutlets.rdVoxelForm }
    var horos_rdOffsetForm: NSView? { sheetOutlets.rdOffsetForm }
    var horos_rdPixelTypeMatrix: NSMatrix? { _rdPixelTypeMatrix }
    var horos_rdAccessory: NSView? { _rdAccessory }
    var horos_exportQuicktimeView: NSView? { _exportQuicktimeView }
    var horos_exportHTMLButton: NSButton? { _exportHTMLButton }
    var horos_exportAccessoryView: NSView? { _exportAccessoryView }
    var horos_ZIPpasswordWindow: NSWindow? { _ZIPpasswordWindow }
    var horos_notificationEmailWindow: NSWindow? { _notificationEmailWindow }
    nonisolated var horos_passwordForExportEncryption: String? {
        get { self.passwordForExportEncryption }
        set { self.passwordForExportEncryption = newValue }
    }
    var horos_openSubSeriesFlag: Bool {
        get { _openSubSeriesFlag }
        set { _openSubSeriesFlag = newValue }
    }
    var horos_subFrom: Int32 {
        get { _subFrom }
        set { _subFrom = newValue }
    }
    var horos_subTo: Int32 {
        get { _subTo }
        set { _subTo = newValue }
    }
    var horos_subInterval: Int32 {
        get { _subInterval }
        set { _subInterval = newValue }
    }
    var horos_subSeriesWindowIsOn: Bool {
        get { _subSeriesWindowIsOn }
        set { _subSeriesWindowIsOn = newValue }
    }
    var horos_subOpenWindow: NSWindow? { _subOpenWindow }
    var horos_subOpenMatrix3D: NSMatrix? { _subOpenMatrix3D }
    var horos_subOpenMatrix4D: NSMatrix? { _subOpenMatrix4D }
    var horos_supOpenButtons: NSMatrix? { _supOpenButtons }
    var horos_subSeriesWindow: NSWindow? { _subSeriesWindow }
    var horos_subSeriesOKButton: NSButton? { _subSeriesOKButton }
    var horos_memoryMessage: NSTextField? { _memoryMessage }
    var horos_leftIcon: NSImageView? { _leftIcon }
    var horos_rightIcon: NSImageView? { _rightIcon }
    var horos_searchInEntireDBResult: NSButton? { _searchInEntireDBResult }
    var horos_databaseDescription: NSTextField? { _databaseDescription }
    nonisolated var horos_distantEntireDBResultCount: Int32 {
        get { _distantEntireDBResultCount }
        set { _distantEntireDBResultCount = newValue }
    }
    nonisolated var horos_localEntireDBResultCount: Int32 {
        get { _localEntireDBResultCount }
        set { _localEntireDBResultCount = newValue }
    }
    nonisolated var horos_lastRefreshComparativeStudies: TimeInterval {
        get { _lastRefreshComparativeStudies }
        set { _lastRefreshComparativeStudies = newValue }
    }
    nonisolated var horos_lastRefreshSmartAlbumDistantStudies: TimeInterval {
        get { _lastRefreshSmartAlbumDistantStudies }
        set { _lastRefreshSmartAlbumDistantStudies = newValue }
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
        set {
            studyListState.previousItem = newValue
            _previousItem = newValue as? NSManagedObject
        }
    }
    var horos_previousNoOfFiles: Int {
        get { _previousNoOfFiles }
        set { _previousNoOfFiles = newValue }
    }
    var horos_columnsMenu: NSMenu? { studyListColumns.menu }
    var horos_refreshTimer: Timer? { _refreshTimer }
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
        set { albumState.importListRefreshPending = newValue; _needDBRefresh = newValue }
    }
    var horos_importAlbumsRefreshPending: Bool {
        get { albumState.importAlbumsRefreshPending }
        set { albumState.importAlbumsRefreshPending = newValue }
    }
    var horos_comparativeScrollView: NSView? { _comparativeScrollView }
    var horos_matrixView: NSView? { _matrixView }
    var horos_activeSends: NSMutableDictionary? {
        get { _activeSends }
        set { _activeSends = newValue }
    }
    var horos_sendLog: NSMutableArray? {
        get { _sendLog }
        set { _sendLog = newValue }
    }
    var horos_activeReceives: NSMutableDictionary? {
        get { _activeReceives }
        set { _activeReceives = newValue }
    }
    var horos_receiveLog: NSMutableArray? {
        get { _receiveLog }
        set { _receiveLog = newValue }
    }
    var horos_bonjourBrowser: BonjourBrowser? {
        get { _bonjourBrowser }
        set { _bonjourBrowser = newValue }
    }
    var horos_databaseWindowedFrame: NSRect {
        get { _databaseWindowedFrame }
        set { _databaseWindowedFrame = newValue }
    }
    var horos_pressedKeys: NSMutableString? { _pressedKeys }
    var horos_bonjourPasswordWindow: NSWindow? { _bonjourPasswordWindow }
    var horos_imageTileMenu: NSMenu? { _imageTileMenu }
    var horos_timeFormat: DateFormatter? {
        get { _TimeFormat }
        set { _TimeFormat = newValue }
    }
    var horos_timeWithSecondsFormat: DateFormatter? {
        get { _TimeWithSecondsFormat }
        set { _TimeWithSecondsFormat = newValue }
    }
    var horos_dateTimeWithSecondsFormat: DateFormatter? {
        get { _DateTimeWithSecondsFormat }
        set { _DateTimeWithSecondsFormat = newValue }
    }

    // MARK: Derived state

    /// The folder of the database shown.
    nonisolated var horos_databaseBaseDirPath: String? { horos_databaseIvar?.baseDirPath }

    /// The modality the modality menu filters by: the filter when an item
    /// other than the first is chosen and it is not empty; nil otherwise. Read
    /// by the search threads: the menu's choice is read by key, as the former
    /// Objective-C read it, without the main thread.
    nonisolated var horos_modalityFilterForQueries: String? {
        let chosen = (_modalityFilterMenu?.value(forKey: "indexOfSelectedItem") as? Int) ?? 0
        guard chosen > 0, let modality = _modalityFilter as String?, !modality.isEmpty else { return nil }
        return modality
    }

    /// The list's rows as the NSArray itself, which the data source reads row
    /// by row: not bridged to a Swift array at each row.
    var horos_outlineViewList: Any? { _outlineViewArray }

    /// The row a reload asks for, once per row of the list; nil out of bounds.
    func horos_outlineViewRow(at index: Int) -> Any? {
        guard let rows = _outlineViewArray, index >= 0, index < rows.count else { return nil }
        return rows.object(at: index)
    }

    /// The number of rows of the list.
    var horos_outlineViewRowCount: Int { _outlineViewArray?.count ?? 0 }

    /// The list set to the array itself, not a Swift array bridged back.
    func horos_storeOutlineViewArray(_ array: Any?) {
        _outlineViewArray = array as? NSArray
    }

    /// The list before a search of an album added the entire database's
    /// result, and its studies, set together.
    func horos_setOriginalOutlineViewArray(_ array: Any?) {
        _originalOutlineViewArray = array as? NSArray
        _originalOutlineViewStudies = _originalOutlineViewArray.map { NSSet(array: $0 as [AnyObject]) }
    }

    /// Whether the list shows a patient's other studies after those it found.
    var horos_hasOriginalOutlineViewArray: Bool { _originalOutlineViewArray != nil }

    /// A study the list found rather than one of its patient's other studies.
    func horos_originalOutlineViewStudiesContains(_ object: Any?) -> Bool {
        guard let object else { return false }
        return _originalOutlineViewStudies?.contains(object) ?? false
    }

    /// previewPixGeneration++, under the lock the caller already holds.
    func horos_incrementPreviewPixGeneration() {
        _previewPixGeneration &+= 1
    }

    // MARK: What the Objective-C writes for Swift

    /// The print: of the database outline, as -printDatabaseSelection: sent it
    /// when the selection may be printed: NSWindowController has no print: action.
    func horos_superPrint(_ sender: Any!) {
        _databaseOutline?.printView(sender)
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
