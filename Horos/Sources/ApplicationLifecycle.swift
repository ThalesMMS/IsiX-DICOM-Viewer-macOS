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

import Cocoa
import CoreData
import IsiXPreferences
import IsiXStorage

// The application's launch, activation and quitting: what +initialize, -init,
// -applicationWillFinishLaunching:, -applicationDidFinishLaunching:, the
// activation delegate methods, -terminate: and -applicationWillTerminate: of
// AppController did. AppController keeps those selectors, which AppKit, the
// nib and the former plugins send, and hands their work here.

/// The wait for a volume a launch needs: a panel that offers to quit or to go
/// on, closed when the volume appears or after DatabaseVolume.waitLimit.
@MainActor struct DatabaseVolumeWait {
    /// The volume waited for ("/Volumes/Name").
    let volume: String
    /// What the panel says.
    let message: String

    /// Shows the panel until the user goes on, the volume appears or the time
    /// runs out; Quit ends the process.
    func run() {
        let dialog = NSPanel.alert(withTitle: DatabaseLocation.dataDirectoryName, message: message,
                                   defaultButton: "Quit", alternateButton: "Continue", icon: nil)
        let session = NSApp.beginModalSession(for: dialog)
        let deadline = Date.timeIntervalSinceReferenceDate + DatabaseVolume.waitLimit
        waiting: while true {
            let response = NSApp.runModalSession(session).rawValue
            switch DatabaseVolume.step(response: response, quitResponse: HorosAlertPanel.defaultResponse,
                                       continueResponse: HorosAlertPanel.alternateResponse,
                                       volumeExists: FileManager.default.fileExists(atPath: volume),
                                       now: Date.timeIntervalSinceReferenceDate, deadline: deadline) {
            case .quit:
                exit(0)
            case .proceed(let timedOut):
                if timedOut {
                    NSLog("Warning: after waiting for 10 minutes, Horos is switching to the default database location because %@ is still not available", volume as NSString)
                }
                break waiting
            case .wait:
                continue
            }
        }
        NSApp.endModalSession(session)
        dialog.orderOut(nil)
    }
}

/// The launch, the activation and the quitting of the application, on the
/// main actor. The application controller makes it once and keeps it.
@MainActor final class ApplicationLifecycle {

    /// What the former +initialize set once for the process.
    @MainActor private enum Once {
        static var initialized = false
        static var pluginManager: PluginManager?
    }

    private unowned let controller: AppController
    private let processGraph: ProcessGraph
    private let preferences: any PreferenceStore

    /// The first activation of a launch is the launch's own.
    private var firstActivation = true
    /// Whether a `horos://` link launched the app. Such a launch is a RIS
    /// request, and it does not bring back the Query/Retrieve window left open
    /// at the last quit: the request never uses that window.
    private(set) var launchedForURL = false
    private(set) var launchFinished = false
    private(set) var quitting = false

    init(controller: AppController, processGraph: ProcessGraph,
         preferences: any PreferenceStore = PreferencesSource.process.preferences) {
        self.controller = controller
        self.processGraph = processGraph
        self.preferences = preferences
    }

    /// The database window, from the application's nib.
    private var browser: BrowserController? {
        controller.browserWindow?.browser
    }

    /// A link arrived: before the launch has finished, it is what launched the app.
    func noteLinkArrived() {
        if !launchFinished { launchedForURL = true }
    }

    // MARK: - Before the application controller

    /// The former +initialize: the log of the machine, the preferences, the
    /// wait for the database's volumes, the crash check of the last start, the
    /// codecs and the plugins. Once per process, before the database window.
    static func initializeProcess() {
        guard !Once.initialized, (Bundle.main.infoDictionary?["CFBundlePackageType"] as? String) == "APPL" else { return }
        Task { await ActivityThread.runUnlisted(name: "DNS resolve") { AppController.DNSResolve(nil) } }

        Once.initialized = true

        srandom(UInt32(truncatingIfNeeded: time(nil)))

        if AppController.hasMacOSXElCapitan() == false {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("macOS", comment: ""), message: NSLocalizedString("This application requires macOS 10.11 or higher. Please upgrade your operating system.", comment: ""), defaultButton: NSLocalizedString("Quit", comment: ""), alternateButton: nil, otherButton: nil)
            exit(0)
        }

