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

/// The name of the exception an HorosObjCException.perform error carries.
private func exception(_ error: Error) -> NSException? {
    return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
}

/// C's conversion of a floating-point value to int: truncation toward zero, as
/// `int width += size.width` did.
private func cInt(_ value: CGFloat) -> Int32 {
    return Int32(truncatingIfNeeded: Int64(value))
}

private let MARGIN: Int32 = 3

/// The thumbnails matrix of the database window, customClass of its xib.
///
/// Implemented in Swift since #828: the Objective-C name and <Horos/BrowserMatrix.h>
/// are those of the former class. The former class declared
/// NSPasteboardItemDataProvider without implementing its required method; the
/// Swift class does not declare it.
@objc(BrowserMatrix)
public final class BrowserMatrix: NSMatrix, NSDraggingSource {
    public override func acceptsFirstMouse(for theEvent: NSEvent?) -> Bool {
        return true
    }

    public override func selectedCell() -> NSCell? {
        let s = super.selectedCell()

        if (s as? NSButtonCell)?.isTransparent ?? false {
            for case let c as NSButtonCell in super.selectedCells {
                if c.isTransparent == false {
                    return c
                }
            }
        }

        return s
    }

    public override var selectedCells: [NSCell] {
        let m = NSMutableArray(array: super.selectedCells)
        let r = NSMutableArray(capacity: m.count)

        for case let c as NSButtonCell in m {
            if c.isTransparent == false {
                r.add(c)
            }
        }

        return r as! [NSCell]
    }

    @objc(selectCellEvent:)
    func selectCellEvent(_ theEvent: NSEvent) {
        var row = 0, column = 0

        if self.getRow(&row, column: &column, for: self.convert(theEvent.locationInWindow, from: nil)) {
            if theEvent.modifierFlags.contains(.shift) {
                let start = (self.cells as NSArray).index(of: (self.selectedCells as NSArray).object(at: 0))
                let end = (self.cells as NSArray).index(of: self.cell(atRow: row, column: column) as Any)

                self.setSelectionFrom(start, to: end, anchor: start, highlight: false)

            } else if theEvent.modifierFlags.contains(.command) {
                let end = (self.cells as NSArray).index(of: self.cell(atRow: row, column: column) as Any)

                if (self.selectedCells as NSArray).contains(self.cell(atRow: row, column: column) as Any) {
                    self.setSelectionFrom(end, to: end, anchor: end, highlight: false)
                } else {
                    self.setSelectionFrom(end, to: end, anchor: end, highlight: false)
                }

            } else {
                if self.cell(atRow: row, column: column)?.isHighlighted == false { self.selectCell(atRow: row, column: column) }
            }
        }
    }

    @objc(startDrag:)
    func startDrag(_ event: NSEvent) {
        do {
            try HorosObjCException.perform {
                let event_location = event.locationInWindow
                var local_point = self.convert(event_location, from: nil)

                local_point.x -= 35
                local_point.y += 35

                let cells = self.selectedCells as NSArray

                if cells.count > 0 {
                    var subArray = cells

                    if subArray.count > 20 {
                        subArray = cells.subarray(with: NSMakeRange(0, 20)) as NSArray
                    }

                    var width: Int32 = 0
                    let firstCell = (subArray.object(at: 0) as! NSCell).image

                    width += MARGIN
                    for i in 0..<subArray.count {
                        width = cInt(CGFloat(width) + ((subArray.object(at: i) as! NSCell).image?.size.width ?? 0))
                        width += MARGIN
                    }

                    let thumbnail = NSImage(size: NSMakeSize(CGFloat(width), 70+6))

                    if thumbnail.size.width > 0 && thumbnail.size.height > 0 {
                        thumbnail.lockFocus()

                        NSColor.gray.set()
                        NSMakeRect(0, 0, CGFloat(width), 70+6).fill(using: .copy)

                        width = 0
                        width += MARGIN
                        for i in 0..<subArray.count {
                            NSMakeRect(CGFloat(width), 0, firstCell?.size.width ?? 0, firstCell?.size.height ?? 0).fill(using: .copy)

                            let im = (subArray.object(at: i) as! NSCell).image
                            im?.draw(at: NSMakePoint(CGFloat(width), 3), from: NSMakeRect(0, 0, im?.size.width ?? 0, im?.size.height ?? 0), operation: .copy, fraction: 0.8)

                            width = cInt(CGFloat(width) + (im?.size.width ?? 0))
                            width += MARGIN
                        }
                        thumbnail.unlockFocus()
                    }

                    // The selection is captured now, as object identifiers; the drop reads
                    // nothing from this matrix (#605).
                    let objects = NSMutableArray()
                    for i in 0..<cells.count {
                        objects.add((BrowserController.currentBrowser().matrixViewArray as NSArray).object(at: (cells.object(at: i) as! NSCell).tag))
                    }
                    let promise = BrowserController.currentBrowser().filePromise(forDatabaseObjects: objects as? [Any])
                    if promise == nil { return }

                    let di = NSDraggingItem(pasteboardWriter: promise!)
                    let p = self.convert(event.locationInWindow, from: nil)
                    di.setDraggingFrame(NSMakeRect(p.x-thumbnail.size.width/2, p.y-thumbnail.size.height/2, thumbnail.size.width, thumbnail.size.height), contents: thumbnail)

                    let session = self.beginDraggingSession(with: [di], event: event, source: self)
                    session.animatesToStartingPositionsOnCancelOrFail = true
                }
            }
        } catch {
            if let e = exception(error) { _N2LogExceptionImpl(e, false, "-[BrowserMatrix startDrag:]") }
        }
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .generic
    }

