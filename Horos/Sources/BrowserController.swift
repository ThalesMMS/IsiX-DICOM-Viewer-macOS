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
import IsiXPreferences

/// The database window: its lists, the thumbnails and the preview, and the
/// database it shows.
///
/// The class coordinates; what it does is in its extensions, by
/// responsibility (BrowserController+StudyList.swift, +Thumbnails.swift,
/// +Sources.swift...). Its state and its views are the instance variables of
/// the former class, fields of this one; what the former class did not have
/// is in holders by subject (BrowserState.swift, BrowserOutlets.swift). The
/// rules that need neither AppKit nor the database (the sizes of text and
/// rows, the folder size, the parallel image conversion) are in IsiXDatabase
/// and IsiXImaging.
///
/// The Objective-C name, the selectors, the key-value coding and observing
/// keys, the nib connections, the notifications and the preference keys are
/// those of the former Objective-C class. BrowserController.h names it for
/// the Objective-C, which reads the generated interface.
@objc(BrowserController)
public class BrowserController: NSWindowController, NSMatrixDelegate, NSMenuDelegate, NSMenuItemValidation {

    // MARK: State

    nonisolated let sheetOutlets = BrowserSheetOutlets()
    nonisolated let previewState = BrowserPreviewState()
    nonisolated let studyListState = BrowserStudyListState()
    nonisolated let comparativeState = BrowserComparativeState()
    nonisolated let albumState = BrowserAlbumState()
    nonisolated let transferState = BrowserTransferState()
    nonisolated let viewerOpeningState = BrowserViewerOpeningState()
    nonisolated let olderInstanceVariables = BrowserOlderInstanceVariables()

    // MARK: Instance variables of the former plugin SDK

