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

// The state of the browser, by what it is about. Each holder keeps the
// former instance variables of its part under their names, so that key-value
// coding reaches them as it reached the instance variables
// (BrowserController+KeyValueCoding.swift); the extensions read them through
// the horos_ accessors of BrowserController+StateAccess.swift. A holder is
// not tied to the main actor: the thumbnails', search and import threads read
// and write some of these values, as they read the instance variables,
// under the locks their users take.

/// The thumbnails and the preview of the selection.
final class BrowserPreviewState: NSObject, @unchecked Sendable {
    /// The images the preview shows; replaced with each selection.
    @objc var previewPix: NSMutableArray? = NSMutableArray()
    /// The thumbnails being made, guarded by @synchronized on it.
    @objc var previewPixThumbnails: NSMutableArray? = NSMutableArray()
    /// Which window the preview is showing and why: a DICOM default, one
    /// computed from the pixels, or an adjustment a person made.
    @objc var previewWindowPolicy: PreviewWindowPolicy?
    /// One preview decode per burst of scroll events, not one per notch.
    @objc var previewRedrawCoalescer: PreviewRedrawCoalescer?
    /// Bumped whenever previewPix is replaced, so a thumbnail batch published
    /// by a thread that started before the selection changed is discarded.
    @objc var previewPixGeneration: UInt = 0
    @objc var loadPreviewIndex: Int = 0
    @objc var setDCMDone = false
    @objc var dontUpdatePreviewPane = false
    /// The rows the thumbnails show.
    @objc var matrixViewArray: NSArray?
    @objc var matrixLoadIconsThread: Thread?
    @objc var timeIntervalOfLastLoadIconsDisplayIcons: TimeInterval = 0
    /// The thumbnail of a file that is not found.
    @objc var notFoundImage: NSImage? = NSImage(named: "FileNotFound.tif")
}

/// The study list: the rows shown, the search, the filters and the time
/// interval, the editing of a row.
final class BrowserStudyListState: NSObject, @unchecked Sendable {
    @objc var outlineViewArray: NSArray? = NSArray()
    /// The list before a search of an album added the entire database's
    /// result, and its studies, for membership while drawing.
    @objc private(set) var originalOutlineViewArray: NSArray?
    @objc private(set) var originalOutlineViewStudies: NSSet?
    @objc var searchString: String?
    @objc var searchType: Int32 = 7
    @objc var filterPredicate: NSPredicate?
    @objc var filterPredicateDescription: String?
    @objc var fetchPredicate: NSPredicate?
    @objc var testPredicate: NSPredicate?
    @objc var timeIntervalType: Int32 = 0
    @objc var timeIntervalStart: Date?
    @objc var timeIntervalEnd: Date?
    @objc var modalityFilter: String?
    @objc var previousItem: Any?
    @objc var previousNoOfFiles: Int = 0
    @objc var DatabaseIsEdited = false
    @objc var refreshDeferredWhileEditing = false
    @objc var columnsMenu: NSMenu?
    @objc var distantEntireDBResultCount: Int32 = 0
    @objc var localEntireDBResultCount: Int32 = 0
    /// The letters typed in the list to select a patient.
    @objc var pressedKeys: NSMutableString? = NSMutableString(string: "")
    @objc var previousFlags: UInt = 0

    func setOriginalOutlineViewArray(_ array: NSArray?) {
        originalOutlineViewArray = array
        originalOutlineViewStudies = array.map { NSSet(array: $0 as [AnyObject]) }
    }
}

/// The patient's history beside the thumbnails, the studies of the PACS
/// On-Demand smart albums and searches, and a study waited for from a node.
final class BrowserComparativeState: NSObject, @unchecked Sendable {
    @objc var searchForComparativeStudiesLock: NSRecursiveLock?
    /// The patient whose history is shown.
    @objc var comparativePatientUID: String?
    /// The queue of patient histories to search.
    @objc var comparativeStudySearchArray: NSMutableArray?
    /// The studies of the history list.
    @objc var comparativeStudies: NSArray?
    @objc var dontSelectStudyFromComparativeStudies = false
    @objc var lastRefreshComparativeStudies: TimeInterval = 0
    /// The studies being retrieved: a study is not retrieved twice at once.
    @objc var comparativeRetrieveQueue: NSMutableArray?
    /// The study to select or open when it arrives, its viewer, since when, and what to do.
    @objc var comparativeStudyWaited: DCMTKStudyQueryNode?
    @objc var comparativeStudyWaitedViewer: ViewerController?
    @objc var comparativeStudyWaitedTime: TimeInterval = 0
    @objc var comparativeStudyWaitedToOpen = false
    @objc var comparativeStudyWaitedToSelect = false
    @objc var smartAlbumDistantName: String?
    @objc var smartAlbumDistantArray: NSArray?
    /// The queue of smart albums to search.
    @objc var smartAlbumDistantSearchArray: NSMutableArray?
    @objc var lastRefreshSmartAlbumDistantStudies: TimeInterval = 0
    /// The text the thumbnails show for a distant study.
    @objc var distantStudyMessage: String?
    @objc var distantTimeIntervalStart: Date?
    @objc var distantTimeIntervalEnd: Date?
    @objc var distantSearchString: String?
    @objc var distantSearchType: Int32 = 0
    @objc var autoretrievingPACSOnDemandSmartAlbum = false
    @objc var distantSearchThread: Thread?
}