    // Option-drag: the displayed frame of an image thumbnail as one JPEG, or a
    // folder of JPEGs and PDF reports for a series or study thumbnail (#605).
    @objc(startDragJPEG:)
    func startDragJPEG(_ event: NSEvent) {
        var row = 0, column = 0
        if !self.getRow(&row, column: &column, for: self.convert(event.locationInWindow, from: nil)) {
            return
        }
        let selectedButtonCell = self.cell(atRow: row, column: column) as? NSButtonCell
        let objects = BrowserController.currentBrowser().matrixViewArray as NSArray?
        if (selectedButtonCell?.isTransparent ?? false) || !(selectedButtonCell?.isEnabled ?? false) || (selectedButtonCell?.tag ?? 0) < 0 || (selectedButtonCell?.tag ?? 0) >= (objects?.count ?? 0) {
            return
        }
        let selectedButtonCellTag = selectedButtonCell!.tag
        self.selectCell(atRow: row, column: column)
        BrowserController.currentBrowser().matrixPressed(self)
        let selectedObject = objects!.object(at: selectedButtonCellTag) as? NSManagedObject
        do {
            try HorosObjCException.perform {
                let image = selectedButtonCell?.image
                let thumbnailWidth = cInt((image?.size.width ?? 0) + 6)
                let thumbnail = NSImage(size: NSMakeSize(CGFloat(thumbnailWidth), 70+6))
                if thumbnail.size.width > 0 && thumbnail.size.height > 0 {
                    thumbnail.lockFocus()
                    NSColor.gray.set()
                    NSMakeRect(0, 0, CGFloat(thumbnailWidth), 70+6).fill(using: .copy)
                    NSMakeRect(3, 0, image?.size.width ?? 0, image?.size.height ?? 0).fill(using: .copy)
                    image?.draw(at: NSMakePoint(3, 3), from: NSMakeRect(0, 0, image?.size.width ?? 0, image?.size.height ?? 0), operation: .copy, fraction: 0.8)
                    thumbnail.unlockFocus()
                }

                var promise: NSPasteboardWriting? = nil
                let selectedImage = selectedObject as? DicomImage
                if (selectedImage?.isImageStorage()?.boolValue ?? false) && !BrowserController.isReportSeries(forFileExport: selectedImage?.series) {
                    // The frame as displayed, captured before the drag starts.
                    let previewPix = BrowserController.currentBrowser().previewPix(Int32(truncatingIfNeeded: selectedButtonCellTag))
                    if previewPix == nil || previewPix!.notAbleToLoadImage { return }
                    let jpeg = NSBitmapImageRep.representationOfImageReps(in: previewPix!.image()?.representations ?? [], using: .jpeg, properties: [.compressionFactor: NSNumber(value: 0.9)])
                    let name = String(format: "%@.%ld.jpg", ((selectedImage?.completePath() as NSString?)?.lastPathComponent ?? "(null)") as NSString, previewPix!.frameNo)
                    promise = BrowserController.currentBrowser().filePromise(forJPEGData: jpeg, name: name)
                } else {
                    promise = BrowserController.currentBrowser().filePromise(forDatabaseObjects: [selectedObject as Any], asJPEG: true)
                }
                if promise == nil { return }

                let di = NSDraggingItem(pasteboardWriter: promise!)
                let p = self.convert(event.locationInWindow, from: nil)
                di.setDraggingFrame(NSMakeRect(p.x-thumbnail.size.width/2, p.y-thumbnail.size.height/2, thumbnail.size.width, thumbnail.size.height), contents: thumbnail)

                let session = self.beginDraggingSession(with: [di], event: event, source: self)
                session.animatesToStartingPositionsOnCancelOrFail = true
            }
        } catch {
            if let e = exception(error) { _N2LogExceptionImpl(e, false, "-[BrowserMatrix startDragJPEG:]") }
        }
    }

