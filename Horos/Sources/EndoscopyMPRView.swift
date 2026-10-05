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
import UniformTypeIdentifiers

// The OpenGL enumerants ROICanvasGL.h names, which Swift cannot import: that
// header imports Horos-Swift.h.
private let GL_POINTS: UInt32 = 0x0000
private let GL_LINES: UInt32 = 0x0001
private let GL_LINE_STRIP: UInt32 = 0x0003
private let GL_POINT_SMOOTH: UInt32 = 0x0B10
private let GL_LINE_SMOOTH: UInt32 = 0x0B20
private let GL_POLYGON_SMOOTH: UInt32 = 0x0B41
private let GL_BLEND: UInt32 = 0x0BE2
private let GL_SRC_ALPHA: UInt32 = 0x0302
private let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303

// The static inline functions of ROICanvasGL.h, with the same parameter types:
// a CGFloat or double argument goes through a float, as it did.
private func roiPushMatrix() { ROICanvas.current?.pushMatrix() }
private func roiPopMatrix() { ROICanvas.current?.popMatrix() }
private func roiLoadIdentity() { ROICanvas.current?.loadIdentity() }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiTranslatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }
private func roiRotatef(_ angle: Float, _ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.rotate(Double(z < 0 ? -angle : angle)) }
private func roiBlendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
private func roiEnable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
private func roiDisable(_ cap: UInt32) { ROICanvas.current?.disable(cap) }
private func roiColor3f(_ r: Float, _ g: Float, _ b: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1)
}
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiPointSize(_ s: Float) { ROICanvas.current?.pointSize(CGFloat(s)) }
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }

/// A float converted to long as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cLong(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// The messages the view sends to objects the former Objective-C typed by a
/// cast, which did not check the class: the protocol names the selectors, it
/// is not checked.
@objc private protocol EndoscopyMPRViewPeerMessages: NSObjectProtocol {
    /// -[EndoscopyViewer setCamera], -exportAllViews, -getRawPixels::::.
    @objc(setCamera) func setCamera()
    @objc(exportAllViews) func exportAllViews() -> Bool
    @objc(getRawPixels::::) func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!) -> UnsafeMutablePointer<UInt8>!
    /// -[EndoscopyViewer vrController] and -[VRController view].
    @objc(vrController) func vrController() -> AnyObject?
    @objc(view) func view() -> AnyObject?
    /// -[VRView exportDICOMFile:].
    @objc(exportDICOMFile:) func exportDICOMFile(_ sender: Any!)
}

/// An id, or an object typed by a cast, as the messages it answers.
private func peer(_ object: Any?) -> EndoscopyMPRViewPeerMessages? {
    return unsafeBitCast(object as AnyObject?, to: EndoscopyMPRViewPeerMessages?.self)
}

/// One of the three MPR views of the endoscopy window: an OrthogonalMPRView
/// that draws the camera's focal and view-up vectors and the fly-through path,
/// and lets the focal vector be dragged.
///
/// Implemented in Swift since #827: the Objective-C name, the selectors and
/// <Horos/EndoscopyMPRView.h> are those of the former class, the customClass
/// of the three MPR views of Endoscopy.xib. Its superclass, OrthogonalMPRView,
/// is Swift too since #870; its cross position, controller and WL/WW menu are
/// read through its accessors, and the DCMView ivars through
/// DCMView+SwiftIvars.h.
@objc(EndoscopyMPRView)
public final class EndoscopyMPRView: OrthogonalMPRView {
    // MARK: - The former instance variables

    private var _cameraPosition = NSPoint(x: 0, y: 0)
    private var _cameraFocalPoint = NSPoint(x: 0, y: 0)
    private var _cameraAngle: Float = 0
    private var _focalPointX: Int = 0
    private var _focalPointY: Int = 0
    private var _focalShiftX: Int = 0
    private var _focalShiftY: Int = 0
    private var near: Int = 0
    private var maxFocalLength: Int = 0
    private var _viewUpX: Int = 0
    private var _viewUpY: Int = 0
    /// flyThroughPath, retained. Typed NSArray: the viewer mutates the array it
    /// hands over, which a Swift array would have copied.
    private var _flyThroughPath: NSArray? = nil

