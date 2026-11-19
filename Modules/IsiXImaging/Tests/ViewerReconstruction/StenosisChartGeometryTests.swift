//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
@testable import IsiXImaging

@Suite struct StenosisChartGeometryTests {

    private func geometry(_ width: CGFloat, _ height: CGFloat, stretch: Double = 30, maximum: Double = 28) -> Stenosis.ChartGeometry? {
        Stenosis.ChartGeometry(bounds: CGRect(x: 0, y: 0, width: width, height: height), stretch: stretch, maximumArea: maximum)
    }

    @Test func aViewWithRoomKeepsTheMarginsOfTheAxisLabels() throws {
        let chart = try #require(geometry(400, 120))
        #expect(chart.plot == CGRect(x: 44, y: 20, width: 328, height: 84))
        #expect(chart.showsLabels)
        #expect(chart.point(position: 0, area: 0) == CGPoint(x: 44, y: 20))
        #expect(chart.point(position: 30, area: 28) == CGPoint(x: 372, y: 104))
        #expect(chart.position(atX: 208) == 15)
    }

    /// The sizes that gave the null rectangle, whose origin is infinite: lower
    /// than 36 points, narrower than 72.
    @Test(arguments: [CGSize(width: 400, height: 30), CGSize(width: 60, height: 120), CGSize(width: 71, height: 35),
                      CGSize(width: 30, height: 10), CGSize(width: 1, height: 1), CGSize(width: 0.5, height: 400)])
    func aViewTooSmallForTheMarginsKeepsAPlotWithinIt(size: CGSize) throws {
        let chart = try #require(geometry(size.width, size.height))
        let bounds = CGRect(origin: .zero, size: size)
        #expect(!chart.plot.isNull && !chart.plot.isInfinite)
        #expect(chart.plot.width > 0 && chart.plot.height > 0)
        #expect(bounds.contains(chart.plot))
        #expect(!chart.showsLabels)
        for (position, area) in [(0.0, 0.0), (7.5, 12.0), (30.0, 28.0)] {
            let point = try #require(chart.point(position: position, area: area))
            #expect(point.x.isFinite && point.y.isFinite)
            #expect(point.x >= chart.plot.minX && point.x <= chart.plot.maxX && point.y >= chart.plot.minY && point.y <= chart.plot.maxY)
        }
    }

    @Test func theSmallestPlotIsServedBeforeTheMargins() throws {
        // 72 points across are the margins alone: the plot takes its 24 first.
        let narrow = try #require(geometry(72, 120))
        #expect(narrow.plot.width == 24)
        #expect(narrow.plot.height == 84)
        let low = try #require(geometry(400, 36))
        #expect(low.plot.height == 12)
        #expect(low.plot.width == 328)
    }

    @Test func aViewWithNothingToDrawInHasNoGeometry() {
        #expect(geometry(0, 0) == nil)
        #expect(geometry(0, 120) == nil)
        #expect(geometry(400, 0) == nil)
        #expect(Stenosis.ChartGeometry(bounds: .null, stretch: 30, maximumArea: 28) == nil)
        #expect(Stenosis.ChartGeometry(bounds: .infinite, stretch: 30, maximumArea: 28) == nil)
        #expect(geometry(.nan, 120) == nil)
    }

    @Test func noPointThatIsNotANumberLeavesTheGeometry() throws {
        let chart = try #require(geometry(400, 120))
        #expect(chart.point(position: .nan, area: 3) == nil)
        #expect(chart.point(position: 3, area: .infinity) == nil)
        #expect(chart.x(-.infinity) == nil)
        #expect(chart.position(atX: .nan) == 0)
        #expect(chart.position(atX: -500) == 0)
        #expect(chart.position(atX: 5000) == 30)
        // A stretch or a largest area that is no measure does not divide by zero.
        let empty = try #require(geometry(400, 120, stretch: 0, maximum: .nan))
        #expect(empty.stretch == 0.001 && empty.maximumArea == 1)
        #expect(empty.point(position: 0, area: 0) == CGPoint(x: 44, y: 20))
    }

    // MARK: The strip's widths

    @Test func aStripWithRoomGivesTheNumbersAndTheControlsWhatTheyAsk() {
        let layout = Stenosis.StripLayout(width: 900, numbers: 300, controls: 283)
        #expect(layout.numbers == 300 && layout.controls == 283 && layout.chart == 317)
        // The chart at its least: nothing is narrowed yet.
        let tight = Stenosis.StripLayout(width: 783, numbers: 300, controls: 283)
        #expect(tight.numbers == 300 && tight.controls == 283 && tight.chart == 200)
    }

    @Test func theNumbersNarrowBeforeTheChartAndTheControlsAfterThem() {
        // 655 points gave the chart 72 with a panel of 583, and less gave it nothing.
        let narrow = Stenosis.StripLayout(width: 640, numbers: 300, controls: 283)
        #expect(narrow.chart == 200 && narrow.numbers == 157 && narrow.controls == 283)
        let narrower = Stenosis.StripLayout(width: 500, numbers: 300, controls: 283)
        #expect(narrower.chart == 200 && narrower.numbers == 150 && narrower.controls == 150)
        let half = Stenosis.StripLayout(width: 300, numbers: 300, controls: 283)
        #expect(half.chart == 150 && half.numbers == 75 && half.controls == 75)
    }

    /// Whatever the language makes of the controls' width, the chart keeps its
    /// least width, or half of a strip narrower than twice that.
    @Test(arguments: [200.0, 283, 340, 420, 600])
    func theChartKeepsItsLeastWidthWhateverTheControlsNeed(needed: Double) {
        let controls = CGFloat(needed)
        for step in 0...228 {
            let width = CGFloat(step * 7)
            let layout = Stenosis.StripLayout(width: width, numbers: 300, controls: controls)
            #expect(layout.chart >= min(Stenosis.StripLayout.leastChart, width / 2))
            #expect(layout.numbers >= 0 && layout.controls >= 0)
            #expect(layout.numbers <= 300 && layout.controls <= controls)
            #expect(layout.chart + layout.numbers + layout.controls == width)
        }
    }

    @Test func aStripWithNoWidthSharesNothing() {
        for width in [0, -40, CGFloat.nan, .infinity] {
            let layout = Stenosis.StripLayout(width: width, numbers: 300, controls: 283)
            #expect(layout.chart == 0 && layout.numbers == 0 && layout.controls == 0)
        }
    }
}
