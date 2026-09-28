/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa

/// Pops up a menu in a window of its own, which can be filtered by typing.
///
/// Implemented in Swift since #709: the Objective-C name, the selector and
/// `<Horos/N2PopUpMenu.h>` are those of the former class. The other classes of
/// this file were private to it.
@objc(N2PopUpMenu)
public final class N2PopUpMenu: NSObject {
    /// When popping up menus using this method, you should make sure the
    /// clicked view forwards mouseup and mousedragged events to the returned
    /// NSWindow, as done in O2DicomPredicateEditorPopUpButton.m.
    @objc(popUpContextMenu:withEvent:forView:withFont:)
    public static func popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSPopUpButton, with font: NSFont?) -> NSWindow? {
        let wc = N2PopUpMenuWindowController()
        // The controller owns itself until its window closes, as the
        // Objective-C alloc did until -windowWillClose: autoreleased it.
        _ = Unmanaged.passRetained(wc)

        wc.startTrackingMenu(menu, with: event, for: view, with: font)

        return wc.window
    }
}

private let FilterFieldBorder = NSSize(width: 20, height: 4)
private let PopUpWindowBorder = NSSize(width: 10, height: 4)

@objc(N2PopUpMenuWindowController)
final class N2PopUpMenuWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private var bgView: N2PopUpMenuWindowView!
    @objc private(set) var puView: N2PopUpMatrix!
    private var sView: NSScrollView!
    private var topScrollButton: N2PopUpScrollView!
    private var bottomScrollButton: N2PopUpScrollView!
    private var filterField: NSTextField!
    private var view: NSView!
    private var popUpMenu: NSMenu!
    private var centerOnNextRefresh = false, refreshing = false
    private var noMouseMovedToWindowLocationOnNextRefresh: UInt = 0
    @objc private(set) var startTime: TimeInterval = 0

    init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc func incNoMouseMovedToWindowLocationOnNextRefresh() {
        noMouseMovedToWindowLocationOnNextRefresh &+= 1
    }

    @objc func windowWillClose(_ notification: Notification) {
        // Balances the retain of +popUpContextMenu:…, after the close is done.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    /// The frame of `view` in screen coordinates; zero without a window, as
    /// the messages to nil gave before.
    private func viewFrameOnScreen(_ view: NSView?) -> NSRect {
        guard let view = view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    @objc(startTrackingMenu:withEvent:forView:withFont:)
    func startTrackingMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView, with font: NSFont?) {
        startTime = event.timestamp

        self.view = view
        popUpMenu = menu

        // The matrix does not exist yet, so this is 0, as it was before.
        let itemHeight: CGFloat = puView?.itemHeight ?? 0

        let viewFrame = viewFrameOnScreen(view)

        let window = N2PopUpMenuWindow(contentRect: viewFrame, styleMask: .borderless, backing: .buffered, defer: false)
        self.window = window
        window.level = .mainMenu
        window.isOpaque = false
        window.backgroundColor = .clear
        // The menu is drawn in the appearance of the control that opens it, so the
        // dynamic colours below resolve light or dark together (#743).
        window.appearance = view.effectiveAppearance
        window.hasShadow = true
        window.acceptsMouseMovedEvents = true
        // Objective-C set YES and balanced the extra release by never releasing
        // its alloc; under ARC the controller owns the window and frees it.
        window.isReleasedWhenClosed = false

        window.menu = menu

        bgView = N2PopUpMenuWindowView(frame: .zero)
        puView = N2PopUpMatrix(frame: .zero)
        sView = NSScrollView(frame: .zero)

        sView.drawsBackground = false
        sView.borderType = .noBorder

        sView.hasHorizontalScroller = false
        sView.hasVerticalScroller = true
        sView.hasHorizontalRuler = false
        sView.hasVerticalRuler = false

        sView.verticalScrollElasticity = .none

        sView.lineScroll = itemHeight

        topScrollButton = N2PopUpScrollView(frame: .zero)
        topScrollButton.setTop()
        topScrollButton.action = #selector(NSResponder.scrollLineUp(_:))
        topScrollButton.target = puView

        bottomScrollButton = N2PopUpScrollView(frame: .zero)
        bottomScrollButton.setBottom()
        bottomScrollButton.action = #selector(NSResponder.scrollLineDown(_:))
        bottomScrollButton.target = puView

        filterField = NSTextField(frame: .zero)
        filterField.delegate = self

        filterField.cell?.controlSize = .small
        filterField.font = NSFont.controlContentFont(ofSize: NSFont.smallSystemFontSize)
        filterField.bezelStyle = .roundedBezel
        filterField.sizeToFit()
        filterField.focusRingType = .none

        window.contentView?.addSubview(bgView)
        bgView.addSubview(sView)
        sView.documentView = puView

        window.delegate = self
        sView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(observeScrollViewContentViewBoundsDidChangeNotification(_:)), name: NSView.boundsDidChangeNotification, object: sView.contentView)

        puView.font = font

        var highlight = NSNotFound
        if let popUpButton = view as? NSPopUpButton {
            let visibleItems = menu.items.filter { !$0.isHidden } as NSArray
            let representedObjects = visibleItems.value(forKeyPath: "representedObject") as! NSArray
            if let selected = popUpButton.selectedItem?.representedObject {
                highlight = representedObjects.index(of: selected)
            }
        }
        puView.highlightItemAtRow(highlight, scroll: true)

        filter(true)

        // Reading clickCount and eventNumber of a keyboard event raises, as it
        // did in Objective-C when O2DicomPredicateEditorPopUpButton opens the
        // menu from -keyDown:. The menu is already up; the exception is logged
        // instead of unwinding through Swift.
        do {
            try HorosObjCException.perform {
                if let mouseUp = NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow, modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil, eventNumber: event.eventNumber + 1, clickCount: event.clickCount, pressure: 0) {
                    view.window?.sendEvent(mouseUp)
                }
            }
        } catch {
            NSLog("N2PopUpMenu: %@", String(describing: (error as NSError).userInfo[HorosObjCExceptionKey] ?? error))
        }
    }

    @objc func windowDidResignKey(_ notification: Notification) {
        window?.close()
    }

    /// Changes the window size.
    @objc(update:)
    func update(_ center: Bool) {
        guard let window = window else { return }

        if center {
            centerOnNextRefresh = true
        }

        let itemHeight = puView.itemHeight

        puView.sizeToCells()

        let totContentSize = puView.frame.size

        var extraH: CGFloat = 0
        if filterField.superview != nil {
            extraH += filterField.frame.size.height + FilterFieldBorder.height * 2
        }

        var screenFrame = view.window?.screen?.visibleFrame ?? .zero
        screenFrame = screenFrame.insetBy(dx: 2, dy: 2) // stay away from screen top & bottom

        var availableSize = screenFrame.size
        availableSize.height -= PopUpWindowBorder.height * 2 // 4 external
        availableSize.height = (availableSize.height / itemHeight).rounded(.towardZero) * itemHeight

        let viewFrame = viewFrameOnScreen(view)

        var f = NSRect(x: viewFrame.origin.x, y: viewFrame.origin.y, width: totContentSize.width,
                       height: min(availableSize.height, totContentSize.height) + PopUpWindowBorder.height * 2 + extraH)
        if f.origin.y + f.size.height > screenFrame.origin.y + screenFrame.size.height {
            f.origin.y += (screenFrame.origin.y + screenFrame.size.height) - (f.origin.y + f.size.height)
        }
        if f.origin.y < screenFrame.origin.y {
            f.origin.y = screenFrame.origin.y
        }

        // make sure the menu is aligned with the popup button
        if view is NSPopUpButton {
            let p = NSPoint(x: viewFrame.origin.x + viewFrame.size.width / 2, y: viewFrame.origin.y + viewFrame.size.height / 2)
            var d = Int(f.origin.y + itemHeight / 2 - p.y)
            d = abs(d)
            d = Int(CGFloat(d % Int(itemHeight)) - PopUpWindowBorder.height)
            if d != 0 {
                f.origin.y += CGFloat(d)
            }
            f.origin.x -= PopUpWindowBorder.width - 6
        }

        while f.origin.y < screenFrame.origin.y {
            f.origin.y += itemHeight
        }
        while f.origin.y + f.size.height > screenFrame.origin.y + screenFrame.size.height {
            f.size.height -= itemHeight
        }

        if window.frame != f {
            window.setFrame(f, display: false)
        } else {
            refresh()
        }

        window.makeKeyAndOrderFront(self)
    }

    @objc func windowDidResize(_ notification: Notification) {
        bgView.frame = bgView.superview?.bounds ?? .zero

        refresh()
    }

    @objc func observeScrollViewContentViewBoundsDidChangeNotification(_ n: Notification) {
        refresh()
    }

    @objc func refresh() {
        guard let window = window else { return }

        if refreshing {
            return
        }
        refreshing = true

        let center = centerOnNextRefresh
        centerOnNextRefresh = false

        let itemHeight = puView.itemHeight

        var wf = window.frame

        var vf = bgView.bounds
        vf.origin.y += PopUpWindowBorder.height
        vf.size.height -= PopUpWindowBorder.height * 2

        if filterField.superview != nil {
            vf.size.height -= filterField.frame.size.height + FilterFieldBorder.height * 2
        }

        if sView.frame == .zero { // initial
            sView.frame = vf
        }

        var screenFrame = view.window?.screen?.visibleFrame ?? .zero
        screenFrame = screenFrame.insetBy(dx: 2, dy: 2) // stay away from screen top & bottom

        var puvf = viewFrameOnScreen(view)
        puvf.origin.y += PopUpWindowBorder.height / 2 // not sure about this... but it works...

        if center {
            if puView.highlightedCellRow >= 0 && puView.highlightedCellRow < puView.numberOfRows {
                var r = window.convertToScreen(puView.convert(puView.cellFrame(atRow: puView.highlightedCellRow, column: 0), to: nil))

                var p = sView.contentView.bounds.origin
                p.y += puvf.origin.y - r.origin.y

                if p.y < 0 {
                    p.y = 0
                }

                sView.contentView.scroll(to: p)
                sView.reflectScrolledClipView(sView.contentView)

                // still not aligned? move the window!

                r = window.convertToScreen(puView.convert(puView.cellFrame(atRow: puView.highlightedCellRow, column: 0), to: nil))

                var d = r.origin.y - puvf.origin.y
                if d != 0 {
                    wf.origin.y -= d
                    window.setFrame(wf, display: false)
                    sView.frame = vf
                }

                // scrolled to white? fix it!

                d = (sView.documentVisibleRect.origin.y + sView.documentVisibleRect.size.height) - (sView.contentView.documentRect.origin.y + sView.contentView.documentRect.size.height)
                if d > 0 {
                    wf.origin.y += d
                    wf.size.height -= d
                    vf.size.height -= d
                    window.setFrame(wf, display: false)
                    sView.frame = vf
                }
                d = sView.documentVisibleRect.origin.y - sView.contentView.documentRect.origin.y
                if d < 0 {
                    wf.origin.y += d
                    wf.size.height -= d
                    vf.size.height -= d
                    window.setFrame(wf, display: false)
                    sView.frame = vf
                }
            }
        }

        // make sure the window is next to the view

        while wf.origin.y + wf.size.height < puvf.origin.y + puvf.size.height {
            wf.origin.y += itemHeight
        }
        while wf.origin.y > puvf.origin.y {
            wf.origin.y -= itemHeight
        }

        // make sure the window hasn't grown out of the screen bounds

        while wf.origin.y < screenFrame.origin.y {
            wf.origin.y += itemHeight
            wf.size.height -= itemHeight
            vf.size.height -= itemHeight
        }
        while wf.origin.y + wf.size.height > screenFrame.origin.y + screenFrame.size.height {
            wf.size.height -= itemHeight
            vf.size.height -= itemHeight
        }

        window.setFrame(wf, display: false)
        sView.frame = vf

        // are there any hidden menu items, and enough space to show them? grow out!

        var sViewDVR = sView.documentVisibleRect
        var scroll: CGFloat = 0
        while true {
            let isShowingTop = sViewDVR.origin.y <= sView.contentView.documentRect.origin.y
            if !isShowingTop && wf.origin.y + wf.size.height < screenFrame.origin.y + screenFrame.size.height - itemHeight {
                wf.size.height += itemHeight
                vf.size.height += itemHeight
                sViewDVR.size.height += itemHeight
                sViewDVR.origin.y -= itemHeight
                scroll -= itemHeight
            } else {
                let isShowingBottom = sViewDVR.origin.y + sViewDVR.size.height >= sView.contentView.documentRect.origin.y + sView.contentView.documentRect.size.height
                if !isShowingBottom && wf.origin.y > screenFrame.origin.y + itemHeight {
                    wf.size.height += itemHeight
                    wf.origin.y -= itemHeight
                    vf.size.height += itemHeight
                    sViewDVR.size.height += itemHeight
                } else {
                    break
                }
            }
        }

        window.setFrame(wf, display: false)
        sView.frame = vf
        if scroll != 0 {
            var p = sView.contentView.bounds.origin
            p.y += scroll
            sView.contentView.scroll(to: p)
            sView.reflectScrolledClipView(sView.contentView)
        }

        let isShowingBottom = sView.documentVisibleRect.origin.y + sView.documentVisibleRect.size.height >= sView.contentView.documentRect.origin.y + sView.contentView.documentRect.size.height
        if !isShowingBottom {
            if bottomScrollButton.superview == nil {
                bgView.addSubview(bottomScrollButton)
            }
            bottomScrollButton.frame = NSRect(x: vf.origin.x, y: vf.origin.y, width: vf.size.width, height: itemHeight)
            vf.origin.y += itemHeight
            vf.size.height -= itemHeight
        } else {
            if bottomScrollButton.superview != nil {
                bottomScrollButton.removeFromSuperview()
            }
        }

        let isShowingTop = (topScrollButton.superview == nil && sView.documentVisibleRect.origin.y <= sView.contentView.documentRect.origin.y)
            || (topScrollButton.superview != nil && sView.documentVisibleRect.origin.y <= sView.contentView.documentRect.origin.y + itemHeight)
        if !isShowingTop {
            if topScrollButton.superview == nil {
                bgView.addSubview(topScrollButton)
            }
            topScrollButton.frame = NSRect(x: vf.origin.x, y: vf.origin.y + vf.size.height - itemHeight, width: vf.size.width, height: itemHeight)
            vf.size.height -= itemHeight
        } else {
            if topScrollButton.superview != nil {
                topScrollButton.removeFromSuperview()
            }
        }

        sView.frame = vf

        if center {
            if puView.highlightedCellRow != NSNotFound {
                let r = window.convertToScreen(puView.convert(puView.cellFrame(atRow: puView.highlightedCellRow, column: 0), to: nil))

                var p = sView.contentView.bounds.origin
                p.y += puvf.origin.y - r.origin.y

                if p.y < 0 {
                    p.y = 0
                }

                sView.contentView.scroll(to: p)
                sView.reflectScrolledClipView(sView.contentView)
            }
        }

        if filterField.superview != nil {
            filterField.frame = NSRect(x: vf.origin.x + FilterFieldBorder.width,
                                       y: wf.size.height - PopUpWindowBorder.height - filterField.frame.size.height - FilterFieldBorder.height,
                                       width: vf.size.width - FilterFieldBorder.width * 2,
                                       height: filterField.frame.size.height)
        }

        let r = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        puView.mouseMovedToWindowLocation(window.convertFromScreen(r).origin)

        refreshing = false
    }

    @objc(interceptEvent:)
    func interceptEvent(_ event: NSEvent) -> Bool {
        if filterField.superview != nil {
            return false
        }

        if event.type == .keyDown {
            keyDown(with: event)
            return true
        }

        if event.type == .leftMouseDragged {
            puView.mouseDragged(with: event)
            return true
        }

        if event.type == .leftMouseUp {
            puView.mouseUp(with: event)
            return true
        }

        return false
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    @objc(maybeDoCommandBySelector:)
    func maybeDoCommand(by command: Selector) -> Bool {
        if responds(to: command) {
            _ = perform(command, with: self)
            return true
        } else if let puView = (window?.windowController as? N2PopUpMenuWindowController)?.puView, puView.responds(to: command) {
            _ = puView.perform(command, with: self)
            return true
        }

        return false
    }

    override func doCommand(by command: Selector) {
        _ = maybeDoCommand(by: command)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.moveRight(_:)) || command == #selector(NSResponder.moveLeft(_:)) {
            return false
        }
        return maybeDoCommand(by: command)
    }

    override func insertText(_ insertString: Any) {
        // An NSString, as the Objective-C signature said; an attributed string
        // gives its characters.
        let str = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""

        filterField.stringValue = str

        if filterField.superview == nil {
            bgView.addSubview(filterField)
            update(false)
        }

        window?.makeFirstResponder(filterField)
        window?.fieldEditor(true, for: filterField)?.selectedRange = NSRange(location: (str as NSString).length, length: 0)
    }

    override func cancelOperation(_ sender: Any?) {
        if filterField.superview != nil {
            filterField.stringValue = ""
            filterField.removeFromSuperview()
            update(false)
            filter()
        } else {
            window?.close()
        }
    }

    override func insertNewline(_ sender: Any?) {
        selectHighlighted()
    }

    @objc func selectHighlighted() {
        if puView.highlightedCellRow != NSNotFound {
            let cells = puView.cells
            guard puView.highlightedCellRow >= 0 && puView.highlightedCellRow < cells.count else {
                // -objectAtIndex: raised here before, leaving the menu open.
                NSLog("N2PopUpMenu: highlighted row %ld is not among %lu cells", puView.highlightedCellRow, UInt(cells.count))
                return
            }
            let tag = cells[puView.highlightedCellRow].tag

            if let popUpButton = view as? NSPopUpButton {
                popUpButton.willChangeValue(forKey: "selectedTag")
                popUpButton.selectItem(withTag: tag)
                popUpButton.didChangeValue(forKey: "selectedTag")
            }

            if let mi = popUpMenu.item(withTag: tag), let target = mi.target as? NSObjectProtocol, let action = mi.action {
                _ = target.perform(action, with: mi)
            }
        }

        window?.close()
    }

    func controlTextDidChange(_ notification: Notification) {
        filterAfterTextChange(notification)
    }

    private func filterAfterTextChange(_ notification: Notification?) {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
        perform(#selector(filter as () -> Void), with: nil, afterDelay: notification != nil ? 0.1 : 0, inModes: [.common]) // TODO: get system key delay preference
        if notification == nil {
            window?.fieldEditor(true, for: filterField)?.selectedRange = NSRange(location: 0, length: (filterField.stringValue as NSString).length)
        }
    }

    @objc func filter() {
        filter(false)
    }

    @objc(filter:)
    func filter(_ center: Bool) {
        var words: [String] = []
        if filterField.superview != nil {
            words = filterField.stringValue.components(separatedBy: .whitespacesAndNewlines)
        }

        var lcwords: [String] = []
        for word in words where !word.isEmpty {
            lcwords.append((word as NSString).lowercased)
        }

        var somethingIsAvailable = false
        for mi in popUpMenu.items {
            let lctitle = (mi.title as NSString).lowercased as NSString
            var matchedAllWords = true
            for word in lcwords where !word.isEmpty {
                if lctitle.range(of: word, options: .literal).location == NSNotFound {
                    matchedAllWords = false
                }
            }

            mi.isHidden = !matchedAllWords

            if matchedAllWords {
                somethingIsAvailable = true
            }
        }

        if !somethingIsAvailable {
            window?.fieldEditor(true, for: filterField)?.selectedRange = NSRange(location: 0, length: (filterField.stringValue as NSString).length)
        }

        update(center)
    }
}

