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

// The browser's window from its nib to its closing: what -awakeFromNib wires
// (the preview, the split views, the list's cells, columns and sort, the
// toolbar, the menus, Bonjour, the search menu), the first launch, the
// observers, waiting for running processes, saving the window's state on
// close, the decision to quit, full screen, and the date formats of the list.
// What decides without the app's classes is IsiXDatabase's ListSort and
// SearchMenuTemplate. -initWithWindow: and the deinit are BrowserController.swift,
// with the class itself. The selectors are those of the former Objective-C
// methods.

/// [value boolValue]: NO for nil and for what is neither a number nor a string.
private func boolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

extension BrowserController {

    // MARK: - The nib

    @objc(awakeFromNib)
    public override func awakeFromNib() {
        // The nib is loaded on the main thread.
        MainActor.assumeIsolated { self.awakeWindow() }
    }

    private func awakeWindow() {
        if let raised = BrowserObjC.attempt({ self.wireWindow() }) {
            BrowserObjC.log(raised, "-[BrowserController awakeFromNib]")
        }

        let defaults = UserDefaults.standard
        let firstTimeExecution = defaults.object(forKey: "FIRST_TIME_EXECUTION_2_0") == nil
        var foundNotValidatedOsiriXPlugins = false

        if firstTimeExecution {
            defaults.set(NSNumber(value: true), forKey: "FIRST_TIME_EXECUTION_2_0")

            for case let pluginDesc as NSDictionary in (pluginManagerController?.plugins() as NSArray?) ?? NSArray()
            where !boolValue(pluginDesc.object(forKey: "HorosCompatiblePlugin")) {
                foundNotValidatedOsiriXPlugins = true
                break
            }

            defaults.set(CPRInterpolationModeCubic.rawValue, forKey: "selectedCPRInterpolationMode")

            DispatchQueue.main.async {
                self.restoreWindowState(self)
            }
        }

        if firstTimeExecution && foundNotValidatedOsiriXPlugins {
            let alert = NSAlert()
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.messageText = NSLocalizedString("Not validated OsiriX plugins were detected!", comment: "")
            alert.informativeText = NSLocalizedString("Not validated OsiriX plugins may cause IsiX DICOM Viewer run-time errors. In case of problems, you can disable/uninstall them in [Plugins => Plugin Manager]. A brand new IsiX DICOM Viewer plugin database is being built for you.", comment: "")
            alert.alertStyle = .warning
            alert.runModal()
        }

        if !defaults.dictionaryRepresentation().keys.contains("ROIColorRotation") {
            defaults.set(true, forKey: "ROIColorRotation")
        }

        if !DatabaseFirstUse.hasPendingChoice {
            ICloudDriveDetector.performStartupICloudDriveTasks(self)
            O2HMigrationAssistant.performStartupO2HTasks(self)
        }
    }

