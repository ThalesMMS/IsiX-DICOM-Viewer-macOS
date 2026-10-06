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

/// Where the viewer's series list sits. The list is the strip of
/// series thumbnails beside the image; it can dock on any edge, and the choice
/// is a preference so it survives a relaunch.
@objc(HorosSeriesListPlacement)
public enum SeriesListPlacement: Int, Sendable {
    case left = 0
    case right
    case top
    case bottom

    /// Top and bottom lay the strip across the window, so the split view
    /// divides horizontally and the thumbnails run in one row.
    public var isHorizontalStrip: Bool { self == .top || self == .bottom }
    /// Left and top keep the dock before the image pane.
    public var docksFirst: Bool { self == .left || self == .top }

    static let names: [SeriesListPlacement: String] = [.left: "left", .right: "right", .top: "top", .bottom: "bottom"]
    public var name: String { SeriesListPlacement.names[self] ?? "left" }
}

/// The floating panel borrows the existing scroll view. Its dock stays in the
/// split view so moving the list never removes the image pane's sibling.
@MainActor
@objc(HorosSeriesListLayout)
public final class SeriesListLayout: NSObject {
    /// Posted when the placement changes, so open viewers re-place their list.
    @objc public static let placementDidChangeNotification = "HorosSeriesListPlacementDidChange"
    /// The preference the placement is stored under.
    @objc public static let placementDefaultsKey = "HorosSeriesListPlacement"

    @objc(placementNamed:) public static func placement(named name: String) -> SeriesListPlacement {
        SeriesListPlacement.names.first { $0.value == name.lowercased() }?.key ?? .left
    }

    @objc(nameOfPlacement:) public static func name(of placement: SeriesListPlacement) -> String {
        placement.name
    }

    /// The stored choice, defaulting to the historical left dock.
    @objc(storedPlacementIn:) public static func storedPlacement(in defaults: UserDefaults) -> SeriesListPlacement {
        placement(named: defaults.string(forKey: placementDefaultsKey) ?? "left")
    }

    @objc(storePlacement:in:) public static func store(_ placement: SeriesListPlacement, in defaults: UserDefaults) {
        defaults.set(placement.name, forKey: placementDefaultsKey)
    }

    @objc(placeScrollView:inSplitView:floating:visible:thumbnailWidth:)
    public static func place(_ scrollView: NSScrollView, in splitView: NSSplitView,
                             floating: Bool, visible: Bool, thumbnailWidth: CGFloat) {
        place(scrollView, in: splitView, floating: floating, visible: visible,
              thumbnailWidth: thumbnailWidth, placement: .left)
    }

    @objc(placeScrollView:inSplitView:floating:visible:thumbnailWidth:placement:)
    public static func place(_ scrollView: NSScrollView, in splitView: NSSplitView,
                             floating: Bool, visible: Bool, thumbnailWidth: CGFloat,
                             placement: SeriesListPlacement) {
        guard splitView.subviews.count == 2 else { return }
        // The dock is wherever the list already lives; before the first
        // placement it is the historical first subview. The other pane is the
        // image, and it is never removed.
        let dock = scrollView.superview.flatMap { splitView.subviews.contains($0) ? $0 : nil }
            ?? splitView.subviews[0]
        guard dock !== scrollView, let image = splitView.subviews.first(where: { $0 !== dock }) else { return }
        // Moving the dock to the other edge is a reorder of the same two
        // subviews: the image pane is never removed, so its content survives.
        if (placement.docksFirst && splitView.subviews.first !== dock)
            || (!placement.docksFirst && splitView.subviews.last !== dock) {
            let keptDelegate = splitView.delegate
            splitView.delegate = nil
            dock.removeFromSuperview()
            if placement.docksFirst { splitView.addSubview(dock, positioned: .below, relativeTo: image) }
            else { splitView.addSubview(dock, positioned: .above, relativeTo: image) }
            splitView.delegate = keptDelegate
        }
        splitView.isVertical = !placement.isHorizontalStrip

        // Restore the borrowed view before calling this method. Keeping the
        // document view intact preserves its cells and selection.
        let delegate = splitView.delegate
        splitView.delegate = nil
        defer { splitView.delegate = delegate }
        if scrollView.superview !== dock { dock.addSubview(scrollView) }
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.isHidden = false
        dock.isHidden = floating || !visible
        let thickness: CGFloat = floating || !visible ? 0 : thumbnailWidth
        if placement.isHorizontalStrip {
            dock.setFrameSize(NSSize(width: splitView.bounds.width, height: thickness))
        } else {
            dock.setFrameSize(NSSize(width: thickness, height: splitView.bounds.height))
        }
        // A horizontal strip scrolls sideways; its thumbnails keep their
        // size, so the scroller has to appear rather than the cells shrink.
        // The floating panel is a column on any edge and scrolls down.
        let row = placement.isHorizontalStrip && !floating
        scrollView.hasHorizontalScroller = row
        scrollView.hasVerticalScroller = !row
        scrollView.frame = dock.bounds
        splitView.dividerStyle = floating ? .thin : .thick
    }

