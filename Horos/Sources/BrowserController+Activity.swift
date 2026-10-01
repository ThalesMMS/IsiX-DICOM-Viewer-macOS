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

// BrowserController (Activity) and ThreadsTableView are implemented in Swift
// since #722, with the selectors and the Objective-C names of the former file.
// -deallocActivity stays Objective-C, in BrowserController+Activity+CAPI.m,
// beside the ivars it releases. The instance variables the category used are read
// through BrowserController (SwiftIvars).
//
// Every @synchronized on the threads controller is objcSynchronized below, the
// same recursive lock on the same object.

/// `@synchronized (object) { … }`: the same recursive lock, taken on nothing
/// when the object is nil, and left before an exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// `[NSArray arrayWithObjects: a, b, …, nil]`: the list ends at the first nil.
fileprivate func objcArray(_ items: Any?...) -> NSArray {
    let array = NSMutableArray()
    for item in items {
        guard let item else { break }
        array.add(item)
    }
    return array
}

public extension BrowserController {

    @objc(awakeActivity)
    func awakeActivity() {
        let helper = BrowserActivityHelper(browser: self)
        horos_activityHelper = helper
        horos_activityTableView?.delegate = helper
        horos_activityTableView?.dataSource = helper
    }

    @objc(_activityTableView)
    func _activityTableView() -> NSTableView! {
        return horos_activityTableView
    }
}

/// The activity list of the database window. It shows the threads of the
/// ThreadsManager and takes no selection.
@objc(ThreadsTableView)
public final class ThreadsTableView: NSTableView {

    // -accessibilityRows, -accessibilityChildren and -accessibilityVisibleRows
    // stay Objective-C, in a category in BrowserController+Activity+CAPI.m:
    // Swift types NSTableView's rows as NSAccessibilityRow, which the
    // NSAccessibilityElement rows returned here do not adopt.

    public override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
    }

    public override func mouseDown(with evt: NSEvent) {
    }

    public override func rightMouseDown(with evt: NSEvent) {
    }
}

fileprivate let BrowserActivityHelperContext = IdentityToken()

