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
//
//  PRHOnOffButtonCell.m
//  PRHOnOffButton
//
//  Created by Peter Hosey on 2010-01-10.
//  Copyright 2010 Peter Hosey. All rights reserved.
//
//  Extended by Dain Kaplan on 2012-01-31.
//  Copyright 2012 Dain Kaplan. All rights reserved.
//

import AppKit
import Carbon

// OnOffSwitchControlCell is implemented in Swift: the Objective-C
// name, the selectors and <Horos/OnOffSwitchControlCell.h> are those of the
// former class. The header keeps the OnOffSwitchControlColors enum and
// DKCenterRect, which is defined in OnOffSwitchControlCell+CAPI.m.

// The former #defines. Those written as float literals (0.45f, 0.9f, 0.35f,
// 0.6f...) are kept as Float and widened to CGFloat, as the C promotion did,
// so that the geometry and the colours are the same to the last bit.
private let USE_COLORED_GRADIENTS = true

private let ONE_THIRD: CGFloat = 1.0 / 3.0
private let ONE_HALF: CGFloat = 1.0 / 2.0
private let TWO_THIRDS: CGFloat = 2.0 / 3.0

private let THUMB_WIDTH_FRACTION = CGFloat(Float(0.45))
private let THUMB_CORNER_RADIUS = CGFloat(Float(2.5))
private let FRAME_CORNER_RADIUS = CGFloat(Float(2.5))

private let THUMB_GRADIENT_MAX_Y_WHITE = CGFloat(Float(1.0))
private let THUMB_GRADIENT_MIN_Y_WHITE = CGFloat(Float(0.9))
private let BACKGROUND_GRADIENT_MAX_Y_WHITE = CGFloat(Float(0.5))
private let BACKGROUND_GRADIENT_MIN_Y_WHITE = TWO_THIRDS
private let BACKGROUND_SHADOW_GRADIENT_WHITE = CGFloat(Float(0.0))
private let BACKGROUND_SHADOW_GRADIENT_MAX_Y_ALPHA = CGFloat(Float(0.35))
private let BACKGROUND_SHADOW_GRADIENT_MIN_Y_ALPHA = CGFloat(Float(0.0))
private let BACKGROUND_SHADOW_GRADIENT_HEIGHT = CGFloat(Float(4.0))
private let BORDER_WHITE = CGFloat(Float(0.125))

private let THUMB_SHADOW_WHITE = CGFloat(Float(0.0))
private let THUMB_SHADOW_ALPHA = CGFloat(Float(0.5))
private let THUMB_SHADOW_BLUR = CGFloat(Float(3.0))

private let DISABLED_OVERLAY_GRAY = CGFloat(Float(1.0))
private let DISABLED_OVERLAY_ALPHA = TWO_THIRDS

@MainActor private func DOWNWARD_ANGLE_IN_DEGREES_FOR_VIEW(_ view: NSView) -> CGFloat {
    return view.isFlipped ? CGFloat(Float(90.0)) : CGFloat(Float(270.0))
}

/// The former struct PRHOOBCStuffYouWouldNeedToIncludeCarbonHeadersFor, which
/// the cell allocated with NSZoneMalloc and never freed. It is a value here.
private struct PRHOOBCStuffYouWouldNeedToIncludeCarbonHeadersFor {
    var clickTimeout: EventTime = 0
    var clickMaxDistance = HISize()
}

/// NSCell copies with NSCopyObject: the copy's object references are this
/// cell's pointers, copied bit for bit and never retained. Retain a shared one
/// once for the copy. The former class did not override -copyWithZone: and
/// never released its labels and colours, so its copies shared them the same
/// way without an over-release.
fileprivate func retainShared(_ copied: AnyObject?, _ original: AnyObject?) {
    if let shared = copied, shared === original {
        _ = Unmanaged.passUnretained(shared).retain()
    }
}

