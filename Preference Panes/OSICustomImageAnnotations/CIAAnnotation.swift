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

/// The rounded corner of an annotation, ROUNDED_CORNER_SIZE of the former file.
private let annotationCornerSize: CGFloat = 3.0

/// +[NSBezierPath bezierPathWithRoundedRect:cornerRadius:], the NSBezierPath
/// (RoundRect) category of GLString.m that CIAAnnotation.m and CIAPlaceHolder.m
/// called through NSBezierPath_RoundRect.h. Same arithmetic, `float` radius
/// included; Swift does not see that category, and bringing GLString.h into
/// the bridging header would expose OpenGL to every Objective-C file that
/// imports Horos-Swift.h.
func ciaRoundedRectPath(_ rect: NSRect, cornerRadius radius: Float) -> NSBezierPath {
    let result = NSBezierPath()
    if !NSIsEmptyRect(rect) {
        if radius > 0.0 {
            // Clamp radius to be no larger than half the rect's width or height.
            let clampedRadius = Float(min(CGFloat(radius), 0.5 * min(rect.size.width, rect.size.height)))

            let topLeft = NSMakePoint(NSMinX(rect), NSMaxY(rect))
            let topRight = NSMakePoint(NSMaxX(rect), NSMaxY(rect))
            let bottomRight = NSMakePoint(NSMaxX(rect), NSMinY(rect))

            result.move(to: NSMakePoint(NSMidX(rect), NSMaxY(rect)))
            result.appendArc(from: topLeft, to: rect.origin, radius: CGFloat(clampedRadius))
            result.appendArc(from: rect.origin, to: bottomRight, radius: CGFloat(clampedRadius))
            result.appendArc(from: bottomRight, to: topRight, radius: CGFloat(clampedRadius))
            result.appendArc(from: topRight, to: topLeft, radius: CGFloat(clampedRadius))
            result.close()
        } else {
            // When radius == 0.0, this degenerates to the simple case of a plain rectangle.
            result.appendRect(rect)
        }
    }
    return result
}

/// -[NSAttributedString initWithString:attributes:], which raised for a nil
/// string: the former code passed its ivars unchecked.
func ciaAttributedString(_ string: String?, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
    guard let string = string else {
        NSException(name: .invalidArgumentException,
                    reason: "NSConcreteAttributedString initWithString:: nil value",
                    userInfo: nil).raise()
        return NSAttributedString()
    }
    return NSAttributedString(string: string, attributes: attributes)
}

// The former file's NSColor (randomColor) category stays Objective-C, in
// CIAAnnotation+CAPI.m: it calls rand(), which Swift does not import.

/// An annotation of the custom annotations layout: a titled token list the user
/// drags into a CIAPlaceHolder.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// CIAAnnotation.h are those of the former class.
@objc(CIAAnnotation)
public final class CIAAnnotation: NSView {
    private var isSelectedFlag = false
    private var mouseDownLocationValue = NSPoint.zero
    private var colorValue: NSColor?
    private var backgroundColorValue: NSColor?
    private var titleValue: String?
    private var contentValue: NSMutableArray?
    private var isOrientationWidgetValue = false
    private var animatedFrameOriginValue = NSPoint.zero
    private var widthValue: Float = 0

    /// Not retained, as the former `assign` ivar; the place holder, a subview of
    /// the layout view, outlives the annotations it holds.
    @objc public weak var placeHolder: CIAPlaceHolder?