    /// Lays the thumbnails along the strip: one column down the side, one row
    /// across the top or bottom. The cell size never changes, so a strip that
    /// is too short scrolls instead of squeezing its thumbnails.
    @objc(layOutMatrix:count:placement:)
    public static func layOut(_ matrix: NSMatrix, count: Int, placement: SeriesListPlacement) {
        // An autosizing matrix divides its width among its cells: turning a
        // column into a row would halve every thumbnail. The cells keep the
        // size their own class asks for and the strip scrolls instead.
        matrix.autosizesCells = false
        if let cell = matrix.cells.first, cell.cellSize.width > 0, cell.cellSize.height > 0 {
            matrix.cellSize = cell.cellSize
        }
        let rows = placement.isHorizontalStrip ? min(count, 1) : count
        let columns = placement.isHorizontalStrip ? count : min(count, 1)
        if matrix.numberOfRows != rows || matrix.numberOfColumns != columns {
            matrix.renewRows(rows, columns: columns)
        }
        matrix.sizeToCells()
    }

    /// Lays the thumbnails out for the list as it is shown: the floating panel
    /// is a column at the side of the screen whatever the edge, so only a
    /// docked list runs in a row.
    @objc(layOutMatrix:count:placement:floating:)
    public static func layOut(_ matrix: NSMatrix, count: Int, placement: SeriesListPlacement, floating: Bool) {
        layOut(matrix, count: count, placement: floating ? .left : placement)
    }

    /// The cell at a position of the list, in a column or in a row, or nil
    /// past its end.
    @objc(cellOfMatrix:atIndex:)
    public static func cell(of matrix: NSMatrix, at index: Int) -> NSCell? {
        index >= 0 && index < matrix.cells.count ? matrix.cells[index] : nil
    }

    /// Scrolls the list to the cell at a position, in a column or in a row.
    @objc(scrollMatrix:toCellAtIndex:)
    public static func scroll(_ matrix: NSMatrix, toCellAt index: Int) {
        guard index >= 0, index < matrix.cells.count else { return }
        if matrix.numberOfRows == 1 && matrix.numberOfColumns > 1 {
            matrix.scrollCellToVisible(atRow: 0, column: index)
        } else {
            matrix.scrollCellToVisible(atRow: index, column: 0)
        }
    }

    /// How thick the strip has to be on a given edge: a thumbnail's width down
    /// a side, a thumbnail's height plus the horizontal scroller across the top
    /// or bottom, so a full thumbnail fits instead of being clipped.
    @objc(thicknessForPlacement:thumbnailWidth:thumbnailHeight:)
    public static func thickness(for placement: SeriesListPlacement, thumbnailWidth: CGFloat, thumbnailHeight: CGFloat) -> CGFloat {
        guard placement.isHorizontalStrip else { return thumbnailWidth }
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
        return thumbnailHeight + (NSScroller.preferredScrollerStyle == .legacy ? scroller : 0)
    }

    /// The split view's pane that holds the list on a given edge: the first
    /// one on the left or the top, the last one on the right or the bottom.
    /// The other pane is the image.
    @objc(dockOfSplitView:placement:)
    public static func dock(of splitView: NSSplitView, placement: SeriesListPlacement) -> NSView? {
        guard splitView.subviews.count == 2 else { return nil }
        return splitView.subviews[placement.docksFirst ? 0 : 1]
    }

    /// The split view's other pane, the one that holds the image. It must
    /// never collapse, whichever edge the list is on.
    @objc(imagePaneOfSplitView:placement:)
    public static func imagePane(of splitView: NSSplitView, placement: SeriesListPlacement) -> NSView? {
        guard let dock = dock(of: splitView, placement: placement) else { return nil }
        return splitView.subviews.first { $0 !== dock }
    }