    // The state of the window is the instance variables of the former Horos
    // and OsiriX plugin SDK: a plugin built for it reads and writes each at
    // the offset the application exports, so each is a stored field of this
    // class with the C declaration's type, under its name after an
    // underscore, never private, lazy, weak or observed; a plugin's write
    // calls no setter. The views are those MainMenu.xib connects, nil until
    // the nib is loaded. nonisolated(unsafe): the thumbnails', search and
    // import threads read and write some of these, as they read the instance
    // variables, under the locks their users take, and key-value coding and
    // the nonisolated accessors read the others.
    nonisolated(unsafe) final var _databaseWindowedFrame: NSRect = .zero, _databaseIndexDictionary: NSMutableDictionary? = NSMutableDictionary(), _TimeFormat: DateFormatter?
    nonisolated(unsafe) final var _TimeWithSecondsFormat: DateFormatter?, _DateTimeWithSecondsFormat: DateFormatter?, _toolbar: NSToolbar?
    nonisolated(unsafe) final var _previewPix: NSMutableArray? = NSMutableArray(), _previewPixThumbnails: NSMutableArray? = NSMutableArray(), _activeSends: NSMutableDictionary?
    nonisolated(unsafe) final var _sendLog: NSMutableArray?, _activeReceives: NSMutableDictionary?, _receiveLog: NSMutableArray?, _logWindowController: LogWindowController?
    nonisolated(unsafe) final var _refreshTimer: Timer?, _loadPreviewIndex = 0, _previousNoOfFiles = 0, _splitViewHorz: NSSplitView?, _splitViewVert: NSSplitView?
    nonisolated(unsafe) final var _splitAlbums: NSSplitView?, _splitDrawer: NSSplitView?, _splitComparative: NSSplitView?, _splitViewVertDividerRatio: CGFloat = 0
    nonisolated(unsafe) final var _setDCMDone = false, _dontUpdatePreviewPane = false, _selectedAlbumName: NSString?, _outlineViewArray: NSArray? = NSArray()
    nonisolated(unsafe) final var _originalOutlineViewArray: NSArray?, _matrixViewArray: NSArray?, _searchString: NSString?, _databaseDescription: NSTextField?
    nonisolated(unsafe) final var _databaseOutline: MyOutlineView?, _oMatrix: BrowserMatrix?, _albumTable: NSTableView?, _bonjourSourcesBox: NSBox?
    nonisolated(unsafe) final var _sourcesArrayController: NSArrayController?, _sourcesTableView: NSTableView?, _sourcesHelper: AnyObject?, _bonjourBrowser: BonjourBrowser?
    nonisolated(unsafe) final var _animationSlider: NSSlider?, _animationCheck: NSButton?, _bottomSplit: NSSplitView?, _imageView: PreviewView?, _matrixView: NSView?
    nonisolated(unsafe) final var _comparativeScrollView: NSView?, _subFrom: Int32 = 0, _subTo: Int32 = 0, _subInterval: Int32 = 0, _subMax: Int32 = 0, _subOpenWindow: NSWindow?
    nonisolated(unsafe) final var _subOpenMatrix3D: NSMatrix?, _subOpenMatrix4D: NSMatrix?, _supOpenButtons: NSMatrix?, _subSeriesWindow: NSWindow?, _subSeriesOKButton: NSButton?
    nonisolated(unsafe) final var _memoryMessage: NSTextField?, _leftIcon: NSImageView?, _rightIcon: NSImageView?, _warningBox: NSBox?, _bonjourPasswordWindow: NSWindow?
    nonisolated(unsafe) final var _password: NSTextField?, _newAlbum: NSWindow?, _newAlbumName: NSTextField?, _rebuildWindow: NSWindow?, _rebuildType: NSMatrix?
    nonisolated(unsafe) final var _estimatedTime: NSTextField?, _noOfFilesToRebuild: NSTextField?, _warning: NSTextField?, _timeIntervalType: Int32 = 0
    nonisolated(unsafe) final var _timeIntervalStart: NSDate?, _timeIntervalEnd: NSDate?, _timeIntervalView: NSView?, _modalityFilter: NSString?
    nonisolated(unsafe) final var _modalityFilterMenu: NSPopUpButton?, _modalityFilterView: NSView?, _searchView: NSView?, _searchField: NSSearchField?
    nonisolated(unsafe) final var _searchInEntireDBResult: NSButton?, _toolbarSearchItem: NSToolbarItem?, _searchType: Int32 = 7, _imageTileMenu: NSMenu?, _urlWindow: NSWindow?
    nonisolated(unsafe) final var _CDpasswordWindow: NSWindow?, _ZIPpasswordWindow: NSWindow?, _urlString: NSTextField?, _rdPixelTypeMatrix: NSMatrix?, _rdAccessory: NSView?
    nonisolated(unsafe) final var _exportQuicktimeView: NSView?, _exportHTMLButton: NSButton?, _exportAccessoryView: NSView?, _compressionMatrix: NSMatrix?
    nonisolated(unsafe) final var _folderTree: NSMatrix?, _testPredicate: NSPredicate?, _DatabaseIsEdited = false, _isNetworkLogsActive = false
    nonisolated(unsafe) final var _thumbnailsScrollView: NSScrollView?, _fetchPredicate: NSPredicate?, _filterPredicate: NSPredicate?, _filterPredicateDescription: NSString?
    nonisolated(unsafe) final var _CDpassword: NSString?, _pathToEncryptedFile: NSString?, _passwordForExportEncryption: NSString?, _previousFlags: UInt = 0
    nonisolated(unsafe) final var _processorsLock: NSConditionLock? = NSConditionLock(condition: 1), _pressedKeys: NSMutableString? = NSMutableString(string: "")
    nonisolated(unsafe) final var _reportTemplatesView: NSView?, _reportTemplatesImageView: NSImageView?, _reportTemplatesListPopUpButton: NSPopUpButton?
    nonisolated(unsafe) final var _addStudiesToUserWindow: NSWindow?, _notificationEmailWindow: NSWindow?, _notificationEmailArrayController: NSArrayController?
    nonisolated(unsafe) final var _temporaryNotificationEmail: NSString?, _customTextNotificationEmail: NSString?, _notFoundImage: NSImage? = NSImage(named: "FileNotFound.tif")
    nonisolated(unsafe) final var _ROIsAndKeyImagesButtonAvailable = false, _openSubSeriesFlag = false, _openReparsedSeriesFlag = false
    nonisolated(unsafe) final var _pluginManagerController: PluginManagerController?, _waitOpeningWindow: WaitRendering?
    nonisolated(unsafe) final var _cachedFilesForDatabaseOutlineSelectionSelectedFiles: NSMutableArray?
    nonisolated(unsafe) final var _cachedFilesForDatabaseOutlineSelectionCorrespondingObjects: NSMutableArray?, _cachedFilesForDatabaseOutlineSelectionTreeObjects: NSMutableSet?
    nonisolated(unsafe) final var _cachedFilesForDatabaseOutlineSelectionIndex: NSIndexSet?, _lastROIsAndKeyImagesSelectedFiles: AnyObject?
    nonisolated(unsafe) final var _lastROIsImagesSelectedFiles: AnyObject?, _lastKeyImagesSelectedFiles: AnyObject?, _ROIsAndKeyImagesCache: NSArray?, _ROIsImagesCache: NSArray?
    nonisolated(unsafe) final var _KeyImagesCache: NSArray?, _ROIsAndKeyImagesCacheSameSeries = false, _ROIsImagesCacheSameSeries = false, activityTableViewOutlet: NSTableView?
    nonisolated(unsafe) final var _activityHelper: AnyObject?, _bannerSplit: NSSplitView?, _banner: NSButton?, _timeIntervalOfLastLoadIconsDisplayIcons: TimeInterval = 0
    nonisolated(unsafe) final var _subSeriesWindowIsOn = false, _comparativePatientUID: NSString?, _comparativeStudies: NSArray?, _comparativeTable: NSTableView?
    nonisolated(unsafe) final var _dontSelectStudyFromComparativeStudies = false, _lastRefreshComparativeStudies: TimeInterval = 0, _comparativeStudyWaited: DCMTKStudyQueryNode?
    nonisolated(unsafe) final var _comparativeStudyWaitedViewer: ViewerController?, _comparativeStudyWaitedTime: TimeInterval = 0, _comparativeStudyWaitedToOpen = false
    nonisolated(unsafe) final var _comparativeStudyWaitedToSelect = false, _smartAlbumDistantName: NSString?, _lastRefreshSmartAlbumDistantStudies: TimeInterval = 0
    nonisolated(unsafe) final var _distantStudyMessage: NSString?, _distantTimeIntervalStart: NSDate?, _distantTimeIntervalEnd: NSDate?, _distantSearchString: NSString?
    nonisolated(unsafe) final var _distantSearchType: Int32 = 0, _distantEntireDBResultCount: Int32 = 0, _localEntireDBResultCount: Int32 = 0, _previewPixGeneration: UInt = 0
    nonisolated(unsafe) final var _originalOutlineViewStudies: NSSet?, _refreshDeferredWhileEditing = false
    // The database shown, for a plugin that reads the variable: written with
    // the slot that keeps it for every thread, never retained here.
    nonisolated(unsafe) final unowned(unsafe) var _database: DicomDatabase?
    // The row last selected when it is a managed object, written with the
    // row the list keeps, which may be of another class (a study of a node).
    nonisolated(unsafe) final var _previousItem: NSManagedObject?