    // Three gestures share this mouse-down. A click selects, and its original
    // event (with its click count and modifiers) reaches NSMatrix untouched. A drag
    // of at least four points starts a DICOM file promise, or a JPEG/PDF one with
    // Option. Holding the button still for one second starts the drag as well,
    // which is the behaviour a trackpad needs and the periodic pump that keeps the
    // second-long hold measurable (A297).
    public override func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        var row = 0, column = 0
        if !self.getRow(&row, column: &column, for: self.convert(event.locationInWindow, from: nil)) {
            super.mouseDown(with: event)
            return
        }
        let cell = self.cell(atRow: row, column: column) as? NSButtonCell
        if (cell?.isTransparent ?? false) || !(cell?.isEnabled ?? false) || event.clickCount > 1 {
            super.mouseDown(with: event)
            return
        }

        do {
            try HorosObjCException.perform {
                NSEvent.stopPeriodicEvents()
                NSEvent.startPeriodicEvents(afterDelay: 0, withPeriod: 0.001)
            }
        } catch {
            if let e = exception(error) { _N2LogExceptionImpl(e, false, "-[BrowserMatrix mouseDown:]") }
        }

        let start = Date()
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged, .periodic]

        // A return inside the former @try left the method; this is set before each.
        var returned = false
        do {
            try HorosObjCException.perform {
                while true {
                    // Peek: a mouse-up must stay queued so NSMatrix handles the click
                    // with the mouse-down event this method was given.
                    let nextEvent = self.window?.nextEvent(matching: mask, until: Date.distantFuture,
                                                           inMode: .eventTracking, dequeue: false)
                    if nextEvent == nil {
                        break
                    }

                    if nextEvent!.type == .leftMouseUp {
                        NSEvent.stopPeriodicEvents()
                        super.mouseDown(with: event)
                        returned = true
                        return
                    }

                    _ = self.window?.nextEvent(matching: mask, until: Date.distantPast,
                                               inMode: .eventTracking, dequeue: true)

                    if nextEvent!.type == .leftMouseDragged {
                        let dx = nextEvent!.locationInWindow.x - event.locationInWindow.x
                        let dy = nextEvent!.locationInWindow.y - event.locationInWindow.y
                        if dx * dx + dy * dy < 16.0 {
                            continue
                        }

                        NSEvent.stopPeriodicEvents()
                        if event.modifierFlags.contains(.option) {
                            self.startDragJPEG(event)
                        } else {
                            if !(self.selectedCells as NSArray).contains(cell as Any) {
                                self.selectCellEvent(event)
                            }
                            self.startDrag(nextEvent!)
                        }
                        returned = true
                        return
                    }

                    if start.timeIntervalSinceNow >= -1 { // still inside the one second hold
                        continue
                    }

                    NSEvent.stopPeriodicEvents()
                    if event.modifierFlags.contains(.option) {
                        self.startDragJPEG(event)
                    } else {
                        self.selectCellEvent(event)
                        self.startDrag(event)
                    }
                    returned = true
                    return
                }
            }
        } catch {
            if let e = exception(error) { _N2LogExceptionImpl(e, false, "-[BrowserMatrix mouseDown:]") }
        }
        if returned {
            return
        }

        NSEvent.stopPeriodicEvents()
    }

    public override func rightMouseDown(with theEvent: NSEvent) {
        self.selectCellEvent(theEvent)

        BrowserController.currentBrowser().matrixPressed(self)

        super.rightMouseDown(with: theEvent)
    }
}
