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

import CoreGraphics
import Foundation

/// The choice of the grid when the viewers' windows are tiled: the order of
/// the viewers, by row and then by centre; the rows and columns, from the
/// number of viewers and screens, the shape of the first screen, the hanging
/// protocol and the request of the tiling menu; the grouping by study; and the
/// frame each viewer is given. Nothing here moves a window: the application
/// describes its viewers and screens, and moves the windows to the frames that
/// come back, in their order.
///
/// The value keeps what the previous tiling chose (its rows, its columns and
/// how many viewers it placed), which the next one reads: one viewer added
/// beside the others keeps the others where they were.
public struct ViewerTilingLayout: Sendable, Equatable {

    /// A viewer as the tiling sees it.
    public struct Viewer: Sendable, Equatable {
        /// The window's frame; zero without a window.
        public var frame: CGRect
        /// The window is on screen. A hidden viewer was just opened: it goes
        /// after the others, and takes the place of one on another screen.
        public var isVisible: Bool
        /// The window is the key window.
        public var isKey: Bool
        /// The place of the window's screen in `orderedScreens(visibleFrames:)`;
        /// nil without a screen.
        public var orderedScreenIndex: Int?
        /// The origin's y of the visible frame of the window's screen; 0
        /// without a screen.
        public var screenVisibleOriginY: CGFloat
        /// The place of the window's screen among the screens the tiling uses;
        /// nil when it is on none of them.
        public var tilingScreenIndex: Int?
        /// The study the viewer shows; nil when it has none.
        public var studyInstanceUID: String?
        /// The date of that study; nil when it has none.
        public var studyDate: Date?

        public init(frame: CGRect, isVisible: Bool, isKey: Bool, orderedScreenIndex: Int?, screenVisibleOriginY: CGFloat,
                    tilingScreenIndex: Int?, studyInstanceUID: String?, studyDate: Date?) {
            self.frame = frame
            self.isVisible = isVisible
            self.isKey = isKey
            self.orderedScreenIndex = orderedScreenIndex
            self.screenVisibleOriginY = screenVisibleOriginY
            self.tilingScreenIndex = tilingScreenIndex
            self.studyInstanceUID = studyInstanceUID
            self.studyDate = studyDate
        }
    }

    /// A screen the viewers are tiled on.
    public struct Screen: Sendable, Equatable {
        /// The screen's visible frame.
        public var visibleFrame: CGRect
        /// The area a grid of windows fills: the screen's tiling area without
        /// the floating panels (toolbar, series list, 4D navigator).
        public var gridRect: CGRect
        /// The area of a single row of windows, or of one window per screen:
        /// the same without the floating panels only when the 2D viewer's
        /// toolbar panel is shown.
        public var rowRect: CGRect

        public init(visibleFrame: CGRect, gridRect: CGRect, rowRect: CGRect) {
            self.visibleFrame = visibleFrame
            self.gridRect = gridRect
            self.rowRect = rowRect
        }
    }

    /// The rows and columns a tiling is asked for: the tiling menus give
    /// `rows` or `columns` (fixed: the other one grows), a hanging protocol
    /// `protocolRows` and `protocolColumns`. A key that was absent is nil; a
    /// value that is not a number is 0, which asks for nothing.
    public struct Request: Sendable, Equatable {
        public var rows: Int32?
        public var columns: Int32?
        public var protocolRows: Int32?
        public var protocolColumns: Int32?

        public init(rows: Int32? = nil, columns: Int32? = nil, protocolRows: Int32? = nil, protocolColumns: Int32? = nil) {
            self.rows = rows
            self.columns = columns
            self.protocolRows = protocolRows
            self.protocolColumns = protocolColumns
        }
    }

    /// The preferences and the hanging protocol the tiling follows.
    public struct Options: Sendable, Equatable {
        /// The rows and columns of the hanging protocol shown, or of the last
        /// tiling when there is none.
        public var rows: Int32
        public var columns: Int32
        /// A hanging protocol is shown.
        public var hasHangingProtocol: Bool
        /// The viewers of a study stay on one screen.
        public var keepsStudiesOnSameScreen: Bool
        /// The windows of the last screen grow into the room the others leave.
        public var stretchesWindows: Bool
        /// The viewers are ordered by the date of their study, the latest
        /// first, or the earliest first when `reversesStudyDateOrder`.
        public var ordersByStudyDate: Bool
        public var reversesStudyDateOrder: Bool