    // What the SDK declared and the browser no longer keeps: kept with the
    // exact type, at 0, NO and nil, read by nothing here and never retained.
    // The albums and their counts are the album catalog's; the delete queue,
    // the PACS On-Demand searches, the retrieves of the history, the load of
    // the thumbnails and the reports are their own types'; the columns menu
    // is the column controller's; the forms of the raw data sheet, the
    // preview's window policy and its redraw coalescer are kept under their
    // Swift classes; the rest has no counterpart.
    final unowned(unsafe) var _transferSyntax: NSString?, _dirArray: NSArray?, _sendQueue: NSMutableArray?, _reportFilesToCheck: NSMutableDictionary?, _curPreviewPix: DCMPix?
    final unowned(unsafe) var _distantAlbumNoOfStudiesCache: NSMutableDictionary?, _distantSearchThread: Thread?, _albumNoOfStudiesCache: NSMutableArray?, _cachedAlbums: NSArray?
    final unowned(unsafe) var _cachedAlbumsIDs: NSArray?, _cachedAlbumsContext: NSManagedObjectContext?, _columnsMenu: NSMenu?, _rdPatientForm: AnyObject?
    final unowned(unsafe) var _rdPixelForm: AnyObject?, _rdVoxelForm: AnyObject?, _rdOffsetForm: AnyObject?, _queueLock: NSConditionLock?, _deleteQueueArray: NSMutableArray?
    final unowned(unsafe) var _deleteQueue: NSRecursiveLock?, _deleteInProgress: NSRecursiveLock?, _matrixLoadIconsThread: Thread?
    final unowned(unsafe) var _searchForComparativeStudiesLock: NSRecursiveLock?, _comparativeStudySearchArray: NSMutableArray?, _comparativeRetrieveQueue: NSMutableArray?
    final unowned(unsafe) var _smartAlbumDistantArray: NSArray?, _smartAlbumDistantSearchArray: NSMutableArray?, _previewWindowPolicy: AnyObject?
    final unowned(unsafe) var _previewRedrawCoalescer: AnyObject?
    final var _previousBonjourIndex = 0, _lastComputeAlbumsForDistantStudies: TimeInterval = 0, _showAllImages = false, _reportToolbarItemType: Int32 = 0
    final var _rtstructProgressBar = false, _rtstructProgressPercent: Float = 0, _avoidRecursive = false, _waitCompressionAbort = false
    final var _computingNumberOfStudiesForAlbums = false, _autoretrievingPACSOnDemandSmartAlbum = false

