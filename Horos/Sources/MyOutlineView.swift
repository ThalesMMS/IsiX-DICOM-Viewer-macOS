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

/// NSFilenamesPboardType, which Swift marks unavailable: the same type name.
fileprivate let filenamesPboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

/// NSAssert, which the Objective-C left enabled in every configuration: the
/// current NSAssertionHandler gets the failure, and by default raises
/// NSInternalInconsistencyException. The descriptions have no format
/// specifiers, so the variadic method is called with none.
fileprivate func assertion(_ condition: Bool, _ description: NSString, in selector: Selector, object: AnyObject, line: Int = #line) {
    if condition { return }
    let handler = NSAssertionHandler.current
    let handleFailure = NSSelectorFromString("handleFailureInMethod:object:file:lineNumber:description:")
    typealias HandleFailure = @convention(c) (AnyObject, Selector, Selector, AnyObject, NSString, Int, NSString) -> Void
    let function = unsafeBitCast(handler.method(for: handleFailure), to: HandleFailure.self)
    function(handler, handleFailure, selector, object, "MyOutlineView.swift", line, description)
}

/// A column identifier as the former code passed it: an NSString in an id.
fileprivate func columnIdentifier(_ identifier: Any?) -> NSUserInterfaceItemIdentifier? {
    guard let string = identifier as? String else { return nil }
    return NSUserInterfaceItemIdentifier(string)
}

/// [identifier isEqualToString:@"name"]: NO for nil, as a message to nil.
fileprivate func isNameIdentifier(_ identifier: Any?) -> Bool {
    return (identifier as? NSString)?.isEqual(to: "name") ?? false
}

/// [value floatValue] on an id: 0 for nil.
fileprivate func objcFloatValue(_ value: Any?) -> Float {
    if let number = value as? NSNumber { return number.floatValue }
    if let string = value as? NSString { return string.floatValue }
    return 0
}

/// [[[BrowserController currentBrowser] database] isReadOnly]: NO when there
/// is no browser or no database, as the messages to nil answered.
@MainActor fileprivate func currentDatabaseIsReadOnly() -> Bool {
    return BrowserController.currentBrowser()?.database?.isReadOnly ?? false
}

/// OutlineView for BrowserController.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/MyOutlineView.h> are those of the former class, and MainMenu.xib
/// uses the name as customClass. -removeTableColumn: (which logs through the
/// variadic N2LogStackTrace) and -draggingSourceOperationMaskForLocal: (which
/// Swift marks unavailable) are a category in MyOutlineView+CAPI.m.
@objc(MyOutlineView)
public final class MyOutlineView: NSOutlineView {

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    public override func keyDown(with event: NSEvent) {
        guard let characters = event.characters as NSString?, characters.length > 0 else { return }

        let c = characters.character(at: 0)

        if (c >= 0xF700 && c <= 0xF8FF) || c == 9 { // Functions keys, 9 == Tab Key
            super.keyDown(with: event)
        } else {
            self.window?.windowController?.keyDown(with: event)
        }
    }

    @objc(columnState)
    public func columnState() -> NSObject & NSCoding {
        let columns = self.tableColumns
        let state = NSMutableArray(capacity: columns.count)

        for column in columns where !column.isHidden {
            state.add(NSDictionary(objects: [column.identifier.rawValue as NSString, NSNumber(value: Float(column.width))],
                                   forKeys: ["Identifier" as NSString, "Width" as NSString]))
        }

        return state
    }

