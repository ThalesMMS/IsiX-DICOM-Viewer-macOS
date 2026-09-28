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
import SecurityInterface

// The value of MovedRowsType, which stays exported from DNDArrayController+CAPI.m
// (with CopiedRowsType, which only -tableView:writeRows:toPasteboard: uses there).
fileprivate let movedRowsType = NSPasteboard.PasteboardType("MOVED_ROWS_TYPE")

/// NSParameterAssert, which the Objective-C left enabled in every
/// configuration: the current NSAssertionHandler gets the failure, and by
/// default raises NSInternalInconsistencyException. The description is the one
/// NSParameterAssert formats, written out: the variadic method is called with
/// no arguments, and the text has no format specifiers.
fileprivate func parameterAssertion(_ condition: Bool, _ conditionText: String, in selector: Selector, object: AnyObject, line: Int = #line) {
    if condition { return }
    let handler = NSAssertionHandler.current
    let handleFailure = NSSelectorFromString("handleFailureInMethod:object:file:lineNumber:description:")
    typealias HandleFailure = @convention(c) (AnyObject, Selector, Selector, AnyObject, NSString, Int, NSString) -> Void
    let function = unsafeBitCast(handler.method(for: handleFailure), to: HandleFailure.self)
    function(handler, handleFailure, selector, object, "DNDArrayController.swift", line, "Invalid parameter not satisfying: \(conditionText)" as NSString)
}

/// [value intValue] on an id: 0 for nil.
fileprivate func objcIntValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

/// Network destination Array Controller for Q/R.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/DNDArrayController.h> are those of the former class. Query.xib and
/// the Listener, Locations and On-Demand preference panes use the name as
/// customClass and connect its tableView outlet, which KVC sets through
/// -setTableView:. The table view data source and delegate methods keep their
/// selectors; as before, the class does not declare the protocols.
@objc(DNDArrayController)
public final class DNDArrayController: NSArrayController {
    /// The former `IBOutlet NSTableView *tableView` ivar. The xibs set it by
    /// KVC, which retained it; the getter is the former -tableView.
    private var tableViewOutlet: NSTableView?

    /// The former `IBOutlet SFAuthorizationView *_authView` ivar, which no xib
    /// connects and -setAuthView: assigned without retaining: weak. Public for
    /// the -tableView:writeRows:toPasteboard: of DNDArrayController+CAPI.m.
    @IBOutlet public weak var _authView: SFAuthorizationView?

    // NSTableColumn *sortedColumn was never used.

    @objc(tableView)
    public func tableView() -> NSTableView? {
        return tableViewOutlet
    }

    /// Where KVC sets the tableView outlet of the xibs.
    @objc(setTableView:)
    public func setTableView(_ tableView: NSTableView?) {
        tableViewOutlet = tableView
    }

    /// [self arrangedObjects], the array itself (not a Swift copy).
    private var arranged: NSArray {
        return (self.arrangedObjects as? NSArray) ?? NSArray()
    }

    /// Whether _authView, when there is one, is locked.
    private var isLockedByAuthView: Bool {
        guard let authView = _authView else { return false }
        return authView.authorizationState() != SFAuthorizationViewUnlockedState
    }

    public override func addObject(_ object: Any) {
        super.addObject(object)
        tableViewOutlet?.selectRowIndexes(NSIndexSet(index: self.arranged.count - 1) as IndexSet, byExtendingSelection: false)
    }

    @objc(setAuthView:)
    public func setAuthView(_ v: SFAuthorizationView?) {
        _authView = v
    }

