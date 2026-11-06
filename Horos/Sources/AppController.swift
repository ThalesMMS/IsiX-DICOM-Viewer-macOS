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
import SystemConfiguration
import UserNotifications
import Synchronization
import os
import IsiXPreferences
import IsiXDICOMFile
import IsiXStorage

// The exported global USETOOLBARPANEL. Inside the class the name is the class
// method +USETOOLBARPANEL, so the global is read and written through here.
@MainActor fileprivate var useToolbarPanel: Bool {
    get { return USETOOLBARPANEL.boolValue }
    set { USETOOLBARPANEL = ObjCBool(newValue) }
}

// The former file sent messages whose receiver may be nil, and read values of
// type id: a message to nil answered 0, NO or nil. These say the same thing.
// The callers run inside HorosObjCException.perform where the former code had
// @try, so the exceptions an Objective-C method raises keep ending where they
// ended.
fileprivate enum ObjC {
    /// The argument of a "%@": nil prints (null).
    static func arg(_ value: Any?) -> CVarArg {
        guard let value = value else { return "(null)" as NSString }
        if let object = (value as AnyObject) as? NSObject { return object }
        return "\(value)" as NSString
    }

    /// [NSString stringWithFormat:format, ...] with object arguments.
    static func format(_ format: String, _ values: Any?...) -> String {
        return String(format: format, arguments: values.map { arg($0) })
    }

    /// [value intValue]: 0 for nil.
    static func int(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }
}

/** \brief  NSApplication delegate
*
*  NSApplication delegate 
*  Primarily manages the user defaults and server
*  Also controls some general main items
*
*
*/
// Main actor: the application delegate, which owns the menus, the windows
// and the listeners' lifecycle. What the listener, import, web portal and
// update-check threads call is nonisolated and says so.
@MainActor
@objc(AppController)
public final class AppController: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {

    // What the static variables of the former file held, with the same
    // first-call semantics: they belong to the class, not to an instance.
    @MainActor private enum State {
        static var LUT12toRGB: UnsafeMutablePointer<UInt8>? = nil
        static var canDisplay12Bit = false
        static var fill12BitBufferInvocation: AnyObject? = nil
        // -defaultWebPortalManagedObjectContext, which any thread may ask.
        nonisolated static let fakeContextLock = NSLock()
        // nonisolated(unsafe): read and written only inside
        // `fakeContextLock.withLock`.
        nonisolated(unsafe) static var fakeContext: NSManagedObjectContext? = nil
    }

    // The former instance variables. The outlets are set by MainMenu.xib; the
    // browser's makes the graph of its window, the database window's is where
    // the viewers' windows leave room for it.
    @IBOutlet @objc private var browserController: BrowserController? {
        didSet { browserWindow = browserController.map { BrowserWindowGraph(browser: $0, processGraph: processGraph) } }
    }
    private(set) var browserWindow: BrowserWindowGraph?

    @IBOutlet @objc public private(set) var filtersMenu: NSMenu!
    @IBOutlet @objc private var roisMenu: NSMenu?
    @IBOutlet @objc private var othersMenu: NSMenu?
    @IBOutlet @objc private var dbMenu: NSMenu?
    @IBOutlet @objc private var dbWindow: NSWindow? {
        didSet { windowArranger.databaseWindow = { [weak self] in self?.dbWindow } }
    }
    @IBOutlet @objc public private(set) var windowsTilingMenuRows: NSMenu!
    @IBOutlet @objc public private(set) var windowsTilingMenuColumns: NSMenu!
    @IBOutlet @objc public private(set) var recentStudiesMenu: NSMenu!

    /// What the process graph keeps for the application: the DICOM listeners,
    /// the menus, the notifications and the arrangement of the viewers' windows.
    private nonisolated var processGraph: ProcessGraph { PreferencesSource.process.processGraph }
    nonisolated var dicomListener: DICOMListenerController { processGraph.dicomListener }
    private var applicationMenus: ApplicationMenus { processGraph.applicationMenus }
    nonisolated var userNotifications: UserNotificationDelivery { processGraph.userNotifications }
    var windowArranger: ViewerWindowArranger { processGraph.windowArranger }

    /// The answer to a change of the preferences, started as the launch finishes.
    private lazy var preferenceChanges = PreferenceChangeResponder(listener: dicomListener, windowArranger: windowArranger)

    /// Starts the answer to the changes of the preferences, as the launch finishes.
    func startPreferenceChanges() {
        preferenceChanges.start()
    }

    /// The Dock's receiving arrow, its badge and the grab sound. Any thread.
    nonisolated let receivingIndicator = ReceivingIndicator()