        public init(rows: Int32, columns: Int32, hasHangingProtocol: Bool, keepsStudiesOnSameScreen: Bool,
                    stretchesWindows: Bool, ordersByStudyDate: Bool, reversesStudyDateOrder: Bool) {
            self.rows = rows
            self.columns = columns
            self.hasHangingProtocol = hasHangingProtocol
            self.keepsStudiesOnSameScreen = keepsStudiesOnSameScreen
            self.stretchesWindows = stretchesWindows
            self.ordersByStudyDate = ordersByStudyDate
            self.reversesStudyDateOrder = reversesStudyDateOrder
        }
    }

    /// A viewer (its place in the list given) and the frame it takes.
    public struct Placement: Sendable, Equatable {
        public var viewer: Int
        public var frame: CGRect

        public init(viewer: Int, frame: CGRect) {
            self.viewer = viewer
            self.frame = frame
        }
    }

    /// What a tiling chose.
    public struct Arrangement: Sendable, Equatable {
        /// The frames, in the order the windows are to be moved.
        public var placements: [Placement]
        /// The viewers in their tiled order (places in the list given).
        public var order: [Int]
        /// The hidden viewers that were not placed among the others: their
        /// series list shows its selection.
        public var hidden: [Int]
        /// The viewer to make key: the last hidden one, or the key one; nil
        /// when there is neither.
        public var keyViewer: Int?
        /// The viewers fitted no grid, and no window was moved.
        public var fitsNoGrid: Bool
    }

    /// The rows and columns of the previous tiling, and the number of viewers
    /// it placed.
    public private(set) var lastRows: Int32 = 0
    public private(set) var lastColumns: Int32 = 0
    public private(set) var lastCount: Int32 = 0

    public init() {}

    // MARK: - Screens

    /// The screens from the lowest and leftmost to the highest and rightmost,
    /// as places in `visibleFrames`: pass after pass, the one lowest and
    /// leftmost of those still left. A pass that picks none (a frame at or
    /// beyond a million points, or not a number) keeps the rest in the order
    /// they came in.
    public static func orderedScreens(visibleFrames: [CGRect]) -> [Int] {
        var source = Array(visibleFrames.indices)
        var ordered: [Int] = []

        while !source.isEmpty {
            var minY: Float = 1000000, minX: Float = 1000000
            var picked: Int? = nil
            for place in source {
                let frame = visibleFrames[place]
                if frame.origin.y <= CGFloat(minY) && frame.origin.x < CGFloat(minX) {
                    minY = Float(frame.origin.y)
                    minX = Float(frame.origin.x)
                    picked = place
                }
            }

            guard let picked else {
                ordered += source
                break
            }
            ordered.append(picked)
            source.removeAll { $0 == picked }
        }

        return ordered
    }

    /// The row of a viewer, for the order of the tiling: the screens in their
    /// order, 3000 points apart, then the window's height on its screen, the
    /// highest window first.
    static func currentRow(of viewer: Viewer) -> Int32 {
        let i = UInt(viewer.orderedScreenIndex ?? 0) &+ 1
        let offset = CGFloat(i &* 3000)
        return Int32(offset - (viewer.frame.origin.y + (3 * viewer.frame.size.height) / 4 - viewer.screenVisibleOriginY))
    }

    /// The centre of a viewer's window, its screen's place in the order
    /// added as 3000 points per screen.
    static func center(of viewer: Viewer) -> CGPoint {
        let i = UInt(viewer.orderedScreenIndex ?? 0) &+ 1
        let offset = CGFloat(i &* 3000)
        return CGPoint(x: offset + viewer.frame.origin.x + viewer.frame.size.width / 2,
                       y: offset + viewer.frame.origin.y + viewer.frame.size.height / 2)
    }

    // MARK: - Tiling