    /// The divider's position is where the first pane ends. With the list
    /// first, on the left or the top, that is the list's thickness. With the
    /// list last, on the right or the bottom, the list is what lies past the
    /// divider: the split view's length along the strip's axis, less the
    /// position and the divider. A position at or past the end hides it.
    @objc(listThicknessForDividerPosition:inSplitView:placement:)
    public static func listThickness(forDividerPosition position: CGFloat, in splitView: NSSplitView, placement: SeriesListPlacement) -> CGFloat {
        if placement.docksFirst { return position }
        let length = placement.isHorizontalStrip ? splitView.bounds.height : splitView.bounds.width
        return max(0, length - position - splitView.dividerThickness)
    }

    /// The divider position that leaves the list with a given thickness, the
    /// inverse of `listThickness(forDividerPosition:in:placement:)`. A hidden
    /// list on the right or the bottom puts the divider at the far end, so the
    /// image pane takes the whole split view.
    @objc(dividerPositionForListThickness:inSplitView:placement:)
    public static func dividerPosition(forListThickness thickness: CGFloat, in splitView: NSSplitView, placement: SeriesListPlacement) -> CGFloat {
        if placement.docksFirst { return thickness }
        let length = placement.isHorizontalStrip ? splitView.bounds.height : splitView.bounds.width
        return thickness > 0 ? max(0, length - thickness - splitView.dividerThickness) : length
    }

    /// Shows or hides the docked list on any edge. Only the dock is hidden;
    /// the image pane never is. A dock that is shown gets its thickness along
    /// the strip's axis, a width down a side and a height across the top or
    /// bottom, before the split view lays both panes out again.
    @objc(setListVisible:inSplitView:placement:thickness:)
    public static func setListVisible(_ visible: Bool, in splitView: NSSplitView, placement: SeriesListPlacement, thickness: CGFloat) {
        guard let dock = dock(of: splitView, placement: placement) else { return }
        dock.isHidden = !visible
        if visible {
            if placement.isHorizontalStrip {
                dock.setFrameSize(NSSize(width: splitView.bounds.width, height: thickness))
            } else {
                dock.setFrameSize(NSSize(width: thickness, height: splitView.bounds.height))
            }
        }
    }

    /// The two panes' frames for a given edge and strip thickness. The host's
    /// split-view delegate used to assume a left dock and a vertical divider.
    @objc(resizeSubviewsOfSplitView:placement:thickness:)
    public static func resizeSubviews(of splitView: NSSplitView, placement: SeriesListPlacement, thickness: CGFloat) {
        guard let dock = dock(of: splitView, placement: placement),
              let image = splitView.subviews.first(where: { $0 !== dock }) else { return }
        let bounds = splitView.bounds
        let divider = thickness > 0 ? splitView.dividerThickness : 0
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 0, bounds.height >= 0 else { return }
        switch placement {
        case .left:
            dock.frame = NSRect(x: 0, y: 0, width: thickness, height: bounds.height)
            image.frame = NSRect(x: thickness + divider, y: 0, width: max(0, bounds.width - thickness - divider), height: bounds.height)
        case .right:
            image.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - thickness - divider), height: bounds.height)
            dock.frame = NSRect(x: max(0, bounds.width - thickness), y: 0, width: thickness, height: bounds.height)
        case .top:
            // AppKit's split view stacks its first subview at the top.
            dock.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thickness)
            image.frame = NSRect(x: 0, y: thickness + divider, width: bounds.width, height: max(0, bounds.height - thickness - divider))
        case .bottom:
            image.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - thickness - divider))
            dock.frame = NSRect(x: 0, y: max(0, bounds.height - thickness), width: bounds.width, height: thickness)
        }
    }

    /// Whether the list is showing: the dock's own thickness along the strip's
    /// axis, whichever edge it is on.
    @objc(isListVisibleInSplitView:placement:thickness:)
    public static func isListVisible(in splitView: NSSplitView, placement: SeriesListPlacement, thickness: CGFloat) -> Bool {
        guard let dock = dock(of: splitView, placement: placement), !dock.isHidden else { return false }
        return (placement.isHorizontalStrip ? dock.frame.height : dock.frame.width) >= thickness
    }
}