/// The albums: their study counts, local and on the nodes, the albums
/// fetched, and the refreshes an import asks for.
final class BrowserAlbumState: NSObject, @unchecked Sendable {
    @objc var albumNoOfStudiesCache: NSMutableArray? = NSMutableArray()
    @objc var distantAlbumNoOfStudiesCache: NSMutableDictionary? = NSMutableDictionary()
    @objc var lastComputeAlbumsForDistantStudies: TimeInterval = 0
    @objc var computingNumberOfStudiesForAlbums = false
    @objc var cachedAlbums: NSArray?
    @objc var cachedAlbumsIDs: NSArray?
    /// The context the albums were fetched in, not retained (compared only).
    @objc weak var cachedAlbumsContext: NSManagedObjectContext?
    /// The album an import adds its studies to; read on any thread.
    @objc var selectedAlbumName: String?
    @objc var lastImportListRefresh: TimeInterval = 0
    @objc var lastImportAlbumsRefresh: TimeInterval = 0
    @objc var importListRefreshPending = false
    @objc var importAlbumsRefreshPending = false
}

/// The files of the list's selection, and the images with ROIs and key
/// images of the last selections, kept until the selection changes.
final class BrowserSelectionCache: NSObject, @unchecked Sendable {
    @objc var cachedFilesForDatabaseOutlineSelectionSelectedFiles: NSMutableArray?
    @objc var cachedFilesForDatabaseOutlineSelectionCorrespondingObjects: NSMutableArray?
    @objc var cachedFilesForDatabaseOutlineSelectionTreeObjects: NSMutableSet?
    @objc var cachedFilesForDatabaseOutlineSelectionIndex: IndexSet?
    @objc var lastROIsAndKeyImagesSelectedFiles: Any?
    @objc var lastROIsImagesSelectedFiles: Any?
    @objc var lastKeyImagesSelectedFiles: Any?
    @objc var ROIsAndKeyImagesCache: NSArray?
    @objc var ROIsImagesCache: NSArray?
    @objc var KeyImagesCache: NSArray?
    @objc var ROIsAndKeyImagesCacheSameSeries = false
    @objc var ROIsImagesCacheSameSeries = false
    @objc var ROIsAndKeyImagesButtonAvailable = false
}

/// Sending, receiving and deleting files: the network logs, the delete
/// queue and its locks.
final class BrowserTransferState: NSObject, @unchecked Sendable {
    @objc var activeSends: NSMutableDictionary?
    @objc var sendLog: NSMutableArray?
    @objc var activeReceives: NSMutableDictionary?
    @objc var receiveLog: NSMutableArray?
    @objc var isNetworkLogsActive = false
    @objc var logWindowController: LogWindowController?
    @objc var deleteQueueArray: NSMutableArray?
    @objc var deleteQueue: NSRecursiveLock?
    @objc var deleteInProgress: NSRecursiveLock?
    @objc var processorsLock: NSConditionLock? = NSConditionLock(condition: 1)
}

/// What a person types in the browser's sheets, which the sheets' fields are
/// bound to: the password of a CD, of an encrypted export and of the file to
/// open, the address and the text of a notification e-mail.
final class BrowserSheetValues: NSObject, @unchecked Sendable {
    @objc var CDpassword: String?
    @objc var pathToEncryptedFile: String?
    @objc var passwordForExportEncryption: String?
    @objc var temporaryNotificationEmail: String?
    @objc var customTextNotificationEmail: String?
}

/// Opening viewers: the sub-selection of a series and its sheet.
final class BrowserViewerOpeningState: NSObject, @unchecked Sendable {
    /// Why the last study asked for did not open; cleared when one is selected.
    @objc var lastStudyNotOpenedReason: String?
    @objc var subFrom: Int32 = 0
    @objc var subTo: Int32 = 0
    @objc var subInterval: Int32 = 0
    @objc var subMax: Int32 = 0
    @objc var openSubSeriesFlag = false
    @objc var openReparsedSeriesFlag = false
    @objc var subSeriesWindowIsOn = false
    @objc var waitOpeningWindow: WaitRendering?
}

/// The window around the lists: its toolbar, its frame before full screen,
/// the divider of the drawer, the reports' toolbar item, the helpers of the
/// Sources and activity lists, Bonjour, the periodic refresh, the formats.
final class BrowserWindowState: NSObject, @unchecked Sendable {
    @objc var toolbar: NSToolbar?
    @objc var toolbarSearchItem: NSToolbarItem?
    @objc var databaseWindowedFrame = NSRect.zero
    @objc var splitViewVertDividerRatio: CGFloat = 0
    @objc var reportFilesToCheck: NSMutableDictionary? = NSMutableDictionary()
    @objc var reportToolbarItemType: Int = 0
    @objc var sourcesHelper: Any?
    @objc var activityHelper: Any?
    @objc var bonjourBrowser: BonjourBrowser?
    @objc var refreshTimer: Timer?
    @objc var TimeFormat: DateFormatter?
    @objc var TimeWithSecondsFormat: DateFormatter?
    @objc var DateTimeWithSecondsFormat: DateFormatter?
    @objc var databaseIndexDictionary: NSMutableDictionary? = NSMutableDictionary()
}
