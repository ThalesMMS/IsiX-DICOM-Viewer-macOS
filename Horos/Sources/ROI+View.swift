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

// What a ROI asks of the view it is drawn in, of the view's window and of the
// text overlay, by the Objective-C selectors they answer.
//
// The viewer draws its ROIs and passes them its mouse events on the main
// thread, where AppKit isolates those classes. A ROI is not isolated: images
// are measured, archived and decoded on other threads, and plugins call it
// from any. It sends these messages as the Objective-C ROI did, through
// these protocols, which name the selectors without the main actor's
// isolation; the objects are those that answered them before.

/// The DCMView of a ROI.
@objc protocol ROIDrawingView: NSObjectProtocol {
    var curDCM: DCMPix? { get }
    @objc(window) var roiWindow: ROIDrawingWindow? { get }
    var drawingFrameRect: NSRect { get }
    @objc(blendingView) var roiBlendingView: ROIDrawingView? { get }
    var origin: NSPoint { get }
    var rotation: Float { get }
    var xFlipped: Bool { get }
    var yFlipped: Bool { get }
    var flippedData: Bool { get }
    var curImage: Int { get }
    var dcmPixList: NSMutableArray? { get }
    var curRoiList: NSMutableArray? { get }
    var rectArray: NSMutableArray? { get }
    var suppressLabels: Bool { get }
    var eraserFlag: Bool { get }
    var currentTool: ToolMode { get }
    func is2DViewer() -> Bool
    func applyImageTransformation()
    @discardableResult
    @objc(ConvertFromGL2View:) func convertFromGL2View(_ a: NSPoint) -> NSPoint
    @objc(ConvertFromView2GL:) func convertFromView2GL(_ a: NSPoint) -> NSPoint
    @objc(ConvertFromNSView2GL:) func convertFromNSView2GL(_ a: NSPoint) -> NSPoint
    @objc(ConvertFromGL2GL:toView:) func convertFromGL2GL(_ a: NSPoint, toView view: ROIDrawingView?) -> NSPoint
    @objc(convertPoint:fromView:) func convertPoint(_ point: NSPoint, fromView view: NSView?) -> NSPoint
    @objc(setNeedsDisplay:) func setNeedsDisplay(_ flag: Bool)
}

/// The window of a ROI's view.
@objc protocol ROIDrawingWindow: NSObjectProtocol {
    var backingScaleFactor: CGFloat { get }
    var mouseLocationOutsideOfEventStream: NSPoint { get }
}

/// HorosAnnotationOverlay, the view's text layer: the class, then a view's own.
@objc protocol ROITextLayerClass: NSObjectProtocol {
    @discardableResult
    @objc(overlayForView:) func overlay(forView view: ROIDrawingView) -> ROITextLayer
}

@objc protocol ROITextLayer: NSObjectProtocol {
    @objc(addFillRed:green:blue:alpha:rect:) func addFill(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, rect: CGRect)
    @objc(addText:x:y:textColor:shadowColor:blendOnAlpha:)
    func add(text: AnnotationText, x: CGFloat, y: CGFloat, textColor: NSColor, shadowColor: NSColor, blendOnAlpha: Bool)
}

/// HorosAnnotationPresentation: the token of the pictures made for a window's colour space.
@objc protocol ROIAnnotationPresentationClass: NSObjectProtocol {
    @discardableResult
    @objc(textureCacheTokenForWindow:) func textureCacheToken(forWindow window: AnyObject?) -> String
}

/// DCMView, the class: its display settings.
@objc protocol ROIViewClass: NSObjectProtocol {
    func setDefaults()
}

extension ROI {
    /// The view, through the selectors a ROI sends it.
    var view: ROIDrawingView? {
        guard let view = _curView else { return nil }
        return unsafeBitCast(view, to: ROIDrawingView.self)
    }

    /// The view's window's backing scale factor, as a float: 0 without a window.
    var backingScaleFactor: Float {
        Float(view?.roiWindow?.backingScaleFactor ?? 0)
    }

    /// The current image of the view.
    var viewImage: DCMPix? { view?.curDCM }

    /// The view's pixel ratio, as `[[curView curDCM] pixelRatio]` answered: 0 without an image.
    var viewPixelRatio: Float { Float(view?.curDCM?.pixelRatio ?? 0) }

    /// The text layer of `view`.
    static func textLayer(of view: ROIDrawingView) -> ROITextLayer {
        unsafeBitCast(AnnotationOverlay.self as AnyObject, to: ROITextLayerClass.self).overlay(forView: view)
    }

    /// The token of the pictures made for the view's window.
    var textureCacheToken: String {
        unsafeBitCast(AnnotationPresentation.self as AnyObject, to: ROIAnnotationPresentationClass.self)
            .textureCacheToken(forWindow: view?.roiWindow)
    }

    /// DCMView's display defaults, set again when the ROIs are revealed.
    static func setViewDefaults() {
        unsafeBitCast(DCMView.self as AnyObject, to: ROIViewClass.self).setDefaults()
    }

    /// The pointer where the view's window last saw it, in the image's pixels.
    var mouseInImage: NSPoint {
        guard let view else { return .zero }
        let location = view.roiWindow?.mouseLocationOutsideOfEventStream ?? .zero
        return view.convertFromNSView2GL(view.convertPoint(location, fromView: nil))
    }
}
