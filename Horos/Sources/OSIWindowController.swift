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

/// The flags every viewer window controller shares, set on the main thread
/// around printing, movie export, tiling and the magnets themselves.
// nonisolated(unsafe): as the Objective-C file statics were, read by class
// methods any thread may call.
enum OSIWindowControllerFlags {
    nonisolated(unsafe) static var dontEnterMagneticFunctions = false
    nonisolated(unsafe) static var dontWindowDidChangeScreen = false
    nonisolated(unsafe) static var protectedReentryWindowDidResize = false
}

// The base class of the viewer window controllers (ViewerController,
// Window3DController and the 3D viewers, XMLController) is implemented here, in
// Swift, under the interface OSIWindowController.h declares
// (@objc @implementation): Objective-C (Window3DController) still subclasses
// it, so the interface stays Objective-C's, without instance variables.
//
// The methods the former .m defined without declaring them are private here,
// as they were to that file, or, for those subclasses implement under the
// same selector (-fileList, -imageView, -windowWillClose and the others), held
// by OSIWindowControllerDefaults and added at run time: a subclass's method
// answers first, as before. The magnetic windows are in
// OSIWindowController+MagneticWindows.swift.
//
// The defaults that touch no window run on any thread (nonisolated), as the
// Objective-C methods did: other threads ask a viewer for its files and images.
@objc @implementation extension OSIWindowController {
    final var magneticWindowActivated = false
    final var windowIsMovedByTheUser = false
    final var savedWindowsFrame = NSRect.zero
    nonisolated(unsafe) final var storedBlendingType: Int32 = 0
    nonisolated(unsafe) final var storedDatabase: DicomDatabase?

    // MARK: - Life cycle

