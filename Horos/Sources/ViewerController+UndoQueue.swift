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
import IsiXROI

// The ROI undo and redo of the 2D viewer are implemented in Swift: a Swift
// extension of ViewerController, which stays Objective-C, with the same
// selectors (-addToUndoQueue:, -removeLastItemFromUndoQueue,
// -prepareObjectForUndo:, -undo:, -redo:, -executeUndo:). A state is
// {type: "roi", rois: [time point][slice][ROI copies]}; the size rule of the
// queue (UndoQueueSize, DontUseUndoQueueForROIs) is in IsiXROI
// (ROIUndoQueuePolicy).

/// `[array addObject: object]` as the Objective-C of the viewer sent it: a
/// nil object raises NSInvalidArgumentException.
func viewerArrayAdd(_ object: Any?, to array: NSMutableArray) {
    if let object {
        array.add(object)
    } else {
        _ = array.perform(#selector(NSMutableArray.add(_:)), with: nil)
    }
}

public extension ViewerController {

    /// Restores the last state of `u` (the undo or the redo queue) and
    /// removes it.
    @objc(executeUndo:)
    func executeUndo(_ u: NSMutableArray!) {
        guard let u, u.count != 0 else { return }
        horos_imageView?.cancelLengthPlacement()
        horos_imageView?.stopROIEditing()

        guard let state = u.lastObject as? NSDictionary,
              (state.object(forKey: "type") as? NSString)?.isEqual(to: "roi") == true else { return }
        let rois = state.object(forKey: "rois") as? NSArray
        let maxMovie = Int(horos_maxMovieIndex)

        var i = 0
        while i < maxMovie {
            let list = horos_roiList(at: i)
            var x = 0
            while x < (list?.count ?? 0) {
                let slice = list?.object(at: x) as? NSMutableArray
                var z = 0
                while z < (slice?.count ?? 0) {
                    NotificationCenter.default.post(name: .OsirixRemoveROI, object: slice?.object(at: z), userInfo: nil)
                    z += 1
                }
                slice?.removeAllObjects()
                x += 1
            }
            i += 1
        }

        i = 0
        while i < maxMovie {
            let r = rois?.object(at: i) as? NSArray
            let list = horos_roiList(at: i)
            var x = 0
            while x < (list?.count ?? 0) {
                let slice = list?.object(at: x) as? NSMutableArray
                slice?.addObjects(from: (r?.object(at: x) as? [Any]) ?? [])
                for case let roi as ROI in slice ?? NSMutableArray() {
                    horos_imageView?.roiSet(roi)
                    NotificationCenter.default.post(name: .OsirixROIChange, object: roi, userInfo: nil)
                }
                x += 1
            }
            i += 1
        }

        var movie = 0
        while movie < maxMovie {
            for roi in volumeLengthROIs(forMovieIndex: movie) ?? [] {
                register(roi, movieIndex: movie, anchor: nil)
                attach(roi, movieIndex: movie)
            }
            movie += 1
        }
        if let view = horos_imageView {
            view.setIndex(view.curImage)
        }

        NSLog("roi undo")

        u.removeLastObject()
    }

    @objc(redo:)
    @IBAction override func redo(_ sender: Any!) {
        guard let redoQueue = horos_redoQueue, redoQueue.count != 0 else {
            NSSound.beep()
            return
        }
        let state = prepareObject(forUndo: (redoQueue.lastObject as? NSDictionary)?.object(forKey: "type") as? String)
        if let undoQueue = horos_undoQueue { viewerArrayAdd(state, to: undoQueue) }
        executeUndo(redoQueue)
    }

    @objc(undo:)
    @IBAction override func undo(_ sender: Any!) {
        guard let undoQueue = horos_undoQueue, undoQueue.count != 0 else {
            NSSound.beep()
            return
        }
        let state = prepareObject(forUndo: (undoQueue.lastObject as? NSDictionary)?.object(forKey: "type") as? String)
        if let redoQueue = horos_redoQueue { viewerArrayAdd(state, to: redoQueue) }
        executeUndo(undoQueue)
    }

    /// The current state of the ROIs, for the `string` kind of state ("roi"),
    /// nil for another kind. A ROI shown on every slice (a volume length, by
    /// its identifier, or an aliased ROI) is one copy, in every slice's list,
    /// so that it stays one ROI after an undo or a redo.
    @objc(prepareObjectForUndo:)
    func prepareObject(forUndo string: String!) -> Any! {
        var result: Any? = nil
        if let exception = viewerObjCTry({
            guard string == "roi" else { return }
            let rois = NSMutableArray()
            var i = 0
            while i < Int(horos_maxMovieIndex) {
                let array = NSMutableArray()
                let volumeCopies = NSMutableDictionary()
                let aliasCopies = NSMapTable<ROI, ROI>(keyOptions: [.strongMemory, .objectPointerPersonality], valueOptions: .strongMemory)
                for case let ar as NSArray in horos_roiList(at: i) ?? NSMutableArray() {
                    let a = NSMutableArray()
                    for case let r as ROI in ar {
                        let identifier = (r as? HorosVolumeLengthROI)?.volumeIdentifier
                        let hasIdentifier = (identifier?.isEmpty == false)
                        var copy: ROI? = hasIdentifier ? volumeCopies.object(forKey: identifier!) as? ROI : nil
                        if copy == nil && !hasIdentifier && r.isAliased {
                            copy = aliasCopies.object(forKey: r)
                        }
                        if copy == nil {
                            copy = r.copy() as? ROI
                            if hasIdentifier {
                                if let copy {
                                    volumeCopies.setObject(copy, forKey: identifier! as NSString)
                                } else {
                                    volumeCopies.removeObject(forKey: identifier! as NSString)
                                }
                            } else if r.isAliased {
                                aliasCopies.setObject(copy, forKey: r)
                            }
                        }
                        viewerArrayAdd(copy, to: a)
                    }
                    array.add(a)
                }
                rois.add(array)
                i += 1
            }
            result = NSDictionary(objects: [string! as NSString, rois], forKeys: ["type" as NSString, "rois" as NSString])
        }) {
            _N2LogExceptionImpl(exception, false, "-[ViewerController prepareObjectForUndo:]")
        }
        return result
    }

    @objc(removeLastItemFromUndoQueue)
    func removeLastItemFromUndoQueue() {
        if let undoQueue = horos_undoQueue, undoQueue.count != 0 {
            undoQueue.removeLastObject()
        }
    }

    /// Records the current state of the `string` kind ("roi") in the undo
    /// queue, as the preferences allow.
    @objc(addToUndoQueue:)
    override func add(toUndoQueue string: String!) {
        let defaults = UserDefaults.standard
        let policy = ROIUndoQueuePolicy(size: defaults.integer(forKey: "UndoQueueSize"),
                                        recordsROIs: !defaults.bool(forKey: "DontUseUndoQueueForROIs"))
        guard policy.isEnabled else { return }

        if policy.recordsROIs {
            let state = prepareObject(forUndo: string)
            if let undoQueue = horos_undoQueue { viewerArrayAdd(state, to: undoQueue) }
        }

        if let undoQueue = horos_undoQueue, policy.dropsOldest(count: undoQueue.count) {
            undoQueue.removeObject(at: 0)
        }
    }
}