@objc(OnOffSwitchControlCell)
public final class OnOffSwitchControlCell: NSButtonCell {
    // The former ivars.
    private var tracking = false
    private var initialTrackingPoint = NSZeroPoint
    private var trackingPoint = NSZeroPoint
    private var initialTrackingTime: TimeInterval = 0
    private var trackingTime: TimeInterval = 0
    private var trackingCellFrame = NSZeroRect // Set by drawWithFrame: when tracking is true.
    private var trackingThumbCenterX: CGFloat = 0 // Set by drawWithFrame: when tracking is true.
    private var stuff = PRHOOBCStuffYouWouldNeedToIncludeCarbonHeadersFor()

    // Storage of the copy properties: object references, so that a copy of
    // the cell can retain them (see copy(with:)).
    private var onSwitchLabelStorage: NSString?
    private var offSwitchLabelStorage: NSString?
    private var customOnColorStorage: NSColor?
    private var customOffColorStorage: NSColor?

    @objc public var showsOnOffLabels: Bool = false
    @objc public var onOffSwitchControlColors: OnOffSwitchControlColors = OnOffSwitchControlDefaultColors

    /// (readwrite, copy)
    @objc public var onSwitchLabel: String! {
        get { return onSwitchLabelStorage as String? }
        set { onSwitchLabelStorage = (newValue as NSString?)?.copy() as? NSString }
    }

    /// (readwrite, copy)
    @objc public var offSwitchLabel: String! {
        get { return offSwitchLabelStorage as String? }
        set { offSwitchLabelStorage = (newValue as NSString?)?.copy() as? NSString }
    }

    /// (readwrite, retain) in the former class extension.
    @objc var customOnColor: NSColor! {
        get { return customOnColorStorage }
        set { customOnColorStorage = newValue }
    }

    /// (readwrite, retain) in the former class extension.
    @objc var customOffColor: NSColor! {
        get { return customOffColorStorage }
        set { customOffColorStorage = newValue }
    }

    public override class var prefersTrackingUntilMouseUp: Bool {
        return /*YES, YES, a thousand times*/ true
    }

    public override class var defaultFocusRingType: NSFocusRingType {
        return .exterior
    }

    @objc func furtherInit() {
        self.focusRingType = Swift.type(of: self).defaultFocusRingType
        var clickTimeout: EventTime = 0
        var clickMaxDistance = HISize()
        let err = HIMouseTrackingGetParameters(OSType(kMouseParamsSticky), &clickTimeout, &clickMaxDistance)
        stuff.clickTimeout = clickTimeout
        stuff.clickMaxDistance = clickMaxDistance
        if err != noErr {
            //Values returned by the above function call as of 10.6.3.
            stuff.clickTimeout = Double(ONE_THIRD) * kEventDurationSecond
            stuff.clickMaxDistance = HISize(width: CGFloat(Float(6.0)), height: CGFloat(Float(6.0)))
        }
        // NOTE(dk): start additions
        self.showsOnOffLabels = true
        self.onOffSwitchControlColors = OnOffSwitchControlBlueGreyColors
        self.onSwitchLabel = "ON"
        self.offSwitchLabel = "OFF"
        // NOTE(dk): end additions
    }

    public override init(imageCell image: NSImage?) {
        super.init(imageCell: image)
        furtherInit()
    }

    public override init(textCell str: String) {
        super.init(textCell: str)
        furtherInit()
    }

    //HAX: IB (I guess?) sets our focus ring type to None for some reason. Nobody asks defaultFocusRingType unless we do it (in furtherInit).
    public required init(coder decoder: NSCoder) {
        super.init(coder: decoder)
        furtherInit()
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let cell = super.copy(with: zone) as! OnOffSwitchControlCell
        retainShared(cell.onSwitchLabelStorage, onSwitchLabelStorage)
        retainShared(cell.offSwitchLabelStorage, offSwitchLabelStorage)
        retainShared(cell.customOnColorStorage, customOnColorStorage)
        retainShared(cell.customOffColorStorage, customOffColorStorage)
        return cell
    }