    @objc public class func defaultSize() -> NSSize {
        return NSMakeSize(75, 22)
    }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        isSelectedFlag = false
        placeHolder = nil
        colorValue = NSColor.orange
        backgroundColorValue = NSColor.red
        self.title = "Annotation"
        contentValue = NSMutableArray()
        isOrientationWidgetValue = false
        widthValue = 0
    }

    /// The former class had no -initWithCoder: of its own: NSView's left every
    /// ivar zero. Annotations are only made in code.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Not in the header: the drawing and the mouse follow the enabled state of
    /// the nearest enclosing control, the layout view.
    @objc public var isEnabled: Bool {
        var view = superview
        while let current = view, !current.isKind(of: NSControl.self) {
            view = current.superview
        }
        return (view as? NSControl)?.isEnabled ?? false
    }

    public override func draw(_ dirtyRect: NSRect) {
        // Lay the annotation out from the view's own bounds. The rectangle passed
        // in is the area needing redraw, which can be larger than the view, and
        // since macOS 14 NSView no longer clips drawing to its bounds: using it
        // painted the whole preference pane in the annotation's colour.
        var rect = bounds
        rect = NSMakeRect(rect.origin.x + 2.0, rect.origin.y + 4.0, rect.size.width - 7.0, rect.size.height - 7.0)

        let borderFrame = ciaRoundedRectPath(rect, cornerRadius: Float(annotationCornerSize))

        let theShadow = NSShadow()
        theShadow.shadowOffset = NSMakeSize(3.0, -3.0)
        theShadow.shadowBlurRadius = 3.0
        theShadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        NSGraphicsContext.saveGraphicsState()
        theShadow.set()

        // background
        colorValue?.set()
        if isSelectedFlag {
            backgroundColorValue?.set()
        }
        if !isEnabled || isOrientationWidgetValue {
            NSColor.gray.set()
        }
        borderFrame.fill()

        NSGraphicsContext.restoreGraphicsState()

        // border
        borderFrame.lineWidth = 1.0
        if isSelectedFlag {
            borderFrame.lineWidth = 2.0
        }

        NSColor.red.set()
        if !isEnabled || isOrientationWidgetValue {
            NSColor.darkGray.set()
        }
        borderFrame.stroke()

        // text
        var attrsDictionary: [NSAttributedString.Key: Any] = [:]
        attrsDictionary[.foregroundColor] = NSColor.white

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.setParagraphStyle(NSParagraphStyle.default)
        paragraphStyle.alignment = .center
        attrsDictionary[.paragraphStyle] = paragraphStyle

        attrsDictionary[.font] = NSFont.systemFont(ofSize: 10.0)

        let contentText = ciaAttributedString(titleValue, attributes: attrsDictionary)

        contentText.draw(in: NSMakeRect(rect.origin.x, rect.origin.y - 1.0, rect.size.width, rect.size.height))
    }

    public override func mouseDragged(with theEvent: NSEvent) {
        if !isEnabled || isOrientationWidgetValue { return }
        NotificationCenter.default.post(name: NSNotification.Name("CIAAnnotationMouseDraggedNotification"), object: self)

        let eventLocation = theEvent.locationInWindow
        let eventLocationInView = convert(eventLocation, from: nil)

        // The former code kept these in `float`.
        let deltaX = Float(eventLocationInView.x - mouseDownLocationValue.x)
        let deltaY = Float(mouseDownLocationValue.y - eventLocationInView.y)
        let newX = Float(frame.origin.x + CGFloat(deltaX))
        let newY = Float(frame.origin.y - CGFloat(deltaY))

        var newOrigin = frame.origin
        animatedFrameOriginValue = newOrigin

        let superviewSize = superview?.frame.size ?? .zero
        var shouldDisplay = false
        if newX > 0.0 && CGFloat(newX) + frame.size.width < superviewSize.width {
            newOrigin.x = CGFloat(newX)
            shouldDisplay = true
        }

        if newY > 0.0 && CGFloat(newY) + frame.size.height < superviewSize.height {
            newOrigin.y = CGFloat(newY)
            shouldDisplay = true
        }

        if shouldDisplay {
            setFrameOrigin(newOrigin)
            superview?.needsDisplay = true
        }
    }

    public override func mouseDown(with theEvent: NSEvent) {
        if !isEnabled || isOrientationWidgetValue { return }
        NotificationCenter.default.post(name: NSNotification.Name("CIAAnnotationMouseDownNotification"), object: self)
        let eventLocation = theEvent.locationInWindow
        mouseDownLocationValue = convert(eventLocation, from: nil)
    }

    @objc public var mouseDownLocation: NSPoint {
        get { return mouseDownLocationValue }
        set { mouseDownLocationValue = newValue }
    }

    @objc public func recomputeMouseDownLocation() {
        let eventLocation = NSApplication.shared.currentEvent?.locationInWindow ?? .zero
        mouseDownLocationValue = convert(eventLocation, from: nil)
    }

    public override func mouseUp(with theEvent: NSEvent) {
        if !isEnabled || isOrientationWidgetValue { return }
        NotificationCenter.default.post(name: NSNotification.Name("CIAAnnotationMouseUpNotification"), object: self)
    }

    /// The former class had this setter and no getter.
    @objc(setIsSelected:)
    public func setIsSelected(_ boo: Bool) {
        isSelectedFlag = boo
    }

    /// An empty title is ignored. The width follows the title.
    @objc public var title: String! {
        get { return titleValue }
        set {
            if let aTitle = newValue, (aTitle as NSString).isEqual(to: "") { return }
            titleValue = newValue

            let attrsDictionary: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.0)]
            let contentText = ciaAttributedString(titleValue, attributes: attrsDictionary)
            let textBounds = contentText.boundingRect(with: bounds.size, options: .usesDeviceMetrics)

            setFrameSize(NSMakeSize(textBounds.size.width + 6.0 * annotationCornerSize, frame.size.height))
            widthValue = Float(textBounds.size.width + 6.0 * annotationCornerSize)
            needsDisplay = true
        }
    }

    /// The tokens, strings. The array itself is handed out and edited in place.
    @objc public var content: NSMutableArray! {
        return contentValue
    }

    /// Replaces the tokens; nil empties them, as -[NSMutableArray setArray:nil].
    @objc(setContent:)
    public func setContent(_ newContent: NSArray!) {
        guard let contentValue = contentValue else { return }
        if let newContent = newContent {
            contentValue.setArray(newContent as! [Any])
        } else {
            contentValue.removeAllObjects()
        }
    }

    @objc public func countOfContent() -> Int32 {
        return Int32(truncatingIfNeeded: contentValue?.count ?? 0)
    }

    @objc(objectInContentAtIndex:)
    public func objectInContent(at index: UInt32) -> String! {
        return contentValue?.object(at: Int(index)) as? String
    }

    @objc(getContent:range:)
    public func getContent(_ strings: AutoreleasingUnsafeMutablePointer<NSString?>, range inRange: NSRange) {
        // -[NSArray getObjects:range:], which Swift does not import: it raised
        // for a range past the end, as -subarrayWithRange: does, and wrote the
        // objects unretained.
        guard let contentValue = contentValue else { return }
        let objects = contentValue.subarray(with: inRange)
        let buffer = UnsafeMutableRawPointer(strings).assumingMemoryBound(to: Unmanaged<AnyObject>?.self)
        for (offset, object) in objects.enumerated() {
            buffer[offset] = Unmanaged.passUnretained(object as AnyObject)
        }
    }

    @objc(insertObject:inContentAtIndex:)
    public func insertObject(_ string: String, inContentAt index: UInt32) {
        contentValue?.insert(string, at: Int(index))
    }

    @objc(removeObjectFromContentAtIndex:)
    public func removeObjectFromContent(at index: UInt32) {
        contentValue?.removeObject(at: Int(index))
    }

    @objc public var isOrientationWidget: Bool {
        get { return isOrientationWidgetValue }
        set { isOrientationWidgetValue = newValue }
    }

    @objc public var width: Float {
        return widthValue
    }

    public override func setFrameOrigin(_ newOrigin: NSPoint) {
        animatedFrameOriginValue = newOrigin
        super.setFrameOrigin(newOrigin)
    }

    /// Animated through the animator proxy (CIAPlaceHolder): `dynamic`, so a
    /// Swift call on the proxy is sent as a message and not made directly.
    @objc public dynamic var animatedFrameOrigin: NSPoint {
        get { return animatedFrameOriginValue }
        set {
            animatedFrameOriginValue = newValue
            super.setFrameOrigin(newValue)
            superview?.needsDisplay = true
        }
    }

    public override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "animatedFrameOrigin" {
            return CABasicAnimation()
        } else {
            return super.defaultAnimation(forKey: key)
        }
    }
}