        logMachine()
        ApplicationPreferencesSetup.adoptLayoutDebugging()
        #if DEBUG
        NSLog("**** DEBUG MODE ****")
        #endif

        ApplicationPreferencesSetup.register()

        waitForDatabaseVolumes(preferences: PreferencesSource.process.preferences)

        // Before the main menu's nib binds the Web Portal's accounts, which
        // opens them: an import from the earlier versions' folder must come first.
        LegacySupportImportPrompt.importIfNeeded()

        // A temporary file during the start. Before the plugins: Protected
        // Mode chosen here must keep them out, and a plugin marker left by the
        // last run is still there.
        if !DatabaseFirstUse.hasPendingChoice {
            let path = (DicomDatabase.defaultBaseDirPath() as NSString?)?.appendingPathComponent("Loading")
            let pluginMarkerExists = FileManager.default.fileExists(atPath: PluginManager.crashMarkerPath())

            // Asked in server mode too: hiding listener errors has nothing
            // to do with a start that keeps failing.
            if FileManager.default.fileExists(atPath: path ?? "") &&
                PluginUpdateRecovery.shouldOfferDatabaseRebuild(loadingFileExists: true, pluginMarkerExists: pluginMarkerExists) {
                let result = HorosAlertPanel.runInformational(title: NSLocalizedString("IsiX DICOM Viewer crashed during last startup", comment: ""), message: NSLocalizedString("Previous crash is maybe related to a corrupt database or corrupted images.\r\rShould I run IsiX DICOM Viewer in Protected Mode (recommended) (no images displayed)? To allow you to delete the crashing/corrupted images/studies.\r\rOr Should I rebuild the local database? All albums, comments and status will be lost.", comment: ""), defaultButton: NSLocalizedString("Continue normally", comment: ""), alternateButton: NSLocalizedString("Protected Mode", comment: ""), otherButton: NSLocalizedString("Rebuild Database", comment: ""))

                if result == HorosAlertPanel.otherResponse {
                    NEEDTOREBUILD = true
                    COMPLETEREBUILD = true
                }
                if result == HorosAlertPanel.alternateResponse { ProtectedMode.activate() }
            }

            if let path {
                try? path.write(toFile: path, atomically: false, encoding: .utf8)
            }
        }

        LegacySupportImportPrompt.offerPluginsIfNeeded()

        // DCMTK starts its own log, written to the standard error, at a level
        // where it prints the identifier of each C-FIND a peer sends the
        // listener. Set here, before anything of DCMTK runs - the plugins, the
        // listeners, a query or a send - and not when the first send does it.
        IsiXDCMTKLog.configure(dumpsDatasets: PreferencesSource.process.preferences[NetworkPreferences.dumpsDICOMDatasets])

        // Plugins may read DICOM through DCMObject as they load.
        AppController.registerDCMTKCodecs()
        Once.pluginManager = PluginManager()

        ApplicationPreferencesSetup.addPresets()