    @objc(thumbRectInFrame:)
    func thumbRect(inFrame cellFrame: NSRect) -> NSRect {
        var cellFrame = cellFrame
        cellFrame.size.width -= 2.0
        cellFrame.size.height -= 2.0
        cellFrame.origin.x += 1.0
        cellFrame.origin.y += 1.0

        var thumbFrame = cellFrame
        thumbFrame.size.width *= THUMB_WIDTH_FRACTION

        let state = self.state
        switch state {
        case .off:
            //Far left. We're already there; don't do anything.
            break
        case .on:
            //Far right.
            thumbFrame.origin.x += (cellFrame.size.width - thumbFrame.size.width)
        case .mixed:
            //Middle.
            thumbFrame.origin.x = (cellFrame.size.width / 2.0) - (thumbFrame.size.width / 2.0)
        default:
            break
        }

        return thumbFrame
    }

    // NOTE(dk): start additions

    @objc(setOnOffSwitchCustomOnColor:offColor:)
    public func setOnOffSwitchCustomOnColor(_ onColor: NSColor!, offColor: NSColor!) {
        self.customOffColor = offColor
        self.customOnColor = onColor
    }

    // NOTE(dk): Split this out so we can call it elsewhere.
    @objc(centerXForThumbWithFrame:)
    func centerXForThumb(withFrame cellFrame: NSRect) -> CGFloat {
        var thumbFrame = thumbRect(inFrame: cellFrame)
        if tracking {
            thumbFrame.origin.x += trackingPoint.x - initialTrackingPoint.x

            //Clamp.
            let minOrigin = cellFrame.origin.x + 1
            let maxOrigin = cellFrame.origin.x + (cellFrame.size.width - thumbFrame.size.width - 1)
            if thumbFrame.origin.x < minOrigin {
                thumbFrame.origin.x = minOrigin
            } else if thumbFrame.origin.x > maxOrigin {
                thumbFrame.origin.x = maxOrigin
            }
        }
        return NSMidX(thumbFrame)
    }

