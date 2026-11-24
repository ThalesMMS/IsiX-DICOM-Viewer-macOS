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
import CoreData
import IsiXImaging

/// The strip above the 2D viewport. It is the `slider` outlet of
/// `ViewerController`, so it keeps the `NSSlider` contract the controller and
/// `DCMView.sliderAction:` use: `intValue` is the image index (already
/// inverted by the controller when the data is flipped), `maxValue` is the last
/// index and `numberOfTickMarks` is the image count.
///
/// On top of that contract it remembers which indices were displayed since the
/// series was loaded, and draws them as a filled band, with the current image
/// as a marker. Loading a series resets the band because the controller sets
/// the tick count on every load.
@objc(HorosImageNavigationSlider)
public final class ImageNavigationSlider: HorosCellSlider {
    private var visited = IndexSet()

    @objc public var visitedIndexes: IndexSet { visited }

    @objc public var imageCount: Int {
        if numberOfTickMarks > 0 { return numberOfTickMarks }
        return max(1, Int((maxValue - minValue).rounded()) + 1)
    }

    /// The images the current one stands for: more than one while a thick
    /// slab (MIP, MinIP, mean or volume rendering) folds those around it
    /// into it, and the marker then covers them all.
    @objc public var slabImageCount: Int = 1 {
        didSet { if slabImageCount != oldValue { needsDisplay = true } }
    }

    /// The key images of the frame shown, as the view counts them: each has
    /// a mark on the strip, so they are found without going through the
    /// series. The viewer gives them when `keyImagesFrame` is not the frame
    /// it shows and when it marks or unmarks an image; a new series starts
    /// without any.
    @objc public var keyImages = IndexSet() {
        didSet { if keyImages != oldValue { needsDisplay = true } }
    }

    /// The movie frame `keyImages` were read for; -1 when they have to be
    /// read again: a series just loaded, or the database changed (a key
    /// object imported, a mark made in another window or on a shared
    /// database), and then the viewer reads them at the next image it shows.
    @objc public var keyImagesFrame = -1