    /// Observes every window closing, for the magnets and the tiling.
    public override init(window: NSWindow?) {
        super.init(window: window)
        // -windowWillCloseNotification: is in OSIWindowController+MagneticWindows.swift.
        NotificationCenter.default.addObserver(self, selector: NSSelectorFromString("windowWillCloseNotification:"),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NSLog("OSIWindowController released")

        if let database = storedDatabase {
            stopObservingDatabase(database, observer: self)
            storedDatabase = nil
        }

        NSObject.cancelPreviousPerformRequests(withTarget: self)

        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - The database

    /// The database whose changes the viewer follows: added images refresh
    /// it, and objects about to become unavailable close it.
    nonisolated var database: DicomDatabase! {
        get { storedDatabase }
        set {
            if newValue != storedDatabase {
                if let database = storedDatabase {
                    stopObservingDatabase(database, observer: self)
                    storedDatabase = nil
                }

                storedDatabase = newValue

                if let database = storedDatabase {
                    let center = NotificationCenter.default
                    center.addObserver(self, selector: #selector(observeDatabaseAddNotification(_:)), name: .OsirixAddToDB, object: database)
                    center.addObserver(self, selector: #selector(observeDatabaseObjectsMayFaultNotification(_:)), name: .OsirixDatabaseObjectsMayBecomeUnavailable, object: database)
                    center.addObserver(self, selector: #selector(observeManagedObjectContextObjectsDidChangeNotification(_:)), name: .NSManagedObjectContextObjectsDidChange, object: database.managedObjectContext)
                }
            }
        }
    }

    nonisolated func refreshDatabase(_ newImages: [Any]!) {
    }

    // MARK: - Flags

    class func dontWindowDidChangeScreen() -> Bool {
        return OSIWindowControllerFlags.dontWindowDidChangeScreen
    }

    class func setDontEnterWindowDidChangeScreen(_ a: Bool) {
        OSIWindowControllerFlags.dontWindowDidChangeScreen = a
    }

    class func dontEnterMagneticFunctions() -> Bool {
        return OSIWindowControllerFlags.dontEnterMagneticFunctions
    }

    class func setDontEnterMagneticFunctions(_ a: Bool) {
        OSIWindowControllerFlags.dontEnterMagneticFunctions = a
    }

    func setMagnetic(_ a: Bool) {
        magneticWindowActivated = a
    }

    func magnetic() -> Bool {
        return magneticWindowActivated
    }

    // MARK: - What subclasses answer

    nonisolated func pixList() -> NSMutableArray! {
        // let subclasses handle it for now
        return nil
    }

    nonisolated func add(toUndoQueue what: String!) {
        NSLog("OSIWindowController addToUndoQueue CALL SUPER ??")
    }

    nonisolated func blendingType() -> Int32 {
        return storedBlendingType
    }

    nonisolated func horosSetBlendingType(_ blendingType: Int32) {
        storedBlendingType = blendingType
    }

    func redo(_ sender: Any!) {
        NSLog("OSIWindowController redo CALL SUPER ??")
    }

    func undo(_ sender: Any!) {
        NSLog("OSIWindowController undo CALL SUPER ??")
    }

    func applyShading(_ sender: Any!) {
        NSLog("OSIWindowController applyShading - CALL SUPER ??")
    }

    nonisolated func updateAutoAdjustPrinting(_ sender: Any!) {
    }

    // MARK: - Current Core Data objects

    nonisolated func currentStudy() -> DicomStudy! {
        return nil
    }

    nonisolated func currentSeries() -> DicomSeries! {
        return nil
    }

    nonisolated func currentImage() -> DicomImage! {
        return nil
    }

    nonisolated func curWW() -> Float {
        return 0.0
    }

    nonisolated func curWL() -> Float {
        return 0.0
    }

    // MARK: - Defaults of the former .m

    /// The defaults OSIWindowControllerDefaults holds, added to the class the
    /// first time a controller that does not implement one is sent it.
    public override class func resolveInstanceMethod(_ selector: Selector!) -> Bool {
        if let selector, OSIWindowControllerDefaults.selectors.contains(selector),
           let method = class_getInstanceMethod(OSIWindowControllerDefaults.self, selector) {
            class_addMethod(OSIWindowController.self, selector, method_getImplementation(method), method_getTypeEncoding(method))
            return true
        }
        return super.resolveInstanceMethod(selector)
    }

    @objc(paste:)
    private func paste(_ sender: Any?) {
        if let pixList = self.pixList(), pixList.count > 0 {
            let pix = pixList.lastObject as? DCMPix

            if let series = pix?.seriesObj() {
                _ = BrowserController.currentBrowser()?.selectThisStudy(series.value(forKey: "study"))
            }

            BrowserController.currentBrowser()?.pasteImage(forSourceFile: pix?.srcFile)
        }
    }

    // MARK: - Notifications

    /// Notifications of the database may come from any thread: the
    /// refresh is sent as the former code sent it, on the posting thread.
    @objc(observeDatabaseAddNotification:)
    private nonisolated func observeDatabaseAddNotification(_ notification: Notification) {
        _ = perform(#selector(refreshDatabase(_:)), with: notification.userInfo?[OsirixAddToDBNotificationImagesArray])
    }

    @objc(observeManagedObjectContextObjectsDidChangeNotification:)
    private nonisolated func observeManagedObjectContextObjectsDidChangeNotification(_ notification: Notification) {
    }

    @objc(observeDatabaseObjectsMayFaultNotification:)
    private nonisolated func observeDatabaseObjectsMayFaultNotification(_ notification: Notification) {
        _ = perform(#selector(NSWindowController.close))
    }
}

/// Removes the observers -setDatabase: added for `database`.
private func stopObservingDatabase(_ database: DicomDatabase, observer: OSIWindowController) {
    let center = NotificationCenter.default
    center.removeObserver(observer, name: .OsirixAddToDB, object: database)
    center.removeObserver(observer, name: .OsirixDatabaseObjectsMayBecomeUnavailable, object: database)
    center.removeObserver(observer, name: .NSManagedObjectContextObjectsDidChange, object: database.managedObjectContext)
}

/// The defaults the former .m gave messages the app sends any viewer window
/// controller without the header declaring them: the 2D viewer, the XML
/// viewer and the 3D viewers implement the same selectors as methods of their
/// own, which Swift refuses beside a declaration of the superclass with the
/// same selector. OSIWindowController adds each default to itself at run
/// time (+resolveInstanceMethod:), when a controller that does not implement
/// it is first sent it: a subclass's method answers first, as before. The
/// methods run with an OSIWindowController as their receiver, and those that
/// need it take it as one.
private final class OSIWindowControllerDefaults: NSObject {
    static let selectors: Set<Selector> = [
        #selector(autoHideMatrix), #selector(syncThumbnails), #selector(refreshToolbar), #selector(imageView),
        #selector(propagateSettings), #selector(fileList), #selector(setWindowFrame(_:showWindow:animate:)),
        #selector(windowWillClose), #selector(orthogonalOrientation), #selector(isEverythingLoaded),
        #selector(registeredViewer), #selector(querySelectedStudy(_:)), #selector(fullScreenON),
        #selector(removeLastItemFromUndoQueue), #selector(applyOpacityString(_:)),
    ]

    /// The receiver, an OSIWindowController, as one.
    private var controller: OSIWindowController {
        return unsafeBitCast(self, to: OSIWindowController.self)
    }

    @objc(autoHideMatrix) func autoHideMatrix() {
    }

    @objc(syncThumbnails) func syncThumbnails() {
    }

    @objc(refreshToolbar) func refreshToolbar() {
    }

    @objc(imageView) func imageView() -> Any! {
        return nil
    }

    @objc(propagateSettings) func propagateSettings() {
    }

    @objc(fileList) func fileList() -> NSArray! {
        return nil
    }

    @objc(setWindowFrame:showWindow:animate:) func setWindowFrame(_ rect: NSRect, showWindow: Bool, animate: Bool) {
        let controller = self.controller
        MainActor.assumeIsolated {
            controller.window?.setFrame(rect, display: false)
        }
    }

    @objc(windowWillClose) func windowWillClose() -> Bool {
        return false
    }

    @objc(orthogonalOrientation) func orthogonalOrientation() -> Int16 {
        return 0
    }

    @objc(isEverythingLoaded) func isEverythingLoaded() -> Bool {
        return true
    }

    @objc(registeredViewer) func registeredViewer() -> ViewerController! {
        return nil
    }

    @objc(querySelectedStudy:) func querySelectedStudy(_ sender: Any!) {
        let controller = self.controller
        MainActor.assumeIsolated {
            BrowserController.currentBrowser()?.querySelectedStudy(controller)
        }
    }

    @objc(FullScreenON) func fullScreenON() -> Bool {
        return false
    }

    @objc(removeLastItemFromUndoQueue) func removeLastItemFromUndoQueue() {
        NSLog("OSIWindowController removeLastItemFromUndoQueue CALL SUPER ??")
    }

    @objc(ApplyOpacityString:) func applyOpacityString(_ s: String!) {
        N2LogStackTraceMessage("ApplyOpacityString - CALL SUPER ??")
    }
}
