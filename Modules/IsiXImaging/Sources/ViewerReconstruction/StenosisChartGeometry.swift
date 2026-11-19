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

extension Stenosis {
    /// Where the chart of the area along the stretch is drawn within its view.
    ///
    /// The plot leaves margins for the axis labels. A view too small for them
    /// keeps a plot all the same: the margins give way first, and the labels
    /// go with them. Insetting a rectangle by more than it has gives the null
    /// rectangle, whose origin is infinite, and a path moved to an infinite
    /// point has no current point for the line that follows: nothing here
    /// hands out a point that is not finite.
    public struct ChartGeometry: Equatable, Sendable {
        /// The margins the axis labels take: the largest area and the zero on
        /// the left, the stretch's length below.
        public static let margins = (left: CGFloat(44), right: CGFloat(28), bottom: CGFloat(20), top: CGFloat(16))
        /// What the plot keeps of a view smaller than the margins ask for.
        public static let smallestPlot = CGSize(width: 24, height: 12)

        /// The rectangle the curve is drawn in, of positive width and height.
        public let plot: CGRect
        /// Whether the margins are whole, so the axis labels fit in them.
        public let showsLabels: Bool
        /// The length of the stretch, in millimetres, along the plot's width.
        public let stretch: Double
        /// The area, in mm², at the plot's top.
        public let maximumArea: Double

        /// Nil for a view with no width or height to draw in.
        public init?(bounds: CGRect, stretch: Double, maximumArea: Double) {
            guard !bounds.isNull, !bounds.isInfinite, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.minX.isFinite, bounds.minY.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
            let margins = Self.margins
            // What a dimension has for its two margins, the smallest plot
            // being served first.
            func room(_ length: CGFloat, _ wanted: CGFloat, _ least: CGFloat) -> CGFloat {
                min(wanted, max(length - least, 0))
            }
            let wide = margins.left + margins.right, high = margins.bottom + margins.top
            let across = room(bounds.width, wide, Self.smallestPlot.width)
            let up = room(bounds.height, high, Self.smallestPlot.height)
            plot = CGRect(x: bounds.minX + across * margins.left / wide, y: bounds.minY + up * margins.bottom / high,
                          width: bounds.width - across, height: bounds.height - up)
            showsLabels = across == wide && up == high
            self.stretch = stretch.isFinite && stretch > 0 ? stretch : 0.001
            self.maximumArea = maximumArea.isFinite && maximumArea > 0 ? maximumArea : 1
        }

        /// The abscissa of a position along the stretch, nil when it is not a number.
        public func x(_ position: Double) -> CGFloat? {
            let x = plot.minX + CGFloat(position / stretch) * plot.width
            return x.isFinite ? x : nil
        }

        /// The ordinate of an area, nil when it is not a number.
        public func y(_ area: Double) -> CGFloat? {
            let y = plot.minY + CGFloat(area / maximumArea) * plot.height
            return y.isFinite ? y : nil
        }

        /// The point of an area at a position, nil when either is not a number.
        public func point(position: Double, area: Double) -> CGPoint? {
            guard let x = x(position), let y = y(area) else { return nil }
            return CGPoint(x: x, y: y)
        }

        /// The position along the stretch under an abscissa of the view,
        /// within the stretch.
        public func position(atX x: CGFloat) -> Double {
            let position = Double((x - plot.minX) / plot.width) * stretch
            return position.isFinite ? min(max(position, 0), stretch) : 0
        }
    }

    /// How the strip under the stretched view shares its width between the
    /// chart, the numbers and the controls.
    ///
    /// The chart is what shows where the narrowing is, so it is served first:
    /// in a strip too narrow for the three, the numbers narrow down (their
    /// text wraps and scrolls), then the controls (they scroll sideways), and
    /// the chart keeps its least width, or half of a strip narrower than twice
    /// that.
    public struct StripLayout: Equatable, Sendable {
        public static let leastChart: CGFloat = 200
        public static let leastNumbers: CGFloat = 150

        public let chart: CGFloat
        public let numbers: CGFloat
        public let controls: CGFloat

        /// - Parameters:
        ///   - width: the strip's width.
        ///   - numbers: the width the numbers take when there is room.
        ///   - controls: the width the controls need in the language shown.
        public init(width: CGFloat, numbers wantedNumbers: CGFloat, controls wantedControls: CGFloat) {
            let width = width.isFinite ? max(width, 0) : 0
            let wantedNumbers = max(wantedNumbers, 0), wantedControls = max(wantedControls, 0)
            let chart = min(Self.leastChart, (width / 2).rounded(.up))
            let spare = width - chart
            let numbers = min(wantedNumbers, max(spare - wantedControls, min(Self.leastNumbers, (spare / 2).rounded(.down))))
            let controls = min(wantedControls, spare - numbers)
            self.numbers = numbers
            self.controls = controls
            self.chart = width - numbers - controls
        }
    }
}