    @objc(restoreColumnState:)
    public func restoreColumnState(_ columnState: NSObject?) {
        assertion(columnState != nil, "nil columnState!", in: #selector(restoreColumnState(_:)), object: self)
        assertion(columnState is NSArray, "columnState is not an NSArray!", in: #selector(restoreColumnState(_:)), object: self)

        self.hideAllColumns()
        for case let params as NSDictionary in (columnState as? NSArray) ?? NSArray() {
            if !isNameIdentifier(params.object(forKey: "Identifier")) {
                if let identifier = columnIdentifier(params.object(forKey: "Identifier")),
                   let column = self.tableColumn(withIdentifier: identifier) {
                    column.isHidden = false
                    column.width = CGFloat(objcFloatValue(params.object(forKey: "Width")))
                    self.setIndicatorImage(nil, in: column)
                    self.needsDisplay = true
                }
            } else {
                self.outlineTableColumn?.width = CGFloat(objcFloatValue(params.object(forKey: "Width")))
                self.needsDisplay = true
            }
        }

        self.sizeLastColumnToFit()
    }

    @objc(setColumnWithIdentifier:visible:)
    public func setColumnWithIdentifier(_ identifier: Any?, visible: Bool) {
        if isNameIdentifier(identifier) {
            return
        }

        let column = columnIdentifier(identifier).flatMap { self.tableColumn(withIdentifier: $0) } // [self initialColumnWithIdentifier:identifier];
        assertion(column != nil, "nil column!", in: #selector(setColumnWithIdentifier(_:visible:)), object: self)
        guard let column else { return }

        let hidden = !visible

        if column.isHidden != hidden {
            column.isHidden = hidden

            if visible {
                self.moveColumn(self.column(withIdentifier: column.identifier), toColumn: 1)
            }

            self.sizeLastColumnToFit()
            self.needsDisplay = true
        }
    }

    @objc(isColumnWithIdentifierVisible:)
    public func isColumnWithIdentifierVisible(_ identifier: Any?) -> Bool {
        guard let identifier = columnIdentifier(identifier), let column = self.tableColumn(withIdentifier: identifier) else { return false }
        return !column.isHidden
    }

    @objc(initialColumnWithIdentifier:)
    public func initialColumn(withIdentifier identifier: Any?) -> NSTableColumn? {
        guard let identifier = columnIdentifier(identifier) else { return nil }
        return self.tableColumn(withIdentifier: identifier)
    }

    @objc(hideAllColumns)
    public func hideAllColumns() {
        for column in self.tableColumns where column.identifier.rawValue != "name" {
            column.isHidden = true
        }
    }

    @available(*, deprecated, message: "hideAllColumns")
    @objc(removeAllColumns)
    public func removeAllColumns() {
        self.hideAllColumns()
    }

    @available(*, deprecated, message: "just use tableColumns")
    @objc(allColumns)
    public func allColumns() -> [NSTableColumn] {
        return self.tableColumns
    }

    @available(*, deprecated)
    @objc(setInitialState)
    public func setInitialState() {
        //allColumns = [[NSArray arrayWithArray:[self tableColumns]] retain];
    }

    // MARK: Dragging destination

    /// [[sender draggingSource] isEqual:self]
    private func isOwnDrag(_ sender: NSDraggingInfo?) -> Bool {
        return (sender?.draggingSource as? NSObject)?.isEqual(self) ?? false
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isOwnDrag(sender) {
            return []
        }

        if currentDatabaseIsReadOnly() {
            return []
        }

        if sender.draggingSourceOperationMask.contains(.generic) {
            //this means that the sender is offering the type of operation we want
            //return that we want the NSDragOperationGeneric operation that they
            //are offering
            return .generic
        } else {
            //since they aren't offering the type of operation we want, we have
            //to tell them we aren't interested
        }

        return []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        //we aren't particularily interested in this so we will do nothing
        //this is one of the methods that we do not have to implement
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if currentDatabaseIsReadOnly() {
            return []
        }

        if sender.draggingSourceOperationMask.contains(.generic) {
            //this means that the sender is offering the type of operation we want
            //return that we want the NSDragOperationGeneric operation that they
            //are offering
            return .generic
        } else {
            //since they aren't offering the type of operation we want, we have
            //to tell them we aren't interested
            return []
        }
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
    }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if currentDatabaseIsReadOnly() {
            return false
        }

        return true
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if currentDatabaseIsReadOnly() {
            return false
        }

        if !isOwnDrag(sender) {
            let paste = sender.draggingPasteboard

            let types = [filenamesPboardType]

            let desiredType = paste.availableType(from: types)
            let carriedData = desiredType.flatMap { paste.data(forType: $0) }

            if carriedData == nil {
                return false
            } else {
                //the pasteboard was able to give us some meaningful data
                if desiredType == filenamesPboardType {
                    return true
                } else {
                    //this can't happen
                    assertion(false, "This can't happen", in: #selector(performDragOperation(_:)), object: self)
                    return false
                }
            }
        }
        return false
    }

    @objc(terminateDrag:)
    public func terminateDrag(_ fileArray: NSArray?) {
        var directory: ObjCBool = false
        var done = false
        let count = fileArray?.count ?? 0
        let first = count > 0 ? fileArray?.object(at: 0) as? NSString : nil

        if count == 1, let first, FileManager.default.fileExists(atPath: first as String, isDirectory: &directory) {
            if first.lastPathComponent == "Horos Data" { // It's a database folder !
                if FileManager.default.fileExists(atPath: first.appendingPathComponent("Database.sql")) {
                    BrowserController.currentBrowser()?.database = DicomDatabase(atPath: first.deletingLastPathComponent)
                    done = true
                }
            }
        }

        if !done {
            if count == 1, let first, first.pathExtension == "sql" { // It's a database file !
                BrowserController.currentBrowser()?.database = DicomDatabase(atPath: first.deletingLastPathComponent)
            } else if count == 1, let first, first.pathExtension == "albums" { // It's a database albums file !
                BrowserController.currentBrowser()?.addAlbumsFile(first as String)
            } else {
                BrowserController.currentBrowser()?.addFilesAndFolder(toDatabase: fileArray as? [Any])
            }
        }
    }

    public override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if currentDatabaseIsReadOnly() {
            return
        }

        guard let paste = sender?.draggingPasteboard else { return }
        //gets the dragging-specific pasteboard from the sender
        let types = [filenamesPboardType]
        //a list of types that we can accept
        let desiredType = paste.availableType(from: types)
        let carriedData = desiredType.flatMap { paste.data(forType: $0) }

        if carriedData == nil {
            return
        } else {
            //the pasteboard was able to give us some meaningful data
            if desiredType == filenamesPboardType {
                //we have a list of file names in an NSData object
                let fileArray = paste.propertyList(forType: filenamesPboardType)

                self.perform(#selector(terminateDrag(_:)), with: fileArray, afterDelay: 0.1)
            } else {
                //this can't happen
                assertion(false, "This can't happen", in: #selector(concludeDragOperation(_:)), object: self)
            }
        }
        self.needsDisplay = true
    }

    // -draggingSourceOperationMaskForLocal: is in MyOutlineView+CAPI.m.

    public override func menu(for event: NSEvent) -> NSMenu? {
        //Find which row is under the cursor
        self.window?.makeFirstResponder(self)
        let menuPoint = self.convert(event.locationInWindow, from: nil)
        let row = Int32(truncatingIfNeeded: self.row(at: menuPoint))

        /* Update the table selection before showing menu
         Preserves the selection if the row under the mouse is selected (to allow for
         multiple items to be selected), otherwise selects the row under the mouse */
        let currentRowIsSelected = (self.selectedRowIndexes as NSIndexSet).contains(Int(row))
        if !currentRowIsSelected {
            self.selectRowIndexes(NSIndexSet(index: Int(row)) as IndexSet, byExtendingSelection: false)
        }

        if self.numberOfSelectedRows <= 0 {
            //No rows are selected, so the table should be displayed with all items disabled
            let tableViewMenu = self.menu?.copy() as? NSMenu
            var i: Int32 = 0
            while i < Int32(truncatingIfNeeded: tableViewMenu?.numberOfItems ?? 0) {
                tableViewMenu?.item(at: Int(i))?.isEnabled = false
                i += 1
            }
            return tableViewMenu
        } else {
            return self.menu
        }
    }

    public override func rightMouseDown(with theEvent: NSEvent) {
        self.window?.makeKeyAndOrderFront(self)
        self.window?.makeFirstResponder(self)
        super.rightMouseDown(with: theEvent)
    }
}