    /// Whether the view shows the series from its last image: the strip
    /// counts the images as the user does, and the key images' marks follow.
    @objc public var flippedData = false {
        didSet { if flippedData != oldValue, !keyImages.isEmpty { needsDisplay = true } }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: .NSManagedObjectContextObjectsDidChange, object: nil)
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(databaseChanged(_:)),
                                                   name: .NSManagedObjectContextObjectsDidChange, object: nil)
        }
    }

    /// Told on the thread of the context that changed.
    @objc private nonisolated func databaseChanged(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.keyImagesFrame = -1 }
        }
    }

    @objc public func resetVisitedImages() {
        visited.removeAll()
        needsDisplay = true
    }

    public override var numberOfTickMarks: Int {
        get { super.numberOfTickMarks }
        set {
            super.numberOfTickMarks = newValue
            keyImages = IndexSet()
            keyImagesFrame = -1
            resetVisitedImages()
        }
    }

    public override func valueDidChange() {
        let index = Int(doubleValue.rounded())
        if index >= 0, index < imageCount {
            visited.insert(index)
        }
        needsDisplay = true
    }

    // MARK: - Geometry

    private var barInset: CGFloat { 1 }
    private var barHeight: CGFloat { 6 }

    private var barRect: NSRect {
        NSRect(x: bounds.minX + barInset,
               y: bounds.midY - barHeight / 2,
               width: max(0, bounds.width - 2 * barInset),
               height: barHeight)
    }

    private func x(forIndex index: Int) -> CGFloat {
        let bar = barRect
        return bar.minX + bar.width * CGFloat(index) / CGFloat(imageCount)
    }

    /// The horizontal extent of the current image's marker in `bar`: the
    /// images of the slab at `index` (ThickSlabSpan: centred on it, and kept
    /// inside the series at its ends, so as wide on every image), or the
    /// image alone; never narrower than `minimumWidth`, centred then. The
    /// strip counts the images as the user does, and there a slab goes
    /// forwards, flipped data or not.
    static func markerSpan(index: Int, slab: Int, count: Int, bar: NSRect,
                           minimumWidth: CGFloat = 3) -> ClosedRange<CGFloat> {
        guard count > 1 else { return (bar.midX - minimumWidth / 2)...(bar.midX + minimumWidth / 2) }
        func x(_ i: Int) -> CGFloat { bar.minX + bar.width * CGFloat(i) / CGFloat(count) }
        let images = ThickSlabSpan(images: slab, at: min(max(index, 0), count - 1), of: count, towardsStart: false)
        let start = x(images.first), end = x(images.last + 1)
        guard end - start < minimumWidth else { return start...end }
        let center = (start + end) / 2
        return (center - minimumWidth / 2)...(center + minimumWidth / 2)
    }

    public override func value(at point: NSPoint) -> Double {
        let bar = barRect
        guard bar.width > 0 else { return minValue }
        let t = min(1, max(0, (point.x - bar.minX) / bar.width))
        let index = min(imageCount - 1, Int(t * CGFloat(imageCount)))
        return snappedValue(minValue + Double(index))
    }

    // MARK: - Drawing

    /// The band is neutral: blue and orange say, in the list of series, which
    /// study a series is of, and the band says nothing of the study. A dark
    /// grey for the images not shown yet and a light one for those shown, the
    /// same in a light and in a dark window.
    static let unseenColor = NSColor(calibratedWhite: 0.22, alpha: 1)
    static let seenColor = NSColor(calibratedWhite: 0.74, alpha: 1)

    /// The mark of a key image: yellow, which neither the band nor the
    /// marker of the image shown uses, taller than the band and edged in
    /// black so that it shows on the light part of the band as on the dark.
    static let keyImageColor = NSColor(calibratedRed: 1, green: 0.8, blue: 0, alpha: 1)
    static let keyImageMarkWidth: CGFloat = 2
    static let keyImageMarkHeight: CGFloat = 12

    public override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        let bar = barRect
        let radius = bar.height / 2

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        Self.unseenColor.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        if imageCount > 1 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).addClip()
            Self.seenColor.withAlphaComponent(alpha).setFill()
            for range in visited.rangeView {
                let start = x(forIndex: range.lowerBound)
                let end = x(forIndex: range.upperBound)
                NSRect(x: start, y: bar.minY, width: max(1, end - start), height: bar.height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // The key images, under the marker of the image shown: on a key
        // image the marker is in front, and the mark shows above and below it.
        if !keyImages.isEmpty {
            let marks = KeyImageNavigation.stripMarks(of: keyImages, count: imageCount, flipped: flippedData,
                                                      from: Double(bar.minX), width: Double(bar.width),
                                                      spacing: Double(Self.keyImageMarkWidth + 2))
            let height = Self.keyImageMarkHeight, width = Self.keyImageMarkWidth
            for mark in marks {
                let rect = NSRect(x: CGFloat(mark) - width / 2, y: bounds.midY - height / 2, width: width, height: height)
                NSColor.black.withAlphaComponent(0.6 * alpha).setFill()
                rect.insetBy(dx: -1, dy: -1).fill()
                Self.keyImageColor.withAlphaComponent(alpha).setFill()
                rect.fill()
            }
        }

        let span = Self.markerSpan(index: Int(doubleValue.rounded()), slab: slabImageCount,
                                   count: imageCount, bar: bar)
        let marker = NSRect(x: span.lowerBound,
                            y: bounds.midY - 6,
                            width: span.upperBound - span.lowerBound,
                            height: 12)
        NSGraphicsContext.saveGraphicsState()
        // Within the band, as the band of the images shown is.
        if imageCount > 1 {
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).addClip()
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3 * alpha)
        shadow.shadowBlurRadius = 1.5
        shadow.set()
        NSColor.systemRed.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: marker, xRadius: 1.5, yRadius: 1.5).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