    /// The frames of `viewers` on `screens` (the first one gives the shape),
    /// for `request` (nil when the tiling was not asked for a grid) and
    /// `options`; records the grid it chose for the next tiling.
    public mutating func arrange(_ viewers: [Viewer], on screens: [Screen], request: Request?, options: Options) -> Arrangement {
        // The visible windows from left-top to right-bottom, per screen.
        var visible = viewers.indices.filter { viewers[$0].isVisible }
        var order: [Int] = []
        while !visible.isEmpty {
            var index = 0
            var row = Self.currentRow(of: viewers[visible[index]])
            for x in visible.indices where Self.currentRow(of: viewers[visible[x]]) < row {
                row = Self.currentRow(of: viewers[visible[x]])
                index = x
            }

            // Kept as a float, as the comparison always was.
            var minX = Float(Self.center(of: viewers[visible[index]]).x)
            for x in visible.indices {
                let center = Self.center(of: viewers[visible[x]])
                if center.x < CGFloat(minX) && Self.currentRow(of: viewers[visible[x]]) <= row {
                    minX = Float(center.x)
                    index = x
                }
            }

            order.append(visible.remove(at: index))
        }

        // The hidden windows go after the others; the last one becomes key.
        var hidden: [Int] = []
        var keyViewer: Int? = nil
        for place in viewers.indices where !viewers[place].isVisible {
            hidden.append(place)
            order.append(place)
            keyViewer = place
        }
        if keyViewer == nil {
            for place in order where viewers[place].isKey {
                keyViewer = place
            }
        }

        if options.ordersByStudyDate {
            hidden.removeAll()
            order = Self.mergeSorted(order) { first, second in
                let earlier = viewers[first].studyDate, later = viewers[second].studyDate
                return options.reversesStudyDateOrder ? Self.compare(earlier, later) : Self.compare(later, earlier)
            }
        }

        // The studies, when their viewers stay together and there are several.
        var keepsStudiesTogether = options.keepsStudiesOnSameScreen
        var identical = true
        if keepsStudiesTogether, let first = order.first {
            let studyUID = viewers[first].studyInstanceUID
            for place in order where !Self.sameStudy(viewers[place].studyInstanceUID, studyUID) {
                identical = false
            }
        }

        var studies: [[Int]] = []
        if keepsStudiesTogether && !identical {
            for place in order {
                let studyUID = viewers[place].studyInstanceUID
                var found = false
                for group in studies.indices where Self.sameStudy(viewers[studies[group][0]].studyInstanceUID, studyUID) {
                    studies[group].append(place)
                    found = true
                }
                if !found {
                    studies.append([place])
                }
            }
        } else {
            keepsStudiesTogether = false
        }

        guard let firstScreen = screens.first else {
            return Arrangement(placements: [], order: order, hidden: hidden, keyViewer: keyViewer, fitsNoGrid: true)
        }

        let viewerCount = Int32(truncatingIfNeeded: order.count)
        let numberOfMonitors = Int32(truncatingIfNeeded: screens.count)

        let screenRect = firstScreen.visibleFrame
        let landscape = screenRect.size.width / screenRect.size.height > 1

        var landscapeRatio: Float = 1.5
        if screenRect.size.width / screenRect.size.height > 1.7 { // 16/9 screen or more
            landscapeRatio = 2.0
        }

        var portraitRatio: Float = 0.9
        if screenRect.size.height / screenRect.size.width > 1.7 { // 16/9 screen or more
            portraitRatio = 0.49
        }

        var rows = options.rows
        var columns = options.columns

        if let request {
            let lowerRows = request.rows ?? 0, lowerColumns = request.columns ?? 0
            if lowerRows != 0 && lowerColumns != 0 {
                rows = lowerRows
                columns = lowerColumns
            } else if lowerRows != 0 {
                rows = lowerRows
                columns = Int32(floor(Double(Float(viewerCount) / Float(rows))))
            } else if lowerColumns != 0 {
                columns = lowerColumns
                rows = Int32(floor(Double(Float(viewerCount) / Float(columns))))
            }

            let upperRows = request.protocolRows ?? 0, upperColumns = request.protocolColumns ?? 0
            if upperRows != 0 && upperColumns != 0 {
                rows = upperRows
                columns = upperColumns
            } else if upperRows != 0 {
                rows = upperRows
                columns = Int32(floor(Double(Float(viewerCount) / Float(rows))))
            } else if upperColumns != 0 {
                columns = upperColumns
                rows = Int32(floor(Double(Float(viewerCount) / Float(columns))))
            }
        } else if !options.hasHangingProtocol || viewerCount < rows * columns {
            if landscape {
                columns = 2 * numberOfMonitors
                rows = 1
            } else {
                columns = numberOfMonitors
                rows = 2
            }
        }

        if rows <= 0 {
            rows = 1
        }

        if columns <= 0 {
            columns = 1
        }

        let ratioValue = landscape ? landscapeRatio : portraitRatio
        let fixedRows = request?.rows != nil
        let fixedColumns = request?.columns != nil

        // Excess viewers: room is made for them.
        if viewerCount > rows * columns {
            let viewerCountPerScreen = Float(viewerCount) / Float(numberOfMonitors)
            var columnsPerScreen = Int32(ceil(Double(Float(columns) / Float(numberOfMonitors))))

            while viewerCountPerScreen > Float(rows * columnsPerScreen) {
                if fixedRows {
                    columnsPerScreen += 1
                } else if fixedColumns {
                    rows += 1
                } else if Float(columnsPerScreen) / Float(rows) > ratioValue {
                    rows += 1
                } else {
                    columnsPerScreen += 1
                }
            }

            let intViewerCountPerScreen = Int32(ceilf(viewerCountPerScreen))

            if rows * columnsPerScreen > intViewerCountPerScreen && rows * (columnsPerScreen - 1) == intViewerCountPerScreen {
                columnsPerScreen -= 1
            }

            if rows * columnsPerScreen > intViewerCountPerScreen && columnsPerScreen * (rows - 1) == intViewerCountPerScreen {
                rows -= 1
            }

            columns = columnsPerScreen * numberOfMonitors
        }

        // One window added to a single screen goes where the new column
        // starts, and the others keep their places.
        if numberOfMonitors == 1 && lastColumns != columns && Int(lastCount) == order.count - 1 && Int(columns) < order.count
            && lastColumns >= 0 && Int(lastColumns) < order.count {
            let added = order.removeLast()
            order.insert(added, at: Int(lastColumns))
        }

        lastColumns = columns
        lastRows = rows
        lastCount = Int32(truncatingIfNeeded: order.count)

        var placements: [Placement] = []
        var fitsNoGrid = false

        if keepsStudiesTogether && numberOfMonitors > 1 {
            // One study per screen; the last screen takes the studies left.
            var columnsForThisScreen = Int32(ceil(Double(Float(columns) / Float(numberOfMonitors))))
            var rowsForThisScreen = rows

            var i: Int32 = 0
            while i < numberOfMonitors && Int(i) < studies.count {
                var viewersForThisScreen = studies[Int(i)]

                if i == numberOfMonitors - 1 || Int(i) == studies.count - 1 {
                    var x = i + 1
                    while Int(x) < studies.count {
                        viewersForThisScreen += studies[Int(x)]
                        x += 1
                    }
                }

                if viewersForThisScreen.count > Int(rowsForThisScreen * columnsForThisScreen) {
                    while viewersForThisScreen.count > Int(rowsForThisScreen * columnsForThisScreen) {
                        if fixedRows {
                            columnsForThisScreen += 1
                        } else if fixedColumns {
                            rowsForThisScreen += 1
                        } else if Float(columnsForThisScreen) / Float(rowsForThisScreen) > ratioValue {
                            rowsForThisScreen += 1
                        } else {
                            columnsForThisScreen += 1
                        }
                    }

                    let intViewerCountPerScreen = Int32(ceilf(Float(viewersForThisScreen.count)))

                    if rowsForThisScreen * columnsForThisScreen > intViewerCountPerScreen && rowsForThisScreen * (columnsForThisScreen - 1) == intViewerCountPerScreen {
                        columnsForThisScreen -= 1
                    }

                    if rowsForThisScreen * columnsForThisScreen > intViewerCountPerScreen && columnsForThisScreen * (rowsForThisScreen - 1) == intViewerCountPerScreen {
                        rowsForThisScreen -= 1
                    }

                    columns = columnsForThisScreen * numberOfMonitors
                }

                // Each screen is the last one, for the stretching.
                placements += Self.grid(viewersForThisScreen, monitorIndex: i, screens: screens, numberOfMonitors: i + 1,
                                        rowsPerScreen: rowsForThisScreen, columnsPerScreen: columnsForThisScreen,
                                        stretchesWindows: options.stretchesWindows)
                i += 1
            }
        } else if viewerCount <= numberOfMonitors {
            // One viewer per screen.
            for i in 0..<Int(viewerCount) {
                placements.append(Placement(viewer: order[i], frame: screens[i].rowRect))
            }

            lastRows = 1
            lastColumns = numberOfMonitors
        } else if viewerCount <= columns && viewerCount % numberOfMonitors == 0 {
            // One row, as many columns on each screen.
            let viewersPerScreen = viewerCount / numberOfMonitors
            for i in 0..<viewerCount {
                let index = i / viewersPerScreen
                let viewerPosition = i % viewersPerScreen
                var frame = screens[Int(index)].rowRect

                frame.size.width /= CGFloat(viewersPerScreen)
                frame.origin.x += frame.size.width * CGFloat(viewerPosition)

                placements.append(Placement(viewer: order[Int(i)], frame: frame))
            }

            lastRows = 1
            lastColumns = viewerCount
        } else if viewerCount <= columns {
            // One row, one column more on the first screens.
            let columnsPerScreen = Int32(ceil(Double(Float(columns) / Float(numberOfMonitors))))
            let extraViewers = viewerCount % numberOfMonitors

            for i in 0..<viewerCount {
                let monitorIndex = i / columnsPerScreen
                let viewerPosition = i % columnsPerScreen
                var frame = screens[Int(monitorIndex)].rowRect

                if monitorIndex < extraViewers {
                    frame.size.width /= CGFloat(columnsPerScreen)
                } else {
                    frame.size.width /= CGFloat(columnsPerScreen - 1)
                }

                frame.origin.x += frame.size.width * CGFloat(viewerPosition)

                Self.insertHidden(&hidden, into: &order, at: Int(i), unlessOn: Int(monitorIndex), viewers)

                placements.append(Placement(viewer: order[Int(i)], frame: frame))
                let placed = order[Int(i)]
                hidden.removeAll { $0 == placed }
            }

            lastRows = 1
            lastColumns = viewerCount
        } else if viewerCount <= columns * rows {
            // A grid on each screen.
            let columnsPerScreen = Int32(ceil(Double(Float(columns) / Float(numberOfMonitors))))
            let rowsPerScreen = rows

            var viewersForThisScreen: [Int] = []
            var previousIndex: Int32 = 0
            var monitorIndex: Int32 = 0

            if viewerCount != 0 {
                for i in 0..<viewerCount {
                    monitorIndex = i / (columnsPerScreen * rowsPerScreen)

                    if monitorIndex == numberOfMonitors { monitorIndex = numberOfMonitors - 1 }

                    if monitorIndex != previousIndex {
                        placements += Self.grid(viewersForThisScreen, monitorIndex: previousIndex, screens: screens, numberOfMonitors: numberOfMonitors,
                                                rowsPerScreen: rowsPerScreen, columnsPerScreen: columnsPerScreen,
                                                stretchesWindows: options.stretchesWindows)
                        viewersForThisScreen.removeAll()

                        previousIndex = monitorIndex
                    }

                    Self.insertHidden(&hidden, into: &order, at: Int(i), unlessOn: Int(monitorIndex), viewers)

                    let placed = order[Int(i)]
                    viewersForThisScreen.append(placed)
                    hidden.removeAll { $0 == placed }
                }

                if !viewersForThisScreen.isEmpty {
                    placements += Self.grid(viewersForThisScreen, monitorIndex: monitorIndex, screens: screens, numberOfMonitors: numberOfMonitors,
                                            rowsPerScreen: rowsPerScreen, columnsPerScreen: columnsPerScreen,
                                            stretchesWindows: options.stretchesWindows)
                }
            }
        } else {
            fitsNoGrid = true
        }

        return Arrangement(placements: placements, order: order, hidden: hidden, keyViewer: keyViewer, fitsNoGrid: fitsNoGrid)
    }

