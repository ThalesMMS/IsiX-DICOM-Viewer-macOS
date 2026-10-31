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
import IsiXPreferences

/// The outline of the query window: keys other than function keys and Tab go
/// to the window controller (the query window's type-to-search), and only an
/// item that is one of its rows is expanded.
///
/// Implemented in Swift: the Objective-C name and
/// <Horos/QueryOutlineView.h> are those of the former class, which
/// Query.xib names as customClass.
@objc(QueryOutlineView)
public final class QueryOutlineView: NSOutlineView {
    // MARK: Expanding only rows the outline holds

    /// Whether `item` can be expanded now: the root (nil), or an item that is
    /// a row of the outline as it stands.
    ///
    /// The window's list is replaced as a whole on every query and refresh,
    /// and the outline only learns of it when -refreshList: reloads it, so a
    /// study of a list not shown yet or already replaced is not a row. Current
    /// AppKit ignores such a call; macOS 15 could not be checked, so the
    /// outline does not rely on it. The call is not kept for after the reload:
    /// the reload brings new objects for the same studies, and expanding one
    /// later would run a series query nobody asked for at that moment.
    /// Studies are the outline's only expandable rows and they are all
    /// top-level, so an item without a row is never one hidden inside a
    /// collapsed parent.
    func holdsRow(for item: Any?) -> Bool {
        item == nil || row(forItem: item) >= 0
    }

    public override func expandItem(_ item: Any?) {
        guard holdsRow(for: item) else { return }
        super.expandItem(item)
    }

    public override func expandItem(_ item: Any?, expandChildren: Bool) {
        guard holdsRow(for: item) else { return }
        super.expandItem(item, expandChildren: expandChildren)
    }

    // MARK: Waiting for a study's series

    /// AppKit asks for a study's series in the middle of expanding its row,
    /// and the data source waits for them in a modal session, which keeps
    /// delivering main-queue work. A reload or a new list arriving then
    /// changes the rows under that expansion: AppKit raises "should not be
    /// expanded already!" when the answer comes, or goes on to read rows that
    /// no longer exist. So what changes the rows waits with it, and runs once
    /// AppKit has finished.
    private var childrenWaits = 0
    private var heldWork: [@MainActor () -> Void] = []

    var isWaitingForChildren: Bool { childrenWaits > 0 }

    func beginWaitingForChildren() {
        childrenWaits += 1
    }

    func endWaitingForChildren() {
        childrenWaits -= 1
        guard childrenWaits == 0, !heldWork.isEmpty else { return }
        // Not here: AppKit is still expanding the row that asked.
        DispatchQueue.main.async { [self] in runHeldWork() }
    }

    func holdUntilChildrenArrive(_ work: @escaping @MainActor () -> Void) {
        heldWork.append(work)
    }

    private func runHeldWork() {
        // A later expansion began first; its end runs this.
        guard childrenWaits == 0 else { return }
        let work = heldWork
        heldWork = []
        work.forEach { $0() }
    }

    public override func reloadData() {
        guard childrenWaits == 0 else {
            holdUntilChildrenArrive { [weak self] in self?.reloadData() }
            return
        }
        super.reloadData()
    }

    // MARK: Events

    public override func keyDown(with event: NSEvent) {
        guard let characters = event.characters as NSString?, characters.length != 0 else { return }

        let c = characters.character(at: 0)

        if c >= 0xF700 && c <= 0xF8FF { // Functions keys
            if c == NSRightArrowFunctionKey {
                // After a reload AppKit can start its keyboard expansion
                // before it has row data. Resizing the outline column after
                // the series wait then creates it midway through that update,
                // whose end has no matching begin. An empty public update
                // prepares the row data before AppKit starts the expansion.
                beginUpdates()
                endUpdates()
            }
            super.keyDown(with: event)
        } else if c == 9 { // Tab Key
            super.keyDown(with: event)
        } else {
            window?.windowController?.keyDown(with: event)
        }
    }

    /// Command on a download arrow queues that row's retrieve. A table takes
    /// a click with Command to toggle the row in the selection and never
    /// tracks the arrow's button, so the click is taken here first; elsewhere
    /// Command still extends the selection.
    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let clickedRow = row(at: point), clickedColumn = column(at: point)
            let queue = #selector(QueryController.queueRetrieveOfItem(_:))
            if clickedRow >= 0, clickedColumn >= 0, tableColumns[clickedColumn].identifier.rawValue == "Button",
               let controller = window?.windowController, controller.responds(to: queue) {
                _ = controller.perform(queue, with: item(atRow: clickedRow))
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// Does not call super, as the former class did not.
    public override func becomeFirstResponder() -> Bool {
        if PreferencesSource.process.preferences[DatabasePreferences.displaySamePatientWithColorBackground] {
            needsDisplay = true
        }

        return true
    }

    /// Does not call super, as the former class did not.
    public override func resignFirstResponder() -> Bool {
        if PreferencesSource.process.preferences[DatabasePreferences.displaySamePatientWithColorBackground] {
            needsDisplay = true
        }

        return true
    }
}
