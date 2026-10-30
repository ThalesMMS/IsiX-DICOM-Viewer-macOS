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

/// The database window: its lists, the thumbnails and the preview, and the
/// database it shows.
///
/// The class coordinates; what it does is in its extensions, by
/// responsibility (BrowserController+StudyList.swift, +Thumbnails.swift,
/// +Sources.swift...), and its state is in holders by subject
/// (BrowserState.swift) and its views in the holders of its window and of
/// its sheets (BrowserOutlets.swift). The rules that need neither AppKit nor
/// the database (the sizes of text and rows, the folder size, the parallel
/// image conversion) are in IsiXDatabase and IsiXImaging.
///
/// The Objective-C name, the selectors, the key-value coding and observing
/// keys, the nib connections, the notifications and the preference keys are
/// those of the former Objective-C class. BrowserController.h names it for
/// the Objective-C, which reads the generated interface.
@objc(BrowserController)
public class BrowserController: NSWindowController, NSMatrixDelegate, NSMenuDelegate, NSMenuItemValidation {

    // MARK: State

    nonisolated let windowOutlets = BrowserWindowOutlets()
    nonisolated let sheetOutlets = BrowserSheetOutlets()
    nonisolated let previewState = BrowserPreviewState()
    nonisolated let studyListState = BrowserStudyListState()
    nonisolated let comparativeState = BrowserComparativeState()
    nonisolated let albumState = BrowserAlbumState()
    nonisolated let selectionCache = BrowserSelectionCache()
    nonisolated let transferState = BrowserTransferState()
    nonisolated let sheetValues = BrowserSheetValues()
    nonisolated let viewerOpeningState = BrowserViewerOpeningState()
    nonisolated let windowState = BrowserWindowState()

    /// The database shown, read from any thread as the instance variable was;
    /// replaced on the main thread by -setDatabase:.
    nonisolated(unsafe) private var shownDatabase: DicomDatabase?

    /// The database shown. The one replaced is autoreleased, as the former
    /// setter did: a caller that read it keeps it until its pool drains.
    nonisolated var horos_databaseIvar: DicomDatabase? {
        get { shownDatabase }
        set {
            let replaced = shownDatabase
            shownDatabase = newValue
            if let replaced { _ = Unmanaged.passRetained(replaced).autorelease() }
        }
    }

    // MARK: The properties of the former header