    /// The value of the "LastWindowsTilingRowsColumns" preference after a
    /// tiling: the rows, then the columns of one of `viewerScreens` screens
    /// (at least one).
    public func lastRowsColumns(viewerScreens: Int) -> String {
        // An unsigned division, as the former C one; none by zero.
        let screens = UInt(max(viewerScreens, 0))
        var perScreen = Int32(truncatingIfNeeded: screens == 0 ? 0 : UInt(bitPattern: Int(lastColumns)) / screens)
        if perScreen < 1 {
            perScreen = 1
        }
        return "\(lastRows)\(perScreen)"
    }

    // MARK: - Helpers

    /// The frames of a grid of `rowsPerScreen` × `columnsPerScreen` windows
    /// on one screen, row after row from the top. On the last screen the
    /// windows stretch, when asked, into the cells the others leave empty.
    static func grid(_ list: [Int], monitorIndex: Int32, screens: [Screen], numberOfMonitors: Int32,
                     rowsPerScreen: Int32, columnsPerScreen: Int32, stretchesWindows: Bool) -> [Placement] {
        var rowsPerScreen = rowsPerScreen, columnsPerScreen = columnsPerScreen
        var lastScreen = false

        if columnsPerScreen <= 0 {
            columnsPerScreen = 1
        }

        if rowsPerScreen <= 0 {
            rowsPerScreen = 1
        }

        let originalColumnsPerScreen = columnsPerScreen
        let originalRowsPerScreen = rowsPerScreen

        var placements: [Placement] = []
        var i: Int32 = 0
        while Int(i) < list.count {
            if monitorIndex == numberOfMonitors - 1 && stretchesWindows && !lastScreen {
                var remaining = Int32(truncatingIfNeeded: list.count - Int(i))

                if remaining < 0 {
                    remaining = 0
                }

                lastScreen = true

                while rowsPerScreen * columnsPerScreen > remaining && rowsPerScreen >= 0 && columnsPerScreen >= 0 {
                    rowsPerScreen -= 1

                    if rowsPerScreen * columnsPerScreen > remaining {
                        columnsPerScreen -= 1
                    }
                }

                if columnsPerScreen > 0 {
                    while rowsPerScreen * columnsPerScreen < remaining {
                        rowsPerScreen += 1
                    }
                }
            }

            if columnsPerScreen == 0 {
                columnsPerScreen = 1
            }

            let posInScreen = i % (originalColumnsPerScreen * originalRowsPerScreen)
            let row = posInScreen / columnsPerScreen
            let column = posInScreen % columnsPerScreen

            var frame = screens[Int(monitorIndex)].gridRect

            // Whole points per cell.
            var temp = Int32(frame.size.width / CGFloat(columnsPerScreen))
            frame.size.width = CGFloat(temp * columnsPerScreen)

            temp = Int32(frame.size.height / CGFloat(rowsPerScreen))
            frame.size.height = CGFloat(temp * rowsPerScreen)

            let visibleFrame = frame
            frame.size.width /= CGFloat(columnsPerScreen)
            frame.origin.x += frame.size.width * CGFloat(column)

            frame.size.height /= CGFloat(rowsPerScreen)
            frame.origin.y += frame.size.height * CGFloat((rowsPerScreen - 1) - row)

            if lastScreen && Int(i + columnsPerScreen) >= list.count && stretchesWindows {
                frame.size.height += frame.origin.y - visibleFrame.origin.y
                frame.origin.y = visibleFrame.origin.y
            }

            placements.append(Placement(viewer: list[Int(i)], frame: frame))
            i += 1
        }
        return placements
    }

