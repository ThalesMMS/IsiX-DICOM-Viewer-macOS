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

/// One identity per displayed series, shared by every window showing it and
/// by its thumbnail.
///
/// A series takes the first free slot and keeps it until its last window
/// closes or changes series. The palette leaves out the thumbnails' orange (this window's
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

    private final class Identity: NSObject {
        let series: NSObject?
        let slot: Int

        init(series: NSObject?, slot: Int) {
            self.series = series
            self.slot = slot
        }
    }

    private static let slots = NSMapTable<AnyObject, Identity>.weakToStrongObjects()

    /// The lowest slot not in `taken`.
    @objc(firstFreeSlotAmong:)
    public nonisolated static func firstFreeSlot(among taken: IndexSet) -> Int {
        var slot = 0
        while taken.contains(slot) { slot += 1 }
        return slot
    }

    @objc(slotForViewer:)
    public static func slot(for viewer: AnyObject) -> Int {
        let series = (viewer as? ViewerController)?.currentSeries()
        if viewer is ViewerController, series == nil {
            slots.removeObject(forKey: viewer)
            return 0 // A window loading its first series does not reserve an identity.
        }
        if let known = slots.object(forKey: viewer), known.series == series { return known.slot }
        // A reused window no longer owns its previous series' slot. Other
        // windows showing that series keep their shared identity alive.
        slots.removeObject(forKey: viewer)
        var taken = IndexSet()
        for case let other as AnyObject in slots.keyEnumerator().allObjects {
            guard let identity = slots.object(forKey: other) else { continue }
            if let series, identity.series == series {
                slots.setObject(identity, forKey: viewer)
                return identity.slot
            }
            taken.insert(identity.slot)
        }
        let slot = firstFreeSlot(among: taken)
        slots.setObject(Identity(series: series, slot: slot), forKey: viewer)
        return slot
    }

    /// A human-readable identity using the same stable allocation as colours.
    @objc(numberForViewer:)
    public static func number(for viewer: AnyObject) -> Int {
        slot(for: viewer) + 1
    }

    /// The displayed series' colour, shared with its other windows.
    @discardableResult
    @objc(colorForViewer:)
    public static func color(for viewer: AnyObject) -> NSColor {
        palette[slot(for: viewer) % palette.count]
    }

    /// Releases this window's use of the identity; duplicates keep it reserved.
    @objc(releaseViewer:)
    public static func release(_ viewer: AnyObject) {
        slots.removeObject(forKey: viewer)
    }

    /// The viewers in identity order. Duplicate series have equal slots.
    @objc(viewersInColorOrder:)
    public static func viewersInColorOrder(_ viewers: [AnyObject]) -> [AnyObject] {
        viewers.sorted { slot(for: $0) < slot(for: $1) }
    }
}
