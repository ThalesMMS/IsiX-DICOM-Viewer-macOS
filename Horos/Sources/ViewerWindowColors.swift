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

/// One colour per 2D viewer window, so that the window and the thumbnails of
/// the series it shows can be matched at a glance, as the MPR's planes are.
///
/// A window takes the first colour no other open window has, the first time
/// it asks, and keeps it until it closes; the colours of the other windows do
/// not move. The palette leaves out the thumbnails' orange (this window's
/// series) and green (the fused series) and the yellow of key images and of
/// the opening flash. Past the palette's length, colours repeat.
@MainActor
@objc(HorosViewerWindowColors)
public final class ViewerWindowColors: NSObject {

    @objc public static let palette: [NSColor] = [
        NSColor(calibratedRed: 0.25, green: 0.55, blue: 1.00, alpha: 1), // blue
        NSColor(calibratedRed: 0.95, green: 0.30, blue: 0.80, alpha: 1), // magenta
        NSColor(calibratedRed: 0.10, green: 0.85, blue: 0.90, alpha: 1), // cyan
        NSColor(calibratedRed: 0.62, green: 0.42, blue: 1.00, alpha: 1), // violet
        NSColor(calibratedRed: 0.95, green: 0.22, blue: 0.22, alpha: 1), // red
        NSColor(calibratedRed: 0.85, green: 0.85, blue: 0.85, alpha: 1), // silver
    ]

    private static let slots = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()

    /// The lowest slot not in `taken`.
    @objc(firstFreeSlotAmong:)
    public nonisolated static func firstFreeSlot(among taken: IndexSet) -> Int {
        var slot = 0
        while taken.contains(slot) { slot += 1 }
        return slot
    }

    @objc(slotForViewer:)
    public static func slot(for viewer: AnyObject) -> Int {
        if let known = slots.object(forKey: viewer) { return known.intValue }
        var taken = IndexSet()
        for case let other as AnyObject in slots.keyEnumerator().allObjects {
            if let number = slots.object(forKey: other) { taken.insert(number.intValue) }
        }
        let slot = firstFreeSlot(among: taken)
        slots.setObject(NSNumber(value: slot), forKey: viewer)
        return slot
    }

    @objc(colorForViewer:)
    public static func color(for viewer: AnyObject) -> NSColor {
        palette[slot(for: viewer) % palette.count]
    }

    /// Frees the window's colour; the next window to open takes it.
    @objc(releaseViewer:)
    public static func release(_ viewer: AnyObject) {
        slots.removeObject(forKey: viewer)
    }

    /// The viewers in the order of their colours, so that a series shown in
    /// several windows takes the first window's colour everywhere.
    @objc(viewersInColorOrder:)
    public static func viewersInColorOrder(_ viewers: [AnyObject]) -> [AnyObject] {
        viewers.sorted { slot(for: $0) < slot(for: $1) }
    }
}