    /// A hidden viewer takes the place `position` when the viewer there is
    /// not on the screen `monitorIndex`.
    static func insertHidden(_ hidden: inout [Int], into order: inout [Int], at position: Int, unlessOn monitorIndex: Int, _ viewers: [Viewer]) {
        guard let first = hidden.first, viewers[order[position]].tilingScreenIndex != monitorIndex else { return }
        order.removeAll { $0 == first }
        order.insert(first, at: position)
        hidden.removeAll { $0 == first }
    }

    /// Two viewers show the same study: both have one, and it is the same.
    static func sameStudy(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second else { return false }
        return first == second
    }

    /// The comparison of two study dates; a missing date compares as equal
    /// to any, as the comparison of the dates' objects answered.
    static func compare(_ first: Date?, _ second: Date?) -> ComparisonResult {
        guard let first, let second else { return .orderedSame }
        return first.compare(second)
    }

    /// A stable merge sort that splits at the middle and takes the left one
    /// of two equal elements: with a comparison where a missing date equals
    /// any, it gives the order the sort of an Objective-C array gave.
    public static func mergeSorted(_ list: [Int], by comparison: (Int, Int) -> ComparisonResult) -> [Int] {
        if list.count <= 1 { return list }
        let middle = list.count / 2
        let left = mergeSorted(Array(list[..<middle]), by: comparison)
        let right = mergeSorted(Array(list[middle...]), by: comparison)
        var merged: [Int] = []
        merged.reserveCapacity(list.count)
        var l = 0, r = 0
        while l < left.count && r < right.count {
            if comparison(left[l], right[r]) != .orderedDescending {
                merged.append(left[l]); l += 1
            } else {
                merged.append(right[r]); r += 1
            }
        }
        return merged + left[l...] + right[r...]
    }
}
