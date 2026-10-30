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
import IsiXROI

/// A length measured between two points in patient space (from the 3D
/// viewers), shown in a 2D viewer where it crosses or lies on the slab of the
/// current image. The patient endpoints are what it archives and measures;
/// its points are only where they project, made again at each drawing. The
/// archive keeps the class name: ROI files and SRs hold it.
@objc(HorosVolumeLengthROI)
public class HorosVolumeLengthROI: ROI {

    private var _volumeLength: NSDictionary?
    /// The endpoint being dragged: 0, 1, or -1 for none.
    private var dragEndpoint = 0

    /// The payload: the patient endpoints, their frame of reference and the
    /// images they were placed on.
    public var volumeLength: [AnyHashable: Any]! {
        get { _volumeLength as? [AnyHashable: Any] }
        set { _volumeLength = newValue.map { NSDictionary(dictionary: $0) } }
    }

    // Objective-C sets and reads the dictionary itself, copied as the
    // property was: the archive keeps its entries in their order.
    @objc(volumeLength)
    public func volumeLengthDictionary() -> NSDictionary? { _volumeLength }

    @objc(setVolumeLength:)
    public func setVolumeLengthDictionary(_ dictionary: NSDictionary?) { _volumeLength = dictionary?.copy() as? NSDictionary }

    // The initializers of ROI, so that the Objective-C ones reach this class.

    public required init() { super.init() }

    public override init!(type itype: ToolMode, _ ipixelSpacingx: Float, _ ipixelSpacingy: Float, _ iimageOrigin: NSPoint) {
        super.init(type: itype, ipixelSpacingx, ipixelSpacingy, iimageOrigin)
    }

    public override init!(texture tBuff: UnsafeMutablePointer<UInt8>!, textWidth tWidth: Int32, textHeight tHeight: Int32, textName tName: String!,
                          positionX posX: Int32, positionY posY: Int32, spacingX ipixelSpacingx: Float, spacingY ipixelSpacingy: Float,
                          imageOrigin iimageOrigin: NSPoint) {
        super.init(texture: tBuff, textWidth: tWidth, textHeight: tHeight, textName: tName, positionX: posX, positionY: posY,
                   spacingX: ipixelSpacingx, spacingY: ipixelSpacingy, imageOrigin: iimageOrigin)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setVolumeLengthDictionary(coder.decodeObject() as? NSDictionary)
        if !valid() { return nil }
        self.isAliased = true
        dragEndpoint = -1
    }

