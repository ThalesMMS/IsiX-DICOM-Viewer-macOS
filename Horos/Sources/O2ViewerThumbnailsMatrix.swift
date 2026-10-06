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

/// The viewer's series and studies thumbnails.
///
/// We overload NSMatrix, but this class isn't as capable as NSMatrix: we only
/// support one column, or one row when the series list runs across the top or
/// the bottom of the viewer. So, actually, this isn't a matrix, it's a list,
/// but we still use NSMatrix so we don't have to modify ViewerController. The
/// list position of a cell is its index in `cells` either way.
///
/// Implemented in Swift: the Objective-C name and
/// <Horos/O2ViewerThumbnailsMatrix.h> are those of the former class, and
/// Viewer.xib uses the name as customClass. -draggingSourceOperationMaskForLocal:,
/// which Swift marks unavailable, is a category in O2ViewerThumbnailsMatrix+CAPI.m.
@objc(O2ViewerThumbnailsMatrix)
public final class O2ViewerThumbnailsMatrix: NSMatrix, NSDraggingSource {
    private var draggingStartingPoint = NSZeroPoint
    private var doubleClick: TimeInterval = 0
    /// The cell of the last click, compared by address only and never
    /// retained, as the former unretained ivar was.
    private var doubleClickCell: ObjectIdentifier?

    /// The frame of each cell up to maxIndex, stacked from the top in a
    /// column and from the left in a row.
    private func computeCellRects(forCells cells: NSArray, maxIndex: Int) -> [NSRect] {
        let cellSize = self.cellSize
        let row = self.isRow

        var rects = [NSRect](repeating: NSZeroRect, count: max(0, maxIndex + 1))

        var rect = NSMakeRect(0, 0, cellSize.width, 0)
        var i = 0
        while i <= maxIndex {
            let cell = cells.object(at: i) as! NSCell

            rect.size = cell.cellSize

            rects[i] = rect

            if row {
                rect.origin.x += rect.size.width
                rect.origin.x += self.intercellSpacing.width
            } else {
                rect.origin.y += rect.size.height
                rect.origin.y += self.intercellSpacing.height
            }
            i += 1
        }

        return rects
    }

    /// One row of several cells: the list runs across the viewer.
    private var isRow: Bool { self.numberOfRows == 1 && self.numberOfColumns > 1 }

    /// How many cells the list has, in a column or in a row.
    private var listCount: Int { max(0, self.isRow ? self.numberOfColumns : self.numberOfRows) }

    /// The list position of the cell at a row and a column.
    private func listIndex(row: Int, column: Int) -> Int { self.isRow ? column : row }