    /// The automatic checks for a new release.
    nonisolated let updateCheckScheduler = UpdateCheckScheduler()

    private var splashController: SplashScreen? = nil

    @objc(XMLRPCServer) public internal(set) var xmlrpcServer: XMLRPCInterface! = nil

    /// The launch, the activation and the quitting (ApplicationLifecycle.swift),
    /// and what arrives from outside: links, files, plugins (ExternalRequestHandler.swift).
    lazy var lifecycle = ApplicationLifecycle(controller: self, processGraph: processGraph)
    lazy var externalRequests = ExternalRequestHandler(controller: self, processGraph: processGraph)

    @objc public var checkAllWindowsAreVisibleIsOff = false
    /// Read by the database's cleaning and the browser, from any thread;
    /// written on the main thread when the session switches.
    @objc public nonisolated var isSessionInactive: Bool {
        get { dicomListener.isSessionInactive }
        set { dicomListener.isSessionInactive = newValue }
    }


    /// Set once while launching, then read by the connection threads of the
    /// shared database: the lock publishes the reference, the object keeps its
    /// own locking.
    private nonisolated let _bonjourPublisher = OSAllocatedUnfairLock<BonjourPublisher?>(uncheckedState: nil)

    /// The DICOM service this process advertises, as an NSNetService for the
    /// callers typed on it; it is never published itself: the advertisement is
    /// `dicomBonjourAdvertisement`, and two registrations of one name and port
    /// would make the daemon rename one of them.
    @objc public var dicomBonjourPublisher: NetService! {
        return dicomListener.bonjourService
    }

    /// The DNS-SD advertisement of this process's DICOM listener (`_dicom._tcp`).
    public var dicomBonjourAdvertisement: BonjourAdvertisement? {
        return dicomListener.bonjourAdvertisement
    }

    @objc public nonisolated var bonjourPublisher: BonjourPublisher! {
        return _bonjourPublisher.withLockUnchecked { $0 }
    }

    /// The publisher of the shared database, made once while launching.
    func adoptBonjourPublisher(_ publisher: BonjourPublisher) {
        _bonjourPublisher.withLockUnchecked { $0 = publisher }
    }

    @objc nonisolated class func operatingSystemVersion() -> OperatingSystemVersion {
        return ProcessInfo.processInfo.operatingSystemVersion
    }

