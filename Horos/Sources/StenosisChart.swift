//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXImaging

/// What the chart of the Stenosis tool's strip shows of a measured stretch.
struct StenosisChartContent {
    struct Section {
        /// From the start of the stretch, in mm.
        var position: Double
        /// In mm².
        var area: Double
        /// Whether a lumen was found, so the section is on the line.
        var isValid: Bool
        /// Whether part of the lumen was erased by hand.
        var corrected = false
        /// Whether the whole lumen was taken, by the calcium or by hand.
        var lumenTaken = false
    }

    var sections: [Section]
    /// The length of the stretch, in mm.
    var stretchLength: Double
    /// The stretches the reference was taken from, in mm from the start.
    var references: [ClosedRange<Double>] = []
    /// The narrowest section.
    var minimum: (position: Double, area: Double)?
    /// Where the section of the middle transverse view is, in mm from the start.
    var current: Double?
}

/// Whoever measured the stretch the chart shows.
@MainActor
protocol StenosisChartSource: AnyObject {
    /// Nil while no stretch was measured.
    var chartContent: StenosisChartContent? { get }
    func showSection(atStretchPosition mm: Double)
}

/// The area of the lumen along the stretch, with the reference shaded, the
/// narrowest section marked, the sections corrected by hand marked with a
/// square, those whose whole lumen was taken with a cross on the axis, and
/// the middle transverse section's position. A click shows that section in
/// the middle transverse view.
///
/// The view is as wide and as high as the strip leaves it, down to nothing:
/// where and whether anything is drawn comes from `Stenosis.ChartGeometry`,
/// which hands out finite points only. A path that is moved or drawn to a
/// point that is not finite raises, and an exception raised while a view
/// draws ends the application.
@MainActor
final class StenosisChart: NSView {
    private weak var source: StenosisChartSource?

    init(source: StenosisChartSource) {
        self.source = source
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    private func geometry(of content: StenosisChartContent) -> Stenosis.ChartGeometry? {
        let largest = content.sections.map(\.area).filter(\.isFinite).max() ?? 1
        return Stenosis.ChartGeometry(bounds: bounds, stretch: content.stretchLength, maximumArea: max(largest, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let content = source?.chartContent, !content.sections.isEmpty, let chart = geometry(of: content) else { return }
        let plot = chart.plot

        NSColor.systemTeal.withAlphaComponent(0.18).setFill()
        for reference in content.references {
            guard let from = chart.x(reference.lowerBound), let to = chart.x(reference.upperBound) else { continue }
            NSRect(x: from, y: plot.minY, width: to - from, height: plot.height).fill()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath.stroke(plot)
        if chart.showsLabels {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
            ("\(Int(chart.maximumArea.rounded())) mm²" as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: plot.maxY - 10), withAttributes: attributes)
            ("0" as NSString).draw(at: NSPoint(x: bounds.minX + 2, y: plot.minY - 4), withAttributes: attributes)
            (String(format: "%.0f mm", chart.stretch) as NSString).draw(at: NSPoint(x: plot.maxX - 30, y: bounds.minY + 2), withAttributes: attributes)
        }

        let line = NSBezierPath()
        for section in content.sections where section.isValid {
            guard let point = chart.point(position: section.position, area: section.area) else { continue }
            if line.isEmpty { line.move(to: point) } else { line.line(to: point) }
        }
        line.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        line.stroke()

        // The sections whose lumen was corrected by hand: a square each.
        NSColor.systemOrange.setFill()
        for section in content.sections where section.corrected {
            guard let point = chart.point(position: section.position, area: section.area) else { continue }
            NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5).fill()
        }
        // The sections whose whole lumen was taken, left out of the line and
        // of the numbers: a cross each, on the axis.
        let taken = NSBezierPath()
        for section in content.sections where section.lumenTaken {
            guard let x = chart.x(section.position) else { continue }
            taken.move(to: NSPoint(x: x - 3, y: plot.minY - 3)); taken.line(to: NSPoint(x: x + 3, y: plot.minY + 3))
            taken.move(to: NSPoint(x: x - 3, y: plot.minY + 3)); taken.line(to: NSPoint(x: x + 3, y: plot.minY - 3))
        }
        taken.lineWidth = 1.5
        NSColor.systemRed.setStroke()
        taken.stroke()
        if let minimum = content.minimum, let point = chart.point(position: minimum.position, area: minimum.area) {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)).fill()
        }
        if let current = content.current, let x = chart.x(current) {
            NSColor.systemYellow.setStroke()
            let marker = NSBezierPath()
            marker.move(to: NSPoint(x: x, y: plot.minY)); marker.line(to: NSPoint(x: x, y: plot.maxY))
            marker.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let source, let content = source.chartContent, content.stretchLength > 0, let chart = geometry(of: content) else { return }
        let point = convert(event.locationInWindow, from: nil)
        source.showSection(atStretchPosition: chart.position(atX: point.x))
        needsDisplay = true
    }
}