    // MARK: Instance variables of older headers of the former plugin SDK

    // What only older headers of the SDK declared, each exported at the
    // offset of its field for the plugins built with such a header, with the
    // C declaration's type. The two timers are the browser's own. The others
    // of this group are copies: the state is the database's, the routing's,
    // the window controller's, the preferences' or that of the controller of
    // a sheet or window the browser opens, and BrowserOlderInstanceVariables
    // (BrowserState.swift) and those controllers write the copy wherever it
    // changes; nothing here reads one. nonisolated(unsafe): the database is
    // replaced through a nonisolated setter and modified by the import threads.
    nonisolated(unsafe) final var _timer: Timer?, _deleteQueueTimer: Timer?, _managedObjectContext: NSManagedObjectContext?, _managedObjectModel: NSManagedObjectModel?
    nonisolated(unsafe) final var _persistentStoreCoordinator: NSPersistentStoreCoordinator?, _bonjourManagedObjectContext: NSManagedObjectContext?
    nonisolated(unsafe) final var _userManagedObjectModel: NSManagedObjectModel?, _userManagedObjectContext: NSManagedObjectContext?
    nonisolated(unsafe) final var _userPersistentStoreCoordinator: NSPersistentStoreCoordinator?, _currentDatabasePath: NSString?, _fixedDocumentsDirectory: NSString?
    nonisolated(unsafe) final var _isCurrentDatabaseBonjour = false, _databaseLastModification: TimeInterval = 0, _COLUMN = 0, _needDBRefresh = false
    nonisolated(unsafe) final var _cfixedDocumentsDirectory = IsiXBrowserDirectoryPath(), _cfixedIncomingDirectory = IsiXBrowserDirectoryPath()
    nonisolated(unsafe) final var _cfixedTempNoIndexDirectory = IsiXBrowserDirectoryPath(), _cfixedIncomingNoIndexDirectory = IsiXBrowserDirectoryPath()
    nonisolated(unsafe) final var _DateTimeFormat: DateFormatter?, _DateOfBirthFormat: DateFormatter?, _numFmt: NumberFormatter?, _allColumns: NSArray?
    nonisolated(unsafe) final var _AtableView: NSTableView?, _bonjourServicesList: NSTableView?, _sourcesSplitView: NSSplitView?, _timeIntervalPopup: NSPopUpButton?
    nonisolated(unsafe) final var _activityCells: NSMutableArray?, _serverWindow: NSWindow?, _keyImageMatrix: NSMatrix?, _syntaxListOffis: NSPopUpButton?
    nonisolated(unsafe) final var _noImages: NSTextField?, _files2Send: NSMutableArray?, _destinationServer: AnyObject?, _smartWindow: NSWindow?
    nonisolated(unsafe) final var _editSmartAlbum: NSWindow?, _editSmartAlbumName: NSTextField?, _editSmartAlbumPredicate: NSPredicateEditor?
    nonisolated(unsafe) final var _persistentStoreCoordinatorDictionary: NSMutableDictionary?, _checkIncomingLock: NSRecursiveLock?, _decompressArray: NSMutableArray?
    nonisolated(unsafe) final var _autoroutingQueueTimer: Timer?, _bonjourTimer: Timer?, _checkBonjourUpToDateThreadLock: NSRecursiveLock?, _bonjourDownloading = false
    // Copies that are not retained: what they name outlives the copy (the
    // window, the shared panel of the custom interval, the publisher of the
    // application, the helper of the activity list) or takes it back as it
    // closes (the Query and Retrieve window, the burner).
    nonisolated(unsafe) final unowned(unsafe) var _mainWindow: NSWindow?, _customTimeIntervalWindow: NSWindow?, _customStart: NSDatePicker?
    nonisolated(unsafe) final unowned(unsafe) var _customEnd: NSDatePicker?, _customStart2: NSDatePicker?, _customEnd2: NSDatePicker?
    nonisolated(unsafe) final unowned(unsafe) var _bonjourPublisher: BonjourPublisher?, _activityObserver: NSObject?
    nonisolated(unsafe) final unowned(unsafe) var _burnerWindowController: BurnerWindowController?, _queryController: QueryController?

