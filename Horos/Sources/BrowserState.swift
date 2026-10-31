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
import IsiXDatabase

// The state of the browser, by what it is about. Each holder keeps the
// former instance variables of its part under their names. The values still
// read or bound by key that the browser does not answer itself (a binding of
// the window, the diagnostic tools) stay visible to Objective-C, and key-value
// coding reaches them as it reached the instance variables
// (BrowserController+KeyValueCoding.swift); the extensions read them through
// the horos_ accessors of BrowserController+StateAccess.swift. A holder is
// not tied to the main actor: the thumbnails', search and import threads read
// and write some of these values, as they read the instance variables,
// under the locks their users take.

/// The thumbnails and the preview of the selection.
final class BrowserPreviewState: NSObject, @unchecked Sendable {
    /// The images the preview shows; replaced with each selection.
    var previewPix: NSMutableArray? = NSMutableArray()
    /// The thumbnails being made, guarded by @synchronized on it.
    var previewPixThumbnails: NSMutableArray? = NSMutableArray()
    /// Which window the preview is showing and why: a DICOM default, one
    /// computed from the pixels, or an adjustment a person made.
    @objc var previewWindowPolicy: PreviewWindowPolicy?
    /// One preview decode per burst of scroll events, not one per notch.
    var previewRedrawCoalescer: PreviewRedrawCoalescer?
    /// Bumped whenever previewPix is replaced, so a thumbnail batch published
    /// by a thread that started before the selection changed is discarded.
    var previewPixGeneration: UInt = 0
    var loadPreviewIndex: Int = 0
    var setDCMDone = false
    var dontUpdatePreviewPane = false
    /// The rows the thumbnails show.
    var matrixViewArray: NSArray?
    /// The load of the thumbnails in progress, cancelled by a new selection.
    var thumbnailLoad: ThumbnailLoad?
    /// When the thumbnails a load made so far were last shown: every half
    /// second at most. Written by the thumbnail loader.
    var timeIntervalOfLastLoadIconsDisplayIcons: TimeInterval = 0
    /// The thumbnail of a file that is not found.
    var notFoundImage: NSImage? = NSImage(named: "FileNotFound.tif")
}

/// The study list: the rows shown, the search, the filters and the time
/// interval, the editing of a row.
final class BrowserStudyListState: NSObject, @unchecked Sendable {
    var outlineViewArray: NSArray? = NSArray()
    /// The list before a search of an album added the entire database's
    /// result, and its studies, for membership while drawing.
    private(set) var originalOutlineViewArray: NSArray?
    private(set) var originalOutlineViewStudies: NSSet?
    var searchString: String?
    @objc var searchType: Int32 = 7
    var filterPredicate: NSPredicate?
    var filterPredicateDescription: String?
    var fetchPredicate: NSPredicate?
    var testPredicate: NSPredicate?
    var timeIntervalType: Int32 = 0
    var timeIntervalStart: Date?
    var timeIntervalEnd: Date?
    var modalityFilter: String?
    var previousItem: Any?
    var previousNoOfFiles: Int = 0
    var DatabaseIsEdited = false
    @objc var refreshDeferredWhileEditing = false
    var distantEntireDBResultCount: Int32 = 0
    var localEntireDBResultCount: Int32 = 0
    /// The letters typed in the list to select a patient.
    var pressedKeys: NSMutableString? = NSMutableString(string: "")
    var previousFlags: UInt = 0

    func setOriginalOutlineViewArray(_ array: NSArray?) {
        originalOutlineViewArray = array
        originalOutlineViewStudies = array.map { NSSet(array: $0 as [AnyObject]) }
    }
}

/// The patient's history beside the thumbnails, what the PACS On-Demand smart
/// albums and searches last found, and a study waited for from a node. The
/// distant studies the list shows are kept by the process's PACSOnDemandSearch.
final class BrowserComparativeState: NSObject, @unchecked Sendable {
    /// The patient whose history is shown.
    var comparativePatientUID: String?
    /// The studies of the history list.
    var comparativeStudies: NSArray?
    var dontSelectStudyFromComparativeStudies = false
    var lastRefreshComparativeStudies: TimeInterval = 0
    /// The studies retrieved from the nodes: a study is not retrieved twice at once.
    let retrieves = DistantStudyRetrieves()
    /// The study to select or open when it arrives, its viewer, since when, and what to do.
    var comparativeStudyWaited: DCMTKStudyQueryNode?
    var comparativeStudyWaitedViewer: ViewerController?
    var comparativeStudyWaitedTime: TimeInterval = 0
    var comparativeStudyWaitedToOpen = false
    var comparativeStudyWaitedToSelect = false
    var smartAlbumDistantName: String?
    var lastRefreshSmartAlbumDistantStudies: TimeInterval = 0
    /// The text the thumbnails show for a distant study.
    var distantStudyMessage: String?
    var distantTimeIntervalStart: Date?
    var distantTimeIntervalEnd: Date?
    var distantSearchString: String?
    var distantSearchType: Int32 = 0
}

