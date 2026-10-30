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

// What the browser's class keeps for every instance and for the other
// classes: the browser of the application, the moments of activity, the
// contextual menus of the thumbnails, the flags of the threads that load
// and open, and the observer that makes the browser's database the active
// local one when the preferences allow it.

/// The former file-scope statics of the Objective-C class. Read and written as
/// they were: the flags and menus on the main thread, the others from any.
enum BrowserClassState {
    nonisolated(unsafe) static var current: BrowserController?
    nonisolated(unsafe) static var lastActivity: TimeInterval = 0
    nonisolated(unsafe) static var dontShowOpenSubSeries = false
    nonisolated(unsafe) static var horizontalHistory = false
    nonisolated(unsafe) static var statesArray: NSArray?
    nonisolated(unsafe) static var waitForRunningProcess = false
    nonisolated(unsafe) static var withReset = false
    nonisolated(unsafe) static var loadingIsOver = false
    nonisolated(unsafe) static var contextual: NSMenu?
    nonisolated(unsafe) static var contextualRT: NSMenu?
    nonisolated(unsafe) static var defaultFolderSizeForDB: Int32 = 0
    nonisolated(unsafe) static var helper: BrowserDefaultDatabaseActivation?

    /// The counts of the list and of the albums.
    static let decimalNumberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    /// What the distant studies of a smart album are synchronized on: one
    /// object for the life of the application.
    nonisolated(unsafe) static let smartAlbumDistantArraySync = NSString(string: "smartAlbumDistantArraySync")
}

/// Makes the browser's database the active local database whenever the
/// preference that allows any local database to be the active one changes,
/// and once at the start.
final class BrowserDefaultDatabaseActivation: NSObject, @unchecked Sendable {
    /// The observation's own context: a pointer that stays the same, read only.
    nonisolated(unsafe) private static let context = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    override init() {
        super.init()
        NSUserDefaultsController.shared.addObserver(self, forValuesKey: OsirixCanActivateDefaultDatabaseOnlyDefaultsKey,
                                                    options: .initial, context: BrowserDefaultDatabaseActivation.context)
    }

    deinit {
        NSUserDefaultsController.shared.removeObserver(self, forValuesKey: OsirixCanActivateDefaultDatabaseOnlyDefaultsKey)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard context == BrowserDefaultDatabaseActivation.context else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        if keyPath == valuesKeyPath(OsirixCanActivateDefaultDatabaseOnlyDefaultsKey), UserDefaults.canActivateAnyLocalDatabase() {
            DicomDatabase.setActiveLocal(BrowserController.currentBrowser()?.database)
        }
    }
}

extension BrowserController {

    @objc(initializeBrowserControllerClass)
    public class func initializeBrowserControllerClass() {
        if BrowserClassState.helper == nil {
            BrowserClassState.helper = BrowserDefaultDatabaseActivation()
        }
    }

    /// The browser of the application, made once, at launch. Any thread.
    /// Dispatched by message, as the Objective-C class method was: DCMPix and
    /// the ROIs ask for it without linking the browser.
    @objc(currentBrowser)
    public nonisolated dynamic class func currentBrowser() -> BrowserController! {
        return BrowserClassState.current
    }

    static var current: BrowserController? {
        get { BrowserClassState.current }
        set { BrowserClassState.current = newValue }
    }

    /// String work only: any thread.
    @objc(statesArray)
    public nonisolated class func statesArray() -> [Any]! {
        return BrowserClassState.statesArray as? [Any]
    }

    @objc(updateActivity)
    public nonisolated class func updateActivity() {
        BrowserClassState.lastActivity = Date.timeIntervalSinceReferenceDate
    }

    @objc(horizontalHistory)
    public nonisolated class func horizontalHistory() -> Bool {
        return BrowserClassState.horizontalHistory
    }

