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
import SecurityInterface
import IsiXDICOMNetwork
import IsiXDICOMFile

/// The window of DICOM Query/Retrieve, and of the automatic query.
///
/// Implemented in Swift: the Objective-C name, the selectors, the outlets, the
/// bindings and actions of Query.xib and the keys other code reads are those of
/// the former class. The class is split by what it does: this file holds the
/// window and its state; +Network the queries of the other windows, the web
/// portal and the routing rules; +Filters the filters, dates and presets;
/// +Query the query of the window and its sources; +Results the list of results
/// and what of it is here; +Retrieve the retrieves; +AutoQuery the automatic
/// query and the refresh of the results.
///
/// Queries and retrieves run on worker threads, as they did. What a worker
/// needs of the window is copied on the main thread (`windowState`), and the
/// state the workers share with the window is `nonisolated(unsafe)`, as the
/// former instance variables were; `@synchronized` became objc_sync on the
/// same objects.
///
/// As before, a controller keeps itself alive: the one-second timer of the
/// automatic refresh retains it, and +currentQueryController answers it.
@objc(QueryController)
public final class QueryController: NSWindowController, NSWindowDelegate, NSOutlineViewDelegate, NSMenuItemValidation,
                                    NSSplitViewDelegate {
    /// The most automatic queries the window keeps.
    nonisolated static let maximumInstances = 40

    // MARK: Outlets of Query.xib

    @IBOutlet @objc public var outlineView: QueryOutlineView!
    @IBOutlet nonisolated(unsafe) var progressIndicator: NSProgressIndicator!
    @IBOutlet var searchFieldName: NSSearchField!
    @IBOutlet var searchFieldRefPhysician: NSSearchField!
    @IBOutlet var searchFieldID: NSSearchField!
    @IBOutlet var searchFieldAN: NSSearchField!
    @IBOutlet var searchFieldStudyDescription: NSSearchField!
    @IBOutlet var searchFieldComments: NSSearchField!
    @IBOutlet var searchInstitutionName: NSSearchField!
    @IBOutlet var searchCustomField: NSSearchField!
    @IBOutlet var dicomFieldsMenu: NSPopUpButton!
    @IBOutlet var sourcesTable: sourcesTableView!
    @IBOutlet var selectedResultSource: NSTextField!
    @IBOutlet var numberOfStudies: NSTextField!
    @IBOutlet var presetsPopup: NSPopUpButton!
    @IBOutlet var presetWindow: NSWindow!
    @IBOutlet var presetName: NSTextField!
    @IBOutlet var birthdateFilterMatrix: NSMatrix!
    @IBOutlet var dateFilterMatrix: NSMatrix!
    @IBOutlet var modalityFilterMatrix: NSMatrix!
    @IBOutlet var statusFilterMatrix: NSMatrix!
    @IBOutlet var PatientModeMatrix: NSTabView!
    @IBOutlet var fromDate: NSDatePicker!
    @IBOutlet var toDate: NSDatePicker!
    @IBOutlet var searchBirth: NSDatePicker!
    @IBOutlet var yearOldBirth: NSTextField!
    @IBOutlet var sendToPopup: NSPopUpButton!
    @IBOutlet var refreshGroup: NSView!
    @IBOutlet var autoQueryCounter: NSTextField!
    @IBOutlet var autoRetrieveWindow: NSWindow!
    @IBOutlet var alreadyInDatabase: NSImageView!
    @IBOutlet var partiallyInDatabase: NSImageView!
    @IBOutlet var addAutoQRInstanceWindow: NSWindow!
    @IBOutlet var autoQRInstanceName: NSTextField!
    @IBOutlet var autoQRNavigationControl: NSSegmentedControl!
    @IBOutlet @objc public var authView: SFHorosAuthorizationView!
    @IBOutlet var authButton: NSButton!

    // MARK: State

    /// The attributes of the DICOM dictionary, for the custom field's menu.
    nonisolated(unsafe) var dicomFields: [CIADICOMField] = []
    /// The DICOM nodes of the window, bound to the sources table.
    @objc nonisolated(unsafe) public var sourcesArray = NSMutableArray()
    /// The seconds before each automatic query is run again.
    nonisolated(unsafe) var autoQueryRemainingSecs = [Int](repeating: 0, count: QueryController.maximumInstances)
    @objc nonisolated(unsafe) public var DatabaseIsEdited = false
    let pressedKeys = NSMutableString()
    /// The studies shown, in the order of the outline.
    nonisolated(unsafe) var resultArray = NSMutableArray()
    /// The key of the last field queried.
    nonisolated(unsafe) var currentQueryKey: String?
    nonisolated(unsafe) var queryArrayPrefs = "SavedQueryArray"
    nonisolated(unsafe) var checkAndViewTry: Int32 = 0
    nonisolated(unsafe) var queryTimer: Timer?
    /// Reachable by KVC as queryManager, as the former instance variable was.
    @objc nonisolated(unsafe) var queryManager: QueryArrayController?
    nonisolated(unsafe) var autoQueryValue = false
    /// Whether the window observes the preferences: only a controller that
    /// loaded its window adds the observers, and removing one that was never
    /// added raises.
    var observesPreferences = false
    nonisolated(unsafe) var queryButtonPressed = false
    nonisolated(unsafe) var performingCFind = false
    var designedMinimumSize = NSSize.zero
    @objc nonisolated public let autoQueryLock = NSRecursiveLock()
    nonisolated(unsafe) var numberOfRunningRetrieve = 0
    nonisolated(unsafe) var lastTemporaryCFindResultUpdate: TimeInterval = 0
    nonisolated(unsafe) var temporaryCFindResultArray: NSMutableArray?
    nonisolated(unsafe) var firstServerRealtimeResults = false
    nonisolated(unsafe) var downloadedStudies: NSMutableArray?
    /// The automatic queries, each a preset with its name and last results.
    nonisolated(unsafe) var autoQRInstances: NSMutableArray?
    nonisolated(unsafe) var currentAutoQRValue: Int32 = 0
    /// The threads running a query of this window.
    nonisolated(unsafe) var performingQueryThreads = NSMutableSet()
    /// The local side of the results, read off the main thread; repaints read
    /// only this. The generation drops a read that a newer one overtook.
    nonisolated(unsafe) var localSnapshot: HorosLocalQuerySnapshot?
    var localSnapshotGeneration = 0
    /// What the workers read of the window, copied on the main thread.
    nonisolated(unsafe) var windowState = QueryWindowState()
    /// The study each series of a retrieve was listed under, for its WADO
    /// retrieve at series level, kept for the worker that runs it.
    nonisolated(unsafe) let studiesOfRetrievedSeries = NSMapTable<AnyObject, AnyObject>.weakToStrongObjects()

    // The current windows, kept by their own timer.
    nonisolated(unsafe) private static weak var currentWindow: QueryController?
    nonisolated(unsafe) private static weak var currentAutomaticWindow: QueryController?

    // MARK: Making the window

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The Query/Retrieve window (`autoQR` NO) or the automatic query's (YES).
    @objc(initAutoQuery:)
    public convenience init!(autoQuery autoQR: Bool) {
        self.init(windowNibName: "Query")

        if DICOMNodeService.nodes(sendOnly: false, queryRetrieveOnly: false).isEmpty && DICOMwebSources.queryRetrieveServers().isEmpty {
            // On the next turn of the run loop, for the reason given below where
            // the listener is warned about: this window is built during
            // -applicationDidFinishLaunching:, and a modal panel raised from
            // inside it stops the launch.
            DispatchQueue.main.async {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Query & Retrieve", comment: ""),
                                                message: NSLocalizedString("No DICOM locations available. See Preferences to add DICOM locations.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(observeDatabaseAddNotification(_:)), name: .OsirixAddToDB, object: nil)
        center.addObserver(self, selector: #selector(observeStoreCompletedNotification(_:)), name: NSNotification.Name("HorosDICOMStoreCompleted"), object: nil)
        center.addObserver(self, selector: #selector(retrieveInventoryDidRefresh(_:)),
                           name: NSNotification.Name(DCMTKQueryNode.retrieveInventoryDidRefreshNotification), object: nil)
        center.addObserver(self, selector: #selector(observeDatabaseSave(_:)), name: .NSManagedObjectContextDidSave, object: nil)
        center.addObserver(self, selector: #selector(observeActiveDatabaseChange(_:)),
                           name: .OsirixActiveLocalDatabaseDidChange, object: nil)

        currentQueryKey = nil
        autoQueryValue = autoQR
        queryArrayPrefs = autoQR ? "SavedQueryArrayAuto" : "SavedQueryArray"

        if let saved = UserDefaults.standard.object(forKey: queryArrayPrefs) as? NSArray {
            sourcesArray = saved.mutableCopy() as? NSMutableArray ?? NSMutableArray()
        }

        refreshSources()

        // Loads the nib: -awakeFromNib and -windowDidLoad run here.
        window?.delegate = self

        if !autoQR {
            window?.toolbar = nil

            _ = dateFilterMatrix.selectCell(withTag: UserDefaults.standard.integer(forKey: "QRLastDateFilterValue"))
            setDateQuery(dateFilterMatrix)

            QueryController.currentWindow = self
            window?.title = NSLocalizedString("DICOM Query/Retrieve", comment: "")

            // Only the nodes that retrieve with C-MOVE are affected; a WADO node
            // works with the listener off, and used to be warned about anyway.
            //
            // The panel is raised on the next turn of the run loop rather than
            // here. -applicationDidFinishLaunching: builds this window when the
            // Q&R window was open at quit, and a modal panel raised from inside
            // it stops the launch: sampling the main thread eleven seconds in
            // found it still at
            //   main -> applicationDidFinishLaunching: -> initAutoQuery:
            //        -> HorosRunCriticalAlertPanel -> runModalForWindow:
            // with no window on screen to explain it. Deferring lets the launch
            // finish first, and the panel then appears over a running
            // application.
            if AppController.shared()?.isStoreSCPRunning() == false &&
                RetrieveListenerRequirement.listenerRequired(forServers: UserDefaults.standard.object(forKey: "SERVERS") as? [[String: Any]]) {
                DispatchQueue.main.async {
                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Query & Retrieve", comment: ""),
                                                    message: NSLocalizedString("Retrieve from a node set to C-MOVE cannot work if the DICOM Listener is not activated. See Preferences - Listener. Nodes set to C-GET or WADO are not affected.", comment: ""),
                                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            }

            if let window {
                // Declare the window as its own full-screen primary: the nib does
                // not, so the Format - Fullscreen command used to do nothing here.
                FullScreenWindowSupport.enablePrimaryFullScreen(window)
                FullScreenWindowSupport.applyLevel(window, keepOnTop: UserDefaults.standard.bool(forKey: "KeepQRWindowOnTop"))
            }

            let defaults = NSUserDefaultsController.shared
            defaults.addObserver(self, forKeyPath: "values.KeepQRWindowOnTop", options: .initial, context: nil)
            defaults.addObserver(self, forKeyPath: "values.SERVERS", options: .initial, context: nil)
            defaults.addObserver(self, forKeyPath: "values.DICOMWEB_SERVERS", options: [], context: nil)
            observesPreferences = true
        } else {
            if let content = window?.contentView {
                view(content, recursiveBindEnableToObject: self, withKeyPath: "isUnlocked")
            }

            setDateQuery(dateFilterMatrix)

            QueryController.currentAutomaticWindow = self

            willChangeValue(forKey: "instancesMenuList")

            autoQRInstances = (UserDefaults.standard.object(forKey: "savedAutoDICOMQuerySettingsArray") as? NSArray)?.mutableCopy() as? NSMutableArray
            if autoQRInstances == nil {
                autoQRInstances = NSMutableArray()
            }

            // retro compatibility
            if let d = (UserDefaults.standard.object(forKey: "savedAutoDICOMQuerySettings") as? NSDictionary)?.mutableCopy() as? NSMutableDictionary {
                UserDefaults.standard.removeObject(forKey: "savedAutoDICOMQuerySettings")
                d.setObject(NSLocalizedString("Default Instance", comment: ""), forKey: "instanceName" as NSString)
                autoQRInstances?.add(d)
                UserDefaults.standard.set(autoQRInstances, forKey: "savedAutoDICOMQuerySettingsArray")
            }

            currentAutoQRValue = -1
            currentAutoQR = 0

            let instances = autoQRInstances ?? NSMutableArray()
            for i in 0..<min(instances.count, QueryController.maximumInstances) {
                let refresh = Int(QueryController.int32((instances[i] as AnyObject).value(forKey: "autoRefreshQueryResults")))
                autoQueryRemainingSecs[i] = refresh >= 0 ? 60 * refresh /* minutes */ : -refresh /* seconds */
            }
            didChangeValue(forKey: "instancesMenuList")
        }

        dicomFields = QueryController.publicDICOMFields()

        if let menu = dicomFieldsMenu.menu {
            menu.autoenablesItems = false
            dicomFieldsMenu.removeAllItems()
            for field in dicomFields {
                let item = NSMenuItem()
                item.title = field.title() ?? ""
                item.representedObject = field
                menu.addItem(item)

                if field.element() == 0x0080 && field.group() == 0x0008 {
                    dicomFieldsMenu.selectItem(withTitle: field.title() ?? "")
                }
            }
            dicomFieldsMenu.menu = menu
        }
    }

    isolated deinit {
        let defaults = NSUserDefaultsController.shared
        if observesPreferences {
            defaults.removeObserver(self, forKeyPath: "values.SERVERS")
            defaults.removeObserver(self, forKeyPath: "values.DICOMWEB_SERVERS")
            defaults.removeObserver(self, forKeyPath: "values.KeepQRWindowOnTop")
        }

        NotificationCenter.default.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(readLocalSnapshot), object: nil)
        localSnapshot = nil

        NSLog("dealloc QueryController")

        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(executeRefresh(_:)), object: nil)
        NSObject.cancelPreviousPerformRequests(withTarget: pressedKeys)

        autoQueryLock.lock()
        autoQueryLock.unlock()

        UserDefaults.standard.set(sourcesArray, forKey: queryArrayPrefs)
        fromDate?.dateValue = QueryController.startOfToday()
        queryTimer?.invalidate()
        queryTimer = nil

        if autoQueryValue {
            if QueryController.currentAutomaticWindow === self { QueryController.currentAutomaticWindow = nil }
        } else if QueryController.currentWindow === self {
            QueryController.currentWindow = nil
        }
    }

    // MARK: The current windows

    @objc(currentQueryController)
    public nonisolated class func current() -> QueryController? {
        return currentWindow
    }

    @objc(currentAutoQueryController)
    public nonisolated class func currentAuto() -> QueryController? {
        return currentAutomaticWindow
    }

    // MARK: Properties

    @objc public var autoQuery: Bool {
        get { autoQueryValue }
        set { autoQueryValue = newValue }
    }

    /// The minutes (or, negative, the seconds) between automatic refreshes,
    /// kept in the preferences. Bound in Query.xib.
    @objc public nonisolated dynamic var autoRefreshQueryResults: Int {
        get {
            UserDefaults.standard.integer(forKey: autoQueryValue ? "autoRefreshQueryResultsAutoQR" : "autoRefreshQueryResults")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoQueryValue ? "autoRefreshQueryResultsAutoQR" : "autoRefreshQueryResults")
        }
    }

    /// The automatic query shown. Setting it saves the one shown and shows the
    /// other; bound in Query.xib.
    @objc public dynamic var currentAutoQR: Int32 {
        get { currentAutoQRValue }
        set { showAutoQRInstance(newValue) }
    }

    // MARK: Window

    public override func awakeFromNib() {
        super.awakeFromNib()
        MainActor.assumeIsolated {
            windowAwoke()
        }
    }

    private func windowAwoke() {
        authView.setDelegate(self)
        authView.setString(QueryController.autoQRRight)
        _ = authView.updateStatus(self)

        numberOfStudies.stringValue = ""

        if autoQueryValue, let refreshGroup {
            var frame = refreshGroup.frame
            frame.origin.y += 6
            refreshGroup.frame = frame
        }

        PatientModeMatrix.selectTabViewItem(at: UserDefaults.standard.integer(forKey: autoQueryValue ? "AutoQRPatientModeMatrixIndex" : "QRPatientModeMatrixIndex"))

        for identifier in ["stateText", "serverStateText"] {
            let buttonCell = NSPopUpButtonCell(textCell: "", pullsDown: false)
            buttonCell.isBordered = false
            buttonCell.addItems(withTitles: (BrowserController.statesArray() as? [String]) ?? [])
            outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(identifier))?.dataCell = buttonCell
        }

        for field in [searchFieldAN, searchFieldStudyDescription, searchFieldComments, searchFieldRefPhysician, searchFieldID, searchFieldName] {
            let cellMenu = NSMenu(title: "Search Menu")
            let item1 = NSMenuItem(title: NSLocalizedString("Recent Searches", comment: ""), action: nil, keyEquivalent: "")
            item1.tag = NSSearchField.recentsTitleMenuItemTag
            cellMenu.insertItem(item1, at: 0)
            let item2 = NSMenuItem(title: NSLocalizedString("Recents", comment: ""), action: nil, keyEquivalent: "")
            item2.tag = NSSearchField.recentsMenuItemTag
            cellMenu.insertItem(item2, at: 1)
            let item3 = NSMenuItem(title: NSLocalizedString("Clear", comment: ""), action: nil, keyEquivalent: "")
            item3.tag = NSSearchField.clearRecentsMenuItemTag
            cellMenu.insertItem(item3, at: 2)
            (field?.cell as? NSSearchFieldCell)?.searchMenuTemplate = cellMenu
        }

        (outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("birthdate"))?.dataCell as? NSCell)?.formatter = UserDefaults.dateFormatter()
        (outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("date"))?.dataCell as? NSCell)?.formatter = UserDefaults.dateFormatter()

        sourcesTable.doubleAction = #selector(selectUniqueSource(_:))

        refreshSources()

        for i in 0..<sourcesArray.count where QueryController.bool((sourcesArray[i] as AnyObject).value(forKey: "activated")) {
            sourcesTable.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
            sourcesTable.scrollRowToVisible(i)
            break
        }

        buildPresetsMenu()

        alreadyInDatabase?.image = NSImage.pieChartImage(withPercentage: 1.0)
        partiallyInDatabase?.image = NSImage.pieChartImage(withPercentage: 0.33)

        autoQueryTimer(self)

        fromDate.dateValue = QueryController.startOfToday()
        toDate.dateValue = QueryController.startOfToday()

        window?.delegate = self

        setBirthDate(nil)

        installResultColumns()
        captureWindowState()
    }

    /// The right that unlocks the automatic query's settings. SFAuthorizationView
    /// may keep the pointer: a literal's static storage, as the former C string.
    private static var autoQRRight: UnsafePointer<CChar> {
        let right: StaticString = "BUNDLE_IDENTIFIER.autoQRWindow"
        return UnsafeRawPointer(right.utf8Start).assumingMemoryBound(to: CChar.self)
    }

    public override func windowDidLoad() {
        super.windowDidLoad()

        // The nib fixes a minimum designed for a large display. Kept as it is, a
        // smaller or differently scaled screen cannot show the whole window: the
        // height stops being adjustable and AppKit displaces the origin to
        // preserve the requested size.
        if let window {
            designedMinimumSize = window.minSize
            WindowSizeLimits.apply(designedMinimumSize, to: window)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        for field in [searchFieldName, searchFieldAN, searchFieldRefPhysician, searchFieldStudyDescription, searchFieldComments, searchFieldID] {
            let cancel = (field?.cell as? NSSearchFieldCell)?.cancelButtonCell
            cancel?.target = self
            cancel?.action = #selector(clearQuery(_:))
        }

        // OutlineView View

        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(retrieveAndViewClick(_:))
        outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("name"))?.dataCell = ImageAndTextCell()

        let menu = NSMenu(title: "Tools")
        for (title, action) in [("Retrieve the images", #selector(retrieve(_:))),
                                ("Retrieve and display the images", #selector(retrieveAndView(_:))),
                                ("Query all studies of this patient", #selector(querySelectedStudy(_:)))] {
            let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let delete = NSMenuItem(title: NSLocalizedString("Delete the local images", comment: ""), action: #selector(deleteSelection(_:)), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        outlineView.menu = menu

        // set up Query Keys
        currentQueryKey = QueryWindowField.patientName.key

        NotificationCenter.default.addObserver(self, selector: #selector(servicesDidChange(_:)), name: NSNotification.Name("DCMNetServicesDidChange"), object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(realtimeCFindResults(_:)), name: NSNotification.Name("realtimeCFindResults"), object: nil)

        let buttonCell = NSButtonCell()
        buttonCell.target = self
        buttonCell.action = #selector(retrieveClick(_:))
        buttonCell.controlSize = .mini
        buttonCell.image = NSImage(named: "InArrow.tif")
        buttonCell.bezelStyle = .accessoryBarAction // was NSBezelStyleFlexiblePush
        outlineView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("Button"))?.dataCell = buttonCell
        _ = RetrieveQueueArrows.install(on: outlineView, column: "Button")
    }

    @objc(screenParametersChanged:)
    func screenParametersChanged(_ notification: Notification) {
        if let window { WindowSizeLimits.apply(designedMinimumSize, to: window) }
    }

    @IBAction @objc(fullScreenMenu:)
    public func fullScreenMenu(_ sender: Any?) {
        if let window { FullScreenWindowSupport.toggleFullScreen(window) }
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        if let window {
            FullScreenWindowSupport.applyLevel(window, keepOnTop: UserDefaults.standard.bool(forKey: "KeepQRWindowOnTop"))
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        captureWindowState()
        if performingCFind {
            return
        }
        outlineView.reloadData()
    }

    public func windowWillClose(_ notification: Notification) {
        saveTableColumns()

        window?.acceptsMouseMovedEvents = false

        if autoQueryValue {
            UserDefaults.standard.set(PatientModeMatrix.indexOfTabViewItem(PatientModeMatrix.selectedTabViewItem!), forKey: "AutoQRPatientModeMatrixIndex")
        } else {
            UserDefaults.standard.set(dateFilterMatrix.selectedTag(), forKey: "QRLastDateFilterValue")
            UserDefaults.standard.set(PatientModeMatrix.indexOfTabViewItem(PatientModeMatrix.selectedTabViewItem!), forKey: "QRPatientModeMatrixIndex")
        }

        UserDefaults.standard.set(sourcesArray, forKey: queryArrayPrefs)

        saveSettings()

        window?.orderOut(self)
        captureWindowState()
    }

    /// Copies what the workers read of the window; main thread.
    func captureWindowState() {
        var state = QueryWindowState()
        state.sortDescriptors = outlineView?.sortDescriptors ?? []
        state.visible = window?.isVisible ?? false
        state.sendToIndex = sendToPopup?.indexOfSelectedItem ?? 0
        state.selectedSourceRow = sourcesTable?.selectedRow ?? -1
        state.fromDate = fromDate?.dateValue ?? Date()
        state.toDate = toDate?.dateValue ?? Date()
        windowState = state
    }

    public override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                                  change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard (object as AnyObject?) === NSUserDefaultsController.shared else { return }
        // The shared defaults controller reports a default written by a worker
        // thread on that thread.
        let controller = self
        let keyPath = keyPath ?? ""
        onMainActor {
            if keyPath == "values.KeepQRWindowOnTop", let window = controller.window {
                FullScreenWindowSupport.applyLevel(window, keepOnTop: UserDefaults.standard.bool(forKey: "KeepQRWindowOnTop"))
            }
            if keyPath == "values.SERVERS" || keyPath == "values.DICOMWEB_SERVERS" {
                controller.refreshSources()
            }
        }
    }

    // MARK: Sheets

    @IBAction @objc(cancel:)
    public func cancel(_ sender: Any?) {
        NSApp.abortModal()
    }

    @IBAction @objc(ok:)
    public func ok(_ sender: Any?) {
        NSApp.stopModal()
    }

    // MARK: Keys, copy and delete

    public override func keyDown(with event: NSEvent) {
        guard let characters = event.characters, let first = characters.utf16.first else { return }
        let c = Int(first)

        guard window?.firstResponder === outlineView else { return }

        if c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey {
            deleteSelection(self)
        } else if c == 0x20 {
            retrieve(self, onlyIfNotAvailable: true)
        } else if c == NSNewlineCharacter || c == NSEnterCharacter || c == NSCarriageReturnCharacter {
            retrieveAndView(self)
        } else if c == 27 { // Escape
            (queryManager?.rootNode() as? DCMTKQueryNode)?._abortAssociation = true
        } else {
            pressedKeys.append(characters)

            let resultFilter = resultArray.filtered(using: NSPredicate(format: "name BEGINSWITH[cd] %@", pressedKeys))

            NSObject.cancelPreviousPerformRequests(withTarget: pressedKeys, selector: #selector(NSMutableString.setString(_:)), object: "")
            pressedKeys.perform(#selector(NSMutableString.setString(_:)), with: "", afterDelay: 0.5)

            if let first = resultFilter.first {
                outlineView.selectRowIndexes(IndexSet(integer: outlineView.row(forItem: first)), byExtendingSelection: false)
                outlineView.scrollRowToVisible(outlineView.selectedRow)
            } else {
                NSSound.beep()
            }
        }
    }

    @IBAction @objc(copy:)
    public func copy(_ sender: Any?) {
        let pb = NSPasteboard.general
        pb.declareTypes([.string], owner: self)

        let string: String?
        if outlineView.selectedRowIndexes.count == 1, let first = outlineView.selectedRowIndexes.first {
            string = (outlineView.item(atRow: first) as AnyObject?)?.value(forKey: "name") as? String
        } else {
            string = exportDBList(onlySelected: true)
        }
        pb.setString(string ?? "", forType: .string)
    }

    @objc(validateMenuItem:)
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(deleteSelection(_:)) else { return true }

        BrowserController.currentBrowser()?.database = DicomDatabase.activeLocal()
        BrowserController.currentBrowser()?.showEntireDatabase()

        var valid = false
        for row in outlineView.selectedRowIndexes where (localStudy(outlineView.item(atRow: row), context: nil)?.count ?? 0) > 0 {
            valid = true
        }
        return valid
    }

    @objc(deleteSelection:)
    func deleteSelection(_ sender: Any?) {
        let indices = outlineView.selectedRowIndexes
        let somethingToDelete = indices.contains { outlineView.item(atRow: $0) is DCMTKStudyQueryNode }

        if !somethingToDelete {
            if indices.count > 0 {
                _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Delete images", comment: ""),
                                                     message: NSLocalizedString("Select a study to delete it. You cannot delete series from this window, go to the Database window to delete series.", comment: ""),
                                                     defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
            return
        }

        guard let browser = BrowserController.currentBrowser() else { return }
        browser.database = DicomDatabase.activeLocal()
        browser.showEntireDatabase()

        var extendingSelection = false
        do {
            try HorosObjCException.perform {
                for row in indices {
                    let item = self.outlineView.item(atRow: row)
                    if item is DCMTKStudyQueryNode {
                        if let study = self.localStudy(item, context: nil)?.first,
                           let series = (browser.childrenArray(study, onlyImages: false)?.first as AnyObject?) {
                            let image = (series.value(forKey: "images") as? NSSet)?.anyObject() as? DicomImage
                            _ = browser.findAndSelectFile(nil, image: image, shouldExpand: false, extendingSelection: extendingSelection)
                            extendingSelection = true
                        }
                    } else {
                        self.outlineView.deselectRow(row)
                    }
                }

                if extendingSelection {
                    browser.delItem(nil)
                }
            }
        } catch {
            QueryController.log(error, "-[QueryController deleteSelection:]")
        }
    }

    // MARK: Split view

    public func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        return splitView.subviews.first !== view
    }

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return dividerIndex == 0 ? 100 : proposedMinimumPosition
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        return dividerIndex == 0 ? splitView.bounds.size.height - 150 : proposedMaximumPosition
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        return true
    }

    // MARK: Authorization of the automatic query's settings

    @objc public var isUnlocked: Bool {
        return authView?.authorizationState() == SFAuthorizationViewUnlockedState
    }

    public override func authorizationViewDidAuthorize(_ view: SFAuthorizationView!) {
        MainActor.assumeIsolated { authorizationChanged() }
    }

    public override func authorizationViewDidDeauthorize(_ view: SFAuthorizationView!) {
        MainActor.assumeIsolated { authorizationChanged() }
    }

    private func authorizationChanged() {
        willChangeValue(forKey: "isUnlocked")
        didChangeValue(forKey: "isUnlocked")
        authButton.image = NSImage(named: isUnlocked ? "NSLockUnlockedTemplate" : "NSLockLockedTemplate")
    }

    @IBAction @objc(authAction:)
    func authAction(_ sender: Any?) {
        authView.buttonPressed(nil)
    }

    /// Binds the enabled state of every control under `view` to `keyPath` of
    /// `obj`, after the bindings it already has.
    @objc(view:recursiveBindEnableToObject:withKeyPath:)
    public func view(_ view: NSView, recursiveBindEnableToObject obj: Any, withKeyPath keyPath: String) {
        if view is NSControl {
            var bki = 0
            var bk = ""
            var doBind = true

            while doBind {
                bki += 1
                bk = "enabled" + (bki == 1 ? "" : String(bki))

                guard let b = view.infoForBinding(NSBindingName(bk)) else { break }

                if (b[NSBindingInfoKey.observedObject] as AnyObject?) === (obj as AnyObject) &&
                    (b[NSBindingInfoKey.observedKeyPath] as? String) == keyPath {
                    doBind = false // already bound
                }
            }

            if doBind {
                do {
                    try HorosObjCException.perform {
                        view.bind(NSBindingName(bk), to: obj, withKeyPath: keyPath,
                                  options: [.conditionallySetsEnabled: true])
                    }
                    return
                } catch {
                    NSLog("Warning: %@", QueryController.describe(error))
                }
            }
        }

        for subview in view.subviews {
            self.view(subview, recursiveBindEnableToObject: obj, withKeyPath: keyPath)
        }

        if let tabView = view as? NSTabView {
            for tabItem in tabView.tabViewItems {
                if let itemView = tabItem.view {
                    self.view(itemView, recursiveBindEnableToObject: obj, withKeyPath: keyPath)
                }
            }
        }
    }

    // MARK: Helpers

    /// Midnight of today, as the date pickers start.
    static func startOfToday() -> Date {
        let now = DICOMCalendarDate()
        let midnight = DICOMCalendarDate(year: now.yearOfCommonEra(), month: UInt(now.monthOfYear()), day: UInt(now.dayOfMonth()),
                                       hour: 0, minute: 0, second: 0, timeZone: nil) as Date?
        return midnight ?? Date()
    }

    /// -intValue of a value that may be a number or a string.
    nonisolated static func int32(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }

    /// -boolValue of a value that may be a number or a string.
    nonisolated static func bool(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? NSString { return string.boolValue }
        return false
    }

    /// The exception or error, as the former @catch logged it.
    nonisolated static func describe(_ error: Error) -> String {
        if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
            return exception.description
        }
        return (error as NSError).description
    }

    /// N2LogExceptionWithStackTrace(e) in the former method `function`.
    nonisolated static func log(_ error: Error, _ function: String) {
        if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
            _N2LogExceptionImpl(exception, true, function)
        } else {
            NSLog("%@: %@", function, (error as NSError).description)
        }
    }

    /// N2LogStackTrace(message).
    nonisolated static func logStackTrace(_ message: String) {
        NSLog("%@\n%@", message, Thread.callStackSymbols.joined(separator: "\n"))
    }

    /// @synchronized(object) { body }: nothing to lock when the object is nil.
    nonisolated static func synchronized<T>(_ object: AnyObject?, _ body: () throws -> T) rethrows -> T {
        guard let object else { return try body() }
        objc_sync_enter(object)
        defer { objc_sync_exit(object) }
        return try body()
    }

    /// N2LocalizedSingularPluralCount(count, singular, plural).
    nonisolated static func singularPluralCount(_ count: Int, _ singular: String, _ plural: String) -> String {
        return String(format: "%@ %@", NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal),
                      count == 1 ? singular : plural)
    }
}

/// The values of the Query window a worker thread needs: copied on the main
/// thread when the window changes them, before a worker starts, and every
/// second by the refresh timer.
struct QueryWindowState {
    var sortDescriptors: [NSSortDescriptor] = []
    var visible = false
    var sendToIndex = 0
    var selectedSourceRow = -1
    var fromDate = Date()
    var toDate = Date()
}