    // What those headers declared and nothing stands behind today: kept with
    // the exact type, at 0, NO and nil, read by nothing here and never
    // retained. The send sheet's other controls, the old sharing's settings
    // and second timer, the criteria of the smart album sheet, the drawer, the log
    // tables and the controls of the sub-series sheet left the window; the
    // incoming folder, the autorouting, the transcoding, the thumbnails and
    // the Dock icon are kept by types that have no timer, lock, list or flag
    // of these; two are of classes the application no longer has.
    final unowned(unsafe) var _AupdateStatsThread: Thread?, _DICOMSendTool: NSMatrix?, _IncomingTimer: Timer?, _addDICOMDIRButton: NSButton?, _albumDrawer: AnyObject?
    final unowned(unsafe) var albumNoOfStudiesCacheOfOlderSDK: NSMutableArray?, _anonymizerController: AnyObject?, _autoroutingInProgress: NSLock?
    final unowned(unsafe) var _autoroutingPreviousStudies: NSMutableDictionary?, _autoroutingQueue: NSLock?, _autoroutingQueueArray: NSMutableArray?
    final unowned(unsafe) var _bonjourPassword: NSTextField?, _bonjourPasswordCheck: NSButton?
    final unowned(unsafe) var _bonjourReportFilesToCheck: NSMutableDictionary?, _bonjourRunLoopTimer: Timer?, _bonjourServiceName: NSTextField?
    final unowned(unsafe) var _bonjourSharingCheck: NSButton?
    final unowned(unsafe) var _currentIcon: NSImage?, _databaseCleanerTimer: Timer?, _decompressArrayLock: NSLock?
    final unowned(unsafe) var _decompressThreadRunning: NSLock?, _downloadingOsiriXIcon: NSImage?, _draggedItems: NSMutableArray?, _editSmartAlbumQuery: NSTextField?
    final unowned(unsafe) var _enoughMem: NSBox?, _incomingProgress: NSProgressIndicator?, _logViewSplit: NSSplitView?, _matrixDisplayIcons: Timer?
    final unowned(unsafe) var _matrixLoadIconsLock: NSLock?, _mountedVolumes: NSArray?, _newFilesConditionLock: NSConditionLock?, _notEnoughMem: NSBox?
    final unowned(unsafe) var _receiveLogTable: NSTableView?, _searchWindow: NSWindow?
    final unowned(unsafe) var _segmentedAlbumButton: NSSegmentedControl?, _sendLogTable: NSTableView?, _sendStatusField: NSTextField?, _serverList: NSComboBox?
    final unowned(unsafe) var _standardOsiriXIcon: NSImage?, _structuredReportController: AnyObject?, _subSeriesFrom: NSTextField?, _subSeriesInterval: NSButton?
    final unowned(unsafe) var _subSeriesIntervalText: NSTextField?, _subSeriesSlider: NSSlider?, _subSeriesTo: NSTextField?, _syntaxList: NSComboBox?
    final unowned(unsafe) var _syntaxListOsiriX: NSPopUpButton?, _viewersListToRebuild: NSMutableArray?, _viewersListToReload: NSMutableArray?
    final unowned(unsafe) var _waitCompressionWindow: Wait?, _working: NSProgressIndicator?
    final var _DicomDirScanDepth: Int32 = 0, _checkForMountedFiles = false, _displayEmptyDatabase = false
    final var _dontLoadSelectionSource = false, _lastCheckForDirectory: TimeInterval = 0, _lastCheckIncoming: TimeInterval = 0, _lastSaved: TimeInterval = 0
    final var _mountedVolume = false, _newFilesInIncoming = false, _shouldDie = false, _threadRunning = false, _threadWillRunning = false
    final var _visibleScreenRect = IsiXBrowserScreenRects()

    /// The patient's history beside the thumbnails (PatientHistoryList.swift).
    lazy var patientHistory = PatientHistoryList(browser: self, search: pacsOnDemand,
                                                 preferences: PreferencesSource.process.preferences)

    /// The database preview: the thumbnails, the frame shown and its window,
    /// the animation slider (BrowserPreviewPane.swift).
    lazy var previewPane = BrowserPreviewPane(browser: self, processGraph: PreferencesSource.process.processGraph,
                                              preferences: PreferencesSource.process.preferences)

    /// The opening of viewers: the selection, the hanging protocols and
    /// workspaces, the external viewer, the sub-series sheets, the
    /// presentation states and the series left out (ViewerOpener.swift).
    lazy var viewerOpener = ViewerOpener(browser: self, processGraph: PreferencesSource.process.processGraph,
                                         preferences: PreferencesSource.process.preferences)

    /// The toolbar, its items and their validation, and the contextual menus
    /// and the validation of the browser's commands (BrowserToolbar.swift).
    lazy var browserToolbar = BrowserToolbar(browser: self, processGraph: PreferencesSource.process.processGraph,
                                             preferences: PreferencesSource.process.preferences)

