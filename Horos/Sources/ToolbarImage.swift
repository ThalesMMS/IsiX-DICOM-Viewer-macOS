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

/// Toolbar artwork policy for every window that builds an `NSToolbar`.
///
/// Artwork ships at its authoring size: PDF icons declare a page-sized canvas
/// and several TIFF icons are not square. Fitting the longest edge into the
/// toolbar's logical size keeps oversized artwork from expanding the toolbar
/// while preserving the aspect ratio, and always works on a copy so the shared
/// instance returned by `+[NSImage imageNamed:]` is never resized app-wide.
@objc(HorosToolbarImage)
public final class ToolbarImage: NSObject {
    /// Toolbar items are laid out in points; anything larger grows the toolbar.
    @objc public static let defaultSize: CGFloat = 32

    /// Returns artwork whose longest edge is at most `size`, preserving the
    /// aspect ratio. Artwork already inside the box is returned unchanged, so
    /// repeated calls neither copy nor drift.
    @objc(imageFittingImage:size:)
    public static func fitting(_ image: NSImage?, size: CGFloat) -> NSImage? {
        guard let image, size > 0 else { return image }
        let source = image.size
        guard source.width > 0, source.height > 0 else { return image }
        let longest = max(source.width, source.height)
        guard longest > size, let copy = image.copy() as? NSImage else { return image }
        copy.size = NSSize(width: source.width * size / longest,
                           height: source.height * size / longest)
        return copy
    }

    /// Fits artwork into the default toolbar size.
    @objc(imageFittingImage:)
    public static func fitting(_ image: NSImage?) -> NSImage? {
        fitting(image, size: defaultSize)
    }

    /// Returns a copy whose longest edge is exactly `edge`, preserving the
    /// aspect ratio. Unlike `fitting`, this also enlarges, for callers that
    /// render artwork at a fixed size-mode dimension.
    @objc(imageScalingImage:toLongestEdge:)
    public static func scaled(_ image: NSImage?, toLongestEdge edge: CGFloat) -> NSImage? {
        guard let image, edge > 0 else { return image }
        let source = image.size
        guard source.width > 0, source.height > 0,
              let copy = image.copy() as? NSImage else { return image }
        let longest = max(source.width, source.height)
        copy.size = NSSize(width: source.width * edge / longest,
                           height: source.height * edge / longest)
        return copy
    }

    /// Named artwork fitted for a toolbar, without mutating the named instance.
    @objc(imageNamed:)
    public static func image(named name: String) -> NSImage? {
        fitting(NSImage(named: name), size: defaultSize)
    }

    /// Named artwork fitted into an explicit box.
    @objc(imageNamed:size:)
    public static func image(named name: String, size: CGFloat) -> NSImage? {
        fitting(NSImage(named: name), size: size)
    }

    /// Monochrome black artwork, drawn for the light toolbars of earlier macOS
    /// releases, sinks into a dark toolbar and into the dark Customize Toolbar
    /// palette. The returned image is fitted like `fitting(_:)` and draws the
    /// original artwork under a light appearance and the same silhouette in
    /// solid white under a dark one. AppKit runs the drawing handler again when
    /// the appearance it draws in changes, so the item follows the system mode.
    @objc(appearanceAdaptiveImage:)
    public static func appearanceAdaptive(_ image: NSImage?) -> NSImage? {
        guard let source = fitting(image, size: defaultSize) else { return nil }
        let size = source.size
        guard size.width > 0, size.height > 0 else { return source }
        let adaptive = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            if isDark(NSAppearance.currentDrawing()) {
                NSColor.white.setFill()
                rect.fill(using: .sourceAtop)
            }
            return true
        }
        adaptive.accessibilityDescription = source.accessibilityDescription
        return adaptive
    }

    /// Named monochrome artwork that stays visible in light and dark toolbars.
    @objc(appearanceAdaptiveImageNamed:)
    public static func appearanceAdaptive(named name: String) -> NSImage? {
        appearanceAdaptive(NSImage(named: name))
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                    .accessibilityHighContrastDarkAqua]).map {
            $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua
        } ?? false
    }

    /// Applies the policy to an item's current artwork.
    ///
    /// Toolbar items swap their image after insertion — play/stop, series sync,
    /// and plugin items rebuilt on demand — so this runs on the image in place
    /// rather than only at construction time. View-backed items own their own
    /// layout and are left alone.
    @objc(normalizeForItem:)
    public static func normalize(for item: NSToolbarItem?) {
        guard let item, item.view == nil, let source = item.image else { return }
        let fitted = fitting(source, size: defaultSize)
        if fitted !== source {
            item.image = fitted
        }
    }
}
