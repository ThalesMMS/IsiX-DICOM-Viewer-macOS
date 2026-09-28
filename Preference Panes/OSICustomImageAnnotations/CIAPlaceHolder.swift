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
import QuartzCore

// TOP_MARGIN, BOTTOM_MARGIN, RIGHT_MARGIN and ROUNDED_CORNER_SIZE of the former file.
private let topMargin: CGFloat = 5.0
private let bottomMargin: CGFloat = 5.0
private let rightMargin: CGFloat = 4.0
private let placeHolderCornerSize: Float = 5.0

/// One of the eight drop areas of the custom annotations layout, holding a
/// column of CIAAnnotation views.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// CIAPlaceHolder.h are those of the former class. The C enums
/// CIAPlaceHolderAlignement and CIAPlaceHolderOrientationWidgetPosition stay
/// declared in CIAPlaceHolder.h.
@objc(CIAPlaceHolder)
public final class CIAPlaceHolder: NSView {
    private var hasFocusValue = false
    private var annotations = NSMutableArray()
    private var animatedFrameSizeValue = NSSize.zero
    private var align = CIAPlaceHolderAlignLeft
    private var orientationWidgetPosition = CIAPlaceHolderOrientationWidgetTop

    @objc public class func defaultSize() -> NSSize {
        let annotationSize = CIAAnnotation.defaultSize()
        return NSMakeSize(annotationSize.width + 5 + rightMargin, annotationSize.height + topMargin + bottomMargin)
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        hasFocusValue = false
        annotations = NSMutableArray(capacity: 0)
        animatedFrameSizeValue = frame.size
        align = CIAPlaceHolderAlignLeft
        orientationWidgetPosition = CIAPlaceHolderOrientationWidgetTop
    }

    /// The former class had no -initWithCoder: of its own. Place holders are
    /// only made in code, by CIALayoutView.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func draw(_ dirtyRect: NSRect) {
        // The placeholder outline follows the view, not the area needing redraw:
        // since macOS 14 NSView no longer clips drawing to its bounds.
        var rect = bounds
        rect = NSMakeRect(rect.origin.x + 2.0, rect.origin.y + 2.0, rect.size.width - 4.0, rect.size.height - 4.0)

        let borderFrame = ciaRoundedRectPath(rect, cornerRadius: placeHolderCornerSize)

        var array: [CGFloat] = [
            5.0, //segment painted with stroke color
            2.0, //segment not painted with a color
        ]
        borderFrame.setLineDash(&array, count: 2, phase: 0.0)

        if hasFocusValue {
            NSColor.controlHighlightColor.withAlphaComponent(0.5).set()
        } else {
            // The half-white wash was invisible over the light appearance's white
            // control background and a bright block over the dark one. This is the
            // semantic colour for a subtly marked area and reads in both.
            NSColor.unemphasizedSelectedContentBackgroundColor.set()
        }
        borderFrame.fill()

        borderFrame.lineWidth = 2.0
        NSColor.gray.set()
        borderFrame.stroke()

        // text: the former code prepared these attributes and drew nothing.
        var attrsDictionary: [NSAttributedString.Key: Any] = [:]
        attrsDictionary[.foregroundColor] = NSColor.lightGray

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.setParagraphStyle(NSParagraphStyle.default)
        paragraphStyle.alignment = .center
        attrsDictionary[.paragraphStyle] = paragraphStyle