    /// The images with ROIs and the key images of the selection, and the
    /// viewer that opens them (SelectionMarkedImages.swift).
    lazy var markedImages = SelectionMarkedImages(browser: self, processGraph: PreferencesSource.process.processGraph,
                                                  preferences: PreferencesSource.process.preferences)

    /// The study list, the albums table and their periodic refresh (StudyListContent.swift).
    lazy var studyList = StudyListContent(browser: self, processGraph: PreferencesSource.process.processGraph,
                                          preferences: PreferencesSource.process.preferences)

    /// The cells and the columns of the study list (StudyListCellStyler.swift,
    /// StudyListColumnController.swift).
    lazy var studyListCells = StudyListCellStyler(browser: self, preferences: PreferencesSource.process.preferences)
    lazy var studyListColumns = StudyListColumnController(browser: self, preferences: PreferencesSource.process.preferences)

    /// The reports of the studies and the report toolbar item (StudyReports.swift).
    lazy var reports = StudyReports(browser: self, preferences: PreferencesSource.process.preferences)

    /// The Sources list (SourceList.swift) and what it opens (DatabaseOpener.swift).
    lazy var sourceList = SourceList(browser: self, preferences: PreferencesSource.process.preferences)
    lazy var databaseOpener = DatabaseOpener(browser: self, preferences: PreferencesSource.process.preferences)

    /// Deleting from the study list and its delete queue (StudyDeletionJob.swift),
    /// merging and unifying studies (StudyMergeJob.swift), the comments filled
    /// from the images (AutoCommentRegenerator.swift), and the rebuilds, the
    /// cleanup preview and the surgical records of the database
    /// (BrowserController+DatabaseMaintenance.swift).
    lazy var deletion = StudyDeletionJob(browser: self, preferences: PreferencesSource.process.preferences)
    lazy var merging = StudyMergeJob(browser: self)
    lazy var autoComments = AutoCommentRegenerator(browser: self, preferences: PreferencesSource.process.preferences)
    lazy var maintenance = DatabaseMaintenance(browser: self)

    /// The import begun in the browser: archives, CDs and the compression of
    /// the selection (ArchiveImport.swift), what is dropped or chosen and the
    /// URLs (DroppedFilesImport.swift), and raw data (RawDataImport.swift).
    lazy var archiveImport = ArchiveImport(browser: self, preferences: PreferencesSource.process.preferences)
    lazy var droppedFiles = DroppedFilesImport(browser: self, preferences: PreferencesSource.process.preferences)
    lazy var rawDataImport = RawDataImport(browser: self, preferences: PreferencesSource.process.preferences)

    /// The database shown, read from any thread as the instance variable was;
    /// replaced on the main thread by -setDatabase:.
    private nonisolated let shownDatabase = DatabaseSlot()

    /// The database shown. The one replaced is autoreleased, as the former
    /// setter did: a caller that read it keeps it until its pool drains.
    nonisolated var horos_databaseIvar: DicomDatabase? {
        get { shownDatabase.database }
        set {
            if let replaced = shownDatabase.exchange(with: newValue) { _ = Unmanaged.passRetained(replaced).autorelease() }
            olderInstanceVariables.show(newValue, in: self)
        }
    }

    // MARK: The properties of the former header

    /// Read from any thread, as it always was; set on the main thread, where
    /// -horos_switchToDatabase: closes the viewers and shows it everywhere.
    /// Observers are told by that method, not by the setter.
    @objc public nonisolated dynamic var database: DicomDatabase! {
        get { shownDatabase.database }
        set {
            // The database is handed to the main thread's method on the main thread.
            nonisolated(unsafe) let database = newValue
            MainActor.assumeIsolated { horos_switchToDatabase(database) }
        }
    }

    public override class func automaticallyNotifiesObservers(forKey key: String) -> Bool {
        if key == "database" { return false }
        return super.automaticallyNotifiesObservers(forKey: key)
    }

    /// Why the last study asked for did not open, for the caller that is
    /// waiting on it to say so. Cleared as soon as one is selected.
    @objc public nonisolated dynamic var lastStudyNotOpenedReason: String! {
        get { viewerOpeningState.lastStudyNotOpenedReason }
        set { viewerOpeningState.lastStudyNotOpenedReason = newValue }
    }