        Reports.checkForWordTemplates()
        Reports.checkForPagesTemplate()
    }

    /// The processors, screens, versions and localization, in the log.
    private static func logMachine() {
        var processors: Int32 = 0
        var mib: [Int32] = [CTL_HW, HW_NCPU]
        var dataLen: Int = MemoryLayout<Int32>.size // 'num' is an 'int'
        if sysctl(&mib, 2, &processors, &dataLen, nil, 0) == -1 {
            processors = 1
        }
        let bits = MemoryLayout<Int>.size == 8 ? "64-bit" : "32-bit"

        NSLog("*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*-+-*")
        NSLog("Number of processors: %d / %d", processors, Int32(truncatingIfNeeded: ProcessInfo.processInfo.processorCount))
        NSLog("Number of screens: %d", Int32(truncatingIfNeeded: NSScreen.screens.count))
        NSLog("Main screen backingScaleFactor: %f", Double(Float(NSScreen.main?.backingScaleFactor ?? 0)))
        let info = Bundle.main.infoDictionary
        NSLog("Horos version: %@ - %@ - %@", String(describing: info?[kCFBundleVersionKey as String] ?? "(null)") as NSString,
              String(describing: info?["CFBundleShortVersionString"] ?? "(null)") as NSString, bits as NSString)
        // <OpenJPEG/opj_config.h> is not published with the framework: AppController+CAPI.m reads it.
        var opjMajor: Int32 = 0, opjMinor: Int32 = 0, opjBuild: Int32 = 0
        AppControllerCAPIOpenJPEGVersion(&opjMajor, &opjMinor, &opjBuild)
        NSLog("OpenJPEG %d.%d.%d", opjMajor, opjMinor, opjBuild)
        let components = (Bundle.main.path(forResource: "Localizable", ofType: "strings") as NSString?)?.pathComponents ?? []
        if components.count > 3 {
            NSLog("Localization: %@", components[components.count - 2] as NSString)
        }
    }

    /// The database's documents folder resolved from the preferences; nil
    /// when it cannot be (a folder on a volume that is not mounted).
    private static func resolvedDocumentsFolder(_ preferences: any PreferenceStore) -> String? {
        var path: String?
        if let exception = HorosObjCException.caught({
            path = DicomDatabase.baseDirPath(forMode: Int32(truncatingIfNeeded: preferences[DatabasePreferences.databaseLocation]),
                                             path: preferences[DatabasePreferences.databaseLocationURL])
        }) {
            _N2LogExceptionImpl(exception, false, "+[AppController initialize]")
        }
        return path
    }

    /// A database on a volume that is not mounted yet waits for it, and so
    /// does a data folder moved to one: if the volume does not appear after a
    /// few minutes, the launch goes on (to the database in the user's home for
    /// the first).
    private static func waitForDatabaseVolumes(preferences: any PreferenceStore) {
        var dataBasePath = resolvedDocumentsFolder(preferences)

        if let volume = DatabaseVolume.documentsVolume(resolved: dataBasePath,
                                                       locationMode: preferences[DatabasePreferences.databaseLocation],
                                                       chosenFolder: preferences[DatabasePreferences.databaseLocationURL]),
           !FileManager.default.fileExists(atPath: volume) {
            let chosen = preferences[DatabasePreferences.databaseLocationURL] ?? "(null)"
            DatabaseVolumeWait(volume: volume, message: String(format: NSLocalizedString("IsiX DICOM Viewer is configured to use the database located at %@. This volume is currently not available, most likely because it hasn't yet been mounted by the system, or because it is not plugged in or is turned off, or because you don't have write permissions for this location. IsiX DICOM Viewer will wait for a few minutes, then give up and switch to a database in the current user's home directory.", comment: ""), chosen as NSString)).run()

            if let exception = HorosObjCException.caught({
                dataBasePath = DicomDatabase.baseDirPath(forMode: Int32(truncatingIfNeeded: preferences[DatabasePreferences.databaseLocation]),
                                                         path: preferences[DatabasePreferences.databaseLocationURL])
            }) {
                _ = exception
                preferences.set(0, for: DatabasePreferences.databaseLocation)
                preferences.set(0, for: DatabasePreferences.defaultDatabaseLocation)
            }
        }

        // Some databases keep their data on another volume, named by the
        // DBFOLDER_LOCATION file of the documents folder: that volume is
        // waited for too.
        dataBasePath = DicomDatabase.baseDirPath(forPath: dataBasePath) // the data directory's path
        // An alias in DBFOLDER_LOCATION is not followed to its volume.
        let dataFolderLocation = ((dataBasePath as NSString?)?.appendingPathComponent("DBFOLDER_LOCATION"))
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        if let volume = DatabaseVolume.dataVolume(dataFolderLocation: dataFolderLocation),
           !FileManager.default.fileExists(atPath: volume) {
            DatabaseVolumeWait(volume: volume, message: String(format: NSLocalizedString("IsiX DICOM Viewer is configured to use the database with data located at %@. This volume is currently not available, most likely because it hasn't yet been mounted by the system, or because it is not plugged in or is turned off, or because you don't have write permissions for this location. IsiX DICOM Viewer will wait for a few minutes, then give up and ignore this highly dangerous situation.", comment: ""), (dataFolderLocation ?? "(null)") as NSString)).run()
        }
    }

    /// The former -init: the globals of the former SDK, the temporary folder,
    /// the debug log, the locks and the handler of the links.
    func prepareProcess() {
        if let exception = HorosObjCException.caught({
            appController = self.controller
            OsiriX = self.controller

            DICOMTLS.eraseKeys()
            try? FileManager.default.removeItem(atPath: FileManager.default.tmpDirPath())

            if let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .localDomainMask).first,
               let bundleName = Bundle.main.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String,
               FileManager.default.fileExists(atPath: ((applicationSupport.path as NSString).appendingPathComponent(bundleName) as NSString).appendingPathComponent("DLog.enable")) {
                N2Debug.setActive(true)
            }

            PapyrusLock = NSRecursiveLock()
            STORESCP = NSRecursiveLock()
            STORESCPTLS = NSRecursiveLock()

            NSAppleEventManager.shared().setEventHandler(self.controller, andSelector: #selector(AppController.getUrl(_:withReplyEvent:)),
                                                         forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

            AppControllerCAPITestGraphicBoard()
        }) {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: exception.reason ?? "(null)", defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            _N2LogExceptionImpl(exception, true, "-[AppController init]")
        }
    }

    // MARK: - Launch

    /// -applicationWillFinishLaunching: the database chosen at first use, the
    /// menus, DCMTK and the listener, the database and browser classes, the
    /// Web Portal, Bonjour, XML-RPC, the presets menus, the launch count and
    /// the files an interrupted run left in the temporary folders.
    func willFinishLaunching() {
        // The event that launched the app: the link itself when one did.
        if let launch = NSAppleEventManager.shared().currentAppleEvent,
           launch.eventClass == AEEventClass(kInternetEventClass), launch.eventID == AEEventID(kAEGetURL) {
            launchedForURL = true
        }
        if let dictionary = HorosVendoredDicomDictionaryPath() {
            _ = HorosLoadVendoredDicomDictionary(dictionary)
        }

        if DatabaseFirstUse.hasPendingChoice {
            if !DatabaseFirstUse.choosePreparedLocation() {
                exit(0)
            }
            ApplicationPreferencesSetup.useDefaultDatabaseLocation()
            browser?.completeFirstUseDatabaseSetup()
            // Whatever had to wait for the database chosen at first use.
            DatabaseFirstUse.databaseDidOpen()
        }

        DispatchQueue.main.async { [controller] in
            _ = controller.setupCrashReporter()
        }

        ApplicationMenuLookup.installSectionHeaders(in: NSApp.mainMenu)

        AppController.cleanOsiriXSubProcesses()

        // Series are independent viewers; tabbing breaks tiling and active-viewer routing.
        NSWindow.allowsAutomaticWindowTabbing = false

        ApplicationPreferencesSetup.migrateAtLaunch()

        // A plugin that raises here used to take the rest of this method with it,
        // and the rest of this method is the DICOM stack: an exception escaping
        // the notification observer left DCMTK, the store SCP, the database and
        // browser classes, the Web Portal, Bonjour and the XML-RPC interface
        // uninitialised, with the application still on screen and nothing but a
        // log line to say so.
        if let exception = HorosObjCException.caught({ controller.installPluginMenus() }) {
            _N2LogExceptionImpl(exception, true, "-[AppController applicationWillFinishLaunching:]")
        }

        appController = controller
        controller.initDCMTK()
        controller.restartSTORESCP()

        DicomDatabase.initializeDicomDatabaseClass()
        BrowserController.initializeBrowserControllerClass()
        WebPortal.initializeWebPortalClass()
        controller.adoptBonjourPublisher(BonjourPublisher())

        XMLRPCServerAccess.migrateLegacyPreferences(in: processGraph.preferences)
        if preferences[NetworkPreferences.xmlrpcServer] {
            if ProtectedMode.isActive { ProtectedMode.skip("XML-RPC server") }
            else if controller.xmlrpcServer == nil { controller.xmlrpcServer = XMLRPCInterface() }
        }

        processGraph.applicationMenus.observePresetChanges()
        processGraph.applicationMenus.updatePresetMenus()

        NotificationCenter.default.addObserver(controller, selector: #selector(AppController.applicationDidChangeScreenParameters(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        controller.updateScreenParameters()

        // The launch counter; its first value replaces FIRSTTIME.
        if ApplicationPreferencesSetup.countLaunch() == 0 {
            switch HorosAlertPanel.runInformational(title: NSLocalizedString("IsiX DICOM Viewer Updates", comment: ""), message: NSLocalizedString("Would you like to activate automatic checking for updates?", comment: ""), defaultButton: NSLocalizedString("Yes", comment: ""), alternateButton: NSLocalizedString("No", comment: ""), otherButton: nil) {
            case 0:
                preferences.set("NO", forKey: ApplicationPreferences.checkHorosUpdates.name)
            default:
                break
            }
        }

        // Checks for Bonjour enabled dicom servers. Most likely other copies of Horos
        _ = DICOMNodeService.shared

        controller.startPreferenceChanges()

        ApplicationPreferencesSetup.applyViewerValues()

        controller.initTilingWindows()

        moveInterruptedFilesToIncoming()
    }

    /// What a run that ended abruptly left in the temporary and decompression
    /// folders goes back to the incoming folder, to be imported. JPEGs kept
    /// for Mail or Photos are outputs, not interrupted receptions, and stay.
    private func moveInterruptedFilesToIncoming() {
        let database = processGraph.activeLocalDatabase
        let incoming = processGraph.databaseIngest.incomingFolderPath(of: database)
        let temporary = database?.tempDirPath()
        let decompression = database?.decompressionDirPath()
        // [NSArray arrayWithObjects: temporary, decompression, nil]: stops at the first nil.
        let folders = temporary.map { [$0] + (decompression.map { [$0] } ?? []) } ?? []
        for folder in folders {
            for case let name as String in FileManager.default.enumerator(atPath: folder, filesOnly: false, recursive: false) {
                if folder == temporary && ImageExportPath.isPrivateExportDirectory(atPath: (folder as NSString).appendingPathComponent(name)) {
                    continue
                }
                if let destination = (incoming as NSString?)?.appendingPathComponent(name) {
                    try? FileManager.default.moveItem(atPath: (folder as NSString).appendingPathComponent(name), toPath: destination)
                }
            }
        }
    }

    /// -applicationDidFinishLaunching: the menu items made in code, the Dock,
    /// the listener's session watch, the notifications, the update checks, the
    /// server mode, the Query window left open at the last quit.
    func didFinishLaunching() {
        ViewerController.installROIInterchangeMenuItems()
        ViewerController.installRegistrationMenuItems()
        ViewerController.installSeriesListPlacementMenuItems()
        ViewerController.installRegisteredGIFMenuItems()
        ViewerController.installGSPSMenuItems()
        SyntheticDWICommand.install(in: processGraph.applicationMenus.exportMenu())
        BrowserController.installAutomaticCleanupPreviewMenu()
        BrowserController.installSurgicalProcedureImportMenu()

        // The progress of the running activities on the Dock icon.
        DockProgress.shared.start()
        ApplicationLifecycle.loadImportStatusImages()
        // ROIs shown on the series propagated with the one they are drawn on.
        ROISeriesPropagation.start()
        controller.receivingIndicator.start()

        processGraph.dicomListener.observeSessionSwitches()

        processGraph.userNotifications.requestAuthorization()

        let serverMode = preferences[NetworkPreferences.hidesListenerErrors]
        if serverMode {
            preferences.set(false, for: ApplicationPreferences.checkForUpdatesPlugins)
        }

        preferences.set(true, for: ViewerPreferences.alwaysUsesToolbarPanel)
        preferences.set(true, for: DatabasePreferences.syncPreviewList)
        preferences.set(true, for: ViewerPreferences.seriesListVisible)

        #if !MACAPPSTORE
        if ProtectedMode.isActive {
            ProtectedMode.skip("automatic update checks for the application and its plugins")
        } else {
            // If Horos crashed before, the check looks for the release that may fix it.
            let horosCrashed = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("HorosCrashed")
            let crashed = FileManager.default.fileExists(atPath: horosCrashed)
            if crashed { try? FileManager.default.removeItem(atPath: horosCrashed) }
            let updateCheckScheduler = controller.updateCheckScheduler
            Task { await updateCheckScheduler.startAtLaunch(crashed: crashed) }
        }
        #endif
        DistributionChannel.configureMenu(NSApp.mainMenu)

        if serverMode {
            browser?.window?.orderOut(controller)
        }

        processGraph.applicationMenus.testMenus()

        ROI.loadDefaultSettings()

        #if !DEBUG
        HorosApplicationInstaller.moveToApplicationsFolderIfNecessary()
        #endif

        if AppController.hasMacOSXElCapitan() == false {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("macOS Version", comment: ""), message: NSLocalizedString("IsiX DICOM Viewer requires macOS 10.11 or higher. Please update your OS: Apple Menu - Software Update...", comment: ""), defaultButton: NSLocalizedString("Quit", comment: ""), alternateButton: nil, otherButton: nil)
            exit(0)
        }

        if preferences[ApplicationPreferences.syncsPreferencesFromURL] {
            // A plain http: address is refused where the list is read, and said so.
            let url = preferences[ApplicationPreferences.preferencesSyncURL].flatMap { URL(string: $0) }
            Task { await ActivityThread.runUnlisted(name: "Preferences from URL") { OSIGeneralPreferencePanePref.addPreferences(from: url) } }
        }

        launchFinished = true
        if preferences[ApplicationPreferences.isQueryWindowVisible] && !launchedForURL {
            if QueryController.current() == nil {
                _ = QueryController(autoQuery: false)
            }
            QueryController.current()?.showWindow(controller)
        }
    }

    /// The images an import shows first - the cancel button of its Activity
    /// row and the browser's marks of a study just received or added - and
    /// where Pages is, for the report toolbar item the browser updates after
    /// an import. Each image is a file of the bundle read when it is first
    /// measured or drawn, and reading it, like finding Pages, asks
    /// LaunchServices: right after an import, with no LaunchServices context
    /// alive, that made it copy its database (about 45 MiB) on top of the
    /// import's memory peak. Done once here; the images are kept.
    private static func loadImportStatusImages() {
        let names = ["Activity_Stop", "Activity_StopPressed", "Receiving.tif",
                     "Realised1.tif", "Realised2.tif", "Realised3.tif", "Realised4.tif"]
        ImportStatusImages.kept = names.compactMap { name in
            let image = NSImage(named: name)
            _ = image?.size
            return image
        }
        _ = PagesApplication.url()
    }

    // MARK: - Activation

    func willBecomeActive() {
        if firstActivation { return }
        NSRunningApplication.current.activate(options: .activateAllWindows)
    }

    /// Reports are synchronized; outside server mode, a hidden or minimized
    /// database window comes back when no viewer is open.
    func didBecomeActive() {
        if firstActivation {
            firstActivation = false
            return
        }

        browser?.syncReportsIfNecessary()

        if !preferences[NetworkPreferences.hidesListenerErrors] { // Server mode
            if (browser?.window?.isMiniaturized ?? false) || !(browser?.window?.isVisible ?? false) {
                if NSApp.windows.contains(where: { $0.windowController is ViewerController }) { return }
                browser?.window?.makeKeyAndOrderFront(controller)
            }
        }
    }

    func shouldHandleReopen(hasVisibleWindows flag: Bool) -> Bool {
        if preferences[NetworkPreferences.hidesListenerErrors] { // Server mode
            return true
        }
        if !flag {
            browser?.window?.makeKeyAndOrderFront(controller)
        }
        return true
    }

    // MARK: - Quitting

    /// The Quit command: the browser may refuse (a transfer under way), then
    /// the rest of quitting.
    func terminate(_ sender: Any?) {
        if !(browser?.shouldTerminate(sender) ?? false) { return }
        finishTermination(sender)
    }

    /// The rest of quitting, once the browser has agreed to it: the Query
    /// window's visibility kept for the next launch, the import and the
    /// listeners stopped, the background threads given ten seconds.
    func finishTermination(_ sender: Any?) {
        // Quitting was asked for and agreed to. A plugin whose dialog is still
        // open, so that its code is on the stack, did not stop anything: its
        // note goes now, before the waits below, and not only when the
        // application terminates.
        PluginManager.endProtectForCrash()

        preferences.set(QueryController.current()?.window?.isVisible ?? false, for: ApplicationPreferences.isQueryWindowVisible)
        for window in NSApp.windows {
            window.orderOut(sender)
        }

        // The incoming import stops at its own gate: ThreadsManager may not list
        // it yet, and an import left reading a file when exit() destroys DCMTK
        // crashed quitting.
        processGraph.databaseIngest.stop()

        // exit() destroys DCMTK's static loggers while a listener thread that
        // is still running reads them: the listener reads its abort only after
        // waiting up to a second for an association, so a fixed half-second
        // pause let quitting crash on the "DICOM Store-SCP" thread.
        if processGraph.dicomListener.stopListeners(before: Date(timeIntervalSinceNow: 10)) == false {
            NSLog("******** DICOM listener still running after 10 s; quitting anyway")
        }

        let start = Date.timeIntervalSinceReferenceDate
        while Date.timeIntervalSinceReferenceDate - start < 10 { // give declared background threads 10 secs to cancel
            // Finished threads leave the list on the main run loop, which this
            // loop does not run: the count never fell, and quitting always
            // waited the full ten seconds.
            ThreadsManager.default()?.cleanupFinishedThreads(nil)
            let threads = ThreadsManager.default()?.threads()?.compactMap { $0 as? Thread } ?? []
            if threads.isEmpty { break }
            for thread in threads where !thread.isCancelled {
                thread.cancel()
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if IncomingImportGate.shared.waitUntilIdle(before: Date(timeIntervalSinceNow: 10)) == false {
            NSLog("******** incoming import still running after 10 s; quitting anyway")
        }

        for window in NSApp.windows {
            window.close()
        }

        processGraph.preferences.synchronize()


        NSApp.terminate(sender)
    }

    /// -applicationWillTerminate: the viewers closed, the threads cancelled,
    /// the database window, the Web Portal, Bonjour and DCMTK put away, and the
    /// temporary folders emptied: what is still in the incoming folder goes to
    /// the Trash, where it stays recoverable.
    func willTerminate() {
        // Every orderly end comes through here, also one that did not come
        // through the Quit command (the Dock, the system shutting down): the
        // note naming a plugin on the stack is only left by an end that was not
        // asked for.
        PluginManager.endProtectForCrash()

        DICOMTLS.eraseKeys()

        controller.xmlrpcServer = nil

        controller.closeAllViewers(controller)
        // ROIs of a series left for other slices, still being saved.
        ROISaveJob.finishAll()

        for thread in ThreadsManager.default()?.threads()?.compactMap({ $0 as? Thread }) ?? [] {
            thread.cancel()
        }

        browser?.browserPrepareForClose()

        WebPortal.finalizeWebPortalClass()

        ROI.saveDefaultSettings()

        processGraph.dicomListener.withdrawBonjour()

        quitting = true

        controller.destroyDCMTK()

        AppController.cleanOsiriXSubProcesses()

        let database = processGraph.activeLocalDatabase
        ApplicationLifecycle.empty(database?.dumpDirPath(), named: "dumpDirectory")

        let keepsIncoming = preferences[DatabasePreferences.keepsIncomingFolderFiles]
        if !keepsIncoming {
            ApplicationLifecycle.empty(database?.tempDirPath(), named: "tempDirectory")
            ApplicationLifecycle.empty(database?.decompressionDirPath(), named: "decompressionDirectory")
        }

        // Delete all process_state files
        let processFolder = String(cString: HorosDICOMProcessFolder())
        for name in (try? FileManager.default.contentsOfDirectory(atPath: processFolder)) ?? [] where name.hasPrefix("process_state-") {
            try? FileManager.default.removeItem(atPath: (processFolder as NSString).appendingPathComponent(name))
        }

        try? FileManager.default.removeItem(atPath: (FileManager.default.tmpDirPath() as NSString).appendingPathComponent("zippedCD"))

        ApplicationLifecycle.empty(FileManager.default.tmpDirPath(), named: "tmpDirPath")

        // EMPTY THE INCOMING.noindex DIRECTORY... into the Trash: what is still there
        // was received and never imported, so it stays recoverable.
        let incomingDirectoryPath = processGraph.databaseIngest.incomingFolderPath(of: database)
        if FileManager.default.fileExists(atPath: incomingDirectoryPath ?? "") && !keepsIncoming {
            do {
                try IncomingFolderOnQuit.sendToTrashIfPending(incomingDirectoryPath ?? "", resultingPath: nil)
            } catch let incomingError {
                NSLog("******** FAILED to clean the INCOMING.noindex directory: %@ (%@)", (incomingDirectoryPath ?? "(null)") as NSString, incomingError.localizedDescription as NSString)
            }
        }

        _ = FileManager.default.confirmDirectory(atPath: incomingDirectoryPath)
    }

    /// Removes a folder of the database or of the application, or moves it to
    /// the Trash when it cannot be removed, and logs one that stays.
    private static func empty(_ folder: String?, named name: String) {
        let path = folder ?? ""
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
        if FileManager.default.fileExists(atPath: path) {
            FileManager.default.moveItemAtPath(toTrash: folder)
        }
        if FileManager.default.fileExists(atPath: path) {
            NSLog("******** FAILED to clean the %@ directory: %@", name as NSString, (folder ?? "(null)") as NSString)
        }
    }

    // MARK: - The former plugins' dictionary of URL handlers

    /// Adds the dicom: URL scheme to the LaunchServices preferences when no
    /// handler has it (a former SDK method, which nothing calls).
    static func checkForOsirixMimeType() {
        let path = ("~/Library/Preferences/com.apple.LaunchServices.plist" as NSString).expandingTildeInPath
        let stored = FileManager.default.contents(atPath: path)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let handlers = stored?["LSHandlers"] as? [Any]
        if handlers?.contains(where: { ($0 as? [String: Any])?["LSHandlerURLScheme"] as? String == "dicom" }) ?? false {
            return
        }
        guard let handlers else {
            // -setObject:forKey: raised on the nil array it was given.
            NSException(name: .invalidArgumentException, reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: LSHandlers)", userInfo: nil).raise()
            return
        }
        var updated = stored ?? [:]
        updated["LSHandlers"] = handlers + [["LSHandlerRoleAll": "thalesmms.isis.workstation" /* BUNDLE_IDENTIFIER */, "LSHandlerURLScheme": "dicom"]]
        try? FileManager.default.removeItem(atPath: path)
        if let data = try? PropertyListSerialization.data(fromPropertyList: updated, format: .xml, options: 0) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}

/// The images loadImportStatusImages() loaded at launch, kept for the life of
/// the application so that they stay read.
@MainActor private enum ImportStatusImages {
    // Written once, when the application has finished launching.
    static var kept: [NSImage] = []
}