    @objc public dynamic var flyThroughPath: NSArray? {
        get { return _flyThroughPath }
        set { _flyThroughPath = newValue }
    }

    // MARK: - Initializers

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        _cameraPosition.x = 0.0
        _cameraPosition.y = 0.0
        _cameraFocalPoint.x = 0.0
        _cameraFocalPoint.y = 0.0
        _cameraAngle = 0.0
        _focalPointX = 0
        _focalPointY = 0
        _focalShiftX = 0
        _focalShiftY = 0
        _viewUpX = 0
        _viewUpY = 0
        near = 6
        maxFocalLength = 50
    }

    /// DCMView's -initWithFrame: sends this one to self: overridden, unchanged,
    /// so that it stays inherited beside the initializer above.
    public override init!(frame: NSRect, imageRows rows: Int32, imageColumns columns: Int32) {
        super.init(frame: frame, imageRows: rows, imageColumns: columns)
    }

    /// Overridden, unchanged, so that it stays inherited beside the initializer above.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Drawing

    public override dynamic func subDraw(_ aRect: NSRect) {
        super.subDraw(aRect)

        let scaleValue = self.horos_scaleValue
        let pwidth = self.curDCM?.pwidth ?? 0
        let pheight = self.curDCM?.pheight ?? 0

        var xCrossCenter: Float, yCrossCenter: Float
        xCrossCenter = (self.crossPositionX() - Float(pwidth / 2)) * scaleValue
        yCrossCenter = (self.crossPositionY() - Float(pheight / 2)) * scaleValue

        // normalization of FOCAL VECTOR
        var vectNorm = Float(sqrt(pow(Double(_focalShiftX), 2) + pow(Double(_focalShiftY) / self.pixelSpacingX * self.pixelSpacingY, 2)))
        var maxSize = Float(maxFocalLength)
        vectNorm = (vectNorm == 0) ? 1.0 : vectNorm
        maxSize = (vectNorm == 0) ? 0.0 : maxSize
        maxSize = (vectNorm > maxSize) ? maxSize : vectNorm
        let normalizationFactor = maxSize / vectNorm

        //normalizationFactor = 1.0;

        roiPushMatrix()

        roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
        let frame = self.drawingFrameRect
        roiScalef(Float(2.0 / (self.xFlipped ? -(Double(frame.size.width)) : Double(frame.size.width))), Float(-2.0 / (self.yFlipped ? -(Double(frame.size.height)) : Double(frame.size.height))), 1.0) // scale to port per pixel scale
        roiRotatef(self.horos_rotation, 0.0, 0.0, 1.0) // rotate matrix for image rotation
        roiTranslatef(Float(self.origin.x), Float(-self.origin.y), 0.0)
        roiScalef(1.0, Float(self.curDCM?.pixelRatio ?? 0), 1.0)

        // antialiasing
        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        roiEnable(GL_BLEND)
        roiEnable(GL_POINT_SMOOTH)
        roiEnable(GL_LINE_SMOOTH)
        roiEnable(GL_POLYGON_SMOOTH)

        let backingScaleFactor = Double(self.window?.backingScaleFactor ?? 0)

        // draw the direction vector
        roiColor3f(1.0, 0.0, 1.0)
        roiLineWidth(Float(1.0 * backingScaleFactor))
        roiBegin(GL_LINES)
        roiVertex2f(xCrossCenter, yCrossCenter)

        var cfocalShiftX = Float(_focalShiftX)
        var cfocalShiftY = Float(_focalShiftY)

        if self.xFlipped {
            cfocalShiftX = Float(Double(cfocalShiftX) * -1.0)
        }

        if self.yFlipped {
            cfocalShiftY = Float(Double(cfocalShiftY) * -1.0)
        }

        roiVertex2f(xCrossCenter + cfocalShiftX * normalizationFactor,
                    yCrossCenter + cfocalShiftY * normalizationFactor)	//*[self pixelSpacingY]/[self pixelSpacingX]
        roiEnd()

        // draw a point at the end of FOCAL POINT vector (handle to move the vector)
        roiPointSize(Float(2.0 * Double(near) * backingScaleFactor))
        roiBegin(GL_POINTS)

        roiVertex2f(xCrossCenter + cfocalShiftX * normalizationFactor,
                    yCrossCenter + cfocalShiftY * normalizationFactor)	//*[self pixelSpacingY]/[self pixelSpacingX]
        roiEnd()
        roiPointSize(Float(1.0 * backingScaleFactor))

        // normalization of VIEW UP VECTOR
        var vectViewUpNorm = Float(sqrt(pow(Double(_viewUpX), 2) + pow(Double(_viewUpY), 2)))
        var sizeViewUp: Float = 25.0
        vectViewUpNorm = (vectViewUpNorm == 0) ? 1.0 : vectViewUpNorm
        sizeViewUp = (vectViewUpNorm == 0) ? 0.0 : sizeViewUp
        sizeViewUp = (vectViewUpNorm > sizeViewUp) ? sizeViewUp : vectViewUpNorm
        let normalizationViewUpFactor = Float(Double(sizeViewUp / vectViewUpNorm) * 2.0)

        // draw the view up vecteur
        roiColor3f(0.0, 0.75, 1.0)
        roiLineWidth(Float(1.0 * backingScaleFactor))
        roiBegin(GL_LINES)
        roiVertex2f(xCrossCenter, yCrossCenter)
        roiVertex2f(xCrossCenter + Float(_viewUpX) * normalizationViewUpFactor,
                    yCrossCenter + Float(_viewUpY) * normalizationViewUpFactor)	//*[self pixelSpacingY]/[self pixelSpacingX]
        roiEnd()

        // draw the Fly Through Path
        roiColor3f(0.8, 0.0, 0.25)
        roiLineWidth(Float(1.0 * backingScaleFactor))
        roiBegin(GL_LINE_STRIP)
        if let path = _flyThroughPath {
            var i = 0
            while i < path.count {
                let pt = unsafeBitCast(path.object(at: i) as AnyObject, to: Point3D.self)
                let x = (pt.x - Float(pwidth / 2)) * scaleValue
                let y = (pt.y - Float(pheight / 2)) * scaleValue //* [self pixelSpacingY]/[self pixelSpacingX];
                roiVertex2f(x, y)
                i += 1
            }
        }

        roiEnd()

        // antialiasing end
        roiDisable(GL_LINE_SMOOTH)
        roiDisable(GL_POLYGON_SMOOTH)
        roiDisable(GL_POINT_SMOOTH)
        roiDisable(GL_BLEND)

        roiPopMatrix()
    }

    // MARK: - Mouse and keyboard

    /// [self convertPoint: [theEvent locationInWindow] fromView: self], then to
    /// the view from the window's content view, then to the image.
    private func imagePoint(_ theEvent: NSEvent?) -> NSPoint {
        var mouseLoc = self.convert(theEvent?.locationInWindow ?? NSZeroPoint, from: self)
        mouseLoc = theEvent?.window?.contentView?.convert(mouseLoc, to: self) ?? NSZeroPoint
        mouseLoc = self.convert(fromNSView2GL: mouseLoc)
        return mouseLoc
    }

    /// Whether the point is on the handle at the end of the focal vector.
    private func onFocalHandle(_ mouseLocStart: NSPoint) -> Bool {
        // normalization of focal vector
        var vectNorm = Float(sqrt(pow(Double(_focalShiftX), 2) + pow(Double(_focalShiftY) / self.pixelSpacingX * self.pixelSpacingY, 2)))
        var maxSize = Float(maxFocalLength)
        vectNorm = (vectNorm == 0) ? 1.0 : vectNorm
        maxSize = (vectNorm == 0) ? 0.0 : maxSize
        maxSize = (vectNorm > maxSize) ? maxSize : vectNorm

        let normalizationFactor = maxSize / vectNorm
        let scaleFactor = self.horos_scaleValue

        var sX = Float(_focalShiftX)
        var sY = Float(_focalShiftY)

        if self.xFlipped {
            sX = Float(Double(sX) * -1.0)
        }

        if self.yFlipped {
            sY = Float(Double(sY) * -1.0)
        }

        let crossPositionX = self.crossPositionX(), crossPositionY = self.crossPositionY()
        let nearScaled = Float(near) / scaleFactor
        let x = Double(mouseLocStart.x), y = Double(mouseLocStart.y)

        if (x > Double(crossPositionX + sX * normalizationFactor / scaleFactor - nearScaled) && x < Double(crossPositionX + sX * normalizationFactor / scaleFactor + nearScaled)) &&
            (y > Double(crossPositionY + sY * normalizationFactor / scaleFactor - nearScaled) && y < Double(crossPositionY + sY * normalizationFactor / scaleFactor + nearScaled)) {
            return true
        }

        return false
    }

    @objc(mouseOnFocal:)
    private dynamic func mouseOnFocal(_ theEvent: NSEvent?) -> Bool {
        return self.onFocalHandle(self.imagePoint(theEvent))
    }

    //navigator
    public override dynamic func keyDown(with event: NSEvent) {
        let characters = event.characters as NSString?
        if (characters?.length ?? 0) == 0 { return }

        let c = Int(characters!.character(at: 0))

        if c == NSUpArrowFunctionKey {
            NotificationCenter.default.post(name: NSNotification.Name("PathAssistantGoForwardNotification"), object: nil, userInfo: nil)
        } else if c == NSDownArrowFunctionKey {
            NotificationCenter.default.post(name: NSNotification.Name("PathAssistantGoBackwardNotification"), object: nil, userInfo: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    /// The event is optional: OrthogonalMPRView sends the application's current
    /// event, which can be nil, as the former Objective-C did.
    public override dynamic func mouseMoved(with theEvent: NSEvent?) {
        if !(self.window?.isVisible ?? false) {
            return
        }

        let view = theEvent?.window?.contentView?.hitTest(theEvent?.locationInWindow ?? NSZeroPoint)

        if view === self {
            // A nil event has no window, so no view is hit: here it is not nil.
            super.mouseMoved(with: theEvent!)

            if self.mouseOnFocal(theEvent) {
                // [cursor release]; cursor = [[NSCursor rotateAxisCursor] retain];
                self.horos_cursor = NSCursor.rotateAxisCursor()
                self.cursor?.set()
            } else {
                self.flagsChanged(with: theEvent!)
            }
        } else {
            if let theEvent = theEvent {
                view?.mouseMoved(with: theEvent)
            }
        }
    }

    public override dynamic func mouseDown(with event: NSEvent) {
        var theEvent: NSEvent? = event
        var mouseLoc: NSPoint

        let mouseLocStart = self.imagePoint(theEvent)

        if self.onFocalHandle(mouseLocStart) {
            let scaleFactor = self.horos_scaleValue
            var keepOn = true
            while keepOn {
                theEvent = self.window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged, .periodic])

                mouseLoc = self.imagePoint(theEvent)

                switch theEvent?.type {
                case .leftMouseDragged?:
                    _focalShiftX = cLong((Double(mouseLoc.x) - Double(self.crossPositionX())) * Double(scaleFactor))
                    _focalShiftY = cLong((Double(mouseLoc.y) - Double(self.crossPositionY())) * Double(scaleFactor))

                    self.setFocalShiftX(_focalShiftX)
                    self.setFocalShiftY(_focalShiftY)
                    self.needsDisplay = true
                    NotificationCenter.default.post(name: NSNotification.Name.OsirixChangeFocalPoint, object: self, userInfo: nil)

                case .leftMouseUp?:
                    keepOn = false

                case .periodic?:
                    break

                default:
                    break
                }
            }
            self.needsDisplay = true
        } else {
            super.mouseDown(with: event)
        }
    }

    // MARK: - Cross position

    public override dynamic func setCrossPosition(_ x: Float, _ y: Float) {
        super.setCrossPosition(x, y)
        self.setFocalShiftX(self.focalShiftX()) // will recompute focalPointX
        self.setFocalShiftY(self.focalShiftY()) // will recompute focalPointX
        NotificationCenter.default.post(name: NSNotification.Name.OsirixChangeFocalPoint, object: self, userInfo: nil)
        peer(self.controller()?.viewer())?.setCamera()
    }

    public override dynamic func setCrossPositionX(_ x: Float) {
        super.setCrossPositionX(x)
        //focalShiftX = focalPointX - crossPositionX;
    }

    public override dynamic func setCrossPositionY(_ y: Float) {
        super.setCrossPositionY(y)
        //focalShiftY = focalPointY - crossPositionY;
    }

    public override dynamic func adjustWLWW(_ wl: Float, _ ww: Float) {
        super.adjustWLWW(wl, ww)
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdate2dWLWWMenu, object: self.curWLWWMenu(), userInfo: nil)
    }

    // MARK: - Camera

    @objc(setCameraPosition::)
    public dynamic func setCameraPosition(_ x: Float, _ y: Float) {
        //NSLog(@"setCameraPosition: %f, %f", x, y);
        _cameraPosition.x = CGFloat(x)
        _cameraPosition.y = CGFloat(y)

        //	y = ([[self controller] sign]>0)? [[originalView dcmPixList] count]-sliceIndex-1 : sliceIndex ;
        //	[[self controller] reslice: (long)x+0.5:  (long)y+0.5: self];
        //	[self setCrossPositionX: (float)x];
        //	[self setCrossPositionY: (float)y];
        //	[self setCrossPosition:x+[self.curDCM pwidth]/2 :y+[self.curDCM pwidth]/2];
    }

    @objc(cameraPosition)
    public dynamic func cameraPosition() -> NSPoint {
        return _cameraPosition
    }

    @objc(setCameraFocalPoint::)
    public dynamic func setCameraFocalPoint(_ x: Float, _ y: Float) {
        _cameraFocalPoint.x = CGFloat(x)
        _cameraFocalPoint.y = CGFloat(y)
    }

    //- (void) setCameraFocalPoint
    //{
    //	float x, y;
    //	x = cameraPosition.x + focalShiftX * [[[self pixList] objectAtIndex:0] pixelSpacingX];
    //	y = cameraPosition.y + focalShiftY * [[[self pixList] objectAtIndex:0] pixelSpacingY];
    //	[self setCameraFocalPoint:x : y];
    //}

    @objc(cameraFocalPoint)
    public dynamic func cameraFocalPoint() -> NSPoint {
        return _cameraFocalPoint
    }

    @objc(setCameraAngle:)
    public dynamic func setCameraAngle(_ alpha: Float) {
        _cameraAngle = alpha
    }

    @objc(cameraAngle)
    public dynamic func cameraAngle() -> Float {
        return _cameraAngle
    }

    @objc(setFocalPointX:)
    public dynamic func setFocalPointX(_ x: Int) {
        _focalPointX = x
        _focalShiftX = cLong(Double(Float(_focalPointX) - self.crossPositionX()))

        if self.xFlipped {
            _focalShiftX = cLong(Double(_focalShiftX) * -1.0)
        }
    }

    @objc(setFocalPointY:)
    public dynamic func setFocalPointY(_ y: Int) {
        _focalPointY = y
        _focalShiftY = cLong(Double(Float(_focalPointY) - self.crossPositionY()))

        if self.yFlipped {
            _focalShiftY = cLong(Double(_focalShiftY) * -1.0)
        }
    }

    @objc(focalPointX)
    public dynamic func focalPointX() -> Int {
        return _focalPointX
    }

    @objc(focalPointY)
    public dynamic func focalPointY() -> Int {
        return _focalPointY
    }

    @objc(setFocalShiftX:)
    public dynamic func setFocalShiftX(_ x: Int) {
        var x = x
        if self.xFlipped {
            x = cLong(Double(x) * -1.0)
        }

        _focalShiftX = x
        _focalPointX = cLong(Double(self.crossPositionX() + Float(_focalShiftX)))
    }

    @objc(setFocalShiftY:)
    public dynamic func setFocalShiftY(_ y: Int) {
        var y = y
        if self.yFlipped {
            y = cLong(Double(y) * -1.0)
        }

        _focalShiftY = y
        _focalPointY = cLong(Double(self.crossPositionY() + Float(_focalShiftY)))
    }

    @objc(focalShiftX)
    public dynamic func focalShiftX() -> Int {
        if self.xFlipped {
            return -_focalShiftX
        } else {
            return _focalShiftX
        }
    }

    @objc(focalShiftY)
    public dynamic func focalShiftY() -> Int {
        if self.yFlipped {
            return -_focalShiftY
        } else {
            return _focalShiftY
        }
    }

    @objc(setViewUpX:)
    public dynamic func setViewUpX(_ x: Int) {
        _viewUpX = x
    }

    @objc(setViewUpY:)
    public dynamic func setViewUpY(_ y: Int) {
        _viewUpY = y
    }

    @objc(viewUpX)
    public dynamic func viewUpX() -> Int {
        return _viewUpX
    }

    @objc(viewUpY)
    public dynamic func viewUpY() -> Int {
        return _viewUpY
    }

    // MARK: - Export

    @objc(sendMail:)
    private dynamic func sendMail(_ sender: Any!) {
        let email: Mailer
        let im = self.nsimage(false)

        let representations: [NSImageRep]?
        let bitmapData: Data?

        representations = im?.representations

        bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

        let path = ((BrowserController.currentBrowser()?.database?.tempDirPath() as NSString?)?.appendingPathComponent("IsiX DICOM Viewer.jpg"))
        if let path = path {
            (bitmapData as NSData?)?.write(toFile: path, atomically: true)
        }

        email = Mailer()

        _ = email.sendMail("--", to: "--", subject: "", isMIME: true, name: "--", sendNow: false, image: path)
    }

    @objc(exportJPEG:)
    private dynamic func exportJPEG(_ sender: Any!) {
        let panel = NSSavePanel()

        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]

        panel.nameFieldStringValue = ((self.controller()?.originalDCMFilesList()?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.name") as? String) ?? ""
        if !["jpg", "jpeg"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".jpg"
        }

        panel.begin { result in
            if result != .OK {
                return
            }

            let im = self.nsimage(false)

            let representations: [NSImageRep]?
            let bitmapData: Data?

            representations = im?.representations

            bitmapData = NSBitmapImageRep.representationOfImageReps(in: representations ?? [], using: .jpeg, properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])

            if let path = panel.url?.path {
                (bitmapData as NSData?)?.write(toFile: path, atomically: true)
            }

            if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                if let url = panel.url {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    @objc(exportDICOMFile:)
    private dynamic func exportDICOMFile(_ sender: Any!) {
        if (sender as? NSObject)?.isEqual(self.window?.windowController) ?? false {
            let curPix = self.curDCM

            let annotCopy = UserDefaults.standard.integer(forKey: "ANNOTATIONS"),
                clutBarsCopy = UserDefaults.standard.integer(forKey: "CLUTBARS")
            var width = 0, height = 0, spp = 0, bpp = 0
            var cwl: Float = 0, cww: Float = 0
            var o = [Float](repeating: 0, count: 9)

            UserDefaults.standard.set(annotGraphics, forKey: "ANNOTATIONS")
            UserDefaults.standard.set(barHide, forKey: "CLUTBARS")
            DCMView.setDefaults()

            let producedFiles = NSMutableArray()

            let data = self.superGetRawPixels(&width, &height, &spp, &bpp, true, false, false)

            if let data = data {
                let exportDCM = DICOMExport()

                exportDCM.setSourceFile((self.controller()?.originalDCMFilesList()?.object(at: Int(self.curImage)) as AnyObject?)?.value(forKey: "completePath") as? String)
                exportDCM.setSeriesDescription("Endoscopy")

                self.getWLWW(&cwl, &cww)
                exportDCM.setDefaultWWWL(cLong(Double(cww)), cLong(Double(cwl)))

                exportDCM.setPixelSpacing(Float((curPix?.pixelSpacingX ?? 0) / Double(self.scaleValue)), Float((curPix?.pixelSpacingX ?? 0) / Double(self.scaleValue)))

                exportDCM.setSliceThickness(curPix?.sliceThickness ?? 0)
                exportDCM.setSlicePosition(Float(curPix?.sliceLocation ?? 0))

                self.orientationCorrected(toView: &o)	// <- Because we do screen capture !!!!! We need to apply the rotation of the image

                exportDCM.setOrientation(&o)

                let tempPt = self.convert(fromUpLeftView2GL: NSMakePoint(0, 0))				// <- Because we do screen capture !!!!!
                curPix?.convertX(Float(tempPt.x), pixY: Float(tempPt.y), toDICOMCoords: &o, pixelCenter: true)
                exportDCM.setPosition(&o)

                _ = exportDCM.setPixelData(data, samplesPerPixel: Int32(truncatingIfNeeded: spp), bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)

                let f = exportDCM.writeDCMFile(nil)
                if f == nil {
                    HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }

                if let f = f {
                    producedFiles.add(NSDictionary(object: f, forKey: "file" as NSString))
                }

                free(data)
            }

            UserDefaults.standard.set(annotCopy, forKey: "ANNOTATIONS")
            UserDefaults.standard.set(clutBarsCopy, forKey: "CLUTBARS")
            DCMView.setDefaults()

            if producedFiles.count > 0 {
                let database = BrowserController.currentBrowser()?.database
                var objects = database?.addFiles(atPaths: producedFiles.value(forKey: "file") as? [Any],
                                                 postNotifications: true,
                                                 dicomOnly: true,
                                                 rereadExistingItems: true,
                                                 generatedByOsiriX: true)

                objects = database?.objects(withIDs: objects)

                if UserDefaults.standard.bool(forKey: "afterExportSendToDICOMNode") {
                    BrowserController.currentBrowser()?.selectServer(objects)
                }

                if UserDefaults.standard.bool(forKey: "afterExportMarkThemAsKeyImages") {
                    for case let im as NSManagedObject in (objects as NSArray?) ?? NSArray() {
                        im.setValue(NSNumber(value: true), forKey: "isKeyImage")
                    }
                }
            }
        } else {
            let v = peer(self.window?.windowController)

            peer(peer(v?.vrController())?.view())?.exportDICOMFile(sender)
        }
    }

    /// NSView's cache of the view for display: the view's pixels as
    /// -getRawPixels:::::: returns them, raw samples in a buffer this method
    /// frees, laid out in a bitmap of their size. An image file decoder, as the
    /// former -initWithData: was, reads no raw samples.
    public override dynamic func bitmapImageRepForCachingDisplay(in aRect: NSRect) -> NSBitmapImageRep? {
        var width = 0, height = 0, spp = 0, bpp = 0
        guard let data = self.getRawPixels(&width, &height, &spp, &bpp, true, false) else {
            return super.bitmapImageRepForCachingDisplay(in: aRect)
        }
        defer { free(data) }

        let bytesPerRow = width * bpp * spp / 8
        guard width > 0, height > 0, spp == 1 || spp == 3, bpp == 8 || bpp == 16,
              let bits = NSBitmapImageRep(bitmapDataPlanes: nil,
                                          pixelsWide: width,
                                          pixelsHigh: height,
                                          bitsPerSample: bpp,
                                          samplesPerPixel: spp,
                                          hasAlpha: false,
                                          isPlanar: false,
                                          colorSpaceName: spp == 3 ? .calibratedRGB : .calibratedWhite,
                                          bytesPerRow: bytesPerRow,
                                          bitsPerPixel: bpp * spp),
              let pixels = bits.bitmapData else {
            return super.bitmapImageRepForCachingDisplay(in: aRect)
        }
        memcpy(pixels, data, bytesPerRow * height)
        return bits
    }

    @objc(superGetRawPixels:::::::)
    public dynamic func superGetRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!, _ screenCapture: Bool, _ force8bits: Bool, _ removeGraphical: Bool) -> UnsafeMutablePointer<UInt8>! {
        return super.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture, force8bits: force8bits, removeGraphical: removeGraphical, squarePixels: true, allTiles: false, allowSmartCropping: false, origin: nil, spacing: nil, offset: nil, isSigned: nil)
    }

    @objc(getRawPixels:::::::)
    private dynamic func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!, _ screenCapture: Bool, _ force8bits: Bool, _ removeGraphical: Bool) -> UnsafeMutablePointer<UInt8>! {
        let viewer = peer(self.window?.windowController)
        if viewer?.exportAllViews() ?? false {
            return viewer?.getRawPixels(width, height, spp, bpp)
        } else {
            return super.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture, force8bits: force8bits, removeGraphical: removeGraphical, squarePixels: true, allTiles: false, allowSmartCropping: false, origin: nil, spacing: nil, offset: nil, isSigned: nil)
        }
    }
}
