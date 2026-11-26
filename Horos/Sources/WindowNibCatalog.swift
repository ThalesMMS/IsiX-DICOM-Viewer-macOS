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
import ObjectiveC

/// The nib of a window in a language that has a catalog and no copy of the nib.
///
/// Spanish, Italian and Japanese have a Localizable.strings and no copy of the
/// nibs of the windows. There a nib loads as its English copy has it, and
/// every text it shows is read from the catalog with the English text as the
/// key, by `CatalogTranslation`, as the panes of the settings window are.
///
/// Every top-level object of the nib is read, not only the window: the sheets,
/// the panels, the views of toolbar items and the menus of a nib are top-level
/// objects of it, and a window controller keeps to itself the ones AppKit
/// loads for it. So the nib is loaded here, in place of -loadWindow, and its
/// objects are kept for as long as the controller lives, as AppKit keeps them.
///
/// A translation is often longer than the frame its English text was drawn
/// in: once the texts are read, `WindowNibFit` gives each one the room that is
/// free beside it.
///
/// In a language that has a copy of the nib, and in English, nothing is loaded
/// here and the controller loads its window as it always did.
@MainActor
enum WindowNibCatalog {
    /// The key under which a window controller keeps the top-level objects of
    /// a nib loaded by `loadWindowReadingCatalog()`. Only its address is used.
    fileprivate static var objectsKey: UInt8 = 0

    /// Whether the nib named `name`, with `owner` as its File's Owner, is one
    /// of the application's that the language has no copy of. A controller
    /// whose class a plugin defines loads its nib from the plugin's bundle,
    /// with the plugin's own texts: it is left alone.
    static func reads(nibNamed name: String, owner: AnyObject) -> Bool {
        Bundle(for: type(of: owner)) == Bundle.main
            && Bundle.main.url(forResource: name, withExtension: "nib") != nil
            && CatalogTranslation.isNeeded(forNibNamed: name)
    }

    /// Reads from the catalog the texts of the top-level objects of the nib
    /// named `name`, which the caller has loaded with `owner`. Nothing is
    /// changed in a language that has a copy of the nib.
    static func read(_ objects: [Any], ofNibNamed name: String, owner: AnyObject) {
        guard reads(nibNamed: name, owner: owner) else { return }
        CatalogTranslation.translate(objects, with: CatalogTranslation.mainCatalog)
        WindowNibFit.makeRoom(in: objects)
    }

    /// Loads the nib named `name` with `owner` and reads its texts from the
    /// catalog. Returns its top-level objects, which the caller keeps; nil
    /// when the language has a copy of the nib or the nib does not load, and
    /// then nothing was loaded.
    static func instantiate(nibNamed name: String, owner: AnyObject) -> [Any]? {
        guard reads(nibNamed: name, owner: owner), let nib = NSNib(nibNamed: name, bundle: .main) else { return nil }
        var loaded: NSArray?
        guard nib.instantiate(withOwner: owner, topLevelObjects: &loaded) else { return nil }
        let objects = loaded.map { Array($0) } ?? []
        NibOwnedWindows.keep(objects)
        CatalogTranslation.translate(objects, with: CatalogTranslation.mainCatalog)
        WindowNibFit.makeRoom(in: objects)
        return objects
    }
}

/// The windows among the top-level objects of a nib that the caller keeps.
///
/// A nib loaded with its top-level objects handed back gives them to the
/// array, which is then the windows' only owner. A window whose nib has
/// "Release When Closed" on releases itself as well when it is closed, and
/// the application closes every window when it quits: that release is one
/// the window was never given, and the array, freed with the viewer or
/// controller that keeps it, then releases a window already deallocated.
/// The windows are kept by the array alone, and close without releasing.
@MainActor
enum NibOwnedWindows {
    static func keep(_ objects: [Any]) {
        for case let window as NSWindow in objects {
            window.isReleasedWhenClosed = false
        }
    }
}

/// Room for the texts the catalog made longer than the frames of a nib.
///
/// The older nibs of the windows are laid out by frames drawn for their
/// English texts, and a frame has no more room than its text needed: "Size:"
/// in 34 points, which "Tamaño:" does not fit. A label, a button, a checkbox
/// or the cells of a radio matrix whose text needs more than its frame takes
/// the room that is free beside it, in its own row of its own view: up to the
/// next view of the row, or to the edge of the view they are in. A text set
/// to the right grows to the left, as the label before a field does, one set
/// to the left grows to the right, and a centred one to both sides. Nothing
/// is moved, nothing is taken from another view, and a control whose text
/// fits is left as the nib has it; where the row has no room the text is cut
/// as before. Views laid out by constraints are left to them.
@MainActor
enum WindowNibFit {
    /// Makes room in the windows and views among `objects`, the top-level
    /// objects of a nib.
    static func makeRoom(in objects: [Any]) {
        for object in objects {
            if let window = object as? NSWindow {
                if let content = window.contentView { makeRoom(in: content) }
            } else if let view = object as? NSView {
                makeRoom(in: view)
            }
        }
    }

    private static func makeRoom(in view: NSView) {
        if let tabs = view as? NSTabView {
            // Only the selected item's view is a subview.
            for item in tabs.tabViewItems { if let content = item.view { makeRoom(in: content) } }
            return
        }
        // A control's subviews are AppKit's drawing of it.
        if view is NSControl { return }
        for child in view.subviews {
            if child.translatesAutoresizingMaskIntoConstraints { widen(child) }
            makeRoom(in: child)
        }
    }

