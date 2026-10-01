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
import UniformTypeIdentifiers

/// Manages the array of FlyThru steps.
///
/// A subclass of NSArrayController used to manage the steps of the flythru.
/// Each step consists of a Camera -- See Camera.h
/// Uses the usual NSArrayController methods.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/FlyThruStepsArrayController.h> are those of the former class, the
/// steps' array controller in FlyThru.xib, and the data source of its table.
///
/// Main actor: the controller of a window's table. The NSArrayController
/// overrides are nonisolated in the SDK; the table and the window send them on
/// the main thread, and they run their part on the main actor through
/// assumeMainActor.
@MainActor
@objc(FlyThruStepsArrayController)
public final class FlyThruStepsArrayController: NSArrayController {
    /// FlyThruTableViewDataType, the pasteboard type of the moved rows.
    private static let dataType = NSPasteboard.PasteboardType("FlyThruTableViewDataType")

    /// The xib's File's Owner, which owns this controller: weak, as the
    /// former outlet ivar did not retain it.
    @IBOutlet private weak var flyThruController: FlyThruController?
    @IBOutlet private var tableview: NSTableView?

    /// [self arrangedObjects], the array itself.
    private var arranged: NSArray {
        return (self.arrangedObjects as? NSArray) ?? NSArray()
    }

    /// [tableview scrollRowToVisible:[tableview selectedRow]]
    private func scrollSelectedRowToVisible() {
        if let tableview = tableview {
            tableview.scrollRowToVisible(tableview.selectedRow)
        }
    }

    public override func addObject(_ object: Any) {
        assumeMainActor(self) { $0.addCurrentCamera() }
    }

    private func addCurrentCamera() {
        // add the current Camera from flythuController
        FlyThruStepsArrayController.addObject(flyThruController?.currentCamera, to: self)
        self.resetCameraIndexes()

        self.scrollSelectedRowToVisible()
    }

    /// What follows a change of the steps: their indexes, and the selected row
    /// in view when `scroll`.
    private func stepsDidChange(scroll: Bool) {
        self.resetCameraIndexes()
        if scroll {
            self.scrollSelectedRowToVisible()
        }
    }

    /// [super addObject:object] of the former -addObject: and of the import,
    /// which keeps the decoded keyframe: a nil object raises, as it did.
    private static func addObject(_ object: Any?, to controller: FlyThruStepsArrayController) {
        if let object = object {
            controller.superAddObject(object)
        } else {
            NSException(name: .invalidArgumentException, reason: "-[FlyThruStepsArrayController addObject:]: object cannot be nil", userInfo: nil).raise()
        }
    }

    private func superAddObject(_ object: Any) {
        super.addObject(object)
    }

    public override func add(contentsOf objects: [Any]) {
        super.add(contentsOf: objects)
        assumeMainActor(self) { $0.stepsDidChange(scroll: true) }
    }

    public override func removeObject(_ sender: Any) {
        super.removeObject(sender)
        assumeMainActor(self) { $0.stepsDidChange(scroll: false) }
    }

    public override func remove(contentsOf sender: [Any]) {
        super.remove(contentsOf: sender)
        assumeMainActor(self) { $0.stepsDidChange(scroll: false) }
    }

    public override func remove(atArrangedObjectIndex index: Int) {
        super.remove(atArrangedObjectIndex: index)
        assumeMainActor(self) { $0.stepsDidChange(scroll: false) }
    }

    public override func setSelectionIndexes(_ indexes: IndexSet) -> Bool {
        let result = super.setSelectionIndexes(indexes)
        guard indexes.first != nil else { return false }
        assumeMainActor(self) { $0.showSelectedCamera() }
        return result
    }

    private func showSelectedCamera() {
        flyThruController?.ftAdapter?.setCurrentViewToCamera((self.selectedObjects as NSArray).object(at: 0) as? Camera)
    }

    @objc(keyDown:)
    public func keyDown(_ theEvent: NSEvent?) {
        guard let characters = theEvent?.characters as NSString?, characters.length > 0 else { return }

        let c = Int(characters.character(at: 0))
        if c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey {
            self.remove(self)
        }
    }

    @objc(flyThruTag:)
    public func flyThruTag(_ x: Int32) {
        switch x {
        case 0: // ADD
            self.add(self)

            flyThruController?.hidePlayBox = true
            flyThruController?.hideExportBox = true

        case 1: // REMOVE
            self.remove(self)

        case 2: // RESET
            self.resetCameras(self)

        case 3: // IMPORT
            let oPanel = NSOpenPanel()
            oPanel.allowsMultipleSelection = false
            oPanel.canChooseDirectories = false
            oPanel.allowedContentTypes = [UTType(filenameExtension: "xml")!]

            let result = oPanel.runModal()

            if result == .OK {
                self.resetCameras(self)
                let stepsDictionary = oPanel.url.flatMap { NSDictionary(contentsOf: $0) }
                let stepsXML = stepsDictionary?.value(forKey: "Step Cameras") as? NSArray
                self.importSteps(stepsXML)
                self.resetCameraIndexes()
            }

        case 4: // SAVE
            let panel = NSSavePanel()

            panel.canSelectHiddenExtension = false
            panel.allowedContentTypes = [UTType(filenameExtension: "xml")!]
            panel.nameFieldStringValue = "OsiriX Fly Through"

            if panel.runModal() == .OK {
                let xml = flyThruController?.flyThru?.exportToXML()
                if let url = panel.url {
                    xml?.write(to: url, atomically: true)
                }
            }

        default:
            break
        }
    }