/// The data source and delegate of the activity list: one ThreadCell per thread
/// of the ThreadsManager.
// Main actor: the activity table's data source. The threads list notifies on
// the thread that changed it; the observer goes to the main thread first.
@MainActor
@objc(BrowserActivityHelper)
public final class BrowserActivityHelper: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Not retained, as before ("no retaining here"): the browser owns the helper.
    private weak var _browser: BrowserController?
    private let _cells: NSMutableArray

    @objc(initWithBrowser:)
    public init(browser: BrowserController!) {
        _browser = browser // no retaining here
        _cells = NSMutableArray()
        super.init()

        // we observe the threads array so we can release cells when they're not needed anymore
        ThreadsManager.default().threadsController.addObserver(self, forKeyPath: "arrangedObjects", options: [.new, .old, .initial], context: BrowserActivityHelperContext.pointer)
    }

    nonisolated deinit {
        ThreadsManager.default().threadsController.removeObserver(self, forKeyPath: "arrangedObjects")
    }

    @objc(cellForThread:)
    public func cell(for thread: Thread!) -> NSCell! {
        return objcSynchronized(ThreadsManager.default().threadsController) { () -> NSCell? in
            for case let cell as ThreadCell in _cells {
                if cell.thread === thread {
                    return cell
                }
            }
            return nil
        }
    }

    @objc(_observeValueForKeyPathOfObjectChangeContext:)
    func _observeValueForKeyPathOfObjectChangeContext(_ args: NSArray) {
        observeOnMainActor(args.object(at: 0) as? String, args.object(at: 1), args.object(at: 2) as? [NSKeyValueChangeKey: Any], (args.object(at: 3) as? NSValue)?.pointerValue)
    }

    public override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if !Thread.isMainThread {
            performSelector(onMainThread: #selector(_observeValueForKeyPathOfObjectChangeContext(_:)), with: objcArray(keyPath, object, change, NSValue(pointer: context)), waitUntilDone: false)
            return
        }
        assumeMainActor((self, keyPath, object, change, context)) { $0.0.observeOnMainActor($0.1, $0.2, $0.3, $0.4) }
    }

    private func observeOnMainActor(_ keyPath: String?, _ object: Any?, _ change: [NSKeyValueChangeKey: Any]?, _ context: UnsafeMutableRawPointer?) {

        if context == BrowserActivityHelperContext.pointer {
            let arrangedObjects = (object as? NSArrayController)?.arrangedObjects as? [Any]
            objcSynchronized(ThreadsManager.default().threadsController) {
                // we are looking for removed threads
                let threadsThatHaveCellsToRemove = ((_cells.value(forKey: "thread") as? NSArray)?.mutableCopy() as? NSMutableArray) ?? NSMutableArray()
                threadsThatHaveCellsToRemove.removeObjects(in: arrangedObjects ?? [])

                let cellsToRemove = NSMutableArray()
                for case let thread as Thread in threadsThatHaveCellsToRemove {
                    if let cell = self.cell(for: thread) as? ThreadCell {
                        cell.cleanup()
                        _ = Unmanaged.passUnretained(cell).retain()
                        cellsToRemove.add(cell)

                        NSObject.cancelPreviousPerformRequests(withTarget: cell, selector: NSSelectorFromString("autorelease"), object: nil)
                        cell.perform(NSSelectorFromString("autorelease"), with: nil, afterDelay: 60) //Yea... I know... not very nice, but avoid a zombie crash, if a thread is cancelled (GUI) AFTER released here...
                    }
                }

                var needToReloadData = false

                if cellsToRemove.count > 0 {
                    _cells.removeObjects(in: cellsToRemove as? [Any] ?? [])
                    needToReloadData = true
                }

                // Check for new added threads
                for case let thread as Thread in arrangedObjects ?? [] {
                    let cell = self.cell(for: thread)
                    if cell == nil {
                        _cells.add(ThreadCell(thread: thread, manager: ThreadsManager.default(), view: _browser?._activityTableView()))
                        needToReloadData = true
                    }
                }

                if needToReloadData {
                    _browser?._activityTableView()?.reloadData()
                    if let tableView = _browser?._activityTableView() {
                        NSAccessibility.post(element: tableView, notification: .layoutChanged)
                    }
                }
            }
            return
        }

        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    @objc(tableView:dataCellForTableColumn:row:)
    public func tableView(_ tableView: NSTableView, dataCellFor tableColumn: NSTableColumn?, row: Int) -> NSCell? {
        return objcSynchronized(ThreadsManager.default().threadsController) { () -> NSCell? in
            // -objectAtIndex: raised out of range, and the @catch returned NULL.
            guard row >= 0 && row < _cells.count else { return nil }
            return _cells.object(at: row) as? NSCell
        }
    }

    @objc(numberOfRowsInTableView:)
    public func numberOfRows(in aTableView: NSTableView) -> Int {
        return objcSynchronized(ThreadsManager.default().threadsController) {
            _cells.count
        }
    }

    @objc(tableView:willDisplayCell:forTableColumn:row:)
    public func tableView(_ tableView: NSTableView, willDisplayCell cellObject: Any, for tableColumn: NSTableColumn?, row: Int) {
        let frame: NSRect
        if let tableColumn { frame = tableView.frameOfCell(atColumn: (tableView.tableColumns as NSArray).index(of: tableColumn), row: row) }
        else { frame = tableView.rect(ofRow: row) }

        objcSynchronized(ThreadsManager.default().threadsController) {
            if let cell = cellObject as? ThreadCell, _cells.contains(cell) {
                let activityName = cell.thread?.name ?? NSLocalizedString("Unspecified Task", comment: "")
                cell.cancelButton?.setAccessibilityElement(true)
                cell.progressIndicator?.setAccessibilityElement(true)
                cell.cancelButton?.setAccessibilityLabel(String(format: NSLocalizedString("Cancel %@", comment: ""), activityName))
                cell.cancelButton?.setAccessibilityHelp(cell.thread?.status)
                cell.progressIndicator?.setAccessibilityLabel(activityName)

                // cancel
                if cell.cancelButton.superview == nil {
                    tableView.addSubview(cell.cancelButton)
                }

                let cancelFrame = NSMakeRect(frame.origin.x + frame.size.width - 15 - 5, frame.origin.y + 5, 15, 15)
                if !NSEqualRects(cell.cancelButton.frame, cancelFrame) {
                    cell.cancelButton.frame = cancelFrame
                }

                // progress
                if cell.progressIndicator.superview == nil {
                    tableView.addSubview(cell.progressIndicator)
                }

                let progressFrame: NSRect
                if AppController.hasMacOSXLion() {
                    progressFrame = NSMakeRect(frame.origin.x + 3, frame.origin.y + 27, frame.size.width - 6, frame.size.height - 32)
                } else { progressFrame = NSMakeRect(frame.origin.x + 1, frame.origin.y + 26, frame.size.width - 2, frame.size.height - 28) }

                if !NSEqualRects(cell.progressIndicator.frame, progressFrame) {
                    cell.progressIndicator.frame = progressFrame
                }
            }
        }
    }
}