    @objc(deleteSelectedRow:)
    public func deleteSelectedRow(_ sender: Any?) {
        if _authView == nil || _authView?.authorizationState() == SFAuthorizationViewUnlockedState {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Delete", comment: ""),
                                                message: NSLocalizedString("Are you sure you want to delete the selected item?", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""),
                                                alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                otherButton: nil) == NSAlertDefaultReturn {
                // [tableView selectedRow]: 0 without a table, as a message to nil.
                self.remove(atArrangedObjectIndex: tableViewOutlet?.selectedRow ?? 0)
            }
        }
    }

    @objc(numberOfRowsInTableView:)
    public func numberOfRows(in aTableView: NSTableView?) -> Int {
        return self.arranged.count
    }

    @objc(tableView:willDisplayCell:forTableColumn:row:)
    public func tableView(_ aTableView: NSTableView?, willDisplayCell aCell: Any?, for aTableColumn: NSTableColumn?, row rowIndex: Int) {
        let identifier = aTableColumn?.identifier.rawValue
        if identifier == "AddressAndPort" ||
            identifier == "Address" { // Warning ! DNDArrayController is used in Query.xib AND in OSILocations.xib
            parameterAssertion(rowIndex >= 0 && rowIndex < self.arranged.count,
                               "rowIndex >= 0 && rowIndex < [[self arrangedObjects] count]",
                               in: #selector(tableView(_:willDisplayCell:for:row:)), object: self)

            let theRecord = self.arranged.object(at: rowIndex) as? NSDictionary

            if let test = theRecord?.object(forKey: "test") {
                // [aCell setTextColor:], sent whatever the cell's class, as before.
                let setTextColor = #selector(setter: NSTextFieldCell.textColor)
                switch objcIntValue(test) {
                case -1:
                    _ = (aCell as? NSObject)?.perform(setTextColor, with: NSColor.orange)

                case -2:
                    _ = (aCell as? NSObject)?.perform(setTextColor, with: NSColor.red)

                case 0:
                    _ = (aCell as? NSObject)?.perform(setTextColor, with: NSColor.black)

                default:
                    break
                }
            }
        }
    }

    public override func awakeFromNib() {
        // register for drag and drop
        tableViewOutlet?.registerForDraggedTypes([movedRowsType])
        super.awakeFromNib()
    }

    // -tableView:writeRows:toPasteboard: stays in Objective-C, in
    // DNDArrayController+CAPI.m: NSObject (NSTableViewDataSourceDeprecated)
    // declares it deprecated since macOS 10.4, which Swift makes unavailable,
    // so a Swift class can neither override it nor reuse its selector.

    @objc(tableView:validateDrop:proposedRow:proposedDropOperation:)
    public func tableView(_ tv: NSTableView?, validateDrop info: NSDraggingInfo?, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        if _authView != nil {
            if isLockedByAuthView {
                return []
            }
        }

        var dragOp: NSDragOperation = .copy

        // if drag source is self, it's a move
        if (info?.draggingSource as AnyObject?) === tableViewOutlet {
            dragOp = .move
        }
        // we want to put the object at, not over,
        // the current row (contrast NSTableViewDropOn)
        tv?.setDropRow(row, dropOperation: .above)

        return dragOp
    }

    @objc(tableView:shouldEditTableColumn:row:)
    public func tableView(_ aTableView: NSTableView?, shouldEdit aTableColumn: NSTableColumn?, row rowIndex: Int) -> Bool {
        if _authView != nil {
            if isLockedByAuthView { return false }
        }

        return true
    }

    @objc(tableView:didClickTableColumn:)
    public func tableView(_ tb: NSTableView?, didClick tableColumn: NSTableColumn?) {
        if _authView != nil {
            if isLockedByAuthView { return }
        }

        self.sortDescriptors = tb?.sortDescriptors ?? []
        self.rearrangeObjects()

        let a = self.arranged.copy() as! NSArray

        self.remove(contentsOf: self.arranged as! [Any])
        self.add(contentsOf: a as! [Any])
    }

    @objc(tableView:acceptDrop:row:dropOperation:)
    public func tableView(_ tv: NSTableView?, acceptDrop info: NSDraggingInfo?, row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
        if _authView != nil {
            if isLockedByAuthView {
                return false
            }
        }

        var row = row
        if row < 0 {
            row = 0
        }

        // if drag source is self, it's a move
        if (info?.draggingSource as AnyObject?) === tableViewOutlet {

            self.sortDescriptors = []

            let rows = info?.draggingPasteboard.propertyList(forType: movedRowsType) as? NSArray
            var indexSet = self.indexSet(fromRows: rows)

            self.moveObjectsInArrangedObjects(fromIndexes: indexSet, toIndex: UInt32(truncatingIfNeeded: row))

            // set selected rows to those that were just moved
            // Need to work out what moved where to determine proper selection...
            let rowsAbove = self.rowsAbove(Int32(truncatingIfNeeded: row), in: indexSet)

            let range = NSMakeRange(row - Int(rowsAbove), indexSet.count)
            indexSet = NSIndexSet(indexesIn: range)
            _ = self.setSelectionIndexes(indexSet as IndexSet)

            return true
        }
        return false
    }

    @objc(moveObjectsInArrangedObjectsFromIndexes:toIndex:)
    public func moveObjectsInArrangedObjects(fromIndexes indexSet: NSIndexSet?, toIndex insertIndex: UInt32) {
        // With a nil set the former loop never ended ([nil lastIndex] and
        // [nil indexLessThanIndex:] are 0): nothing moves.
        guard let indexSet else { return }

        let objects = self.arranged
        var index: Int = indexSet.lastIndex
        var insertIndex = insertIndex

        var aboveInsertIndexCount: Int32 = 0
        var object: Any
        var removeIndex: Int32

        while NSNotFound != index {
            if index >= Int(insertIndex) {
                removeIndex = Int32(truncatingIfNeeded: index + Int(aboveInsertIndexCount))
                aboveInsertIndexCount += 1
            } else {
                removeIndex = Int32(truncatingIfNeeded: index)
                insertIndex &-= 1
            }
            object = objects.object(at: Int(removeIndex))
            self.remove(atArrangedObjectIndex: Int(removeIndex))
            self.insert(object, atArrangedObjectIndex: Int(insertIndex))

            tableViewOutlet?.selectRowIndexes(NSIndexSet(index: Int(insertIndex)) as IndexSet, byExtendingSelection: false)

            index = indexSet.indexLessThanIndex(index)
        }
    }

    @objc(indexSetFromRows:)
    public func indexSet(fromRows rows: NSArray?) -> NSIndexSet {
        let indexSet = NSMutableIndexSet()
        for idx in rows ?? NSArray() {
            indexSet.add(Int(objcIntValue(idx)))
        }
        return indexSet
    }

    @objc(rowsAboveRow:inIndexSet:)
    public func rowsAbove(_ row: Int32, in indexSet: NSIndexSet?) -> Int32 {
        // With a nil set the former loop never ended ([nil indexGreaterThanIndex:]
        // is 0): no rows.
        guard let indexSet else { return 0 }
        var currentIndex: Int = indexSet.firstIndex
        var i: Int = 0
        while currentIndex != NSNotFound {
            if currentIndex < Int(row) { i += 1 }
            currentIndex = indexSet.indexGreaterThanIndex(currentIndex)
        }
        return Int32(truncatingIfNeeded: i)
    }
}