        attrsDictionary[.font] = NSFont.systemFont(ofSize: 10.0)
        _ = attrsDictionary
    }

    @objc public var hasFocus: Bool {
        get { return hasFocusValue }
        set { hasFocusValue = newValue }
    }

    @objc public func hasAnnotations() -> Bool {
        return annotations.count > 0
    }

    @objc(removeAnnotation:)
    public func removeAnnotation(_ anAnnotation: CIAAnnotation!) {
        if let anAnnotation = anAnnotation {
            annotations.remove(anAnnotation)
        }
        anAnnotation?.placeHolder = nil

        alignAnnotations()
        updateFrameAroundAnnotations()
    }

    @objc(addAnnotation:)
    public func addAnnotation(_ anAnnotation: CIAAnnotation!) {
        addAnnotation(anAnnotation, animate: true)
    }

    @objc(addAnnotation:animate:)
    public func addAnnotation(_ anAnnotation: CIAAnnotation!, animate: Bool) {
        insertAnnotation(anAnnotation, at: Int32(truncatingIfNeeded: annotations.count), animate: animate)
    }

    @objc(insertAnnotation:atIndex:)
    public func insertAnnotation(_ anAnnotation: CIAAnnotation!, at index: Int32) {
        insertAnnotation(anAnnotation, at: index, animate: true)
    }

    @objc(insertAnnotation:atIndex:animate:)
    public func insertAnnotation(_ anAnnotation: CIAAnnotation!, at index: Int32, animate: Bool) {
        var index = index
        anAnnotation?.placeHolder?.removeAnnotation(anAnnotation)

        if orientationWidgetPosition == CIAPlaceHolderOrientationWidgetTop {
            if index == 0 && annotations.count > 0 {
                if (annotations.object(at: 0) as! CIAAnnotation).isOrientationWidget {
                    index = 1
                }
            }
        } else if orientationWidgetPosition == CIAPlaceHolderOrientationWidgetBottom {
            if Int(index) == annotations.count && annotations.count > 0 {
                if (annotations.lastObject as! CIAAnnotation).isOrientationWidget {
                    index = Int32(truncatingIfNeeded: annotations.count - 1)
                }
            }
        }

        if anAnnotation?.isOrientationWidget ?? false {
            if orientationWidgetPosition == CIAPlaceHolderOrientationWidgetTop {
                annotations.insert(anAnnotation!, at: 0)
            } else if orientationWidgetPosition == CIAPlaceHolderOrientationWidgetBottom {
                annotations.add(anAnnotation!)
            }
        } else if index >= 0 && Int(index) < annotations.count {
            // The former `index<[annotationsArray count]` compared unsigned: a
            // negative index was past the end and appended.
            insertOrRaise(anAnnotation, at: Int(index))
        } else {
            insertOrRaise(anAnnotation, at: nil)
        }

        anAnnotation?.placeHolder = self

        alignAnnotations()
        updateFrameAroundAnnotations(withAnimation: animate)
    }

    /// -insertObject:atIndex: and -addObject: raised for nil.
    private func insertOrRaise(_ anAnnotation: CIAAnnotation?, at index: Int?) {
        guard let anAnnotation = anAnnotation else {
            NSException(name: .invalidArgumentException,
                        reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                        userInfo: nil).raise()
            return
        }
        if let index = index {
            annotations.insert(anAnnotation, at: index)
        } else {
            annotations.add(anAnnotation)
        }
    }

    @objc(containsAnnotation:)
    public func containsAnnotation(_ anAnnotation: CIAAnnotation!) -> Bool {
        guard let anAnnotation = anAnnotation else { return false }
        return annotations.contains(anAnnotation)
    }

    /// The array itself: CIALayoutController empties it in place.
    @objc public func annotationsArray() -> NSMutableArray! {
        return annotations
    }

    @objc public func alignAnnotations() {
        alignAnnotations(withAnimation: false)
    }

    @objc(alignAnnotationsWithAnimation:)
    public func alignAnnotations(withAnimation animate: Bool) {
        // The former code kept the positions in `float`.
        var positionX0: Float = 0
        var positionX: Float
        var previousY: Float

        if align == CIAPlaceHolderAlignLeft {
            positionX0 = Float(frame.origin.x + 3.0)
        } else if align == CIAPlaceHolderAlignCenter {
            positionX0 = Float(frame.origin.x + frame.size.width / 2.0)
        } else if align == CIAPlaceHolderAlignRight {
            positionX0 = Float(frame.origin.x + frame.size.width)
        }

        previousY = Float(frame.origin.y + frame.size.height - topMargin)

        if animate {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0.001
        }

        var i = 0
        while i < annotations.count {
            let currentAnnotation = annotations.object(at: i) as! CIAAnnotation

            positionX = positionX0
            if align == CIAPlaceHolderAlignCenter {
                positionX = Float(CGFloat(positionX) - currentAnnotation.frame.size.width / 2.0)
            } else if align == CIAPlaceHolderAlignRight {
                positionX = Float(CGFloat(positionX) - currentAnnotation.frame.size.width)
            }

            let newOrigin: NSPoint
            if i == 0 {
                newOrigin = NSMakePoint(CGFloat(positionX), CGFloat(previousY) - currentAnnotation.frame.size.height)
            } else {
                newOrigin = NSMakePoint(CGFloat(positionX), CGFloat(previousY) - currentAnnotation.frame.size.height + 2.0)
            }

            if animate {
                // animatedFrameOrigin is `dynamic`: this is a message to the proxy.
                currentAnnotation.animator().animatedFrameOrigin = newOrigin
            } else {
                currentAnnotation.setFrameOrigin(newOrigin)
            }

            previousY = Float(currentAnnotation.frame.origin.y)
            i += 1
        }

        if animate { NSAnimationContext.endGrouping() }

        needsDisplay = true
    }

    @objc public func updateFrameAroundAnnotations() {
        updateFrameAroundAnnotations(withAnimation: true)
    }

    @objc(updateFrameAroundAnnotationsWithAnimation:)
    public func updateFrameAroundAnnotations(withAnimation animate: Bool) {
        var totalHeight: Float = 0.0
        var maxWidth = Float(CIAPlaceHolder.defaultSize().width - rightMargin)
        var i = 0
        while i < annotations.count {
            let currentAnnotation = annotations.object(at: i) as! CIAAnnotation
            if i == 0 {
                totalHeight = Float(CGFloat(totalHeight) + currentAnnotation.frame.size.height)
            } else {
                totalHeight = Float(CGFloat(totalHeight) + currentAnnotation.frame.size.height - 2.0)
            }
            if currentAnnotation.width > maxWidth { maxWidth = currentAnnotation.width }
            i += 1
        }

        totalHeight = Float(CGFloat(totalHeight) + topMargin + bottomMargin)
        maxWidth = Float(CGFloat(maxWidth) + rightMargin)

        if CGFloat(totalHeight) < CIAPlaceHolder.defaultSize().height {
            totalHeight = Float(CIAPlaceHolder.defaultSize().height)
        }

        let newSize = NSMakeSize(CGFloat(maxWidth), CGFloat(totalHeight))

        if newSize.height != frame.size.height || newSize.width != frame.size.width {
            if animate {
                NSAnimationContext.current.duration = 0.1
                // animatedFrameSize is `dynamic`: this is a message to the proxy.
                animator().animatedFrameSize = newSize
            } else {
                animatedFrameSize = newSize
            }
        }
        (superview as? CIALayoutView)?.updatePlaceHolderOrigins()
    }

    /// Animated through the animator proxy: `dynamic`, so a Swift call on the
    /// proxy is sent as a message and not made directly.
    @objc public dynamic var animatedFrameSize: NSSize {
        get { return animatedFrameSizeValue }
        set {
            animatedFrameSizeValue = newValue
            setFrameSize(animatedFrameSizeValue)
            superview?.needsDisplay = true
        }
    }

    public override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "animatedFrameSize" {
            return CABasicAnimation()
        } else {
            return super.defaultAnimation(forKey: key)
        }
    }

    /// Moves the annotations with the place holder, then aligns them.
    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        let oldOrigin = frame.origin
        let shift = NSPoint(x: newOrigin.x - oldOrigin.x, y: newOrigin.y - oldOrigin.y)

        var i = 0
        while i < annotations.count {
            let annotation = annotations.object(at: i) as! NSView
            var origin = annotation.frame.origin
            origin.x += shift.x
            origin.y -= shift.y
            annotation.setFrameOrigin(origin)
            i += 1
        }

        super.setFrameOrigin(newOrigin)
        alignAnnotations()
    }

    @objc(setAlignment:)
    public func setAlignment(_ alignement: CIAPlaceHolderAlignement) {
        align = alignement
    }

    @objc(setOrientationWidgetPosition:)
    public func setOrientationWidgetPosition(_ pos: CIAPlaceHolderOrientationWidgetPosition) {
        orientationWidgetPosition = pos
    }
}