    /// The keyframes of an imported file, each shown in the view for its
    /// preview; the loop of the former IMPORT case.
    func importSteps(_ stepsXML: NSArray?) {
        var count: Int32 = 1
        for cam in stepsXML ?? NSArray() {
            let camera = Camera(dictionary: cam as? [AnyHashable: Any])
            camera?.index = count
            count += 1
            flyThruController?.ftAdapter?.setCurrentViewToCamera(camera)
            let im = flyThruController?.ftAdapter?.getCurrentCameraImage(false)
            camera?.previewImage = im
            // Keep the decoded keyframe; addObject: captures the current view.
            FlyThruStepsArrayController.addObject(camera, to: self)
        }
    }

    @IBAction public func flyThruButton(_ sender: Any?) {
        // [sender selectedSegment]: 0 without a segmented control, as a message to nil.
        self.flyThruTag(Int32(truncatingIfNeeded: (sender as? NSSegmentedControl)?.selectedSegment ?? 0))
    }

    @objc(tableView:writeRowsWithIndexes:toPasteboard:)
    public func tableView(_ tv: NSTableView?, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard?) -> Bool {
        // Copy the row numbers to the pasteboard.
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: rowIndexes as NSIndexSet, requiringSecureCoding: true) else {
            return false
        }
        pboard?.declareTypes([FlyThruStepsArrayController.dataType], owner: self)
        pboard?.setData(data, forType: FlyThruStepsArrayController.dataType)
        return true
    }

    /// Whether a drag onto `tv` comes from the steps table itself. The
    /// pasteboard type is private but any application can write it, so the
    /// drag's source is checked as well as its destination.
    private func isDragWithinSteps(_ tv: NSTableView?, _ info: NSDraggingInfo?) -> Bool {
        guard let tableview = tableview, let tv = tv, tv === tableview,
              let source = info?.draggingSource as? NSTableView, source === tableview else {
            return false
        }
        return true
    }

    @objc(tableView:validateDrop:proposedRow:proposedDropOperation:)
    public func tableView(_ tv: NSTableView?, validateDrop info: NSDraggingInfo?, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        // only allow drops within the table
        return isDragWithinSteps(tv, info) ? .move : []
    }

    /// The rows a drag moves and the index they are inserted at once they
    /// are removed, or nil when the payload is missing, is not a secure
    /// archive of an index set, is empty, names a row outside the `count`
    /// steps, or the destination `row` is outside 0...count.
    static func validatedMove(_ payload: Data?, count: Int, row: Int) -> (rows: IndexSet, insertion: Int)? {
        guard let payload, !payload.isEmpty else { return nil }
        let decoded: NSIndexSet?
        do {
            decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSIndexSet.self, from: payload)
        } catch {
            NSLog("FlyThru: refused a drop whose rows do not decode: %@", "\(error)")
            return nil
        }
        guard let rows = decoded as IndexSet?, let last = rows.last, last < count,
              row >= 0, row <= count else {
            return nil
        }
        // The destination row counts the moved rows above it; they are removed first.
        let insertion = row - rows.count(in: 0..<row)
        guard insertion >= 0, insertion <= count - rows.count else { return nil }
        return (rows, insertion)
    }

    @objc(tableView:acceptDrop:row:dropOperation:)
    public func tableView(_ aTableView: NSTableView?, acceptDrop info: NSDraggingInfo?, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        // Nothing is read from the pasteboard, and the steps do not change,
        // unless the drag comes from this table and all its rows are steps.
        guard isDragWithinSteps(aTableView, info) else { return false }
        let steps = self.arranged
        let payload = info?.draggingPasteboard.data(forType: FlyThruStepsArrayController.dataType)
        guard let move = FlyThruStepsArrayController.validatedMove(payload, count: steps.count, row: row) else {
            return false
        }
        let moved = steps.objects(at: move.rows)
        self.remove(atArrangedObjectIndexes: move.rows)
        self.insert(contentsOf: moved, atArrangedObjectIndexes: IndexSet(integersIn: move.insertion..<(move.insertion + moved.count)))
        self.resetCameraIndexes()
        return true
    }

    @objc public func resetCameraIndexes() {
        var count: Int32 = 1
        for case let camera as Camera in self.arranged {
            camera.index = count
            count += 1
        }
    }

    @IBAction public func updateCamera(_ sender: Any?) {
        let index = self.selectionIndex
        if index == NSNotFound { return }
        self.remove(sender)
        if let camera = flyThruController?.currentCamera {
            self.insert(camera, atArrangedObjectIndex: index)
        } else {
            NSException(name: .invalidArgumentException, reason: "-[FlyThruStepsArrayController updateCamera:]: object cannot be nil", userInfo: nil).raise()
        }
        self.resetCameraIndexes()
    }

    @IBAction public func resetCameras(_ sender: Any?) {
        self.remove(contentsOf: self.arranged as? [Any] ?? [])

        flyThruController?.hidePlayBox = true
        flyThruController?.hideExportBox = true
    }
}