    /// What -awakeFromNib does inside its @try.
    private func wireWindow() {
        buildMetadataExportMenuItem()

        // The preview keeps the reason for its window, so that a scroll or a
        // second thumbnail batch cannot quietly undo an adjustment.
        if horos_previewWindowPolicy == nil {
            horos_previewWindowPolicy = PreviewWindowPolicy()
        }
        if horos_previewRedrawCoalescer == nil {
            horos_previewRedrawCoalescer = PreviewRedrawCoalescer(interval: 0.03)
        }
        horos_imageView?.windowDelegate = self

        let savedFrame = NSRectFromString(UserDefaults.standard.string(forKey: "DBWindowFrame") ?? "")

        if let window { FullScreenWindowSupport.enablePrimaryFullScreen(window) }

        BrowserController.horos_horizontalHistory = UserDefaults.standard.bool(forKey: "horizontalHistory")

        if BrowserController.horizontalHistory() {
            let split = NSSplitView(frame: horos_splitViewVert?.bounds ?? .zero)
            split.delegate = self
            if let history = horos_comparativeScrollView { split.addSubview(history) }
            if let thumbnails = horos_matrixView { split.addSubview(thumbnails) }

            horos_splitViewVert?.addSubview(split)
            if let preview = horos_imageView { horos_splitViewVert?.addSubview(preview) }

            horos_splitComparative = split
        }

        setTableViewRowHeight()

        // The nib's views: messages to a missing outlet did nothing.
        if let split = horos_splitAlbums { DatabaseBrowserLayout.prepareSidebar(split) }
        DatabaseBrowserLayout.prepareColumns(drawer: horos_splitDrawer, comparative: horos_splitComparative)
        if let view = horos_timeIntervalView { DatabaseBrowserLayout.prepareFilterView(view) }
        if let view = horos_modalityFilterView { DatabaseBrowserLayout.prepareFilterView(view) }
        if let view = horos_searchView { DatabaseBrowserLayout.prepareSearchView(view) }

        saveLoadAlbumsSortDescriptors()

        let wait = AppController.shared()?.splashScreen() as? WaitRendering

        horos_oMatrix?.intercellSpacing = NSSize(width: -1, height: -1)

        wait?.showWindow(self)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(updateReportToolbarIcon(_:)), name: NSOutlineView.selectionDidChangeNotification, object: horos_databaseOutline)
        center.addObserver(self, selector: #selector(updateReportToolbarIcon(_:)), name: NSOutlineView.selectionIsChangingNotification, object: horos_databaseOutline)
        horos_reportTemplatesListPopUpButton?.setAccessibilityLabel(NSLocalizedString("Report template", comment: ""))
        horos_reportTemplatesListPopUpButton?.setAccessibilityHelp(NSLocalizedString("Choose a template to create a report for the selected study.", comment: ""))
        center.addObserver(self, selector: #selector(reportToolbarItemWillPopUp(_:)), name: NSPopUpButton.willPopUpNotification, object: horos_reportTemplatesListPopUpButton)

        center.addObserver(self, selector: #selector(observeScrollerStyleDidChange(_:)), name: NSNotification.Name("NSPreferredScrollerStyleDidChangeNotification"), object: nil)
        observeScrollerStyleDidChange(nil)

        if let raised = BrowserObjC.attempt({ self.wireViews(savedFrame: savedFrame) }) {
            BrowserObjC.log(raised, stack: true, "-[BrowserController awakeFromNib]")
            _ = try? ("" as NSString).write(toFile: horos_databaseIvar?.loadingFilePath() ?? "", atomically: false, encoding: String.Encoding.utf8.rawValue)

            let message = String(format: NSLocalizedString("A problem occured during start-up of IsiX DICOM Viewer:\r\r%@\r\r%@", comment: ""),
                                 raised.description, raised.printStackTrace() ?? "")
            HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: message,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            exit(0)
        }

        wait?.close()

        testAutorouting()

        setDBWindowTitle()

        BrowserController.horos_loadingIsOver = true

        outlineViewRefresh()

        awakeActivity()
        window?.makeKeyAndOrderFront(self)

        refreshMatrix(self)

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "restartAutoQueryAndRetrieve") && defaults.object(forKey: "savedAutoDICOMQuerySettingsArray") != nil {
            AppController.shared()?.notificationTitle(NSLocalizedString("Auto-Query", comment: ""),
                                                      description: NSLocalizedString("DICOM Auto-Query is restarting...", comment: ""), name: "autoquery")
            NSLog("-------- automatically restart DICOM AUTO-QUERY --------")

            let restarting = WaitRendering(NSLocalizedString("Restarting Auto Query/Retrieve...", comment: ""))
            restarting?.showWindow(self)
            // The controller keeps itself: +currentAutoQueryController answers it.
            if let controller = QueryController(autoQuery: true) { _ = Unmanaged.passRetained(controller) }
            QueryController.currentAuto()?.switchAutoRetrieving(self)
            Thread.sleep(forTimeInterval: 0.5)
            restarting?.close()
        } else {
            defaults.set(false, forKey: "autoRetrieving")
        }

        window?.animationBehavior = .none

        // Responder chain
        horos_albumTable?.nextKeyView = horos_databaseOutline
        horos_sourcesTableView?.nextKeyView = horos_databaseOutline
        horos_databaseOutline?.nextKeyView = horos_searchField
        horos_searchField?.nextKeyView = horos_databaseOutline

        // Extend every localized nib's search menu without renumbering saved modes.
        let searchCell = horos_searchField?.cell as? NSSearchFieldCell
        if let searchMenu = searchCell?.searchMenuTemplate?.copy() as? NSMenu {
            if searchMenu.item(withTag: SearchMenuTemplate.seriesDescriptionTag) == nil {
                let seriesSearch = NSMenuItem(title: NSLocalizedString("Series Description", comment: ""), action: #selector(setSearchType(_:)), keyEquivalent: "")
                seriesSearch.tag = SearchMenuTemplate.seriesDescriptionTag
                seriesSearch.target = self
                searchMenu.insertItem(seriesSearch, at: SearchMenuTemplate.seriesDescriptionIndex(itemCount: searchMenu.numberOfItems,
                                                                                                   indexOfTag4: searchMenu.indexOfItem(withTag: 4)))
            }
            searchCell?.searchMenuTemplate = searchMenu
        } else {
            searchCell?.searchMenuTemplate = nil
        }
        setSearchType(searchCell?.searchMenuTemplate?.item(withTag: UserDefaults.standard.integer(forKey: "searchType")))
    }

    /// What -awakeFromNib does inside its inner @try: the thumbnails, the
    /// list, the toolbar, the menus, Bonjour, the split views.
    private func wireViews(savedFrame: NSRect) {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(previewMatrixScrollViewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: horos_thumbnailsScrollView)
        previewMatrixScrollViewFrameDidChange(nil)

        // thumbnails : no background color
        horos_thumbnailsScrollView?.drawsBackground = false
        horos_thumbnailsScrollView?.contentView.drawsBackground = false

        if !DatabaseFirstUse.hasPendingChoice {
            awakeSources()
        }
        let matrix = horos_oMatrix
        matrix?.delegate = self
        matrix?.isSelectionByRect = false
        matrix?.doubleAction = #selector(matrixDoublePressed(_:))
        matrix?.focusRingType = .exterior
        matrix?.renewRows(0, columns: 0)

        horos_imageView?.theMatrix = matrix

        let outline = horos_databaseOutline
        outline?.action = #selector(databasePressed(_:))
        outline?.doubleAction = #selector(databaseDoublePressed(_:))
        outline?.registerForDraggedTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        outline?.allowsMultipleSelection = true
        outline?.autosaveName = nil
        outline?.autosaveTableColumns = false
        outline?.allowsTypeSelect = false

        setupToolbar()

        horos_toolbar?.isVisible = true
        // Toolbar attachment changes the frame to preserve content height. Restore
        // the saved outer frame only after the toolbar is installed and visible.
        if let window { DatabaseWindowPlacement.restore(window, savedFrame: savedFrame) }
        // NSMenu for DatabaseOutline
        let menu = NSMenu(title: "")
        menu.delegate = self
        outline?.menu = menu

        addHelpMenu()

        let cell = ImageAndTextCell()
        cell.isEditable = true
        horos_albumTable?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Source"))?.dataCell = cell
        horos_albumTable?.delegate = self
        // With O2AlbumDragType, the original, non-UTI type, in case some plugin uses it.
        horos_albumTable?.registerForDraggedTypes(((BrowserController.databaseObjectXIDsPasteboardTypes() ?? []) + ["Osirix Album drag"])
            .map { NSPasteboard.PasteboardType($0) })

        let states = [NSLocalizedString("empty", comment: ""), NSLocalizedString("unread", comment: ""), NSLocalizedString("reviewed", comment: ""),
                      NSLocalizedString("dictated", comment: ""), NSLocalizedString("validated", comment: "")]
        BrowserController.horos_statesArray = states

        outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))?.dataCell = ImageAndTextCell()
        outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("reportURL"))?.dataCell = ImageAndTextCell()

