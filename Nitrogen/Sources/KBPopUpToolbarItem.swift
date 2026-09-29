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

//  KBPopUpToolbarItem.swift
//  ------------------------
//
//  Created by Keith Blount on 14/05/2006.
//  Copyright 2006 Keith Blount. All rights reserved.
//
//  Provides a toolbar item that performs its given action if clicked, or displays a pop-up menu
//  (if it has one) if held down for over half a second.
//
// Implemented in Swift since #709; the Objective-C names, the selectors and
// <Horos/KBPopUpToolbarItem.h> are those of the former classes.

import AppKit
import ObjectiveC

private let backgroundInset: Float = 1.5

/// Sends `selector`, a `-(BOOL)validate…:(id)item` method the receiver was
/// checked to respond to. The receiver is any object, as the former
/// `respondsToSelector:` test allowed: it need not adopt a validation protocol.
private func sendValidation(_ receiver: AnyObject, _ selector: Selector, _ item: AnyObject) -> Bool {
    typealias Validation = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
    guard let receiverClass = object_getClass(receiver),
          let implementation = class_getMethodImplementation(receiverClass, selector) else { return false }
    return unsafeBitCast(implementation, to: Validation.self)(receiver, selector, item).boolValue
}

private func objectResponds(_ object: AnyObject?, to selector: Selector) -> Bool {
    (object as? NSObjectProtocol)?.responds(to: selector) ?? false
}

@objc(KBDelayedPopUpButtonCell)
public final class KBDelayedPopUpButtonCell: NSButtonCell {
    @objc public var arrowPath: NSBezierPath?

    public override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! KBDelayedPopUpButtonCell
        // NSCell copies with NSCopyObject: the copy's arrowPath is our pointer,
        // copied bit for bit and never retained. Retain it once so that the
        // assignment below releases what it does not own. The former code
        // overwrote the ivar without releasing it, for the same reason.
        if let shared = copy.arrowPath, shared === arrowPath {
            _ = Unmanaged.passUnretained(shared).retain()
        }
        copy.arrowPath = arrowPath?.copy(with: zone) as? NSBezierPath
        return copy
    }

    private func menuPosition(for cellFrame: NSRect, in controlView: NSView) -> NSPoint {
        var result = controlView.convert(cellFrame.origin, to: nil)
        result.x += 1.0
        result.y -= cellFrame.size.height + 5.5
        return result
    }

    public override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: cellFrame, in: controlView)

        if menu != nil && isEnabled {

            if arrowPath == nil {
                let frameSize = cellFrame.size

                let path = NSBezierPath()

                // float, as the former code computed the arrow.
                let arrowWidth = Float(NSFont.systemFontSize(for: controlSize) * 0.6)
                let arrowHeight = Float(NSFont.systemFontSize(for: controlSize) * 0.5)

                let x = Float(frameSize.width - CGFloat(backgroundInset) - CGFloat(arrowWidth) + cellFrame.origin.x)
                let y = Float(frameSize.height - CGFloat(backgroundInset) - CGFloat(arrowHeight) + cellFrame.origin.y)

                path.move(to: NSMakePoint(CGFloat(x), CGFloat(y)))
                path.line(to: NSMakePoint(CGFloat(x + arrowWidth), CGFloat(y)))
                path.line(to: NSMakePoint(CGFloat(x) + CGFloat(arrowWidth) / 2.0, CGFloat(y + arrowHeight)))
                path.close()

                arrowPath = path
            }

            // A near-black arrow vanished on the dark toolbar and palette; the
            // label colour is near-black under a light appearance and light
            // under a dark one.
            NSColor.labelColor.set()
            arrowPath?.fill()
        }
    }

    private func showMenu(for theEvent: NSEvent, controlView: NSView, cellFrame: NSRect) {
        let menuPosition = menuPosition(for: cellFrame, in: controlView)

        // Create event for pop up menu with adjusted mouse position
        // (-[NSEvent context] always returns nil since macOS 10.12, and the
        // factory ignores the argument.)
        guard let menu,
              let menuEvent = NSEvent.mouseEvent(with: theEvent.type,
                                                 location: menuPosition,
                                                 modifierFlags: theEvent.modifierFlags,
                                                 timestamp: theEvent.timestamp,
                                                 windowNumber: theEvent.windowNumber,
                                                 context: nil,
                                                 eventNumber: theEvent.eventNumber,
                                                 clickCount: theEvent.clickCount,
                                                 pressure: theEvent.pressure) else { return }

        NSMenu.popUpContextMenu(menu, with: menuEvent, for: controlView)
    }

    public override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView,
                                    untilMouseUp: Bool) -> Bool {
        var result = false
        var endDate: Date
        var currentPoint = theEvent.locationInWindow
        var done = false

        if menu != nil {

            let frameSize = cellFrame.size

            // check if mouse is over menu arrow
            let localPoint = controlView.convert(currentPoint, from: nil)

            let arrowWidth = Float(NSFont.systemFontSize(for: controlSize) * 0.6)
            let arrowHeight = Float(NSFont.systemFontSize(for: controlSize) * 0.5)

            let x = Float(frameSize.width - CGFloat(backgroundInset) - CGFloat(arrowWidth))
            let y = Float(frameSize.height - CGFloat(backgroundInset) - CGFloat(arrowHeight))

            if localPoint.x >= CGFloat(x) && localPoint.y >= CGFloat(y) {
                showMenu(for: theEvent, controlView: controlView, cellFrame: cellFrame)
                return true
            }
        }

        let trackContinously = startTracking(at: currentPoint, in: controlView)

        // Catch next mouse-dragged or mouse-up event until timeout
        var mouseIsUp = false
        while !done {
            let lastPoint = currentPoint

            // Set up timer for pop-up menu if we have one
            if menu != nil {
                endDate = Date(timeIntervalSinceNow: 0.4)
            } else {
                endDate = Date.distantFuture
            }

            let event = NSApp.nextEvent(matching: [.leftMouseUp, .leftMouseDragged],
                                        until: endDate,
                                        inMode: .eventTracking,
                                        dequeue: true)

            if let event { // Mouse event
                currentPoint = event.locationInWindow

                // Send continueTracking.../stopTracking...
                if trackContinously {
                    if !continueTracking(last: lastPoint, current: currentPoint, in: controlView) {
                        done = true
                        stopTracking(last: lastPoint, current: currentPoint, in: controlView, mouseIsUp: mouseIsUp)
                    }
                    if isContinuous, let action {
                        NSApp.sendAction(action, to: target, from: controlView)
                    }
                }

                mouseIsUp = event.type == .leftMouseUp
                done = done || mouseIsUp

                if untilMouseUp {
                    result = mouseIsUp
                } else {
                    // Check if the mouse left our cell rect
                    result = NSPointInRect(controlView.convert(currentPoint, from: nil), cellFrame)
                    if !result {
                        done = true
                    }
                }

                if done && result && !isContinuous, let action {
                    NSApp.sendAction(action, to: target, from: controlView)
                }

            } else { // Show menu
                done = true
                result = true
                showMenu(for: theEvent, controlView: controlView, cellFrame: cellFrame)
            }
        }
        return result
    }
}

