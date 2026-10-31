//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
@testable import IsiXImaging

@Suite struct ViewerTilingLayoutTests {

    typealias Layout = ViewerTilingLayout

    static let wide = Layout.Screen(visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                                    gridRect: CGRect(x: 0, y: 0, width: 1920, height: 1000),
                                    rowRect: CGRect(x: 0, y: 0, width: 1920, height: 1055))
    static let right = Layout.Screen(visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1055),
                                     gridRect: CGRect(x: 1920, y: 0, width: 1920, height: 1000),
                                     rowRect: CGRect(x: 1920, y: 0, width: 1920, height: 1055))

    static func options(rows: Int32 = 0, columns: Int32 = 0, hangingProtocol: Bool = false, keepStudies: Bool = false,
                        byDate: Bool = false) -> Layout.Options {
        Layout.Options(rows: rows, columns: columns, hasHangingProtocol: hangingProtocol, keepsStudiesOnSameScreen: keepStudies,
                       stretchesWindows: true, ordersByStudyDate: byDate, reversesStudyDateOrder: false)
    }

    /// A visible viewer whose window sits at `x`, `y` on the first screen.
    static func viewer(_ x: CGFloat, _ y: CGFloat, screen: Int = 0, study: String? = "1.2.3", date: Date? = nil,
                       visible: Bool = true, key: Bool = false) -> Layout.Viewer {
        Layout.Viewer(frame: CGRect(x: x, y: y, width: 400, height: 300), isVisible: visible, isKey: key,
                      orderedScreenIndex: screen, screenVisibleOriginY: 0, tilingScreenIndex: screen,
                      studyInstanceUID: study, studyDate: date)
    }

    @Test func screensFromLowestLeftmost() {
        let frames = [CGRect(x: 0, y: 0, width: 1512, height: 944), CGRect(x: 1512, y: 0, width: 2560, height: 1415),
                      CGRect(x: -1920, y: 0, width: 1920, height: 1080)]
        #expect(Layout.orderedScreens(visibleFrames: frames) == [2, 0, 1])
        // A frame the comparison never picks keeps its place after the others.
        let far = [CGRect(x: 2_000_000, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: 10),
                   CGRect(x: CGFloat.nan, y: CGFloat.nan, width: 1, height: 1)]
        #expect(Layout.orderedScreens(visibleFrames: far) == [1, 0, 2])
        #expect(Layout.orderedScreens(visibleFrames: []) == [])
    }

    @Test func fourViewersMakeTwoRowsInReadingOrder() {
        var layout = Layout()
        // Given bottom-right first: the order is by row from the top, then by centre.
        let viewers = [Self.viewer(900, 0), Self.viewer(0, 600), Self.viewer(0, 0), Self.viewer(900, 600)]
        let result = layout.arrange(viewers, on: [Self.wide], request: nil, options: Self.options())
        #expect(result.order == [1, 3, 2, 0])
        #expect(result.placements == [
            .init(viewer: 1, frame: CGRect(x: 0, y: 500, width: 960, height: 500)),
            .init(viewer: 3, frame: CGRect(x: 960, y: 500, width: 960, height: 500)),
            .init(viewer: 2, frame: CGRect(x: 0, y: 0, width: 960, height: 500)),
            .init(viewer: 0, frame: CGRect(x: 960, y: 0, width: 960, height: 500)),
        ])
        #expect(layout.lastRows == 2 && layout.lastColumns == 2 && layout.lastCount == 4)
        #expect(layout.lastRowsColumns(viewerScreens: 1) == "22")
    }

    @Test func threeViewersMakeOneRow() {
        var layout = Layout()
        let viewers = [Self.viewer(0, 600), Self.viewer(900, 600), Self.viewer(0, 0)]
        let result = layout.arrange(viewers, on: [Self.wide], request: nil, options: Self.options())
        // A wide screen grows columns before rows: one row of three, in the row area.
        #expect(result.placements.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 640, height: 1055), CGRect(x: 640, y: 0, width: 640, height: 1055),
            CGRect(x: 1280, y: 0, width: 640, height: 1055),
        ])
        #expect(result.placements.map(\.viewer) == [0, 1, 2])
        #expect(layout.lastRows == 1 && layout.lastColumns == 3)
    }

    @Test func fiveViewersStretchTheLastRow() {
        var layout = Layout()
        let viewers = (0..<5).map { Self.viewer(CGFloat($0 % 3) * 600, $0 < 3 ? 600 : 0) }
        let result = layout.arrange(viewers, on: [Self.wide], request: nil, options: Self.options())
        // Three columns, two rows: the last window of the top row grows down
        // into the cell the bottom row leaves empty.
        #expect(result.placements.map(\.frame) == [
            CGRect(x: 0, y: 500, width: 640, height: 500), CGRect(x: 640, y: 500, width: 640, height: 500),
            CGRect(x: 1280, y: 0, width: 640, height: 1000),
            CGRect(x: 0, y: 0, width: 640, height: 500), CGRect(x: 640, y: 0, width: 640, height: 500),
        ])
    }

    @Test func oneViewerPerScreenTakesTheRowArea() {
        var layout = Layout()
        let viewers = [Self.viewer(2000, 0, screen: 1), Self.viewer(0, 0)]
        let result = layout.arrange(viewers, on: [Self.wide, Self.right], request: nil, options: Self.options())
        #expect(result.placements == [.init(viewer: 1, frame: Self.wide.rowRect), .init(viewer: 0, frame: Self.right.rowRect)])
        #expect(layout.lastRows == 1 && layout.lastColumns == 2)
        #expect(layout.lastRowsColumns(viewerScreens: 2) == "11")
    }

    @Test func fixedRowsFromTheMenu() {
        var layout = Layout()
        let viewers = [Self.viewer(0, 0), Self.viewer(500, 0), Self.viewer(1000, 0)]
        let result = layout.arrange(viewers, on: [Self.wide], request: Layout.Request(rows: 1), options: Self.options())
        // One row: three columns of the row area.
        #expect(result.placements.map(\.frame) == [
            CGRect(x: 0, y: 0, width: 640, height: 1055), CGRect(x: 640, y: 0, width: 640, height: 1055),
            CGRect(x: 1280, y: 0, width: 640, height: 1055),
        ])
    }

    @Test func hangingProtocolGrid() {
        var layout = Layout()
        let viewers = (0..<6).map { Self.viewer(CGFloat($0 % 3) * 600, $0 < 3 ? 600 : 0) }
        let options = Self.options(rows: 2, columns: 3, hangingProtocol: true)
        let result = layout.arrange(viewers, on: [Self.wide], request: nil, options: options)
        #expect(result.placements.count == 6)
        #expect(result.placements[0].frame == CGRect(x: 0, y: 500, width: 640, height: 500))
        #expect(result.placements[5].frame == CGRect(x: 1280, y: 0, width: 640, height: 500))
        #expect(layout.lastRows == 2 && layout.lastColumns == 3)
        // Without the protocol the same viewers make a grid of the screen's shape.
        var plain = Layout()
        _ = plain.arrange(viewers, on: [Self.wide], request: nil, options: Self.options(rows: 2, columns: 3))
        #expect(plain.lastRows == 2 && plain.lastColumns == 3)
        // A protocol for more viewers than are open falls back to the default.
        var fewer = Layout()
        _ = fewer.arrange(Array(viewers.prefix(2)), on: [Self.wide], request: nil, options: options)
        #expect(fewer.lastRows == 1 && fewer.lastColumns == 2)
    }

    @Test func anAddedViewerTakesTheNewColumn() {
        var layout = Layout()
        _ = layout.arrange([Self.viewer(0, 0), Self.viewer(960, 0)], on: [Self.wide], request: nil, options: Self.options())
        #expect(layout.lastColumns == 2 && layout.lastCount == 2)
        // A third viewer, hidden: it goes in the place of the new column, not last.
        let viewers = [Self.viewer(0, 0), Self.viewer(960, 0), Self.viewer(0, 0, visible: false)]
        let result = layout.arrange(viewers, on: [Self.wide], request: nil, options: Self.options())
        #expect(result.keyViewer == 2)
        #expect(result.order == [0, 1, 2])
        var three = Layout()
        _ = three.arrange([Self.viewer(0, 0), Self.viewer(600, 0), Self.viewer(1200, 0)], on: [Self.wide], request: nil,
                          options: Self.options())
        // Four viewers where three had three columns: the fourth goes at place 3 of a 2 × 2 grid already.
        let four = three.arrange([Self.viewer(0, 0), Self.viewer(600, 0), Self.viewer(1200, 0), Self.viewer(0, 0, visible: false)],
                                 on: [Self.wide], request: nil, options: Self.options())
        #expect(four.order == [0, 1, 2, 3])
        #expect(three.lastColumns == 2)
    }

    @Test func hiddenViewerOnTheOtherScreen() {
        var layout = Layout()
        // Two visible viewers on the first screen, a hidden one: one row over two screens.
        let viewers = [Self.viewer(0, 0), Self.viewer(960, 0), Self.viewer(0, 0, visible: false)]
        let result = layout.arrange(viewers, on: [Self.wide, Self.right], request: nil, options: Self.options())
        // The second place is on the first screen, the third on the second: the
        // hidden viewer is put where a viewer of another screen would go.
        #expect(result.placements.map(\.viewer) == [0, 1, 2])
        #expect(result.hidden.isEmpty)
        #expect(result.keyViewer == 2)
    }

    @Test func latestStudyFirst() {
        var layout = Layout()
        let old = Date(timeIntervalSinceReferenceDate: 0), new = Date(timeIntervalSinceReferenceDate: 1000)
        let viewers = [Self.viewer(0, 0, date: old), Self.viewer(960, 0, date: new), Self.viewer(0, 0, date: nil, visible: false)]
        let result = layout.arrange(viewers, on: [Self.wide], request: nil, options: Self.options(byDate: true))
        #expect(result.order == [1, 0, 2])
        #expect(result.hidden.isEmpty)
        // Equal dates keep their order.
        #expect(Layout.mergeSorted([3, 1, 2, 0]) { _, _ in .orderedSame } == [3, 1, 2, 0])
        #expect(Layout.compare(nil, old) == .orderedSame && Layout.compare(old, nil) == .orderedSame)
        #expect(Layout.compare(old, new) == .orderedAscending)
    }

    @Test func studiesStayOnTheirScreen() {
        var layout = Layout()
        let viewers = [Self.viewer(0, 0, study: "A"), Self.viewer(500, 0, study: "B"), Self.viewer(1000, 0, study: "A")]
        let result = layout.arrange(viewers, on: [Self.wide, Self.right], request: nil, options: Self.options(keepStudies: true))
        // Study A (viewers 0 and 2) on the first screen, B on the second.
        #expect(result.placements.map(\.viewer) == [0, 2, 1])
        #expect(result.placements[0].frame.minX < 1920 && result.placements[1].frame.minX < 1920)
        #expect(result.placements[2].frame.minX >= 1920)
        // A viewer without a study is a study of its own.
        #expect(!Layout.sameStudy(nil, nil) && Layout.sameStudy("A", "A") && !Layout.sameStudy("A", "B"))
    }

    @Test func noScreenNoPlacement() {
        var layout = Layout()
        let result = layout.arrange([Self.viewer(0, 0)], on: [], request: nil, options: Self.options())
        #expect(result.placements.isEmpty && result.fitsNoGrid)
        #expect(layout.lastCount == 0)
    }
}