    @objc nonisolated public class func hasMacOSX1083() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion == 10 && v.minorVersion == 8 && v.patchVersion == 3)
    }

    @objc nonisolated class func hasMacOSXSierra() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion > 10 || v.minorVersion >= 12)
    }

    @objc nonisolated class func hasMacOSXElCapitan() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion > 10 || v.minorVersion >= 11)
    }

    @objc nonisolated public class func hasMacOSXYosemite() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion > 10 || v.minorVersion >= 10)
    }

    @objc nonisolated public class func hasMacOSXMaverick() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion > 10 || v.minorVersion >= 9)
    }

    @objc nonisolated public class func hasMacOSXMountainLion() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion > 10 || v.minorVersion >= 8)
    }

    @objc nonisolated public class func hasMacOSXLion() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion > 10 || v.minorVersion >= 7)
    }

    @objc nonisolated public class func hasMacOSXSnowLeopard() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion > 10 || v.minorVersion >= 6)
    }

    @objc nonisolated public class func hasMacOSXLeopard() -> Bool {
        let v = self.operatingSystemVersion()
        return (v.majorVersion > 10 || v.minorVersion >= 5)
    }

    @available(*, deprecated) @objc(createNoIndexDirectoryIfNecessary:) public class func createNoIndexDirectoryIfNecessary(_ path: String!) { // __deprecated
        FileManager.default.confirmNoIndexDirectory(atPath: path)
    }

    @available(*, deprecated) @objc(pause) nonisolated public class func pause() {
        // The instance method -pause has the same selector as this class method.
        AppController.shared()?.performSelector(onMainThread: NSSelectorFromString("pause"), with: nil, waitUntilDone: false)
    }

    @objc(applicationDidChangeScreenParameters:) func applicationDidChangeScreenParameters(_ aNotification: Notification!) {
        windowArranger.updateScreenParameters()
    }

    @objc public func updateScreenParameters() {
        windowArranger.updateScreenParameters()
    }

    @objc(resizeWindowWithAnimation:newSize:) public class func resizeWindow(withAnimation window: NSWindow!, newSize newWindowFrame: NSRect) {
        ViewerWindowArranger.resizeWindow(withAnimation: window, newSize: newWindowFrame)
    }

    @objc(thumbnailsListPanelForScreen:) public class func thumbnailsListPanel(for screen: NSScreen!) -> ThumbnailsListPanel! {
        return ViewerWindowArranger.thumbnailsListPanel(for: screen)
    }

    // +displayImportantNotice: (WITH_IMPORTANT_NOTICE, not defined) is in AppController+CAPI.m.

    // Kept for plugins. JPEG 2000 goes through the DCMTK codec; there is no
    // other engine to choose.
    @objc nonisolated public class func isKDUEngineAvailable() -> Bool {
        return false
    }

    @objc(checkForPreferencesUpdate:) public class func checkForPreferencesUpdate(_ b: Bool) {
        PreferenceChangeResponder.isChecking = b
    }

    @objc nonisolated class func cleanOsiriXSubProcesses() {
        let kPIDArrayLength: Int32 = 100

        var MyArray = [pid_t](repeating: 0, count: Int(kPIDArrayLength))
        var NumberOfMatches: UInt32 = 0
        let Error: Int32

        // Every candidate below is matched on its BSD process name, which is shared
        // by anything else of that name this user is running. Only a process
        // launched from inside our own bundle may be signalled.
        let bundlePath = (Bundle.main.bundlePath as NSString).fileSystemRepresentation

        // The listener no longer forks a process per association: there
        // are no children of ours to end here.

        Error = GetAllPIDsForProcessName("CrashReporter", &MyArray, UInt32(kPIDArrayLength), &NumberOfMatches, nil)

        if Error == 0 {
            for Counter in 0..<Int(NumberOfMatches) {
                if MyArray[Counter] != getpid() && AppControllerCAPIProcessIsOurs(MyArray[Counter], bundlePath) {
                    NSLog("Child Process to kill (CrashReporter): %d (PID)", MyArray[Counter])
                    kill(MyArray[Counter], 15)
                }
            }
        }
    }

    @objc(UID) nonisolated public class func uid() -> String! {
        return ObjC.format("%@|%@", N2Shell.serialNumber(), NSUserName())
    }

    @objc(setUSETOOLBARPANEL:) public class func setUSETOOLBARPANEL(_ b: Bool) {
        useToolbarPanel = b
    }

    @objc(USETOOLBARPANEL) public class func usetoolbarpanel() -> Bool {
        return useToolbarPanel
    }

    @objc(sharedAppController) nonisolated public class func shared() -> AppController! {
        return appController
    }

    @objc(DNSResolve:) nonisolated class func DNSResolve(_ o: Any!) {
        NSLog("start DNSResolve")

        for s in DefaultPreferences.currentHost().names {
            NSLog("%@", s as NSString)
        }

        NSLog("end DNSResolve")
    }

    @available(*, deprecated) @objc(printStackTrace:) nonisolated public class func printStackTrace(_ e: NSException!) -> String! {
        // The return addresses, symbolized and logged: nothing here raises.
        let r = NSMutableString()

        let addresses = e?.callStackReturnAddresses ?? []
        if addresses.count > 0 {
            var backtrace_frames = [UnsafeMutableRawPointer?](repeating: nil, count: addresses.count)
            var i = 0
            for address in addresses {
                backtrace_frames[i] = UnsafeMutableRawPointer(bitPattern: address.uintValue)
                i += 1
            }

            var frameStrings = backtrace_symbols(&backtrace_frames, Int32(addresses.count))

            if frameStrings != nil {
                for x in 0..<addresses.count {
                    let frame_description = frameStrings?[x].flatMap { NSString(utf8String: $0) }
                    NSLog("------- %@", ObjC.arg(frame_description))
                    r.appendFormat("%@\r", ObjC.arg(frame_description))
                }
                free(frameStrings)
                frameStrings = nil
            }
        }

        return r as String
    }

    @objc nonisolated public class func willExecutePlugin() -> Bool {
        return self.willExecutePlugin(nil)
    }

    @objc(willExecutePlugin:) nonisolated public class func willExecutePlugin(_ filter: Any!) -> Bool {
        let returnValue = true

        return returnValue
    }

    @objc func pause() { // __deprecated
        // Keep the legacy plugin pause on the database queue.
        N2ManagedObjectContextPerformAndWait(browserWindow?.browser.database?.managedObjectContext) {
            sleep(2)
        }
    }

    // Plugins installation (ExternalRequestHandler)
    @objc(installPlugins:) public func installPlugins(_ pluginsArray: [Any]!) {
        externalRequests.installPlugins(pluginsArray ?? [])
    }

    /// The plugins' items in the Filters, ROIs, Others and Database menus.
    func installPluginMenus() {
        PluginManager.setMenus(filtersMenu, roisMenu, othersMenu, dbMenu)
    }

    @objc nonisolated func computerName() -> String! {
        return SCDynamicStoreCopyComputerName(nil, nil) as String?
    }

    @objc nonisolated public func privateIP() -> String! {
        return String(utf8String: GetPrivateIP())
    }

    @IBAction @objc(cancelModal:) public func cancelModal(_ sender: Any!) {
        NSApp.abortModal()
    }

    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    @IBAction @objc(okModal:) public func okModal(_ sender: Any!) {
        NSApp.stopModal()
    }

    @IBAction @objc(autoQueryRefresh:) public func autoQueryRefresh(_ sender: Any!) {
        QueryController.currentAuto()?.refreshAutoQR(sender)
    }

    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    // MARK: -

    @IBAction @objc(openHorosWebPage:) public func openHorosWebPage(_ sender: Any!) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS")!) // URL_HOROS_WEB_PAGE
    }

    @IBAction @objc(help:) public func help(_ sender: Any!) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS")!) // URL_HOROS_LEARNING
    }

    @IBAction @objc(openHorosSupport:) public func openHorosSupport(_ sender: Any!) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/issues")!) // URL_HOROS_SUPPORT_PAGE
    }

    @IBAction @objc(openCommunityPage:) public func openCommunityPage(_ sender: Any!) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/issues")!) // URL_HOROS_COMMUNITY
    }

    @IBAction @objc(openBugReportPage:) public func openBugReportPage(_ sender: Any!) {
        NSWorkspace.shared.open(URL(string: "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/issues")!) // URL_HOROS_BUG_REPORT_PAGE
    }

    @IBAction @objc(sendEmail:) public func sendEmail(_ sender: Any!) {
        // The original project's mailbox is not this application's support address.
        NSWorkspace.shared.open(URL(string: "https://github.com/ThalesMMS/IsiX-DICOM-Viewer-macOS/issues")!) // URL_HOROS_SUPPORT_PAGE
    }

    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    // MARK: -

    @objc(waitForPID:) nonisolated func waitForPID(_ pidNumber: NSNumber!) {
        let pid = ObjC.int(pidNumber)
        var rc: Int32, state: Int32 = 0
        var threadStateChanged = false
        let path = String(format: "%s/process_state-%d", HorosDICOMProcessFolder(), pid)

        repeat {
            if threadStateChanged == false {
                if FileManager.default.fileExists(atPath: path) && ((try? NSString(contentsOfFile: path, encoding: String.Encoding.utf8.rawValue))?.length ?? 0) > 0 {
                    Thread.current.status = (Thread.current.status as NSString?)?.appendingFormat(NSLocalizedString(" - %@", comment: "") as NSString, ObjC.arg(try? NSString(contentsOfFile: path, usedEncoding: nil))) as String?
                    Thread.sleep(forTimeInterval: 1)
                    threadStateChanged = true
                }
            }

            rc = waitpid(pid, &state, WNOHANG)
            Thread.sleep(forTimeInterval: 0.1)
        } while rc >= 0
    }

    // The menus found by their resource identifier: `ApplicationMenus`.
    @objc public func viewerMenu() -> NSMenu! { applicationMenus.viewerMenu() }
    @objc public func fileMenu() -> NSMenu! { applicationMenus.fileMenu() }
    @objc public func exportMenu() -> NSMenu! { applicationMenus.exportMenu() }
    @objc public func imageTilingMenu() -> NSMenu! { applicationMenus.imageTilingMenu() }
    @objc public func orientationMenu() -> NSMenu! { applicationMenus.orientationMenu() }
    @objc public func opacityMenu() -> NSMenu! { applicationMenus.opacityMenu() }
    @objc public func wlwwMenu() -> NSMenu! { applicationMenus.wlwwMenu() }
    @objc public func convMenu() -> NSMenu! { applicationMenus.convMenu() }
    @objc public func clutMenu() -> NSMenu! { applicationMenus.clutMenu() }
    @objc public func workspaceMenu() -> NSMenu! { applicationMenus.workspaceMenu() }

    // MainMenu.xib makes this object the delegate of the Load Workspace State
    // DICOM SR menu.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        applicationMenus.menuNeedsUpdate(menu)
    }

    // MARK: - The DICOM listeners

    /// Starts the listeners the preferences ask for: `DICOMListenerController`.
    @objc public func restartSTORESCP() {
        dicomListener.restart()
    }

    @objc(displayError:) public func displayError(_ err: String!) {
        HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: ObjC.format("%@", err), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// Kept for the Objective-C listeners and plugins that report through the
    /// controller; the report itself is `ApplicationNetworkNotices`'.
    @objc(reportListenBindFailureForService:port:errnoCode:) nonisolated public func reportListenBindFailure(forService service: String!, port: Int, errnoCode code: Int32) {
        // A nil service reached the Swift ListenBindFailure methods as "".
        ApplicationNetworkNotices.process.listenBindFailed(service: service ?? "", port: port, errno: code)
    }

    // the DiscPublishing plugin swizzles this method, do not rename it
    // (dynamic: a call from Swift also goes through the Objective-C runtime, as the swizzling expects)
    @objc(displayListenerError:) dynamic func displayListenerError(_ err: String!) {
        dicomListener.reportListenerError(err ?? "")
    }

    /// A horos:// or osirix:// link (ExternalRequestHandler).
    @objc(getUrl:withReplyEvent:) func getUrl(_ event: NSAppleEventDescriptor!, withReplyEvent replyEvent: NSAppleEventDescriptor!) {
        lifecycle.noteLinkArrived()
        externalRequests.open(link: event?.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue)
    }

    @objc(application:openFiles:) func application(_ sender: NSApplication!, openFiles filenames: [Any]!) {
        externalRequests.open(files: filenames ?? [])
    }

    @objc(applicationWillBecomeActive:) func applicationWillBecomeActive(_ aNotification: Notification!) {
        lifecycle.willBecomeActive()
    }

    @objc(applicationDidBecomeActive:) func applicationDidBecomeActive(_ aNotification: Notification!) {
        lifecycle.didBecomeActive()
    }

    @objc(applicationShouldHandleReopen:hasVisibleWindows:) func applicationShouldHandleReopen(_ theApplication: NSApplication!, hasVisibleWindows flag: Bool) -> Bool {
        lifecycle.shouldHandleReopen(hasVisibleWindows: flag)
    }

    /// The menu's abort of the incoming transfers (MainMenu.xib).
    @IBAction @objc(killAllStoreSCU:) public func killAllStoreSCU(_ sender: Any!) {
        dicomListener.abortIncomingTransfers()
    }

    @objc(applicationWillTerminate:) func applicationWillTerminate(_ aNotification: Notification!) {
        lifecycle.willTerminate()
    }

    @IBAction @objc(terminate:) public func terminate(_ sender: Any!) {
        lifecycle.terminate(sender)
    }

    /// The rest of quitting, once the browser has agreed to it.
    func finishTermination(_ sender: Any!) {
        lifecycle.finishTermination(sender)
    }

    public override init() {
        super.init()
        // A DICOM date archived by an earlier version names the former
        // class; it reads as the current one, which archives under that name.
        DICOMCalendarDate.registerArchiveName()
        lifecycle.prepareProcess()
    }

    /// The former +initialize, sent by AppController+CAPI.m and, first, by the
    /// database window's initializer: once per process (ApplicationLifecycle).
    @objc class func initializeAppController() {
        guard self == AppController.self else { return }
        if let exception = HorosObjCException.caught({ ApplicationLifecycle.initializeProcess() }) {
            NSLog("+initialize exception: %@", exception.description as NSString)
        }
    }

    // MARK: -
    // MARK: notification

    /// Any thread posts these (imports, listeners, routing): `UserNotificationDelivery`.
    @objc(notificationTitle:description:name:) nonisolated public func notificationTitle(_ title: String!, description: String!, name: String!) {
        userNotifications.post(title: title, description: description, name: name)
    }

    // MARK: -

    /// Stops the listeners and the incoming transfers; with `w`, waits for the
    /// listeners to leave their loops.
    @objc(killDICOMListenerWait:) public func killDICOMListenerWait(_ w: Bool) {
        dicomListener.stopListeners(wait: w)
    }

    /// Whether a listener receives what a C-MOVE sends here. Any thread.
    @objc nonisolated public func isStoreSCPRunning() -> Bool {
        dicomListener.isListening
    }

    @objc(applicationDidFinishLaunching:) func applicationDidFinishLaunching(_ aNotification: Notification!) {
        lifecycle.didFinishLaunching()
    }

    @objc func checkForOsirixMimeType() {
        ApplicationLifecycle.checkForOsirixMimeType()
    }

    @objc(applicationWillFinishLaunching:) func applicationWillFinishLaunching(_ aNotification: Notification!) {
        lifecycle.willFinishLaunching()
    }

    @IBAction @objc(updateViews:) public func updateViews(_ sender: Any!) {
        let winList = NSApp.windows

        for loopItem in winList
        {
            if let viewer = loopItem.windowController as? ViewerController
            {
                viewer.needsDisplayUpdate()
            }
        }
    }



    // MARK: -

    @objc nonisolated public class func isFDACleared() -> Bool {
        return false
    }

    @objc public func splashScreen() -> Any! {
        var wait: WaitRendering? = nil

        // (OSIRIX_LIGHT: WaitRendering "Starting Horos Lite...", not compiled)
        if MemoryLayout<Int>.size == 8 {
            wait = WaitRendering(NSLocalizedString("Starting IsiX DICOM Viewer 64-bit", comment: ""))
        }
        else {
            wait = WaitRendering(NSLocalizedString("Starting IsiX DICOM Viewer 32-bit", comment: ""))
        }

        return wait
    }

    /// The Check for Updates item of the menu (`checkForUpdates:` is also its
    /// selector as text); this object as the sender asks for an automatic
    /// check, "crash" for the one after a crash. Any thread: `UpdateCheck`.
    @IBAction @objc(checkForUpdates:) nonisolated public func checkForUpdates(_ sender: Any!) {
        let kind: UpdateCheck.Kind = (sender as AnyObject?) === self ? .automatic
            : ((sender as? String) == "crash" ? .afterCrash : .manual)
        updateCheckScheduler.checkNow(kind)
    }

    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————
    // MARK: -

    @IBAction @objc(about:) public func about(_ sender: Any!) {
        splashController = SplashScreen()
        splashController?.showWindow(self)
        splashController?.affiche()
    }

    @IBAction @objc(printFromMenu:) public func printFromMenu(_ sender: Any!) {
        let controller = NSApp.keyWindow?.windowController
        if let browser = controller as? BrowserController {
            browser.printDatabaseSelection(sender)
        }
        else {
            _ = NSApp.sendAction(NSSelectorFromString("print:"), to: nil, from: sender)
        }
    }

    @objc(validatePrintFromMenu:) func validatePrintFromMenu(_ item: NSMenuItem!) -> Bool {
        if NSApp.keyWindow?.windowController is BrowserController {
            return true
        }

        // Preserve the existing responder and its validation in other windows.
        let target = NSApp.target(forAction: NSSelectorFromString("print:"), to: nil, from: item)
        if target == nil {
            return false
        }
        let legacyItem = item?.copy() as? NSMenuItem
        legacyItem?.action = NSSelectorFromString("print:")
        // The target may implement these without adopting the protocols: sent through their IMP, as ObjC sent the message.
        typealias ValidateIMP = @convention(c) (AnyObject, Selector, NSMenuItem?) -> Bool
        let validateMenuItemSelector = NSSelectorFromString("validateMenuItem:")
        let validateUserInterfaceItemSelector = NSSelectorFromString("validateUserInterfaceItem:")
        if let target = target as? NSObject, target.responds(to: validateMenuItemSelector) {
            return unsafeBitCast(target.method(for: validateMenuItemSelector), to: ValidateIMP.self)(target, validateMenuItemSelector, legacyItem)
        }
        if let target = target as? NSObject, target.responds(to: validateUserInterfaceItemSelector) {
            return unsafeBitCast(target.method(for: validateUserInterfaceItemSelector), to: ValidateIMP.self)(target, validateUserInterfaceItemSelector, legacyItem)
        }
        return true
    }

    @IBAction @objc(showPreferencePanel:) public func showPreferencePanel(_ sender: Any!) {
        PreferencesWindowController.sharedPreferencesWindowController().showWindow(sender)
    }


    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// [a isEqualToString: b]: NO when either is nil.
    private func idIsEqualToString(_ a: Any?, _ b: Any?) -> Bool {
        guard let a = a as? NSString, let b = b as? String else { return false }
        return a.isEqual(to: b)
    }

    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    // MARK: - The viewers' windows

    // The selectors below, which the nibs and plugins send, forward to the
    // arrangement of the viewers' windows and their tiling, `windowArranger`.

    // pixList is compared by identity: the viewer's own array is the object compared.
    @objc(FindViewer::) public func FindViewer(_ nib: String!, _ pixList: NSArray!) -> Any! {
        return windowArranger.findViewer(nibName: nib, pixList: pixList)
    }

    @objc(FindRelatedViewers:) public func FindRelatedViewers(_ pixList: NSArray!) -> [Any]! {
        return windowArranger.findRelatedViewers(pixList: pixList)
    }

    @objc public func viewerScreens() -> [Any]! {
        return windowArranger.viewerScreens()
    }

    @objc(checkAllWindowsAreVisible:makeKey:) public func checkAllWindowsAreVisible(_ sender: Any!, makeKey: Bool) {
        if checkAllWindowsAreVisibleIsOff { return }
        windowArranger.bringViewersToFront(makeKey: makeKey)
    }

    @objc(checkAllWindowsAreVisible:) public func checkAllWindowsAreVisible(_ sender: Any!) {
        self.checkAllWindowsAreVisible(sender, makeKey: false)
    }

    @objc(scaleToFit:) public func scaleToFit(_ sender: Any!) {
        for case let v as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
            v.imageView()?.scaleToFit()
        }
    }

    // MARK: -

    /// Any thread: now on the main thread, or later on the main queue. A nil
    /// study changes nothing. Recent Studies is `ApplicationMenus`.
    @objc(addStudyToRecentStudiesMenu:) nonisolated public func addStudyToRecentStudiesMenu(_ studyID: NSManagedObjectID!) {
        guard let studyID else { return }
        onMainActor { self.applicationMenus.addRecentStudy(studyID) }
    }

    @objc(loadRecentStudy:) public func loadRecentStudy(_ sender: Any!) {
        applicationMenus.loadRecentStudy(sender)
    }

    @objc public func buildRecentStudiesMenu() {
        applicationMenus.buildRecentStudiesMenu()
    }

    // MARK: -

    @objc public func initTilingWindows() {
        windowArranger.installTilingMenus(rows: windowsTilingMenuRows, columns: windowsTilingMenuColumns, target: self)
    }

    @IBAction @objc(setTilingArea:) public func setTilingArea(_ sender: Any!) {
        windowArranger.setTilingArea(presetNamed: (sender as? NSMenuItem)?.representedObject as? String)
    }

    @IBAction @objc(setFixedTilingRows:) public func setFixedTilingRows(_ sender: Any!) {
        windowArranger.tileWindows(fixedRows: (sender as? NSValidatedUserInterfaceItem)?.tag ?? 0)
    }

    @IBAction @objc(setFixedTilingColumns:) public func setFixedTilingColumns(_ sender: Any!) {
        windowArranger.tileWindows(fixedColumns: (sender as? NSValidatedUserInterfaceItem)?.tag ?? 0)
    }

    @objc(validateMenuItem:) public func validateMenuItem(_ item: NSMenuItem!) -> Bool {
        if !DistributionChannel.supportsGitHubUpdates && item?.action == NSSelectorFromString("checkForUpdates:") {
            return false
        }
        if item?.action == #selector(AppController.printFromMenu(_:)) {
            return self.validatePrintFromMenu(item)
        }

        if item?.action == #selector(AppController.setTilingArea(_:)) {
            var screen = NSApp.keyWindow?.screen
            if screen == nil { screen = NSScreen.main }

            let chosen = idIsEqualToString(TilingArea.presetName(for: screen), item?.representedObject)
            item?.state = chosen ? .on : .off
            item?.isEnabled = true
            return true
        }

        // Recent Studies validates its own items: `ApplicationMenus`.
        if item?.action == #selector(AppController.autoQueryRefresh(_:)) {
            // This test sat inside the tiling branch below, which never sees this
            // action, so the item stayed enabled without an auto query window.
            // #ifndef OSIRIX_LIGHT
            if QueryController.currentAuto() != nil {
                return true
            } else {
                return false
            }
        } else if item?.action == #selector(AppController.setFixedTilingRows(_:)) || item?.action == #selector(AppController.setFixedTilingColumns(_:)) {
            // [item tag] (NSInteger) <= [... count] (NSUInteger): compared unsigned, as in C
            if item?.action == #selector(AppController.setFixedTilingColumns(_:)) {
                if (item?.tag ?? 0) == Int(windowArranger.layout.lastColumns) && UInt(bitPattern: item?.tag ?? 0) <= UInt(processGraph.viewerRegistry.displayedViewers.count) {
                    item?.state = .on
                } else {
                    item?.state = .off
                }
            }

            if item?.action == #selector(AppController.setFixedTilingRows(_:)) {
                if (item?.tag ?? 0) == Int(windowArranger.layout.lastRows) && UInt(bitPattern: item?.tag ?? 0) <= UInt(processGraph.viewerRegistry.displayedViewers.count) {
                    item?.state = .on
                } else {
                    item?.state = .off
                }
            }

            if UInt(bitPattern: item?.tag ?? 0) > UInt(processGraph.viewerRegistry.displayedViewers.count) {
                return false
            }
        }
        return true
    }

    @objc(usefullRectForScreen:) public class func usefullRect(for screen: NSScreen!) -> NSRect {
        return ViewerWindowArranger.usefulRect(for: screen, showFloatingWindows: true)
    }

    @objc(usefullRectForScreen:showFloatingWindows:) class func usefullRect(for screen: NSScreen!, showFloatingWindows: Bool) -> NSRect {
        return ViewerWindowArranger.usefulRect(for: screen, showFloatingWindows: showFloatingWindows)
    }

    @IBAction @objc(tileWindows:) public func tileWindows(_ sender: Any!) {
        windowArranger.tileWindows(sender: sender)
    }

    @IBAction @objc(tile3DWindows:) public func tile3DWindows(_ sender: Any!) {
        windowArranger.tile3DWindows(sender: sender)
    }

    @IBAction @objc(closeAllViewers:) public func closeAllViewers(_ sender: Any!) {
        windowArranger.closeAllViewers()
    }

    //———————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————————

    // MARK: -
    // MARK: HTML Templates
    @available(*, deprecated) @objc public class func checkForHTMLTemplates() { // __deprecated
        DatabaseTemplateInstaller(database: PreferencesSource.process.processGraph.browserWindow?.browser.database).install()
    }

    // MARK: -
    // MARK: 12 Bit Display support.

    @objc public class func canDisplay12Bit() -> Bool {
        return State.canDisplay12Bit
    }

    @objc(setCanDisplay12Bit:) public class func setCanDisplay12Bit(_ boo: Bool) {
        State.canDisplay12Bit = boo
        PreferencesSource.process.preferences.set(boo, for: ApplicationPreferences.is12BitPluginAvailable)
    }

    @objc(setLUT12toRGB:) public class func setLUT12toRGB(_ lut: UnsafeMutablePointer<UInt8>!) {
        State.LUT12toRGB = lut
    }

    @objc public class func LUT12toRGB() -> UnsafeMutablePointer<UInt8>! {
        return State.LUT12toRGB
    }

    // Swift cannot name NSInvocation: the invocation is kept and answered as an
    // object, and the generated interface declares it as id.
    @objc(set12BitInvocation:) public class func set12BitInvocation(_ invocation: AnyObject!) {
        State.fill12BitBufferInvocation = invocation
    }

    @objc public class func fill12BitBufferInvocation() -> AnyObject! {
        return State.fill12BitBufferInvocation
    }

    // MARK: -

    @objc nonisolated func defaultWebPortalManagedObjectContext() -> NSManagedObjectContext! {
        var context: NSManagedObjectContext? = nil
        if let exception = HorosObjCException.caught({
            // #ifndef OSIRIX_LIGHT
            context = WebPortal.default()?.database?.managedObjectContext
        }) {
            NSLog("***** defaultWebPortalManagedObjectContext : %@", exception)
        }
        if let context { return context }

        // Nib bindings can ask before the portal is ready without raising an
        // exception. Its array controller still needs a context while the
        // first-use location dialog runs its modal loop.
        // static NSManagedObjectContext *fakeContext
        return State.fakeContextLock.withLock {
            if State.fakeContext == nil {
                // The UI binds to it: a main-queue context, with no store.
                State.fakeContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
                let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("/WebPortalDB.momd")))
                let psc = model.map { NSPersistentStoreCoordinator(managedObjectModel: $0) }
                State.fakeContext?.persistentStoreCoordinator = psc
            }
            return State.fakeContext
        }
    }

    @objc nonisolated public func defaultWebPortal() -> WebPortal! {
        // (OSIRIX_LIGHT: returned nil, not compiled)
        return WebPortal.default()
    }

    // #ifndef OSIRIX_LIGHT

    @objc nonisolated public func weasisBasePath() -> String! {
        return (Bundle.main.resourcePath as NSString?)?.appendingPathComponent("weasis")
    }

    // #endif


    // The Dock's receiving arrow, its badge and the grab sound: `ReceivingIndicator`.
    @objc nonisolated public func setReceivingIcon() {
        receivingIndicator.showReceiving(true)
    }

    @objc nonisolated public func unsetReceivingIcon() {
        receivingIndicator.showReceiving(false)
    }

    @objc(setBadgeLabel:) nonisolated public func setBadgeLabel(_ label: String!) {
        receivingIndicator.setBadgeLabel(label)
    }

    @objc public func playGrabSound() {
        receivingIndicator.playGrabSound()
    }

    // //////////////////////////////////////////////////////////////////////////////////////////////////


    // MARK: -
    // #pragma Crash report


    @objc func crash() {
        NSLog("crash")
        // Preserve the intentional segmentation fault used by crash reporting.
        _ = Darwin.raise(SIGSEGV)
    }


    /// Shows the crash report window when the application crashed since the
    /// last launch, in GitHub builds; the App Store and TestFlight builds leave
    /// crashes to Xcode's Organizer. YES when the window is shown.
    @objc func setupCrashReporter() -> Bool {
        NSLog("Unicode test: مرحبا - 你好 - שלום")
        #if MACAPPSTORE
        return false
        #else
        return CrashReportWindowController.showIfCrashed()
        #endif
    }

    // The SMTP server, account and password of the original project's crash
    // report mailbox were returned here in clear text and never used. They are
    // gone: the crash report window opens a draft in the user's mail
    // application, and nothing is sent without the user.

}

