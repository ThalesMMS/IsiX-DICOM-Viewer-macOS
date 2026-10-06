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

import AppKit

/// The pop-up buttons of the smart album editor's rows. They show
/// noSelectionLabel, when one was set, while no item is selected, size to their title, open
/// contextualMenu on a right click and, in n2mode, open their menu as an
/// N2PopUpMenu, which can be filtered by typing.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/O2DicomPredicateEditorPopUpButton.h> are those of the former class.
@objc(O2DicomPredicateEditorPopUpButton)
public final class O2DicomPredicateEditorPopUpButton: NSPopUpButton {
    /// Retained, as before. The former property was atomic; it is set and
    /// read on the main thread.
    @objc public var contextualMenu: NSMenu?

    private var _noSelectionLabel: String?

    /// The former property was atomic; it is set and read on the main thread.
    @objc public var n2mode = false

    /// The N2PopUpMenu window while it is open. The former instance variable
    /// did not retain it either: N2PopUpMenu keeps it until it closes, and
    /// its NSWindowWillCloseNotification clears this.
    private weak var menuWindow: NSWindow?

    /// Shows noSelectionLabel while no item is selected. The cell drew it in
    /// -drawInteriorWithFrame:inView:, which AppKit no longer calls for this
    /// text: a new row's pop-up was blank.
    private var noSelectionField: NSTextField?

    public override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        cell = O2DicomPredicateEditorPopUpButtonCell()
    }

    /// -[NSPopUpButton initWithFrame:] is -initWithFrame:pullsDown:NO, which
    /// the former class overrode: it gets the cell too.
    public override convenience init(frame buttonFrame: NSRect) {
        self.init(frame: buttonFrame, pullsDown: false)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func rightMouseDown(with event: NSEvent) {
        // The former call passed a nil menu too; AppKit shows nothing.
        guard let contextualMenu = contextualMenu else {
            return
        }
        NSMenu.popUpContextMenu(contextualMenu, with: event, for: self, with: font)
    }

    public override func viewWillDraw() {
        updateNoSelectionField()
        super.viewWillDraw()
    }

    public override func layout() {
        super.layout()
        updateNoSelectionField()
    }

    private func updateNoSelectionField() {
        let empty = (selectedItem?.title ?? "").isEmpty
        guard let label = _noSelectionLabel, empty || noSelectionField != nil else { return }

        let field: NSTextField
        if let existing = noSelectionField {
            field = existing
        } else {
            field = NSTextField(labelWithString: "")
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
            noSelectionField = field
        }
        field.isHidden = !empty
        guard empty else { return }

        if field.stringValue != label { field.stringValue = label }
        if field.font != font { field.font = font }
        // With no item the cell's title rectangle is empty: the text goes
        // between the bezel's left edge and the arrows.
        var titleRect = cell?.titleRect(forBounds: bounds) ?? .zero
        if titleRect.width <= 0 {
            titleRect = NSRect(x: 8, y: 0, width: bounds.width - 8 - 18, height: bounds.height)
        }
        let height = field.intrinsicContentSize.height
        let frame = NSRect(x: titleRect.minX, y: (bounds.height - height) / 2, width: max(0, titleRect.width), height: height).integral
        if field.frame != frame { field.frame = frame }
    }

    public override func sizeToFit() {
        var size = frame.size
        let empty = (selectedItem?.title ?? "").isEmpty
        let str: String? = empty ? noSelectionLabel : selectedItem?.title
        // The label field has its own margins: a little more room than a title.
        size.width = ((str ?? "") as NSString).size(withAttributes: font.map { [.font: $0] }).width + (empty && _noSelectionLabel != nil ? 32 : 22)
        setFrameSize(size)
    }

    /// Retained; "null" when it was never set.
    @objc public var noSelectionLabel: String? {
        get {
            if let label = _noSelectionLabel {
                return label
            }
            return "null"
        }
        set {
            _noSelectionLabel = newValue
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if n2mode {
            NotificationCenter.default.post(name: NSPopUpButton.willPopUpNotification, object: self)

            if let menu = menu?.copy() as? NSMenu {
                for mi in menu.items where mi.title.isEmpty {
                    menu.removeItem(mi)
                }

                menuWindow = N2PopUpMenu.popUpContextMenu(menu, with: event, for: self, with: font)
            } else {
                menuWindow = nil
            }
            NotificationCenter.default.addObserver(self, selector: #selector(observeMenuWindowWillCloseNotification(_:)), name: NSWindow.willCloseNotification, object: menuWindow)
        } else {
            super.mouseDown(with: event)
        }
    }

    @objc(observeMenuWindowWillCloseNotification:)
    func observeMenuWindowWillCloseNotification(_ notification: Notification) {
        menuWindow = nil
    }

    /// The event, in the coordinates of the menu window. The former code
    /// passed event.context, which AppKit has returned nil for since 10.12.
    private func forward(_ event: NSEvent, as type: NSEvent.EventType, to menuWindow: NSWindow) {
        let r = NSRect(origin: event.locationInWindow, size: .zero)
        let location = menuWindow.convertFromScreen(event.window?.convertToScreen(r) ?? .zero).origin
        if let forwarded = NSEvent.mouseEvent(with: type, location: location, modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: menuWindow.windowNumber, context: nil, eventNumber: event.eventNumber, clickCount: event.clickCount, pressure: event.pressure) {
            menuWindow.sendEvent(forwarded)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if let menuWindow = menuWindow {
            forward(event, as: .leftMouseDragged, to: menuWindow)
        } else {
            super.mouseDragged(with: event)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if let menuWindow = menuWindow {
            forward(event, as: .leftMouseUp, to: menuWindow)
        } else {
            super.mouseUp(with: event)
        }
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { // tab
            super.keyDown(with: event)
            return
        }
        mouseDown(with: event)
    }
}

/// The buttons' cell. It drew noSelectionLabel, which the button now shows
/// as a subview; the class keeps its Objective-C name.
@objc(O2DicomPredicateEditorPopUpButtonCell)
public final class O2DicomPredicateEditorPopUpButtonCell: NSPopUpButtonCell {
}