    @objc public nonisolated var sources: NSArrayController! { _sourcesArrayController }
    @objc public nonisolated var TimeFormat: DateFormatter! { _TimeFormat }
    @objc public nonisolated var TimeWithSecondsFormat: DateFormatter! { _TimeWithSecondsFormat }
    @objc public nonisolated var DateTimeWithSecondsFormat: DateFormatter! { _DateTimeWithSecondsFormat }
    @objc public nonisolated var matrixViewArray: [Any]! { _matrixViewArray as? [Any] }
    @objc public nonisolated var oMatrix: NSMatrix! { _oMatrix }
    @objc public nonisolated var databaseOutline: MyOutlineView! { _databaseOutline }
    @objc public nonisolated var albumTable: NSTableView! { _albumTable }
    @objc public nonisolated var bonjourSourcesBox: NSBox! { _bonjourSourcesBox }
    @objc public nonisolated var bonjourBrowser: BonjourBrowser! { _bonjourBrowser }
    @objc public nonisolated var pluginManagerController: PluginManagerController! { _pluginManagerController }
    @objc public nonisolated var databaseIndexDictionary: NSMutableDictionary! { _databaseIndexDictionary }

    // The fields of the sheets are bound to these.
    @objc(CDpassword) public nonisolated dynamic var cDpassword: String! {
        get { _CDpassword as String? }
        set { _CDpassword = newValue as NSString? }
    }
    @objc public nonisolated dynamic var pathToEncryptedFile: String! {
        get { _pathToEncryptedFile as String? }
        set { _pathToEncryptedFile = newValue as NSString? }
    }
    @objc public nonisolated dynamic var passwordForExportEncryption: String! {
        get { _passwordForExportEncryption as String? }
        set { _passwordForExportEncryption = newValue as NSString? }
    }
    @objc public nonisolated dynamic var temporaryNotificationEmail: String! {
        get { _temporaryNotificationEmail as String? }
        set { _temporaryNotificationEmail = newValue as NSString? }
    }
    @objc public nonisolated dynamic var customTextNotificationEmail: String! {
        get { _customTextNotificationEmail as String? }
        set { _customTextNotificationEmail = newValue as NSString? }
    }

    // The patient's history and the PACS On-Demand searches.
    @objc public nonisolated dynamic var comparativePatientUID: String! {
        get { _comparativePatientUID as String? }
        set { _comparativePatientUID = newValue as NSString? }
    }
    @objc public nonisolated dynamic var smartAlbumDistantName: String! {
        get { _smartAlbumDistantName as String? }
        set { _smartAlbumDistantName = newValue as NSString? }
    }
    /// The text the thumbnails show for a distant study; bound in the window.
    @objc public nonisolated dynamic var distantStudyMessage: String! {
        get { _distantStudyMessage as String? }
        set { _distantStudyMessage = newValue as NSString? }
    }
    @objc public nonisolated dynamic var distantSearchString: String! {
        get { _distantSearchString as String? }
        set { _distantSearchString = newValue as NSString? }
    }
    @objc public nonisolated dynamic var distantSearchType: Int32 {
        get { _distantSearchType }
        set { _distantSearchType = newValue }
    }
    @objc public nonisolated dynamic var distantTimeIntervalStart: Date! {
        get { _distantTimeIntervalStart as Date? }
        set { _distantTimeIntervalStart = newValue as NSDate? }
    }
    @objc public nonisolated dynamic var distantTimeIntervalEnd: Date! {
        get { _distantTimeIntervalEnd as Date? }
        set { _distantTimeIntervalEnd = newValue as NSDate? }
    }
    @objc public nonisolated dynamic var comparativeStudies: [Any]! {
        get { _comparativeStudies as? [Any] }
        set { _comparativeStudies = newValue.map { $0 as NSArray } }
    }

    /// Read on any thread: the album an import adds its studies to.
    @objc public nonisolated dynamic var selectedAlbumName: String! {
        get { _selectedAlbumName as String? }
        set { _selectedAlbumName = newValue as NSString? }
    }

    // The study list's predicates.
    @objc public nonisolated dynamic var fetchPredicate: NSPredicate! {
        get { _fetchPredicate }
        set { _fetchPredicate = newValue }
    }
    @objc public nonisolated dynamic var testPredicate: NSPredicate! {
        get { _testPredicate }
        set { _testPredicate = newValue }
    }
    @objc public nonisolated var filterPredicate: NSPredicate! { _filterPredicate }
    @objc public nonisolated var filterPredicateDescription: String! { _filterPredicateDescription as String? }

    /// The modality menu's filter; setting it refreshes the list
    /// (BrowserController+Search.swift).
    @objc public nonisolated dynamic var modalityFilter: String! {
        get { _modalityFilter as String? }
        set { MainActor.assumeIsolated { horos_applyModalityFilter(newValue) } }
    }