        // Set International dates for columns
        setDBDate()

        let stateColumn = outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("stateText"))
        let buttonCell = NSPopUpButtonCell(textCell: "", pullsDown: false)
        buttonCell.isEditable = true
        buttonCell.isBordered = false
        buttonCell.addItems(withTitles: states)

        stateColumn?.dataCell = buttonCell

        // setInitialState was a compatibility no-op; tableColumns is authoritative.

        let defaults = UserDefaults.standard
        if let columns = defaults.object(forKey: "databaseColumns2") {
            outline?.restoreColumnState(columns as? NSObject)
        }

        switch ListSort.restored(saved: defaults.object(forKey: "databaseSortDescriptor") as? NSDictionary, isVisible: { key in
            outline?.isColumnWithIdentifierVisible(key) ?? false
        }) {
        case .saved(let key, let ascending):
            let prototype = outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key ?? ""))?.sortDescriptorPrototype
            outline?.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending, selector: prototype?.selector)]
        case .byName:
            outline?.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.caseInsensitiveCompare(_:)))]
        }

        loadSortDescriptors(nil)

        outline?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        outline?.scrollRowToVisible(0)
        buildColumnsMenu()

        self.modalityFilter = nil

        horos_animationCheck?.state = defaults.bool(forKey: "AutoPlayAnimation") ? .on : .off

        horos_activeSends = NSMutableDictionary()
        horos_sendLog = NSMutableArray()
        horos_activeReceives = NSMutableDictionary()
        horos_receiveLog = NSMutableArray()

        // bonjour
        let bonjour = BonjourBrowser(browserController: self)
        horos_bonjourBrowser = bonjour
        displayBonjourServices()

        NSUserDefaultsController.shared.addObserver(self, forValuesKey: OsirixBonjourSharingIsActiveDefaultsKey, options: .initial,
                                                    context: Unmanaged.passUnretained(bonjour).toOpaque())

        horos_splitDrawer?.restoreDefault("SplitDrawer")
        horos_splitAlbums?.restoreDefault("SplitAlbums")
        if let split = horos_splitAlbums { DatabaseBrowserLayout.layoutSidebar(split) }
        horos_splitViewHorz?.restoreDefault("SplitHorz2")
        horos_splitComparative?.restoreDefault("SplitComparative")
        horos_splitViewVert?.restoreDefault("SplitVert2")

        // The history above the thumbnails, or on the right of them.
        if defaults.bool(forKey: "SplitComparativeHidden") != isSubviewHidden(horos_splitComparative, at: BrowserController.horizontalHistory() ? 0 : 1) {
            comparativeToggle(self)
        }
        if defaults.bool(forKey: "SplitDrawerHidden") != isSubviewHidden(horos_splitDrawer, at: 0) {
            drawerToggle(self)
        }
        DatabaseBrowserLayout.restoreHistoryWidth(in: horos_splitComparative)

        horos_albumTable?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Source"))?.dataCell = PrettyCell()

        horos_comparativeTable?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Cell"))?.dataCell = ComparativeCell()
        horos_comparativeTable?.doubleAction = #selector(doubleClickComparativeStudy(_:))

        initContextualMenus()

        // opens a port for interapplication communication
        BrowserController.horos_registerLegacyDistributedBrowser(self)
        // start timer for monitoring incoming logs on main thread
        _ = LogManager.currentLogManager()

        // Mounted media are handled by the volume observers in BrowserController+Sources.
    }

    /// [[split subviews] objectAtIndex: index] is hidden or collapsed: NO
    /// without the split view, and an NSRangeException without the subview.
    private func isSubviewHidden(_ split: NSSplitView?, at index: Int) -> Bool {
        guard let split, let view = (split.subviews as NSArray).object(at: index) as? NSView else { return false }
        return view.isHidden || split.isSubviewCollapsed(view)
    }

    @objc(completeFirstUseDatabaseSetup)
    func completeFirstUseDatabaseSetup() {
        // Sources can have queued a nil default database while setup was pending.
        // Do not let that stale nib-loading selection clear the chosen database.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(setter: BrowserController.database), object: nil)
        awakeSources()
        resetToLocalDatabase()
        ICloudDriveDetector.performStartupICloudDriveTasks(self)
        O2HMigrationAssistant.performStartupO2HTasks(self)
    }

    /// The banner was fetched and shown only when WITH_BANNER was defined, which
    /// it never is. The action stays: it is declared in the public header.
    @objc(clickBanner:)
    @IBAction func clickBanner(_ sender: Any!) {
    }

    @objc(observeValueForKeyPath:ofObject:change:context:)
    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        var keyPath = keyPath
        // [NSUserDefaultsController sharedUserDefaultsController], asked as
        // Objective-C asked it, on whichever thread the change arrives.
        let shared = (NSUserDefaultsController.self as AnyObject).perform(NSSelectorFromString("sharedUserDefaultsController"))?.takeUnretainedValue()
        if let object = object as AnyObject?, object === shared {
            // "values." and the key.
            keyPath = (keyPath as NSString?)?.substring(from: 7)
            if (keyPath as NSString?)?.isEqual(to: OsirixBonjourSharingIsActiveDefaultsKey) ?? false {
                // The defaults controller tells its observers on the main
                // thread; the database is changed there in any case.
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self.resetToDefaultDatabaseIfNecessary() }
                } else {
                    DispatchQueue.main.async { self.resetToDefaultDatabaseIfNecessary() }
                }
                return
            }
        }

        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    // MARK: - Closing

    @objc(waitForRunningProcesses)
    func waitForRunningProcesses() {
        autoreleasepool {
            if BrowserController.horos_waitForRunningProcess { return }

            BrowserController.horos_waitForRunningProcess = true

            var wait: WaitRendering?
            if Thread.isMainThread && (window?.isVisible ?? false) {
                wait = WaitRendering(NSLocalizedString("Wait for running processes...", comment: ""))
            }

            if let raised = BrowserObjC.attempt({
                let defaults = UserDefaults.standard
                if !defaults.hasArgumentOverride(forKey: "hideListenerError") {
                    let hideListenerError = defaults.bool(forKey: "hideListenerError")

                    defaults.set(hideListenerError, forKey: "copyHideListenerError")
                    defaults.set(true, forKey: "hideListenerError")
                    defaults.synchronize()

                    defaults.set(hideListenerError, forKey: "hideListenerError")
                    defaults.removeObject(forKey: "copyHideListenerError")
                    defaults.synchronize()
                }

                _ = BrowserController.tryLock(self.horos_searchForComparativeStudiesLock, during: 120)

                // Something in the delete queue? Write it to the disk
                self.saveDeleteQueue()
                self.syncReportsIfNecessary()
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController waitForRunningProcesses]")
            }

            BrowserController.horos_waitForRunningProcess = false

            wait?.close()
        }
    }

    @objc(browserPrepareForClose)
    func browserPrepareForClose() {
        let defaults = UserDefaults.standard
        var savedFrame = window?.frame ?? .zero
        if (window?.styleMask.contains(.fullScreen) ?? false) && !NSIsEmptyRect(horos_databaseWindowedFrame) {
            savedFrame = horos_databaseWindowedFrame
        }
        defaults.set(NSStringFromRect(savedFrame), forKey: "DBWindowFrame")

        NSLog("browserPrepareForClose")

        saveLoadAlbumsSortDescriptors()

        DicomStudy.dbModifyLock()?.lock()
        DicomStudy.dbModifyLock()?.unlock()

        _ = WebPortal.default()?.database?.save(nil)
        _ = horos_databaseIvar?.save(nil)
        _ = WebPortal.default()?.database?.save(nil)

        waitForRunningProcesses()

        _ = horos_databaseIvar?.save(nil)

        self.database = nil

        horos_splitViewVert?.saveDefault("SplitVert2")
        horos_splitViewHorz?.saveDefault("SplitHorz2")
        horos_splitAlbums?.saveDefault("SplitAlbums")
        horos_splitComparative?.saveDefault("SplitComparative")
        horos_splitDrawer?.saveDefault("SplitDrawer")

        defaults.set(isSubviewHidden(horos_splitDrawer, at: 0), forKey: "SplitDrawerHidden")

        // The history above the thumbnails, or on the right of them.
        defaults.set(isSubviewHidden(horos_splitComparative, at: BrowserController.horizontalHistory() ? 0 : 1), forKey: "SplitComparativeHidden")

        let outline = horos_databaseOutline
        if let first = outline?.sortDescriptors.first {
            defaults.set(ListSort.saved(ascending: first.ascending, key: first.key), forKey: "databaseSortDescriptor")
        }
        defaults.set(outline?.columnState(), forKey: "databaseColumns2")

        window?.delegate = nil

        defaults.set(horos_animationCheck?.state == .on, forKey: "AutoPlayAnimation")

        defaults.synchronize()

        let temporary = FileManager.default.tmpDirPath() as NSString
        try? FileManager.default.removeItem(atPath: temporary.appendingPathComponent("OsiriXTemporaryDatabase"))
        try? FileManager.default.removeItem(atPath: temporary.appendingPathComponent("dicomsr_osirix"))
    }

    @objc(shouldTerminateCallback:)
    func shouldTerminateCallback(_ timer: Timer!) {
        if (ThreadsManager.default()?.threadsCount() ?? 0) == 0 {
            NSApplication.shared.stopModal(withCode: NSApplication.ModalResponse(rawValue: Int(HorosAlertAlternateResponse)))
        }
    }

    @objc(shouldTerminate:)
    func shouldTerminate(_ sender: Any!) -> Bool {
        // Is there a full screen window displayed?
        for window in NSApp.orderedWindows where window is NSFullScreenWindow {
            NSSound.beep()
            return false
        }

        ViewerController.closeAllWindows()

        _ = horos_databaseIvar?.save(nil)

        if (ThreadsManager.default()?.threadsCount() ?? 0) > 0 {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Background Operations", comment: "")
            alert.informativeText = NSLocalizedString("Background operations are currently running. Are you sure you want to quit now? These operations will be cancelled.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))

            let timer = Timer(timeInterval: 0.3, target: self, selector: #selector(shouldTerminateCallback(_:)), userInfo: alert, repeats: true)
            RunLoop.current.add(timer, forMode: .modalPanel)

            let response = alert.runModal()

            timer.invalidate()

            if (ThreadsManager.default()?.threadsCount() ?? 0) > 0 && response == .alertFirstButtonReturn {
                return false
            }

            // AppController will cancel these threads and give them 10 secs to finish... then kill them
        }

        if SendController.sendControllerObjects() > 0 {
            if HorosAlertPanel.runInformational(
                title: NSLocalizedString("DICOM Sending - STORE", comment: ""),
                message: NSLocalizedString("Files are currently being sent to a DICOM node. Are you sure you want to quit now? The sending will be stopped.", comment: ""),
                defaultButton: NSLocalizedString("No", comment: ""), alternateButton: NSLocalizedString("Quit", comment: ""),
                otherButton: nil) == HorosAlertDefaultResponse {
                return false
            }
        }

        self.database = nil

        return true
    }

    // MARK: - Full screen and showing the window

    @objc(fullScreenMenu:)
    @IBAction func fullScreenMenu(_ sender: Any!) {
        window?.toggleFullScreen(sender)
    }

    @objc(windowWillEnterFullScreen:)
    func windowWillEnterFullScreen(_ notification: Notification!) {
        if (notification.object as AnyObject?) === window {
            horos_databaseWindowedFrame = window?.frame ?? .zero
        }
    }

    @objc(showDatabase:)
    @IBAction func showDatabase(_ sender: Any!) {
        if let window { DatabaseWindowPlacement.restore(window, savedFrame: window.frame) }
        if window?.isMiniaturized ?? false { window?.deminiaturize(sender) }
        NSApp.activate(ignoringOtherApps: true)

        window?.makeKeyAndOrderFront(sender)
        outlineViewRefresh()
    }

    // MARK: - Date formats

    @objc(setDBDate)
    func setDBDate() {
        let time = DateFormatter()
        time.timeStyle = .short
        horos_timeFormat = time

        let timeWithSeconds = DateFormatter()
        timeWithSeconds.timeStyle = .medium
        horos_timeWithSecondsFormat = timeWithSeconds

        let dateTimeWithSeconds = DateFormatter()
        dateTimeWithSeconds.dateStyle = .short
        dateTimeWithSeconds.timeStyle = .medium
        horos_dateTimeWithSecondsFormat = dateTimeWithSeconds

        let outline = horos_databaseOutline
        func column(_ identifier: String) -> NSCell? {
            outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.dataCell as? NSCell
        }
        column("dateOpened")?.formatter = UserDefaults.dateTimeFormatter()
        column("date")?.formatter = UserDefaults.dateTimeFormatter()
        column("dateAdded")?.formatter = UserDefaults.dateTimeFormatter()

        column("dateOfBirth")?.formatter = UserDefaults.dateFormatter()
        column("reportURL")?.formatter = UserDefaults.dateFormatter()
        column("noFiles")?.formatter = BrowserController.horos_decimalNumberFormatter
    }

    /// A date written by one of the browser's formatters, which its users share
    /// across threads: under the formatter's own lock, as @synchronized was.
    nonisolated private static func string(from date: Date!, with formatter: () -> DateFormatter?) -> String! {
        guard let formatter = formatter() else { return nil }
        return BrowserObjC.synchronized(formatter) { date.map { formatter.string(from: $0) } }
    }

    // These three are dispatched by message, as the Objective-C class methods
    // were: DCMPix and the ROIs call them without linking the browser's window.
    @objc(DateTimeWithSecondsFormat:)
    nonisolated dynamic class func dateTime(withSecondsFormat t: Date!) -> String! {
        string(from: t) { BrowserController.horos_currentBrowserDateTimeWithSecondsFormat() }
    }

    @objc(TimeWithSecondsFormat:)
    nonisolated dynamic class func time(withSecondsFormat t: Date!) -> String! {
        string(from: t) { BrowserController.horos_currentBrowserTimeWithSecondsFormat() }
    }

    @objc(TimeFormat:)
    nonisolated dynamic class func timeFormat(_ t: Date!) -> String! {
        string(from: t) { BrowserController.horos_currentBrowserTimeFormat() }
    }

    @objc(DateOfBirthFormat)
    var dateOfBirthFormat: DateFormatter! {
        UserDefaults.dateFormatter()
    }

    @objc(DateOfBirthFormat:)
    static func dateOfBirthFormat(_ d: Date!) -> String! {
        d.map { UserDefaults.dateFormatter().string(from: $0) }
    }

    @objc(DateTimeFormat)
    var dateTimeFormat: DateFormatter! {
        UserDefaults.dateTimeFormatter()
    }

    @objc(DateTimeFormat:)
    static func dateTimeFormat(_ d: Date!) -> String! {
        d.map { UserDefaults.dateTimeFormatter().string(from: $0) }
    }

    @objc(computeDATABASEINDEXforDatabase:)
    static func computeDATABASEINDEX(forDatabase path: String!) -> Int {
        Int(DicomDatabase(atPath: path)?.computeDataFileIndex() ?? 0)
    }
}