    /// The number of files a database folder holds, from the preferences:
    /// 10000, saved, when they have none. Read once.
    @objc(DefaultFolderSizeForDB)
    public nonisolated class func defaultFolderSizeForDB() -> Int32 {
        if BrowserClassState.defaultFolderSizeForDB == 0 {
            let saved = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "DefaultFolderSizeForDB"))
            let effective = DatabaseFolderSize.effective(saved: saved)
            BrowserClassState.defaultFolderSizeForDB = effective.size
            if effective.save {
                UserDefaults.standard.set(Int(effective.size), forKey: "DefaultFolderSizeForDB")
            }
        }
        return BrowserClassState.defaultFolderSizeForDB
    }

    /// Whether the lock can be taken within `sec` seconds, letting it go at
    /// once; a nil lock can. Logs the one that cannot.
    @objc(tryLock:during:)
    public nonisolated class func tryLock(_ c: Any!, during sec: TimeInterval) -> Bool {
        guard let lock = c as AnyObject? else { return true }
        let limit = Date(timeIntervalSinceNow: sec)
        let taken: Bool
        switch lock {
        case let lock as NSRecursiveLock: taken = lock.lock(before: limit)
        case let lock as NSLock: taken = lock.lock(before: limit)
        case let lock as NSConditionLock: taken = lock.lock(before: limit)
        default: taken = false
        }
        if taken {
            (lock as? NSLocking)?.unlock()
            return true
        }
        NSLog("******* tryLockDuring failed for this lock: %@ (%f sec)", String(describing: lock), sec)
        return false
    }

    // MARK: The statics the extensions read and write

    static var horos_contextualMenu: NSMenu? {
        get { BrowserClassState.contextual }
        set { BrowserClassState.contextual = newValue }
    }
    /// The thumbnails' contextual menu for RT objects, which often have no images.
    static var horos_contextualRTMenu: NSMenu? {
        get { BrowserClassState.contextualRT }
        set { BrowserClassState.contextualRT = newValue }
    }
    static var horos_waitForRunningProcess: Bool {
        get { BrowserClassState.waitForRunningProcess }
        set { BrowserClassState.waitForRunningProcess = newValue }
    }
    static var horos_dontShowOpenSubSeries: Bool {
        get { BrowserClassState.dontShowOpenSubSeries }
        set { BrowserClassState.dontShowOpenSubSeries = newValue }
    }
    static var horos_withReset: Bool {
        get { BrowserClassState.withReset }
        set { BrowserClassState.withReset = newValue }
    }
    /// The browser has finished loading.
    static var horos_loadingIsOver: Bool {
        get { BrowserClassState.loadingIsOver }
        set { BrowserClassState.loadingIsOver = newValue }
    }
    static var horos_horizontalHistory: Bool {
        get { BrowserClassState.horizontalHistory }
        set { BrowserClassState.horizontalHistory = newValue }
    }
    static var horos_statesArray: [Any]? {
        get { BrowserClassState.statesArray as? [Any] }
        set { BrowserClassState.statesArray = newValue.map { $0 as NSArray } }
    }
    nonisolated static var horos_decimalNumberFormatter: NumberFormatter { BrowserClassState.decimalNumberFormatter }
    /// The same object at every read, which @synchronized needs.
    nonisolated static var horos_smartAlbumDistantArraySync: NSString { BrowserClassState.smartAlbumDistantArraySync }

    /// The historical OsiriX Distributed Objects endpoint for SDK clients
    /// (BrowserController+CAPI.m).
    static func horos_registerLegacyDistributedBrowser(_ browser: Any?) {
        HorosBrowserRegisterLegacyDistributedBrowser(browser)
    }

    /// The date formats of the browser, from any thread.
    nonisolated static func horos_currentBrowserTimeFormat() -> DateFormatter? {
        return BrowserClassState.current?.windowState.TimeFormat
    }
    nonisolated static func horos_currentBrowserTimeWithSecondsFormat() -> DateFormatter? {
        return BrowserClassState.current?.windowState.TimeWithSecondsFormat
    }
    nonisolated static func horos_currentBrowserDateTimeWithSecondsFormat() -> DateFormatter? {
        return BrowserClassState.current?.windowState.DateTimeWithSecondsFormat
    }

    /// The literal the local copy thread synchronizes on, and the copy of
    /// DicomDatabase+MediaCopy.swift (BrowserController+CAPI.m).
    nonisolated static func horos_oneCopyAtATimeLock() -> NSObject! {
        return HorosBrowserOneCopyAtATimeLock()
    }
}