    /// The time interval menu's choice; setting it refreshes the list
    /// (BrowserController+Search.swift).
    @objc public nonisolated dynamic var timeIntervalType: Int32 {
        get { _timeIntervalType }
        set { MainActor.assumeIsolated { horos_applyTimeIntervalType(newValue) } }
    }

    // The sub-selection sheet's fields are bound to these, through an object
    // controller whose content is the browser. Their setters are the sheet's
    // actions, -setSubFrom:, -setSubTo: and -setSubInterval:
    // (BrowserController+SubSeriesSheets.swift).
    @objc public nonisolated var subFrom: Int32 { _subFrom }
    @objc public nonisolated var subTo: Int32 { _subTo }
    @objc public nonisolated var subInterval: Int32 { _subInterval }
    @objc public nonisolated dynamic var subMax: Int32 {
        get { _subMax }
        set { _subMax = newValue }
    }

    // MARK: Life cycle

    public override init(window: NSWindow?) {
        AppController.initializeAppController()

        super.init(window: window)

        forgetTemporarySources()

        // Shift and Option are read in main, before the plugins are loaded.
        if ProtectedMode.isActive {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Protected Mode", comment: ""), message: ProtectedMode.alertMessage,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        _searchType = 7
        self.timeIntervalType = 0
        BrowserController.current = self

        let defaults = UserDefaults.standard
        // The default location is the one opened; one given at the launch is not stored.
        ApplicationPreferencesSetup.useDefaultDatabaseLocation()

        if !DatabaseFirstUse.hasPendingChoice {
            self.database = BrowserController.activeLocalDatabaseInOperation()
        }

        _timer = Timer.scheduledTimer(timeInterval: 0.15, target: self, selector: #selector(previewPerformAnimation(_:)), userInfo: self, repeats: true)

        if defaults.integer(forKey: "LISTENERCHECKINTERVAL") < 1 {
            defaults.set(1, forKey: "LISTENERCHECKINTERVAL")
        }
        if !defaults[NetworkPreferences.hidesListenerErrors] {
            _refreshTimer = Timer.scheduledTimer(timeInterval: 5 * 60, target: self, selector: #selector(refreshDatabase(_:)),
                                                            userInfo: self, repeats: true)
        }
        _deleteQueueTimer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(emptyDeleteQueue(_:)), userInfo: self, repeats: true)
        Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(refreshComparativeStudiesIfNeeded(_:)),
                             userInfo: self, repeats: true)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateReportToolbarIcon(_:)), name: .OsirixReportModeChanged, object: nil)
        center.addObserver(self, selector: #selector(alternateButtonPressed(_:)), name: .OsirixAlternateButtonPressed, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("The browser is made by MainMenu.xib with -init")
    }

    isolated deinit {
        deallocActivity()
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: OsirixBonjourSharingIsActiveDefaultsKey)
        deallocSources()

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(applyPreviewWindowForCurrentFrame), object: nil)
        _imageView?.windowDelegate = nil
        previewState.previewRedrawCoalescer?.cancel()
        previewState.previewRedrawCoalescer = nil
        previewState.previewWindowPolicy = nil
    }

    /// Removes the identical local sources, and the ones that were never worth
    /// remembering: a CD is copied under the user's temporary directory and
    /// opened from there, so inserting one left a permanent entry pointing at
    /// a path that stops existing when the media is ejected, or when the
    /// system empties its temporary folders on its own.
    private func forgetTemporarySources() {
        let defaults = UserDefaults.standard
        let entries = (defaults.array(forKey: "localDatabasePaths") ?? []).compactMap { $0 as? [String: Any] }
        for dropped in SourceLocation.temporaryEntries(in: entries, pathKey: "Path") {
            NSLog("---- sources: forgetting %@; it is in a temporary location, not a database to come back to", dropped)
        }
        defaults.set(SourceLocation.permanentEntries(in: entries, pathKey: "Path"), forKey: "localDatabasePaths")
    }

    /// The active local database, opened as an operation of the current thread,
    /// whose name is kept.
    private static func activeLocalDatabaseInOperation() -> DicomDatabase? {
        let thread = Thread.current
        let oldThreadName = thread.name
        var database: DicomDatabase?
        thread.enterOperation()
        autoreleasepool {
            if let exception = HorosObjCException.caught({ database = DicomDatabase.activeLocal() }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController initWithWindow:]")
            }
        }
        thread.exitOperation()
        thread.name = oldThreadName
        return database
    }
}
