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
import Synchronization
import IsiXDICOMNetwork
import IsiXDICOMFile
import IsiXPreferences

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
/// The window's state is the main actor's. Queries and retrieves run on
/// worker threads, as they did: each receives what it needs of the window as
/// values copied on the main thread (QueryWindowRun and QueryWindowState of
/// IsiXDICOMNetwork), and what they genuinely share with the window (the query
/// manager, the answers shown while a C-FIND runs, whether one runs) is in
/// QueryWindowWorkerState, under its lock. `@synchronized` became objc_sync on
/// the same objects.
///
/// The automatic query, and the automatic refresh of the Query/Retrieve
/// window, run in the AutoQueryScheduler actor of IsiXDICOMNetwork; the
/// window only makes it, hands it the instances and shows what comes back.
///
/// As before, a controller keeps itself alive: the countdown of its scheduler
/// keeps the scheduler's ports, which keep the window, as the one-second timer
/// did, and +currentQueryController answers it.
@objc(QueryController)
public final class QueryController: NSWindowController, NSWindowDelegate, NSOutlineViewDelegate, NSMenuItemValidation,
                                    NSSplitViewDelegate, AutoQueryCountdownDisplay {
    /// The most automatic queries the window keeps.
    nonisolated static let maximumInstances = AutoQueryScheduler.maximumInstances

    // MARK: Outlets of Query.xib

    @IBOutlet @objc public var outlineView: QueryOutlineView!
    @IBOutlet var progressIndicator: NSProgressIndicator!
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
    var dicomFields: [CIADICOMField] = []
    /// The DICOM nodes of the window, bound to the sources table.
    @objc public var sourcesArray = NSMutableArray()
    @objc public var DatabaseIsEdited = false
    let pressedKeys = NSMutableString()
    /// What the window does after a pause: forget the typed letters, read
    /// what of the results is here, refresh once the database is quiet, open
    /// a retrieved item once it has arrived.
    let deferredCalls = DeferredCalls()
    /// The studies shown, in the order of the outline.
    var resultArray = NSMutableArray()
    var queryArrayPrefs = NetworkPreferences.querySources.name
    var checkAndViewTry: Int32 = 0
    /// The query manager of the last query asked, kept for the threads that
    /// run it. Reachable by KVC as queryManager, as the former instance
    /// variable was.
    @objc nonisolated var queryManager: QueryArrayController? {
        get { workers.queryManager }
        set { workers.queryManager = newValue }
    }
    var autoQueryValue = false
    /// Whether the window observes the preferences: only a controller that
    /// loaded its window adds the observers, and removing one that was never
    /// added raises.
    var observesPreferences = false
    var queryButtonPressed = false
    var designedMinimumSize = NSSize.zero
    @objc nonisolated public let autoQueryLock = NSRecursiveLock()
    /// The retrieves of this window under way, which its automatic retrieve
    /// counts before starting another.
    nonisolated let retrieves = RetrieveMoveQueue()
    /// What the window shares with the threads that query and retrieve for it.
    nonisolated let workers = QueryWindowWorkerState()
    /// The automatic queries, each a preset with its name; the scheduler
    /// receives them after each change.
    var autoQRInstances: [AutoQueryInstance] = [] {
        didSet { autoQueryInstancesDidChange() }
    }
    /// The answers of each instance's last query, shown with it.
    var autoQRAnswers: [UUID: [Any]] = [:]
    /// When each automatic query runs; also the automatic refresh of the
    /// Query/Retrieve window, whose filters are its one instance.
    var autoQueryScheduler: AutoQueryScheduler?
    /// The commands handed to the scheduler, run in the order they were given.
    var autoQuerySchedulerCommands: Task<Void, Never>?
    /// The instance of the Query/Retrieve window's automatic refresh.
    let windowRefreshID = UUID()
    /// What the whole process shares, handed over by the window's factory.
    var processGraph: ProcessGraph! {
        didSet { graphForWorkers.withLock { $0 = processGraph } }
    }
    /// The same graph, for the query and retrieve threads.
    private nonisolated let graphForWorkers = Mutex<ProcessGraph?>(nil)
    nonisolated var workerGraph: ProcessGraph? { graphForWorkers.withLock { $0 } }
    var currentAutoQRValue: Int32 = 0
    /// The local side of the results, read off the main thread; repaints read
    /// only this. The generation drops a read that a newer one overtook.
    nonisolated var localSnapshot: HorosLocalQuerySnapshot? { workers.localSnapshot }
    var localSnapshotGeneration = 0
    /// What the workers read of the window, copied on the main thread.
    nonisolated var windowState: QueryWindowState { workers.windowState }

    // The current windows, kept by their own timer.
    private static weak var currentWindow: QueryController?
    private static weak var currentAutomaticWindow: QueryController?

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
        // The factory of the window: what follows, the nib included, uses the
        // graph it hands over.
        self.init(windowNibName: "Query")
        processGraph = ProcessGraph.process
        // A property observer does not run when the class's own initializer
        // sets the property, so the worker threads' copy is handed over here;
        // without it every retrieve thread saw no database and did nothing.
        graphForWorkers.withLock { $0 = processGraph }

        if DICOMNodeService.dicomNodes(sendOnly: false, queryRetrieveOnly: false).isEmpty && DICOMwebSources.queryRetrieveServers().isEmpty {
            // On the next turn of the main run loop, for the reasons given below
            // where the listener is warned about: this window is built during
            // -applicationDidFinishLaunching:, and a modal panel raised from
            // inside it stops the launch; raised from the main queue, it would
            // stop that queue.
            onMainRunLoop {
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

        autoQueryValue = autoQR
        queryArrayPrefs = (autoQR ? NetworkPreferences.autoQuerySources : NetworkPreferences.querySources).name

        if let saved = preferences.object(forKey: queryArrayPrefs) as? NSArray {
            sourcesArray = saved.mutableCopy() as? NSMutableArray ?? NSMutableArray()
        }

        refreshSources()

        // Loads the nib: -awakeFromNib and -windowDidLoad run here.
        window?.delegate = self

        if !autoQR {
            window?.toolbar = nil

            _ = dateFilterMatrix.selectCell(withTag: preferences[NetworkPreferences.queryLastDateFilter])
            setDateQuery(dateFilterMatrix)

            QueryController.currentWindow = self
            window?.title = NSLocalizedString("DICOM Query/Retrieve", comment: "")

            // Only the nodes that retrieve with C-MOVE are affected; a WADO node
            // works with the listener off, and used to be warned about anyway.
            //
            // The panel is raised on the next turn of the main run loop rather
            // than here. -applicationDidFinishLaunching: builds this window when the
            // Q&R window was open at quit, and a modal panel raised from inside
            // it stops the launch: sampling the main thread eleven seconds in
            // found it still at
            //   main -> applicationDidFinishLaunching: -> initAutoQuery:
            //        -> HorosRunCriticalAlertPanel -> runModalForWindow:
            // with no window on screen to explain it. Deferring lets the launch
            // finish first, and the panel then appears over a running
            // application. The launch runs outside any turn of the run loop, so
            // the panel waits for it to return. Not the main queue: a modal
            // inside one of its blocks serves neither the queue nor what waits
            // for it, and with nobody to answer the panel an import stops there.
            if processGraph.appController?.isStoreSCPRunning() == false &&
                RetrieveListenerRequirement.listenerRequired(forServers: preferences[NetworkPreferences.dicomNodes].flatMap { $0.map(\.object) as? [[String: Any]] }) {
                onMainRunLoop {
                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("DICOM Query & Retrieve", comment: ""),
                                                    message: NSLocalizedString("Retrieve from a node set to C-MOVE cannot work if the DICOM Listener is not activated. See Preferences - Listener. Nodes set to C-GET or WADO are not affected.", comment: ""),
                                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            }

            if let window {
                // Declare the window as its own full-screen primary: the nib does
                // not, so the Format - Fullscreen command used to do nothing here.
                FullScreenWindowSupport.enablePrimaryFullScreen(window)
                FullScreenWindowSupport.applyLevel(window, keepOnTop: preferences[NetworkPreferences.keepsQueryWindowOnTop])
            }

            let defaults = NSUserDefaultsController.shared
            defaults.addObserver(self, forKeyPath: NetworkPreferences.controllerKeyPath(NetworkPreferences.keepsQueryWindowOnTop), options: .initial, context: nil)
            defaults.addObserver(self, forKeyPath: NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomNodes), options: .initial, context: nil)
            defaults.addObserver(self, forKeyPath: NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomwebNodes), options: [], context: nil)
            observesPreferences = true
        } else {
            if let content = window?.contentView {
                view(content, recursiveBindEnableToObject: self, withKeyPath: "isUnlocked")
            }

            setDateQuery(dateFilterMatrix)

            QueryController.currentAutomaticWindow = self

            willChangeValue(forKey: "instancesMenuList")

            // With the single instance of former versions moved into the list.
            // Each instance starts counting from its own interval.
            autoQRInstances = AutoQueryInstanceStore.load(from: NodePreferences(processGraph: processGraph),
                                                          defaultName: NSLocalizedString("Default Instance", comment: ""))
            // An initializer does not run the property's observers: the
            // scheduler, made when the nib loaded, receives them here.
            autoQueryInstancesDidChange()

            currentAutoQRValue = -1
            currentAutoQR = 0

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
            defaults.removeObserver(self, forKeyPath: NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomNodes))
            defaults.removeObserver(self, forKeyPath: NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomwebNodes))
            defaults.removeObserver(self, forKeyPath: NetworkPreferences.controllerKeyPath(NetworkPreferences.keepsQueryWindowOnTop))
        }

        NotificationCenter.default.removeObserver(self)
        deferredCalls.cancelAll()
        workers.localSnapshot = nil

        NSLog("dealloc QueryController")

        autoQueryLock.lock()
        autoQueryLock.unlock()

        preferences.set(sourcesArray, forKey: queryArrayPrefs)
        fromDate?.dateValue = QueryController.startOfToday()
        if let scheduler = autoQueryScheduler {
            Task { await scheduler.stop() }
        }

        if autoQueryValue {
            if QueryController.currentAutomaticWindow === self { QueryController.currentAutomaticWindow = nil }
        } else if QueryController.currentWindow === self {
            QueryController.currentWindow = nil
        }
    }

    // MARK: The current windows

    @objc(currentQueryController)
    public class func current() -> QueryController? {
        return currentWindow
    }

    @objc(currentAutoQueryController)
    public class func currentAuto() -> QueryController? {
        return currentAutomaticWindow
    }

    // MARK: Properties

    @objc public var autoQuery: Bool {
        get { autoQueryValue }
        set { autoQueryValue = newValue }
    }

    /// The minutes (or, negative, the seconds) between automatic refreshes,
    /// kept in the preferences, within one day either way: a corrupted value
    /// would not fit the countdown. Bound in Query.xib.
    @objc public dynamic var autoRefreshQueryResults: Int {
        get {
            QueryRefreshSetting.clamped(preferences[autoQueryValue ? NetworkPreferences.autoQueryRefreshSetting : NetworkPreferences.queryRefreshSetting])
        }
        set {
            preferences.set(newValue, for: autoQueryValue ? NetworkPreferences.autoQueryRefreshSetting : NetworkPreferences.queryRefreshSetting)
        }
    }

    /// The preferences, as the process graph hands them to any thread.
    nonisolated var preferences: UserDefaults {
        workerGraph?.preferences ?? PreferencesSource.process.preferences
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

        PatientModeMatrix.selectTabViewItem(at: preferences[autoQueryValue ? NetworkPreferences.autoQueryPatientModeIndex : NetworkPreferences.queryPatientModeIndex])

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

        for (i, source) in currentSources().enumerated() where source.activated {
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
            FullScreenWindowSupport.applyLevel(window, keepOnTop: preferences[NetworkPreferences.keepsQueryWindowOnTop])
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        captureWindowState()
        if workers.isPerformingCFind {
            return
        }
        outlineView.reloadData()
    }

    public func windowWillClose(_ notification: Notification) {
        saveTableColumns()

        window?.acceptsMouseMovedEvents = false

        if autoQueryValue {
            preferences.set(PatientModeMatrix.indexOfTabViewItem(PatientModeMatrix.selectedTabViewItem!), for: NetworkPreferences.autoQueryPatientModeIndex)
        } else {
            preferences.set(dateFilterMatrix.selectedTag(), for: NetworkPreferences.queryLastDateFilter)
            preferences.set(PatientModeMatrix.indexOfTabViewItem(PatientModeMatrix.selectedTabViewItem!), for: NetworkPreferences.queryPatientModeIndex)
        }

        preferences.set(sourcesArray, forKey: queryArrayPrefs)

        saveSettings()

        window?.orderOut(self)
        captureWindowState()
    }

    /// Copies what the workers read of the window; main thread.
    func captureWindowState() {
        workers.windowState = currentWindowState()
    }

    /// What the workers read of the window, as it is now.
    func currentWindowState() -> QueryWindowState {
        var state = QueryWindowState()
        state.sortKeys = (outlineView?.sortDescriptors ?? []).map(QueryController.sortKey)
        state.visible = window?.isVisible ?? false
        state.sendToIndex = sendToPopup?.indexOfSelectedItem ?? 0
        state.selectedSourceRow = sourcesTable?.selectedRow ?? -1
        state.fromDate = fromDate?.dateValue ?? Date()
        state.toDate = toDate?.dateValue ?? Date()
        state.sources = currentSources()
        return state
    }

    /// The rows of the sources table, as values.
    func currentSources() -> [QueryWindowSource] {
        return sourcesArray.map { row in
            let source = row as? [String: Any] ?? [:]
            return QueryWindowSource(addressAndPort: source["AddressAndPort"] as? String, aeTitle: source["AETitle"] as? String,
                                     activated: QueryController.bool(source["activated"]),
                                     server: source["server"].flatMap { DICOMNode(propertyList: $0) })
        }
    }

    /// A sort descriptor of the results list, by its parts.
    nonisolated static func sortKey(_ descriptor: NSSortDescriptor) -> QueryWindowState.SortKey {
        return QueryWindowState.SortKey(key: descriptor.key, ascending: descriptor.ascending,
                                        selector: descriptor.selector.map(NSStringFromSelector))
    }

    /// The sort descriptor of `key`, made again on the thread that sorts.
    nonisolated static func sortDescriptor(_ key: QueryWindowState.SortKey) -> NSSortDescriptor {
        return NSSortDescriptor(key: key.key, ascending: key.ascending, selector: key.selector.map(NSSelectorFromString))
    }

    public override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                                  change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard (object as AnyObject?) === NSUserDefaultsController.shared else { return }
        // The shared defaults controller reports a default written by a worker
        // thread on that thread.
        let controller = self
        let keyPath = keyPath ?? ""
        onMainActor {
            if keyPath == NetworkPreferences.controllerKeyPath(NetworkPreferences.keepsQueryWindowOnTop), let window = controller.window {
                FullScreenWindowSupport.applyLevel(window, keepOnTop: controller.preferences[NetworkPreferences.keepsQueryWindowOnTop])
            }
            if keyPath == NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomNodes) || keyPath == NetworkPreferences.controllerKeyPath(NetworkPreferences.dicomwebNodes) {
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

            deferredCalls.cancel("forgetPressedKeys")
            deferredCalls.perform("forgetPressedKeys", after: 0.5) { [pressedKeys] in pressedKeys.setString("") }

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

        processGraph.currentBrowser?.database = DicomDatabase.activeLocal()
        processGraph.currentBrowser?.showEntireDatabase()

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

        guard let browser = processGraph.currentBrowser else { return }
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