    public override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(_volumeLength)
    }

    @discardableResult
    public override func copyROI(with zone: NSZone?) -> ROI? {
        let copy = super.copyROI(with: zone) as? HorosVolumeLengthROI
        copy?._volumeLength = _volumeLength
        copy?.originalIndexForAlias = self.originalIndexForAlias
        copy?.dragEndpoint = -1
        return copy
    }

    // MARK: Geometry

    /// What the payload says of an image: its instance, frame and plane.
    @objc(referenceForPix:)
    @discardableResult
    public class func reference(for pix: DCMPix!) -> [AnyHashable: Any]! {
        let image = pix?.imageObj() as AnyObject?
        var orientation = [Double](repeating: 0, count: 9)
        pix?.orientationDouble(&orientation)
        return ["sopInstanceUID": image?.value(forKey: "sopInstanceUID") ?? "",
                "frame": image?.value(forKey: "frameID") ?? NSNumber(value: 0),
                "generated": NSNumber(value: pix?.generated ?? false),
                "imagePositionPatient": [NSNumber(value: pix?.originX ?? 0), NSNumber(value: pix?.originY ?? 0), NSNumber(value: pix?.originZ ?? 0)],
                "imageOrientationPatient": orientation[0..<6].map { NSNumber(value: $0) },
                "pixelSpacing": [NSNumber(value: pix?.pixelSpacingX ?? 0), NSNumber(value: pix?.pixelSpacingY ?? 0)]]
    }

    /// The plane of an image in patient space; nil without an image.
    private static func plane(of pix: DCMPix?) -> ROIImagePlane? {
        guard let pix else { return nil }
        var o = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&o)
        return ROIImagePlane(originX: pix.originX, y: pix.originY, z: pix.originZ, orientation: o, spacingX: pix.pixelSpacingX,
                             spacingY: pix.pixelSpacingY, hasFrameOfReference: (pix.frameofReferenceUID?.count ?? 0) > 0)
    }

    @objc(validGeometry:)
    @discardableResult
    public class func validGeometry(_ pix: DCMPix!) -> Bool {
        plane(of: pix)?.isValid ?? false
    }

    @objc(patientPoint:pix:)
    @discardableResult
    public class func patientPoint(_ point: NSPoint, pix: DCMPix!) -> [Any]! {
        plane(of: pix)?.patientPoint(of: point)
    }

    @objc(projectPoint:pix:depth:)
    @discardableResult
    public class func projectPoint(_ point: [Any]!, pix: DCMPix!, depth: UnsafeMutablePointer<Double>!) -> NSPoint {
        guard let plane = plane(of: pix) else { return .zero }
        return plane.project((point ?? []) as NSArray, depth: depth)
    }

    @objc(validPayload:)
    @discardableResult
    public class func validPayload(_ payload: [AnyHashable: Any]!) -> Bool {
        ROIPatientSpaceLength.isValid(payload: payload.map { NSDictionary(dictionary: $0) })
    }

    @objc public var volumeIdentifier: String! { _volumeLength?["id"] as? String }

    @objc public var distanceMM: Double {
        ROIPatientSpaceLength.distance(ofPayload: _volumeLength ?? NSDictionary())
    }

    @discardableResult
    public override func valid() -> Bool {
        ROIPatientSpaceLength.isValid(payload: _volumeLength)
    }

    @discardableResult
    public override func mesureLength(_ pixels: UnsafeMutablePointer<Float>!) -> Float {
        // A 3D distance has no single-plane pixel length.
        pixels?.pointee = 0
        return Float(self.distanceMM / 10.0)
    }

    /// Where the length shows on the view's image: its ends, where they
    /// project, and where it crosses the image's slab; not visible when it is
    /// in another frame of reference or away from the slab. Sets the points
    /// to the projected ends. In the runtime under its Objective-C name, as
    /// it was, for a probe to ask.
    @objc(volumeProjection)
    private func volumeProjection() -> ROIPlaneCrossing? {
        guard let view, let p = view.curDCM else { return nil }
        if !view.is2DViewer() || !valid() || !HorosVolumeLengthROI.validGeometry(p) { return nil }
        guard let frame = p.frameofReferenceUID, let reference = _volumeLength?["frameOfReference"] as? String,
              (frame as NSString).isEqual(to: reference) else { return nil }
        var da = 0.0, db = 0.0
        let a = HorosVolumeLengthROI.projectPoint(_volumeLength?["a"] as? [Any], pix: p, depth: &da)
        let b = HorosVolumeLengthROI.projectPoint(_volumeLength?["b"] as? [Any], pix: p, depth: &db)
        // A slice occupies its physical thickness. With missing thickness only
        // the plane tolerance is used; never invent spacing for measurement itself.
        let half = p.sliceThickness.isFinite ? fmax(0.01, abs(p.sliceThickness) / 2) : 0.01
        var lo = -half, hi = half
        if p.stack > 1 {
            let index = Int(view.curImage), count = view.dcmPixList?.count ?? 0
            let end = Swift.max(0, Swift.min(count - 1, index + (view.flippedData ? -1 : 1) * (Int(p.stack) - 1)))
            if let last = view.dcmPixList?.object(at: end) as? DCMPix {
                var dz = 0.0
                _ = HorosVolumeLengthROI.projectPoint([NSNumber(value: last.originX), NSNumber(value: last.originY), NSNumber(value: last.originZ)],
                                                      pix: p, depth: &dz)
                let endHalf = last.sliceThickness.isFinite ? fmax(0.01, abs(last.sliceThickness) / 2) : 0.01
                lo = fmin(lo, dz - endHalf)
                hi = fmax(hi, dz + endHalf)
            }
        }
        let crossing = ROIPlaneCrossing(a: a, b: b, depthA: da, depthB: db, half: half, lower: lo, upper: hi, stacked: p.stack > 1)
        if !crossing.visible { return nil }
        // The points are transient drawing coordinates. The archived patient
        // endpoints remain authoritative, including when their projection is a single point.
        _points.removeAllObjects()
        _points.add(MyPoint(point: crossing.a))
        _points.add(MyPoint(point: crossing.b))
        return crossing
    }

    // MARK: Interaction

    @discardableResult
    public override func click(inROI pt: NSPoint, _ offsetx: Float, _ offsety: Float, _ scale: Float, _ testDrawRect: Bool) -> Int {
        if !self.selectable || self.hidden || testDrawRect { return ROI_sleep }
        guard let p = volumeProjection() else { return ROI_sleep }
        let ratio = view?.curDCM?.pixelRatio ?? 0
        let tolerance = 7.0 * Double(view?.roiWindow?.backingScaleFactor ?? 0) / fmax(Double(scale), 0.001)
        let ax = Double(pt.x - p.a.x), ay = Double(pt.y - p.a.y)
        let da = hypot(ax, ay * ratio), db = hypot(Double(pt.x - p.b.x), Double(pt.y - p.b.y) * ratio)
        if !self.locked && (p.handleA || p.handleB) {
            if p.handleA && da <= tolerance {
                dragEndpoint = 0
                return ROI_selectedModify
            }
            if p.handleB && db <= tolerance {
                dragEndpoint = 1
                return ROI_selectedModify
            }
        }
        let dx = Double(p.b.x - p.a.x), dy = Double(p.b.y - p.a.y) * ratio
        let denom = (dy * dy).addingProduct(dx, dx)
        var t = denom > 0 ? ((ay * ratio) * dy).addingProduct(ax, dx) / denom : 0
        t = fmax(0, fmin(1, t))
        return hypot(ax.addingProduct(-t, dx), (-(t * dy)).addingProduct(ay, ratio)) <= tolerance ? ROI_selected : ROI_sleep
    }

    @discardableResult
    public override func mouseRoiDragged(_ pt: NSPoint, _ modifier: UInt32, _ scale: Float) -> Bool {
        guard let pix = view?.curDCM else { return false }
        if mode != ROI_selectedModify || dragEndpoint < 0 || self.locked || pix.stack > 1 { return false }
        guard let point = HorosVolumeLengthROI.patientPoint(pt, pix: pix) else { return false }
        let updated = NSMutableDictionary(dictionary: _volumeLength ?? NSDictionary())
        updated[dragEndpoint == 0 ? "a" : "b"] = point
        updated[dragEndpoint == 0 ? "referenceA" : "referenceB"] = HorosVolumeLengthROI.reference(for: pix)
        if !HorosVolumeLengthROI.validPayload(updated as? [AnyHashable: Any]) { return false }
        setVolumeLengthDictionary(updated)
        recompute()
        postChange(nil)
        return true
    }

    @discardableResult
    public override func mouseRoiUp(_ pt: NSPoint, scaleValue: Float) -> Bool {
        dragEndpoint = -1
        if mode == ROI_selectedModify { mode = ROI_selected }
        return false
    }

    @discardableResult
    public override func deleteSelectedPoint() -> Bool { false }

    /// Moving a projected line cannot choose its depth: its endpoint handles are dragged instead.
    public override func roiMove(_ offset: NSPoint) {}
    public override func roiMove(_ offset: NSPoint, _ sendNotification: Bool) {}

    @discardableResult
    public override func dataString() -> NSMutableDictionary! {
        NSMutableDictionary(dictionary: ["Length3DMM": NSNumber(value: self.distanceMM),
                                         "PatientEndpoints": [_volumeLength?["a"] as Any, _volumeLength?["b"] as Any],
                                         "Geometry": "Patient-space Length; use ROI archive or JSON v2 to preserve geometry"])
    }

    // MARK: Drawing

    public override func draw(withScaleValue scaleValue: Float, offsetX offsetx: Float, offsetY offsety: Float, pixelSpacingX spacingX: Float,
                              pixelSpacingY spacingY: Float, highlightIfSelected: Bool, thickness thick: Float, prepareTextualData: Bool) {
        _textualBoxLine1 = nil; _textualBoxLine2 = nil; _textualBoxLine3 = nil
        _textualBoxLine4 = nil; _textualBoxLine5 = nil; _textualBoxLine6 = nil
        if self.hidden { return }
        guard let p = volumeProjection() else { return }
        guard let canvas = ROICanvas.current else { return }
        let sf = backingScaleFactor
        func onScreen(_ q: CGPoint) -> (Float, Float) {
            (Float((Double(q.x) - Double(offsetx)) * Double(scaleValue)), Float((Double(q.y) - Double(offsety)) * Double(scaleValue)))
        }
        canvas.pushAttributes()
        ROIGL.enable(ROIGL.blend)
        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)
        ROIGL.color4f(Float(Double(rgbcolor.red) / 65535.0), Float(Double(rgbcolor.green) / 65535.0), Float(Double(rgbcolor.blue) / 65535.0), opacity)
        ROIGL.lineWidth(Float(fmax(1, Double(thick * sf))))
        ROIGL.enable(ROICanvas.lineStipple)
        canvas.lineStipple(factor: 1, pattern: 0x0F0F)
        ROIGL.begin(ROIGL.lines)
        let a = onScreen(p.a), b = onScreen(p.b)
        ROIGL.vertex2f(a.0, a.1)
        ROIGL.vertex2f(b.0, b.1)
        ROIGL.end()
        ROIGL.disable(ROICanvas.lineStipple)
        ROIGL.pointSize(Float(highlightIfSelected && mode != ROI_sleep ? 8 : 5) * sf)
        ROIGL.begin(ROIGL.points)
        if p.handleA { ROIGL.vertex2f(a.0, a.1) }
        if p.handleB { ROIGL.vertex2f(b.0, b.1) }
        if p.crossesPlane {
            let i = onScreen(p.intersection)
            ROIGL.vertex2f(i.0, i.1)
        }
        ROIGL.end()
        canvas.popAttributes()
        if prepareTextualData && self.isTextualDataDisplayed {
            _textualBoxLine1 = String(format: NSLocalizedString("Length 3D: %@", comment: ""), LengthPresentation.string(millimetres: self.distanceMM)) as NSString
            self.prepareTextualData(lowerRightPoint())
        }
    }
}