    // NOTE(dk): Center the text (as able) in the provided frame and draw it.
    @objc(drawText:withFrame:)
    func drawText(_ text: String!, withFrame textFrame: NSRect) {
        let fontSize = NSFont.systemFontSize(for: self.controlSize)
        let sysFont = NSFont.boldSystemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: sysFont,
            .foregroundColor: NSColor.white]
        let text = text as NSString?
        let textSize = text?.size(withAttributes: attributes) ?? NSZeroSize
        let textBounds = DKCenterRect(NSMakeRect(0, 0, textSize.width, textSize.height), textFrame)
        text?.draw(in: textBounds, withAttributes: attributes)
    }

    // Applies tints to the background to show the on/off state.
    @objc(tintBackgroundWithFrame:inView:)
    func tintBackground(withFrame cellFrame: NSRect, in controlView: NSView) {

        let context = NSGraphicsContext.current
        context?.saveGraphicsState()
        NSBezierPath(roundedRect: cellFrame, xRadius: FRAME_CORNER_RADIUS, yRadius: FRAME_CORNER_RADIUS).addClip()

        // NOTE(dk): Make everything to the left of the thumb one color, and to the right another.
        let thumbFrame = thumbRect(inFrame: cellFrame)
        let thumbCenterX = centerXForThumb(withFrame: cellFrame)
        var leftFrame = NSZeroRect
        var rightFrame = NSZeroRect
        let offsetWidth = thumbCenterX
        NSDivideRect(cellFrame, &leftFrame, &rightFrame, offsetWidth - cellFrame.origin.x, .minX)

        let onStartColor: NSColor?
        let onEndColor: NSColor?
        let offStartColor: NSColor?
        let offEndColor: NSColor?

        let _blueColor = NSColor(calibratedRed: 0.0, green: 0.3, blue: 1.0, alpha: CGFloat(Float(0.6)))
        let _greyColor = NSColor(calibratedRed: 1.0, green: 0.0, blue: 0.0, alpha: CGFloat(Float(0.0)))
        let _greenColor = NSColor(calibratedRed: 0.0, green: 0.7, blue: 0.0, alpha: CGFloat(Float(0.6)))
        let _redColor = NSColor(calibratedRed: 0.7, green: 0.0, blue: 0.0, alpha: CGFloat(Float(0.6)))

        switch self.onOffSwitchControlColors {
        case OnOffSwitchControlBlueGreyColors:
            onStartColor = _blueColor; onEndColor = _blueColor
            offStartColor = _greyColor; offEndColor = _greyColor
        case OnOffSwitchControlGreenRedColors:
            onStartColor = _greenColor; onEndColor = _greenColor
            offStartColor = _redColor; offEndColor = _redColor
        case OnOffSwitchControlBlueRedColors:
            onStartColor = _blueColor; onEndColor = _blueColor
            offStartColor = _redColor; offEndColor = _redColor
        case OnOffSwitchControlCustomColors:
            onStartColor = self.customOnColor; onEndColor = self.customOnColor
            offStartColor = self.customOffColor; offEndColor = self.customOffColor
        default:
            onStartColor = nil; onEndColor = nil
            offStartColor = nil; offEndColor = nil
        }

        if let onStartColor, let onEndColor, let offStartColor, let offEndColor {
            let leftBackground = NSGradient(starting: onStartColor, ending: onEndColor)
            let rightBackground = NSGradient(starting: offStartColor, ending: offEndColor)
            leftBackground?.draw(in: NSInsetRect(leftFrame, 1.0, 1.0), angle: DOWNWARD_ANGLE_IN_DEGREES_FOR_VIEW(controlView))
            rightBackground?.draw(in: NSInsetRect(rightFrame, 1.0, 1.0), angle: DOWNWARD_ANGLE_IN_DEGREES_FOR_VIEW(controlView))
        }
        context?.restoreGraphicsState()

        if self.showsOnOffLabels {
            // Left label
            var leftSizeFrame = NSZeroRect
            leftSizeFrame.origin.x = (tracking ? thumbCenterX - (thumbFrame.size.width / 2) : thumbFrame.origin.x) - (cellFrame.size.width - thumbFrame.size.width) + 2
            leftSizeFrame.origin.y = cellFrame.origin.y
            leftSizeFrame.size.width = cellFrame.size.width - thumbFrame.size.width - 2
            leftSizeFrame.size.height = cellFrame.size.height
            drawText(self.onSwitchLabel, withFrame: leftSizeFrame)

            // Right label
            var rightSizeFrame = leftSizeFrame
            rightSizeFrame.origin.x = (tracking ? thumbCenterX + (thumbFrame.size.width / 2) : thumbFrame.origin.x + thumbFrame.size.width) + 1
            rightSizeFrame.origin.y = cellFrame.origin.y
            drawText(self.offSwitchLabel, withFrame: rightSizeFrame)
        }
    }
    // NOTE(dk): end additions

    public override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        if tracking {
            trackingCellFrame = cellFrame
        }

        let context = NSGraphicsContext.current
        let quartzContext = context?.cgContext
        quartzContext?.beginTransparencyLayer(auxiliaryInfo: /*auxInfo*/ nil)

        //Draw the background, then the frame.
        let borderPath = NSBezierPath(roundedRect: NSInsetRect(cellFrame, 1.0, 1.0), xRadius: FRAME_CORNER_RADIUS, yRadius: FRAME_CORNER_RADIUS)

        NSColor(calibratedWhite: BORDER_WHITE, alpha: 1.0).setStroke()
        borderPath.stroke()

        let startColor = NSColor(calibratedWhite: BACKGROUND_GRADIENT_MAX_Y_WHITE, alpha: 1.0)
        let endColor = NSColor(calibratedWhite: BACKGROUND_GRADIENT_MIN_Y_WHITE, alpha: 1.0)
        let background = NSGradient(starting: startColor, ending: endColor)
        background?.draw(in: borderPath, angle: DOWNWARD_ANGLE_IN_DEGREES_FOR_VIEW(controlView))

        context?.saveGraphicsState()

        NSBezierPath(roundedRect: cellFrame, xRadius: FRAME_CORNER_RADIUS, yRadius: FRAME_CORNER_RADIUS).addClip()

        // NOTE(dk): start additions
        if USE_COLORED_GRADIENTS && !self.allowsMixedState {
            tintBackground(withFrame: cellFrame, in: controlView)
        }
        // NOTE(dk): end additions

        let backgroundShadow = NSGradient(starting: NSColor(calibratedWhite: BACKGROUND_SHADOW_GRADIENT_WHITE, alpha: BACKGROUND_SHADOW_GRADIENT_MAX_Y_ALPHA),
                                          ending: NSColor(calibratedWhite: BACKGROUND_SHADOW_GRADIENT_WHITE, alpha: BACKGROUND_SHADOW_GRADIENT_MIN_Y_ALPHA))
        var backgroundShadowRect = cellFrame
        if !controlView.isFlipped {
            backgroundShadowRect.origin.y += backgroundShadowRect.size.height - BACKGROUND_SHADOW_GRADIENT_HEIGHT
        }
        backgroundShadowRect.size.height = BACKGROUND_SHADOW_GRADIENT_HEIGHT
        backgroundShadow?.draw(in: backgroundShadowRect, angle: DOWNWARD_ANGLE_IN_DEGREES_FOR_VIEW(controlView))

        context?.restoreGraphicsState()

        drawInterior(withFrame: cellFrame, in: controlView)

        if !self.isEnabled {
            let color = CGColor(gray: DISABLED_OVERLAY_GRAY, alpha: DISABLED_OVERLAY_ALPHA)
            quartzContext?.setBlendMode(.lighten)
            quartzContext?.setFillColor(color)
            quartzContext?.fill(NSRectToCGRect(cellFrame))
        }
        quartzContext?.endTransparencyLayer()
    }

    public override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        //Draw the thumb.
        var thumbFrame = thumbRect(inFrame: cellFrame)

        let context = NSGraphicsContext.current
        context?.saveGraphicsState()

        var cellFrame = cellFrame
        cellFrame.size.width -= 2.0
        cellFrame.size.height -= 2.0
        cellFrame.origin.x += 1.0
        cellFrame.origin.y += 1.0
        let clipPath = NSBezierPath(roundedRect: cellFrame, xRadius: THUMB_CORNER_RADIUS, yRadius: THUMB_CORNER_RADIUS)
        clipPath.addClip()

        if tracking {
            thumbFrame.origin.x += trackingPoint.x - initialTrackingPoint.x

            //Clamp.
            let minOrigin = cellFrame.origin.x
            let maxOrigin = cellFrame.origin.x + (cellFrame.size.width - thumbFrame.size.width)
            if thumbFrame.origin.x < minOrigin {
                thumbFrame.origin.x = minOrigin
            } else if thumbFrame.origin.x > maxOrigin {
                thumbFrame.origin.x = maxOrigin
            }

            trackingThumbCenterX = centerXForThumb(withFrame: cellFrame)
        }

        let thumbPath = NSBezierPath(roundedRect: thumbFrame, xRadius: THUMB_CORNER_RADIUS, yRadius: THUMB_CORNER_RADIUS)
        let thumbShadow = NSShadow()
        thumbShadow.shadowColor = NSColor(calibratedWhite: THUMB_SHADOW_WHITE, alpha: THUMB_SHADOW_ALPHA)
        thumbShadow.shadowBlurRadius = THUMB_SHADOW_BLUR
        thumbShadow.shadowOffset = NSZeroSize
        thumbShadow.set()
        NSColor.white.setFill()
        if self.showsFirstResponder && (self.focusRingType != .none) {
            NSFocusRingPlacement.below.set() // NSSetFocusRingStyle(NSFocusRingBelow)
        }
        thumbPath.fill()
        let thumbGradient = NSGradient(starting: NSColor(calibratedWhite: THUMB_GRADIENT_MAX_Y_WHITE, alpha: 1.0), ending: NSColor(calibratedWhite: THUMB_GRADIENT_MIN_Y_WHITE, alpha: 1.0))
        thumbGradient?.draw(in: thumbPath, angle: DOWNWARD_ANGLE_IN_DEGREES_FOR_VIEW(controlView))

        context?.restoreGraphicsState()

        if tracking && (getenv("PRHOnOffButtonCellDebug") != nil) {
            let thumbCenterLine = NSBezierPath()
            thumbCenterLine.move(to: NSPoint(x: NSMidX(thumbFrame), y: thumbFrame.origin.y + thumbFrame.size.height * ONE_THIRD))
            thumbCenterLine.line(to: NSPoint(x: NSMidX(thumbFrame), y: thumbFrame.origin.y + thumbFrame.size.height * TWO_THIRDS))
            thumbCenterLine.stroke()

            let sectionLines = NSBezierPath()
            if self.allowsMixedState {
                sectionLines.move(to: NSPoint(x: cellFrame.origin.x + cellFrame.size.width * ONE_THIRD, y: NSMinY(cellFrame)))
                sectionLines.line(to: NSPoint(x: cellFrame.origin.x + cellFrame.size.width * ONE_THIRD, y: NSMaxY(cellFrame)))
                sectionLines.move(to: NSPoint(x: cellFrame.origin.x + cellFrame.size.width * TWO_THIRDS, y: NSMinY(cellFrame)))
                sectionLines.line(to: NSPoint(x: cellFrame.origin.x + cellFrame.size.width * TWO_THIRDS, y: NSMaxY(cellFrame)))
            } else {
                sectionLines.move(to: NSPoint(x: cellFrame.origin.x + cellFrame.size.width * ONE_HALF, y: NSMinY(cellFrame)))
                sectionLines.line(to: NSPoint(x: cellFrame.origin.x + cellFrame.size.width * ONE_HALF, y: NSMaxY(cellFrame)))
            }
            sectionLines.stroke()
        }
    }

    public override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        let mouseLocation = controlView.convert(event.locationInWindow, from: nil)
        return NSPointInRect(mouseLocation, cellFrame) ? [.contentArea, .trackableArea] : []
    }

    public override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        //We rely on NSControl behavior, so only start tracking if this is a control.
        tracking = true
        initialTrackingPoint = startPoint
        trackingPoint = initialTrackingPoint
        initialTrackingTime = Date.timeIntervalSinceReferenceDate
        trackingTime = initialTrackingTime
        return controlView.isKind(of: NSControl.self)
    }

    public override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
        let control = controlView.isKind(of: NSControl.self) ? (controlView as? NSControl) : nil
        if let control {
            trackingPoint = currentPoint
            //No need to update the time here as long as nothing cares about it.
            initialTrackingTime = Date.timeIntervalSinceReferenceDate
            trackingTime = initialTrackingTime
            control.drawCell(self)
            return true
        }
        tracking = false
        return false
    }

    public override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint, in controlView: NSView, mouseIsUp flag: Bool) {
        tracking = false
        trackingTime = Date.timeIntervalSinceReferenceDate

        let control = controlView.isKind(of: NSControl.self) ? (controlView as? NSControl) : nil
        if control != nil {
            let xFraction = trackingThumbCenterX / trackingCellFrame.size.width

            let isClickNotDragByTime = (trackingTime - initialTrackingTime) < stuff.clickTimeout
            let isClickNotDragBySpaceX = (stopPoint.x - initialTrackingPoint.x) < stuff.clickMaxDistance.width
            let isClickNotDragBySpaceY = (stopPoint.y - initialTrackingPoint.y) < stuff.clickMaxDistance.height
            let isClickNotDrag = isClickNotDragByTime && isClickNotDragBySpaceX && isClickNotDragBySpaceY

            if !isClickNotDrag {
                let desiredState: NSControl.StateValue

                if self.allowsMixedState {
                    if xFraction < ONE_THIRD {
                        desiredState = .off
                    } else if xFraction >= TWO_THIRDS {
                        desiredState = .on
                    } else {
                        desiredState = .mixed
                    }
                } else {
                    if xFraction < ONE_HALF {
                        desiredState = .off
                    } else {
                        desiredState = .on
                    }
                }

                //We actually need to set the state to the one *before* the one we want, because NSCell will advance it. I'm not sure how to thwart that without breaking -setNextState, which breaks AXPress and the space bar.
                var stateBeforeDesiredState = NSControl.StateValue.off
                switch desiredState {
                case .on:
                    if self.allowsMixedState {
                        stateBeforeDesiredState = .mixed
                    } else {
                        //Fall through.
                        stateBeforeDesiredState = .off
                    }
                case .mixed:
                    stateBeforeDesiredState = .off
                case .off:
                    stateBeforeDesiredState = .on
                default:
                    break
                }

                self.state = stateBeforeDesiredState
            }
        }
    }
}