/// The albums: the catalog of the database's albums and their study counts,
/// local and on the nodes, when they are counted, and the refreshes an import
/// asks for.
final class BrowserAlbumState: NSObject, @unchecked Sendable {
    let catalog = DatabaseAlbumCatalog()
    let countScheduler = AlbumCountScheduler<DatabaseAlbumCounter>()
    /// The album an import adds its studies to; read on any thread.
    var selectedAlbumName: String?
    var lastImportListRefresh: TimeInterval = 0
    var lastImportAlbumsRefresh: TimeInterval = 0
    var importListRefreshPending = false
    var importAlbumsRefreshPending = false
}

/// The files of the list's selection, and the images with ROIs and key
/// images of the last selections, kept until the selection changes.
final class BrowserSelectionCache: NSObject, @unchecked Sendable {
    var cachedFilesForDatabaseOutlineSelectionSelectedFiles: NSMutableArray?
    var cachedFilesForDatabaseOutlineSelectionCorrespondingObjects: NSMutableArray?
    var cachedFilesForDatabaseOutlineSelectionTreeObjects: NSMutableSet?
    var cachedFilesForDatabaseOutlineSelectionIndex: IndexSet?
    /// The selections the images below were found in (SelectionMarkedImages.swift).
    var lastROIsAndKeyImagesSelectedFiles: [NSObject]?
    var lastROIsImagesSelectedFiles: [NSObject]?
    var lastKeyImagesSelectedFiles: [NSObject]?
    var ROIsAndKeyImagesCache: [DicomImage]?
    var ROIsImagesCache: [DicomImage]?
    var KeyImagesCache: [DicomImage]?
    var ROIsAndKeyImagesCacheSameSeries = false
    var ROIsImagesCacheSameSeries = false
    var ROIsAndKeyImagesButtonAvailable = false
}

/// Sending, receiving and deleting files: the network logs and the delete
/// queue.
final class BrowserTransferState: NSObject, @unchecked Sendable {
    var activeSends: NSMutableDictionary?
    var sendLog: NSMutableArray?
    var activeReceives: NSMutableDictionary?
    var receiveLog: NSMutableArray?
    var isNetworkLogsActive = false
    var logWindowController: LogWindowController?
    /// The files removed from the database, waiting to be deleted from the disk.
    let deleteQueue = DatabaseDeleteQueue()
    var processorsLock: NSConditionLock? = NSConditionLock(condition: 1)
}

/// What a person types in the browser's sheets, which the sheets' fields are
/// bound to: the password of a CD, of an encrypted export and of the file to
/// open, the address and the text of a notification e-mail.
final class BrowserSheetValues: NSObject, @unchecked Sendable {
    @objc var CDpassword: String?
    var pathToEncryptedFile: String?
    var passwordForExportEncryption: String?
    var temporaryNotificationEmail: String?
    var customTextNotificationEmail: String?
}

/// Opening viewers: the sub-selection of a series and its sheet.
final class BrowserViewerOpeningState: NSObject, @unchecked Sendable {
    /// Why the last study asked for did not open; cleared when one is selected.
    @objc var lastStudyNotOpenedReason: String?
    var subFrom: Int32 = 0
    var subTo: Int32 = 0
    var subInterval: Int32 = 0
    var subMax: Int32 = 0
    var openSubSeriesFlag = false
    var openReparsedSeriesFlag = false
    var subSeriesWindowIsOn = false
    var waitOpeningWindow: WaitRendering?
}

/// The window around the lists: its toolbar, its frame before full screen,
/// the divider of the drawer, the helpers of the Sources and activity lists,
/// Bonjour, the periodic refresh, the formats. The reports' state is
/// StudyReports'.
final class BrowserWindowState: NSObject, @unchecked Sendable {
    @objc var toolbar: NSToolbar?
    var toolbarSearchItem: NSToolbarItem?
    var databaseWindowedFrame = NSRect.zero
    var splitViewVertDividerRatio: CGFloat = 0
    @objc var sourcesHelper: Any?
    var activityHelper: Any?
    var bonjourBrowser: BonjourBrowser?
    var refreshTimer: Timer?
    var TimeFormat: DateFormatter?
    var TimeWithSecondsFormat: DateFormatter?
    var DateTimeWithSecondsFormat: DateFormatter?
    var databaseIndexDictionary: NSMutableDictionary? = NSMutableDictionary()
}