@objc(N2PopUpMatrixCell)
final class N2PopUpMatrixCell: NSCell {
    /// NSCell does not keep a tag; this cell does.
    private var storedTag = 0

    override var tag: Int {
        get { storedTag }
        set { storedTag = newValue }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSGraphicsContext.current?.saveGraphicsState()

        var cellFrame = cellFrame
        let font = (controlView as? NSControl)?.font

        var attributes: [NSAttributedString.Key: Any]
        if isHighlighted {
            NSColor.selectedMenuItemColor.withAlphaComponent(1).setFill()
            NSBezierPath.fill(cellFrame.insetBy(dx: -1, dy: 0))
            attributes = [.foregroundColor: NSColor.selectedMenuItemTextColor]
        } else {
            attributes = [.foregroundColor: NSColor.controlTextColor]
        }
        // A nil font ended the Objective-C dictionary literal list here.
        if let font = font {
            attributes[.font] = font
        }

        attributedStringValue = NSAttributedString(string: title, attributes: attributes)

        cellFrame.origin.y += 1

        if state != .off {
            var cmrect = cellFrame
            cmrect.origin.x += 5
            NSAttributedString(string: "✓", attributes: attributes).draw(in: cmrect)
        }

        cellFrame.origin.x += 9

        cellFrame.size.width += PopUpWindowBorder.width // see insetrect in next line...
        super.draw(withFrame: cellFrame.insetBy(dx: PopUpWindowBorder.width, dy: 0), in: controlView)

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

@objc(N2PopUpMatrix)
final class N2PopUpMatrix: NSMatrix {
    @objc var itemHeight: CGFloat = 16
    private var minItemWidth: CGFloat = 120
    @objc var highlightedCellRow: Int = NSNotFound
    private var highlighting = false

    private var windowController: N2PopUpMenuWindowController? {
        window?.windowController as? N2PopUpMenuWindowController
    }

    /// -[NSMatrix initWithFrame:] is this call, which Swift cannot make itself.
    init(frame frameRect: NSRect) {
        super.init(frame: frameRect, mode: .radioModeMatrix, cellClass: NSActionCell.self, numberOfRows: 0, numberOfColumns: 0)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.assumeInside, .mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil))
        cellClass = N2PopUpMatrixCell.self
        intercellSpacing = .zero
        drawsBackground = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func sizeToCells() {
        let mis = (window?.menu?.items ?? []).filter { !$0.isHidden }

        var attributes: [NSAttributedString.Key: Any] = [:]
        if let font = font {
            attributes[.font] = font
        }

        renewRows(mis.count, columns: 1) // +1 ??? wtf??? but if we don't, the last cell is never displayed..
        var maxw = minItemWidth
        for (i, mi) in mis.enumerated() {
            if let cell = cell(atRow: i, column: 0) {
                cell.title = mi.title
                cell.representedObject = mi.representedObject
                cell.tag = mi.tag
                cell.state = mi.state
            }

            maxw = max(maxw, (mi.title as NSString).size(withAttributes: attributes).width)
        }

        cellSize = NSSize(width: maxw + PopUpWindowBorder.width * 2 + 9, height: itemHeight) // 9 for the checkmarks

        super.sizeToCells()
    }

    override func adjustScroll(_ newVisible: NSRect) -> NSRect {
        var rect = newVisible
        rect.origin.y = (rect.origin.y / itemHeight).rounded(.towardZero) * itemHeight
        return rect
    }

    /// Not NSView's -acceptsFirstMouse:, which takes an event; kept as it was.
    @objc func acceptsFirstMouse() -> Bool {
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        mouseMovedToWindowLocation(event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMovedToWindowLocation(event.locationInWindow)
    }

    @objc(mouseMovedToWindowLocation:)
    func mouseMovedToWindowLocation(_ windowLocation: NSPoint) {
        var row = 0, col = 0

        if !getRow(&row, column: &col, for: convert(windowLocation, from: nil)) {
            row = NSNotFound
        }

        highlightItemAtRow(row, scroll: false)
    }

    @objc(highlightItemAtRow:scroll:)
    func highlightItemAtRow(_ row: Int, scroll: Bool) {
        if highlighting {
            return
        }
        highlighting = true

        if highlightedCellRow != NSNotFound {
            highlightCell(false, atRow: highlightedCellRow, column: 0)
        }

        if row != NSNotFound {
            if scroll {
                windowController?.incNoMouseMovedToWindowLocationOnNextRefresh()
                scrollCellToVisible(atRow: row, column: 0)
            }
            highlightCell(true, atRow: row, column: 0)
            if scroll {
                scrollCellToVisible(atRow: row, column: 0)
            }
        }

        for r in 0..<max(numberOfRows, 0) { // this should not be necessary, however...
            highlightCell(r == row, atRow: r, column: 0)
        }

        highlightedCellRow = row

        highlighting = false
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
    }

    override func mouseUp(with event: NSEvent) {
        if event.timestamp - (windowController?.startTime ?? 0) > 0.1666 {
            if highlightedCellRow != NSNotFound {
                windowController?.selectHighlighted()
            }
        }
    }

    private var containingScrollView: NSScrollView? {
        var v: NSView? = self
        while let view = v {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            v = view.superview
        }
        return nil
    }

    private func scroll(_ scrollView: NSScrollView?, to p: NSPoint) {
        guard let scrollView = scrollView else { return }
        scrollView.contentView.scroll(to: p)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func scrollLineUp(_ sender: Any?) {
        var p = containingScrollView?.contentView.bounds.origin ?? .zero
        p.y -= itemHeight
        scroll(containingScrollView, to: p)
    }

    override func scrollLineDown(_ sender: Any?) {
        var p = containingScrollView?.contentView.bounds.origin ?? .zero
        p.y += itemHeight
        scroll(containingScrollView, to: p)
    }

    override func scrollPageUp(_ sender: Any?) {
        let puViewHeight = windowController?.puView?.frame.size.height ?? 0
        let b = containingScrollView?.contentView.bounds ?? .zero
        var p = b.origin
        let po = p
        p.y -= b.size.height - itemHeight
        if po.y + b.size.height + itemHeight == puViewHeight {
            p.y += itemHeight
        }
        if p.y == itemHeight {
            p.y -= itemHeight
        }
        if p.y < 0 {
            p.y = 0
        }
        scroll(containingScrollView, to: p) // TODO: grow window to max height, then scroll
    }

    override func scrollPageDown(_ sender: Any?) {
        let puViewHeight = windowController?.puView?.frame.size.height ?? 0
        let b = containingScrollView?.contentView.bounds ?? .zero
        var p = b.origin
        p.y += b.size.height - itemHeight
        if p.y + b.size.height > puViewHeight {
            p.y = puViewHeight - b.size.height
        }
        scroll(containingScrollView, to: p) // TODO: grow window to max height, then scroll
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        scroll(containingScrollView, to: .zero) // TODO: grow window to max height, then scroll
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        let puViewHeight = windowController?.puView?.frame.size.height ?? 0
        let b = containingScrollView?.contentView.bounds ?? .zero
        var p = NSPoint(x: 0, y: puViewHeight)
        if p.y + b.size.height > puViewHeight {
            p.y = puViewHeight - b.size.height
        }
        scroll(containingScrollView, to: p) // TODO: grow window to max height, then scroll
        if sender != nil {
            scrollToEndOfDocument(nil) // this is ugly...
        }
    }

    override func moveUp(_ sender: Any?) {
        var row = highlightedCellRow
        if row == NSNotFound {
            row = numberOfRows - 1
        } else if row == 0 {
            return
        } else {
            row -= 1
        }
        highlightItemAtRow(row, scroll: true)
    }

    override func moveDown(_ sender: Any?) {
        var row = highlightedCellRow
        if row == NSNotFound {
            row = 0
        } else if row == numberOfRows - 1 {
            return
        } else {
            row += 1
        }
        highlightItemAtRow(row, scroll: true)
    }
}

@objc(N2PopUpScrollView)
final class N2PopUpScrollView: NSControl {
    /// Unretained, as the Objective-C assign property was: NSControl keeps its
    /// target in a cell, and this control has none.
    private weak var storedTarget: AnyObject?
    private var storedAction: Selector?
    /// The run loop retains the timer; this only points at it, as before.
    private weak var timer: Timer?
    private var bottom = false

    override var target: AnyObject? {
        get { storedTarget }
        set { storedTarget = newValue }
    }

    override var action: Selector? {
        get { storedAction }
        set { storedAction = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        timer?.invalidate()
    }

    @objc func setTop() {
        bottom = false
    }

    @objc func setBottom() {
        bottom = true
    }

    override func mouseEntered(with event: NSEvent) {
        timer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: #selector(timerFire(_:)), userInfo: nil, repeats: true) // 0.05
    }

    override func mouseExited(with event: NSEvent) {
        stopTimer()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    @objc func timerFire(_ timer: Timer) {
        sendAction(action, to: target)
        if superview == nil {
            // -mouseExited: with the current event before, which it ignored.
            stopTimer()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()

        var r = bounds
        let mins = min(r.size.width, r.size.height) * 0.45, minw = mins * 2.0.squareRoot()
        r = NSRect(x: r.origin.x + (r.size.width - minw) / 2, y: r.origin.y + (r.size.height - mins) / 2, width: minw, height: mins)

        let path = NSBezierPath()
        if bottom {
            r.origin.y -= 2
            path.move(to: NSPoint(x: r.origin.x, y: r.origin.y + r.size.height))
            path.line(to: NSPoint(x: r.origin.x + r.size.width, y: r.origin.y + r.size.height))
            path.line(to: NSPoint(x: r.origin.x + r.size.width / 2, y: r.origin.y))
        } else {
            r.origin.y += 2
            path.move(to: r.origin)
            path.line(to: NSPoint(x: r.origin.x + r.size.width, y: r.origin.y))
            path.line(to: NSPoint(x: r.origin.x + r.size.width / 2, y: r.origin.y + r.size.height))
        }

        path.close()

        NSColor.controlTextColor.setFill()
        path.fill()

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

@objc(N2PopUpMenuWindow)
final class N2PopUpMenuWindow: NSWindow {
    override var canBecomeKey: Bool {
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        if !((windowController as? N2PopUpMenuWindowController)?.interceptEvent(event) ?? false) {
            super.sendEvent(event)
        }
    }
}

@objc(N2PopUpMenuWindowView)
final class N2PopUpMenuWindowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()

        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        // What the items are drawn on: a fixed white left them white on white in dark mode (#743).
        NSColor.controlBackgroundColor.setFill()
        path.fill()

        NSGraphicsContext.restoreGraphicsState()
    }
}
