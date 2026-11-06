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

/// Draws the curves: mean as a line with points, minimum and maximum as a
/// band, time across, value up.
final class CurveView: NSView {
    var curves: [EnhancementCurve] = [] {
        didSet { needsDisplay = true }
    }

    private static let colours: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal]

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let samples = curves.flatMap(\.samples)
        guard let firstTime = samples.map(\.time).min(), let lastTime = samples.map(\.time).max(),
              let low = samples.map(\.minimum).min(), let high = samples.map(\.maximum).max() else { return }
        let plot = bounds.insetBy(dx: 48, dy: 28)
        let timeSpan = max(lastTime - firstTime, 1e-9)
        let valueSpan = max(high - low, 1e-9)
        func point(_ time: Double, _ value: Double) -> NSPoint {
            NSPoint(x: plot.minX + plot.width * (time - firstTime) / timeSpan,
                    y: plot.minY + plot.height * (value - low) / valueSpan)
        }
        NSColor.secondaryLabelColor.setStroke()
        let axes = NSBezierPath()
        axes.move(to: NSPoint(x: plot.minX, y: plot.maxY))
        axes.line(to: NSPoint(x: plot.minX, y: plot.minY))
        axes.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        axes.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        String(format: "%.1f", high).draw(at: NSPoint(x: 4, y: plot.maxY - 6), withAttributes: attributes)
        String(format: "%.1f", low).draw(at: NSPoint(x: 4, y: plot.minY - 6), withAttributes: attributes)
        String(format: "%.1f s", lastTime).draw(at: NSPoint(x: plot.maxX - 30, y: 6), withAttributes: attributes)
        for (index, curve) in curves.enumerated() {
            let colour = Self.colours[index % Self.colours.count]
            let band = NSBezierPath()
            for (i, sample) in curve.samples.enumerated() {
                i == 0 ? band.move(to: point(sample.time, sample.maximum)) : band.line(to: point(sample.time, sample.maximum))
            }
            for sample in curve.samples.reversed() { band.line(to: point(sample.time, sample.minimum)) }
            band.close()
            colour.withAlphaComponent(0.15).setFill()
            band.fill()
            let line = NSBezierPath()
            line.lineWidth = 2
            for (i, sample) in curve.samples.enumerated() {
                i == 0 ? line.move(to: point(sample.time, sample.mean)) : line.line(to: point(sample.time, sample.mean))
            }
            colour.setStroke()
            line.stroke()
            curve.name.draw(at: NSPoint(x: plot.maxX - 120, y: plot.maxY - 14 * CGFloat(index + 1)),
                            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: colour])
        }
    }
}

/// The plugin's window for one viewer's curves. The plugin owns it and
/// closes it when the viewer closes.
@MainActor
final class CurveWindowController: NSWindowController {
    let curveView = CurveView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))

    init(title: String) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = curveView
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }
}