    /// The side a control grows to.
    private enum Side { case leading, trailing, both }

    /// The width the text of `view` needs on one line and the side it grows
    /// to; nil for a view that shows no text of the nib on one line.
    private static func need(of view: NSView) -> (width: CGFloat, side: Side)? {
        func side(_ alignment: NSTextAlignment) -> Side {
            switch alignment {
            case .right: return .leading
            case .center: return .both
            default: return .trailing
            }
        }
        if view is NSPopUpButton { return nil }
        if let button = view as? NSButton {
            guard !button.title.isEmpty, button.imagePosition != .imageOnly, button.infoForBinding(.title) == nil,
                  let cell = button.cell else { return nil }
            return (cell.cellSize.width, side(button.alignment))
        }
        if let field = view as? NSTextField {
            guard !field.isEditable, !field.isBezeled, !field.stringValue.isEmpty, field.infoForBinding(.value) == nil,
                  field.infoForBinding(NSBindingName("displayPatternValue1")) == nil, let cell = field.cell else { return nil }
            let line = cell.cellSize
            // A label as high as two lines wraps its text, and needs no more width.
            guard field.frame.height < line.height * 1.6 else { return nil }
            return (line.width, side(field.alignment))
        }
        return nil
    }

    /// The room free before and after `view` in its row of `superview`: up to
    /// the views that stand before and after it, or to the edges. A view that
    /// crosses it (a box drawn behind it, a control shown in its place) bounds
    /// nothing.
    private static func room(around view: NSView, in superview: NSView) -> (before: CGFloat, after: CGFloat) {
        let frame = view.frame
        // Two points are kept to the edge of the view; the frames of two neighbours may touch, as the nibs draw them.
        let margin: CGFloat = 2
        var low = superview.bounds.minX + margin, high = superview.bounds.maxX - margin
        for sibling in superview.subviews where sibling !== view {
            let other = sibling.frame
            guard other.minY < frame.maxY - 1, other.maxY > frame.minY + 1 else { continue }
            if other.maxX <= frame.midX && other.minX < frame.minX {
                low = max(low, min(other.maxX, frame.minX))
            } else if other.minX >= frame.midX && other.maxX > frame.maxX {
                high = min(high, max(other.minX, frame.maxX))
            }
        }
        return (max(0, frame.minX - low), max(0, high - frame.maxX))
    }

    private static func widen(_ view: NSView) {
        guard let superview = view.superview else { return }
        if let matrix = view as? NSMatrix {
            widen(matrix, in: superview)
            return
        }
        guard let need = need(of: view) else { return }
        let missing = ceil(need.width - view.frame.width)
        guard missing > 0 else { return }
        let room = room(around: view, in: superview)
        var before: CGFloat = 0, after: CGFloat = 0
        switch need.side {
        case .leading:
            before = min(missing, room.before)
            after = min(missing - before, room.after)
        case .trailing:
            after = min(missing, room.after)
        case .both:
            before = min(ceil(missing / 2), room.before)
            after = min(missing - before, room.after)
            before = min(missing - after, room.before)
        }
        guard before + after > 0 else { return }
        var frame = view.frame
        frame.origin.x -= before
        frame.size.width += before + after
        view.frame = frame
    }

    /// The cells of a matrix of radio buttons or checkboxes are as wide as
    /// its widest title was in English: every column grows by what the widest
    /// title needs now, into the room after the matrix.
    private static func widen(_ matrix: NSMatrix, in superview: NSView) {
        let titled = matrix.cells.compactMap { $0 as? NSButtonCell }.filter { !$0.title.isEmpty && $0.imagePosition != .imageOnly }
        guard !titled.isEmpty, matrix.numberOfColumns > 0 else { return }
        let needed = titled.map(\.cellSize.width).max() ?? 0
        let missing = ceil(needed - matrix.cellSize.width)
        guard missing > 0 else { return }
        let columns = CGFloat(matrix.numberOfColumns)
        let growth = min(missing, floor(room(around: matrix, in: superview).after / columns))
        guard growth > 0 else { return }
        let autosizes = matrix.autosizesCells
        matrix.autosizesCells = false
        matrix.cellSize = NSSize(width: matrix.cellSize.width + growth, height: matrix.cellSize.height)
        matrix.setFrameSize(NSSize(width: matrix.frame.width + growth * columns, height: matrix.frame.height))
        matrix.autosizesCells = autosizes
    }
}


extension NSWindowController {
    /// Loads the controller's nib with its texts read from the catalog, where
    /// the language has no copy of the nib. A controller of a window of the
    /// application overrides -loadWindow with it:
    ///
    ///     public override func loadWindow() {
    ///         if !loadWindowReadingCatalog() { super.loadWindow() }
    ///     }
    ///
    /// Returns false when nothing was loaded, and -loadWindow of the
    /// superclass then loads the window.
    func loadWindowReadingCatalog() -> Bool {
        guard !isWindowLoaded, let name = windowNibName,
              let objects = WindowNibCatalog.instantiate(nibNamed: name, owner: owner ?? self) else { return false }
        objc_setAssociatedObject(self, &WindowNibCatalog.objectsKey, objects, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }
}