    @objc(startDrag:)
    public func startDrag(_ event: NSEvent?) {
        do {
            try HorosObjCException.perform {
                if let selectedCell = self.selectedCell() {
                    let firstCell = selectedCell.image
                    let firstCellSize = firstCell?.size ?? NSZeroSize

                    let MARGIN: CGFloat = 3

                    let thumbnail = NSImage(size: NSMakeSize(firstCellSize.width + MARGIN * 2, firstCellSize.height + MARGIN * 2), flipped: false) { bounds in
                        NSColor.gray.set()
                        __NSRectFill(bounds)

                        firstCell?.draw(at: NSMakePoint(MARGIN, MARGIN), from: NSMakeRect(0, 0, firstCellSize.width, firstCellSize.height), operation: .copy, fraction: 0.8)

                        return true
                    }

                    let pbi = NSPasteboardItem()

                    // The dragged series; startDrag: is only sent for a cell that has one.
                    guard let series = (selectedCell.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object else { return }
                    if let data = try? PropertyListSerialization.data(fromPropertyList: ([series] as NSArray).value(forKey: "XID") as Any, format: .binary, options: 0) {
                        pbi.setPropertyList(data, forType: NSPasteboard.PasteboardType(O2PasteboardTypeDatabaseObjectXIDs))
                    }

                    guard let event = event else { return }

                    let di = NSDraggingItem(pasteboardWriter: pbi)
                    let p = self.convert(event.locationInWindow, from: nil)
                    di.setDraggingFrame(NSMakeRect(p.x - thumbnail.size.width / 2, p.y - thumbnail.size.height / 2, thumbnail.size.width, thumbnail.size.height), contents: thumbnail)

                    let session = self.beginDraggingSession(with: [di], event: event, source: self)
                    session.animatesToStartingPositionsOnCancelOrFail = true
                }
            }
        } catch {
            if let localException = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                NSLog("Exception while dragging: %@", localException.description)
            }
        }
    }

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .generic
    }

    public func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        draggingStartingPoint = screenPoint
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == [] {
            let w = NSApplication.shared.window(withWindowNumber: NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0))

            var screen: NSScreen? = nil

            for case let s as NSScreen in AppController.shared().viewerScreens() ?? [] {
                if NSPointInRect(screenPoint, s.frame) {
                    screen = s
                }
            }

            var usefulRect = NSMakeRect(0, 0, 0, 0)

            if let screen = screen {
                usefulRect = AppController.usefullRect(for: screen)
            }

            if abs(screenPoint.x - draggingStartingPoint.x) > 50 && !(w?.windowController is ThumbnailsListPanel) && screen != nil && NSPointInRect(screenPoint, usefulRect) {
                let series = (self.selectedCell()?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object as? NSManagedObject
                let newViewer = BrowserController.currentBrowser()?.loadSeries(series, nil, true, keyImagesOnly: false)
                newViewer?.setHighLighted(1.0)
                if UserDefaults.standard.bool(forKey: "AUTOTILING") {
                    NSApp.sendAction(NSSelectorFromString("tileWindows:"), to: nil, from: self)
                } else {
                    AppController.shared().checkAllWindowsAreVisible(self, makeKey: true)
                }

                newViewer?.window?.makeKeyAndOrderFront(self)
            }
        }
    }

    @objc(actionAndFullscreen:)
    public func actionAndFullscreen(_ cell: Any?) {
        do {
            try HorosObjCException.perform {
                let cell = cell as? NSCell
                _ = (cell?.target as? NSObject)?.perform(cell?.action, with: self)

                if cell?.action == NSSelectorFromString("matrixPreviewPressed:") {
                    let v = cell?.target as? ViewerController
                    v?.fullScreenMenu(self)
                }
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(exception, false, "-[O2ViewerThumbnailsMatrix actionAndFullscreen:]")
            }
        }
    }

    public override func mouseDown(with firstEvent: NSEvent) {
        var event = firstEvent
        var lastMouse = firstEvent
        var start = Date()
        var previousSelectedCell: NSCell? = nil

        let DRAGTIMEOUT: TimeInterval = -2

        repeat {
            let point = self.convert(event.locationInWindow, from: nil)
            var row = 0, column = 0

            if self.getRow(&row, column: &column, for: point) {
                let cell = (self.cells as NSArray).object(at: self.listIndex(row: row, column: column)) as! NSCell

                let cellFrame = self.cellFrame(atRow: row, column: column)
                let nextState = cell.nextState

                cell.highlight(true, withFrame: cellFrame, in: self)

                cell.state = NSControl.StateValue(rawValue: nextState)

                self.selectCell(atRow: row, column: column)
                self.keyCell = cell

                if let previous = previousSelectedCell, self.selectedCell() !== previous {
                    self.selectCell(previous)
                    start = Date(timeIntervalSinceNow: DRAGTIMEOUT) // Force drag
                }

                if previousSelectedCell == nil {
                    previousSelectedCell = self.selectedCell()
                }
            } else {
                start = Date(timeIntervalSinceNow: DRAGTIMEOUT) // Force drag
            }

            // A mouse-down always comes through a window; without one there is
            // no event to wait for.
            guard let next = self.window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .periodic]) else { break }
            event = next

            if event.type != .periodic {
                lastMouse = event
            }
        } while lastMouse.type != .leftMouseUp && start.timeIntervalSinceNow >= DRAGTIMEOUT

        let cell = self.selectedCell()

        do {
            try HorosObjCException.perform {
                if start.timeIntervalSinceNow < DRAGTIMEOUT && (cell?.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject)?.object is DicomSeries {
                    cell?.isHighlighted = false
                    self.startDrag(event)
                } else {
                    if let cell = cell, cell.action != nil && cell.target != nil {
                        if Date.timeIntervalSinceReferenceDate - self.doubleClick < NSEvent.doubleClickInterval && self.doubleClickCell == ObjectIdentifier(cell) {
                            self.perform(#selector(self.actionAndFullscreen(_:)), with: cell, afterDelay: 0.001)
                        } else {
                            (cell.target as? NSObject)?.perform(cell.action!, with: self, afterDelay: 0.001)
                        }

                        self.doubleClick = Date.timeIntervalSinceReferenceDate
                        self.doubleClickCell = ObjectIdentifier(cell)
                    } else {
                        cell?.isHighlighted = false
                    }
                }
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(exception, false, "-[O2ViewerThumbnailsMatrix mouseDown:]")
            }
        }
    }

    public override func cellFrame(atRow row: Int, column col: Int) -> NSRect {
        let cells = self.cells as NSArray

        if row < 0 || row > self.numberOfRows - 1 || col < 0 || col > self.numberOfColumns - 1 {
            return NSZeroRect
        }

        let index = self.listIndex(row: row, column: col)
        let rects = self.computeCellRects(forCells: cells, maxIndex: index)

        return rects[index]
    }

    public override func getRow(_ row: UnsafeMutablePointer<Int>?, column col: UnsafeMutablePointer<Int>?, for aPoint: NSPoint) -> Bool {
        let cells = self.cells as NSArray
        let count = self.listCount
        let rects = self.computeCellRects(forCells: cells, maxIndex: count - 1)

        for i in 0..<count {
            if NSPointInRect(aPoint, rects[i]) {
                row?.pointee = self.isRow ? 0 : i
                col?.pointee = self.isRow ? i : 0
                return true
            }
        }

        return false
    }

    //- (void)highlightCell:(BOOL)flag atRow:(NSInteger)row column:(NSInteger)column { // .....
    //    if (flag)
    //        _highlightedRow = row;
    //    else _highlightedRow = -1;
    //}

    /// All the cells together: the length of the list, and the tallest or
    /// widest cell across it.
    private var listSize: NSSize {
        let rects = self.computeCellRects(forCells: self.cells as NSArray, maxIndex: self.listCount - 1)
        return rects.reduce(NSZeroSize) { NSMakeSize(max($0.width, NSMaxX($1)), max($0.height, NSMaxY($1))) }
    }

    /// The viewer's matrix does not translate its autoresizing mask into
    /// constraints, so Auto Layout sizes it from this. NSMatrix's own answer
    /// was not always invalidated when the list changed length, and the
    /// stale size cut the list down to its first cell.
    public override var intrinsicContentSize: NSSize { self.listSize }

    public override func sizeToCells() {
        let size = self.listSize
        self.frame = NSMakeRect(0, 0, size.width, size.height)
        self.invalidateIntrinsicContentSize()
        // [self.superview setNeedsDisplay:YES];
    }

    public override func draw(_ dirtyRect: NSRect) {
        let cells = self.cells as NSArray
        let rects = self.computeCellRects(forCells: cells, maxIndex: self.listCount - 1)

        for i in 0..<rects.count {
            let cell = cells.object(at: i) as! NSCell
            cell.draw(withFrame: rects[i], in: self)
        }
    }
}

/// What a thumbnail cell of the matrix stands for: a study with its series, or
/// a series.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/O2ViewerThumbnailsMatrix.h> are those of the former class.
@objc(O2ViewerThumbnailsMatrixRepresentedObject)
public final class O2ViewerThumbnailsMatrixRepresentedObject: NSObject {
    /// Retained, as before; the former properties were atomic.
    @objc public var object: Any?
    @objc public var children: NSArray?

    @objc(object:)
    public class func object(_ object: Any?) -> O2ViewerThumbnailsMatrixRepresentedObject {
        return self.object(object, children: nil)
    }

    @objc(object:children:)
    public class func object(_ object: Any?, children: NSArray?) -> O2ViewerThumbnailsMatrixRepresentedObject {
        let oro = O2ViewerThumbnailsMatrixRepresentedObject()
        oro.object = object
        oro.children = children?.copy() as? NSArray
        return oro
    }
}