@objc(KBDelayedPopUpButton)
public final class KBDelayedPopUpButton: NSButton {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if !(cell is KBDelayedPopUpButtonCell) {
            let title = self.title
            cell = KBDelayedPopUpButtonCell(textCell: title)
            cell?.controlSize = .regular
        }
    }

    /// The former class did not override -initWithCoder: either.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

@objc(KBPopUpToolbarItem)
public final class KBPopUpToolbarItem: NSToolbarItem {
    // Note that we make no assumptions about the retain/release of the toolbar item's view, just to be sure -
    // we therefore retain our button view until we are dealloc'd.
    private let button: KBDelayedPopUpButton
    private var smallImage: NSImage?
    private var regularImage: NSImage?

    public override init(itemIdentifier ident: NSToolbarItem.Identifier) {
        button = KBDelayedPopUpButton(frame: NSMakeRect(0, 0, 42, 32))
        super.init(itemIdentifier: ident)
        button.setButtonType(.momentaryChange)
        button.isBordered = false

        button.imagePosition = .imageLeft
        // A button made in code draws its image unscaled. Artwork larger than
        // the button, such as a page-sized PDF, then showed only a crop of its
        // middle, a grey band in the Customize Toolbar palette.
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        view = button
        minSize = NSMakeSize(42, 32)
        maxSize = NSMakeSize(42, 32)
    }

    private var popupCell: NSCell? {
        (view as? NSControl)?.cell
    }

    @objc public var menu: NSMenu? {
        get {
            popupCell?.menu
        }
        set {
            popupCell?.menu = newValue

            // Also set menu form representation -
            // This is used in the toolbar overflow menu but also, more importantly, to display a menu in text-only mode.
            let menuFormRep = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            menuFormRep.submenu = newValue
            menuFormRepresentation = menuFormRep
        }
    }

    public override var action: Selector? {
        get { popupCell?.action }
        set { popupCell?.action = newValue }
    }

    public override var target: AnyObject? {
        get { popupCell?.target }
        set { popupCell?.target = newValue }
    }

    public override var image: NSImage? {
        get {
            popupCell?.image
        }
        set {
            // Sizing both edges to the box squashed non-square artwork; scale the
            // longest edge instead so the icon keeps its proportions at each size mode.
            regularImage = ToolbarImage.scaled(newValue, toLongestEdge: 32)
            smallImage = ToolbarImage.scaled(newValue, toLongestEdge: 24)

            // The artwork as given waited for -validate to be sized. The
            // Customize Toolbar palette does not validate its items, so it
            // showed the artwork at its authoring size.
            popupCell?.image = toolbar?.sizeMode == .small ? smallImage : regularImage
        }
    }

    public override var toolTip: String? {
        get { view?.toolTip }
        set { view?.toolTip = newValue }
    }

    public override func validate() {
        // First, make sure the toolbar image size fits the toolbar size mode; there must be a better place to do this!
        let sizeMode = toolbar?.sizeMode

        if sizeMode == .small {
            popupCell?.image = smallImage
        } else if sizeMode == .regular {
            popupCell?.image = regularImage
        }

        let validateToolbarItem = #selector(NSToolbarItemValidation.validateToolbarItem(_:))

        if let action {
            if let target {
                if objectResponds(target, to: validateToolbarItem) {
                    isEnabled = sendValidation(target, validateToolbarItem, self)
                } else {
                    isEnabled = objectResponds(target, to: action)
                }
            } else {
                isEnabled = objectResponds(view?.window?.firstResponder, to: action)
            }
        } else if let delegate = toolbar?.delegate {
            var enabled = true

            if objectResponds(delegate, to: validateToolbarItem) {
                enabled = sendValidation(delegate, validateToolbarItem, self)
            } else if objectResponds(delegate, to: #selector(NSUserInterfaceValidations.validateUserInterfaceItem(_:))) {
                enabled = sendValidation(delegate, #selector(NSUserInterfaceValidations.validateUserInterfaceItem(_:)), self)
            }

            isEnabled = enabled
        } else {
            super.validate()
        }
    }
}