    /// Read from any thread, as it always was; set on the main thread, where
    /// -horos_switchToDatabase: closes the viewers and shows it everywhere.
    /// Observers are told by that method, not by the setter.
    @objc public nonisolated dynamic var database: DicomDatabase! {
        get { shownDatabase }
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

    @objc public nonisolated var sources: NSArrayController! { windowOutlets.sourcesArrayController }
    @objc public nonisolated var TimeFormat: DateFormatter! { windowState.TimeFormat }
    @objc public nonisolated var TimeWithSecondsFormat: DateFormatter! { windowState.TimeWithSecondsFormat }
    @objc public nonisolated var DateTimeWithSecondsFormat: DateFormatter! { windowState.DateTimeWithSecondsFormat }
    @objc public nonisolated var matrixViewArray: [Any]! { previewState.matrixViewArray as? [Any] }
    @objc public nonisolated var oMatrix: NSMatrix! { windowOutlets.oMatrix }
    @objc public nonisolated var databaseOutline: MyOutlineView! { windowOutlets.databaseOutline }
    @objc public nonisolated var albumTable: NSTableView! { windowOutlets.albumTable }
    @objc public nonisolated var bonjourSourcesBox: NSBox! { windowOutlets.bonjourSourcesBox }
    @objc public nonisolated var bonjourBrowser: BonjourBrowser! { windowState.bonjourBrowser }
    @objc public nonisolated var pluginManagerController: PluginManagerController! { windowOutlets.pluginManagerController }
    @objc public nonisolated var databaseIndexDictionary: NSMutableDictionary! { windowState.databaseIndexDictionary }

    // The fields of the sheets are bound to these.
    @objc(CDpassword) public nonisolated dynamic var cDpassword: String! {
        get { sheetValues.CDpassword }
        set { sheetValues.CDpassword = newValue }
    }
    @objc public nonisolated dynamic var pathToEncryptedFile: String! {
        get { sheetValues.pathToEncryptedFile }
        set { sheetValues.pathToEncryptedFile = newValue }
    }
    @objc public nonisolated dynamic var passwordForExportEncryption: String! {
        get { sheetValues.passwordForExportEncryption }
        set { sheetValues.passwordForExportEncryption = newValue }
    }
    @objc public nonisolated dynamic var temporaryNotificationEmail: String! {
        get { sheetValues.temporaryNotificationEmail }
        set { sheetValues.temporaryNotificationEmail = newValue }
    }
    @objc public nonisolated dynamic var customTextNotificationEmail: String! {
        get { sheetValues.customTextNotificationEmail }
        set { sheetValues.customTextNotificationEmail = newValue }
    }

    // The patient's history and the PACS On-Demand searches.
    @objc public nonisolated dynamic var comparativePatientUID: String! {
        get { comparativeState.comparativePatientUID }
        set { comparativeState.comparativePatientUID = newValue }
    }
    @objc public nonisolated dynamic var smartAlbumDistantName: String! {
        get { comparativeState.smartAlbumDistantName }
        set { comparativeState.smartAlbumDistantName = newValue }
    }
    /// The text the thumbnails show for a distant study; bound in the window.
    @objc public nonisolated dynamic var distantStudyMessage: String! {
        get { comparativeState.distantStudyMessage }
        set { comparativeState.distantStudyMessage = newValue }
    }
    @objc public nonisolated dynamic var distantSearchString: String! {
        get { comparativeState.distantSearchString }
        set { comparativeState.distantSearchString = newValue }
    }
    @objc public nonisolated dynamic var distantSearchType: Int32 {
        get { comparativeState.distantSearchType }
        set { comparativeState.distantSearchType = newValue }
    }
    @objc public nonisolated dynamic var distantTimeIntervalStart: Date! {
        get { comparativeState.distantTimeIntervalStart }
        set { comparativeState.distantTimeIntervalStart = newValue }
    }
    @objc public nonisolated dynamic var distantTimeIntervalEnd: Date! {
        get { comparativeState.distantTimeIntervalEnd }
        set { comparativeState.distantTimeIntervalEnd = newValue }
    }
    @objc public nonisolated dynamic var comparativeStudies: [Any]! {
        get { comparativeState.comparativeStudies as? [Any] }
        set { comparativeState.comparativeStudies = newValue.map { $0 as NSArray } }
    }

    /// Read on any thread: the album an import adds its studies to.
    @objc public nonisolated dynamic var selectedAlbumName: String! {
        get { albumState.selectedAlbumName }
        set { albumState.selectedAlbumName = newValue }
    }

    // The study list's predicates.
    @objc public nonisolated dynamic var fetchPredicate: NSPredicate! {
        get { studyListState.fetchPredicate }
        set { studyListState.fetchPredicate = newValue }
    }
    @objc public nonisolated dynamic var testPredicate: NSPredicate! {
        get { studyListState.testPredicate }
        set { studyListState.testPredicate = newValue }
    }
    @objc public nonisolated var filterPredicate: NSPredicate! { studyListState.filterPredicate }
    @objc public nonisolated var filterPredicateDescription: String! { studyListState.filterPredicateDescription }

    /// The modality menu's filter; setting it refreshes the list
    /// (BrowserController+Search.swift).
    @objc public nonisolated dynamic var modalityFilter: String! {
        get { studyListState.modalityFilter }
        set { MainActor.assumeIsolated { horos_applyModalityFilter(newValue) } }
    }

    /// The time interval menu's choice; setting it refreshes the list
    /// (BrowserController+Search.swift).
    @objc public nonisolated dynamic var timeIntervalType: Int32 {
        get { studyListState.timeIntervalType }
        set { MainActor.assumeIsolated { horos_applyTimeIntervalType(newValue) } }
    }

    // The sub-selection sheet's fields are bound to these, through an object
    // controller whose content is the browser. Their setters are the sheet's
    // actions, -setSubFrom:, -setSubTo: and -setSubInterval:
    // (BrowserController+SubSeriesSheets.swift).
    @objc public nonisolated var subFrom: Int32 { viewerOpeningState.subFrom }
    @objc public nonisolated var subTo: Int32 { viewerOpeningState.subTo }
    @objc public nonisolated var subInterval: Int32 { viewerOpeningState.subInterval }
    @objc public nonisolated dynamic var subMax: Int32 {
        get { viewerOpeningState.subMax }
        set { viewerOpeningState.subMax = newValue }
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

        studyListState.searchType = 7
        self.timeIntervalType = 0
        BrowserController.current = self

        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "DEFAULT_DATABASELOCATION"), forKey: "DATABASELOCATION")
        defaults.set(defaults.string(forKey: "DEFAULT_DATABASELOCATIONURL"), forKey: "DATABASELOCATIONURL")

        if !DatabaseFirstUse.hasPendingChoice {
            self.database = BrowserController.activeLocalDatabaseInOperation()
        }

        Timer.scheduledTimer(timeInterval: 0.15, target: self, selector: #selector(previewPerformAnimation(_:)), userInfo: self, repeats: true)

        if defaults.integer(forKey: "LISTENERCHECKINTERVAL") < 1 {
            defaults.set(1, forKey: "LISTENERCHECKINTERVAL")
        }
        if !defaults.bool(forKey: "hideListenerError") {
            windowState.refreshTimer = Timer.scheduledTimer(timeInterval: 5 * 60, target: self, selector: #selector(refreshDatabase(_:)),
                                                            userInfo: self, repeats: true)
        }
        Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(emptyDeleteQueue(_:)), userInfo: self, repeats: true)
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
        windowOutlets.imageView?.windowDelegate = nil
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
            if let exception = BrowserObjC.attempt({ database = DicomDatabase.activeLocal() }) {
                BrowserObjC.log(exception, stack: true, "-[BrowserController initWithWindow:]")
            }
        }
        thread.exitOperation()
        thread.name = oldThreadName
        return database
    }
}
