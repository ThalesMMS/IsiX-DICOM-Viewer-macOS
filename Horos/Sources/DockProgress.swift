//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// How far the activities are, in one number, on the application's Dock icon:
/// a clock-like sector that fills from twelve o'clock as they advance.
///
/// The number is the mean of the progress of every running task of the
/// activity list whose progress is known (a retrieve, a send, an import with a
/// total). Tasks that only say they are working are left out; without any
/// task of the first kind the icon is the plain one. The tile is redrawn when
/// the whole percentage changes, at most twice a second; the badge of
/// imported files is the Dock's own and stays over the drawing.
@objc(HorosDockProgress)
@MainActor
public final class DockProgress: NSObject {

    /// The mean of the values in 0…1; a negative value (a task whose progress
    /// is unknown) or one that is not a number is left out, and one above 1
    /// counts as 1. Nil when no value is left.
    public nonisolated static func aggregate(_ values: [Double]) -> Double? {
        let known = values.filter { $0.isFinite && $0 >= 0 }.map { min($0, 1) }
        guard !known.isEmpty else { return nil }
        return known.reduce(0, +) / Double(known.count)
    }

    /// The whole percentage drawn, 0…100, rounded down: the sector is full
    /// only when every task is done.
    public nonisolated static func percent(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded(.down))
    }

    @objc public static let shared = DockProgress()

    public static let interval: TimeInterval = 0.5

    private var timer: Timer?
    private var shownPercent: Int?
    private var shownIcon: NSImage?
    private let view = DockProgressView()

    /// Starts following the activity list; called once the application has
    /// finished launching.
    @objc public func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { DockProgress.shared.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc public func refresh() {
        let threads = (ThreadsManager.default()?.threads() as? [Thread]) ?? []
        let values = threads.filter { !$0.isFinished }.map { Double($0.subthreadsAwareProgress) }
        show(Self.aggregate(values).map(Self.percent))
    }

    /// Draws `percent` on the tile, or the plain icon for nil. The tile is
    /// redrawn only when what it shows changes.
    @objc(showPercent:)
    public func show(percent: NSNumber?) {
        show(percent?.intValue)
    }

    private func show(_ percent: Int?) {
        let tile = NSApp.dockTile
        let icon = NSApp.applicationIconImage
        guard percent != shownPercent || (percent != nil && icon !== shownIcon) else { return }
        shownPercent = percent
        shownIcon = icon
        if let percent {
            view.icon = icon
            view.fraction = Double(percent) / 100
            if tile.contentView !== view {
                tile.contentView = view
            }
        } else {
            tile.contentView = nil
        }
        tile.display()
    }

    /// What the tile shows now: the percentage, or nil for the plain icon.
    @objc public var displayedPercent: NSNumber? {
        NSApp.dockTile.contentView === view ? shownPercent.map { NSNumber(value: $0) } : nil
    }

    @objc public var tileView: NSView { view }
}

/// The application's icon with the progress sector over its lower right
/// corner, where the Dock's badge (upper right) does not reach.
final class DockProgressView: NSView {
    var icon: NSImage?
    var fraction: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        icon?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

        let side = bounds.width * 0.44
        let inset = bounds.width * 0.04
        let disc = NSRect(x: bounds.maxX - side - inset, y: bounds.minY + inset, width: side, height: side)
        let center = NSPoint(x: disc.midX, y: disc.midY)
        let radius = side / 2

        NSColor(white: 0.12, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: disc).fill()

        // From twelve o'clock, clockwise: AppKit's angles go counter-clockwise.
        let sector = NSBezierPath()
        sector.move(to: center)
        sector.appendArc(withCenter: center, radius: radius * 0.82, startAngle: 90,
                         endAngle: 90 - 360 * CGFloat(min(max(fraction, 0), 1)), clockwise: true)
        sector.close()
        NSColor.white.setFill()
        sector.fill()

        let ring = NSBezierPath(ovalIn: disc.insetBy(dx: radius * 0.06, dy: radius * 0.06))
        ring.lineWidth = max(1, radius * 0.08)
        NSColor.white.setStroke()
        ring.stroke()
    }
}
