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
import IsiXROI

// Selectors of ROI that only later headers of the plugin SDK declare and the
// application has something behind. A plugin built with those headers sends
// them by name, from any thread, and an absent one raises «unrecognized
// selector» in the middle of the plugin's work: an export of the statistics
// of every ROI stopped at the first of them. The headers give each a name
// and its types; what each answers follows its name and what the ROI already
// computes for its own label, and is said at each one.
extension ROI {
    // MARK: Statistics

    /// Measures the image inside the ROI when the ROI has not been measured
    /// since it last changed, as the label does before it is drawn; `moments`
    /// measures it in any case, since the label computes no skewness or
    /// kurtosis. A ROI without an image keeps what it has.
    private func laterSDKMeasure(moments: Bool = false) {
        guard moments || rtotal == -1 else { return }
        guard let image = _pix ?? viewImage else { return }
        computeStatistics(of: image)
    }

    /// The sum of the values inside the ROI.
    @objc(total) func laterSDKTotal() -> Float { laterSDKMeasure(); return rtotal }
    @objc(setTotal:) func laterSDKSetTotal(_ value: Float) { rtotal = value }

    /// Their standard deviation.
    @objc(dev) func laterSDKDev() -> Float { laterSDKMeasure(); return rdev }
    @objc(setDev:) func laterSDKSetDev(_ value: Float) { rdev = value }

    /// Their skewness and kurtosis, measured when asked for.
    @objc(skewness) func laterSDKSkewness() -> Float { laterSDKMeasure(moments: true); return rskewness }
    @objc(setSkewness:) func laterSDKSetSkewness(_ value: Float) { rskewness = value }
    @objc(kurtosis) func laterSDKKurtosis() -> Float { laterSDKMeasure(moments: true); return rkurtosis }
    @objc(setKurtosis:) func laterSDKSetKurtosis(_ value: Float) { rkurtosis = value }

    /// Measures the ROI when it has not been since it last changed.
    @objc(computeROIIfNedeed) func laterSDKComputeIfNeeded() { laterSDKMeasure() }

    /// Forgets the measures: they are taken again when next asked for or shown.
    @objc(resetCache) func laterSDKResetCache() { forgetStatistics() }

    // MARK: Length and area

    /// The kinds of ROI whose label shows an area and the length of their outline.
    private var laterSDKHasOutline: Bool {
        switch _type {
        case .tOval, .tROI, .tDynAngle, .tTAGT, .tAxis, .tCPolygon, .tOPolygon, .tPencil, .tPlain: return true
        default: return false
        }
    }

    /// The length the label shows: of a length ROI, between its two points;
    /// of a ROI with an outline, along it. In cm, or in pixels when `inPixels`
    /// or the image has no pixel spacing; 0 for the other kinds.
    private func laterSDKLength(inPixels: Bool) -> Float {
        if _type == .tMesure {
            guard _points.count >= 2, let a = _points.object(at: 0) as? MyPoint, let b = _points.object(at: 1) as? MyPoint else { return 0 }
            return length(from: a.point, to: b.point, inPixel: inPixels)
        }
        guard laterSDKHasOutline, let outline = splinePoints() else { return 0 }
        let closed = _type != .tOPolygon
        if !inPixels { return perimeter(ofPoints: outline, closed: closed) }
        return ROI.points(of: outline).withUnsafeBufferPointer {
            ROIPlanarGeometry.perimeter(of: $0.baseAddress, count: $0.count, closed: closed, spacingX: 0, spacingY: 0)
        }
    }

    /// The area inside the outline, in pixels; 0 for a ROI without one.
    private func laterSDKAreaInPixels() -> Float {
        switch _type {
        case .tOval: return ellipseArea()
        case .tROI: return Float(abs(_rect.size.width * _rect.size.height))
        default: return laterSDKHasOutline ? area() : 0
        }
    }

    // The four measures are properties a plugin can also set: a value it
    // sets is what the ROI then answers, and until then the ROI answers what
    // its shape gives.

    /// In cm, or in pixels without pixel spacing.
    @objc(length) func laterSDKLength() -> Float { LaterPluginSDK.keptIfSet("length", of: self) ?? laterSDKLength(inPixels: false) }
    @objc(setLength:) func laterSDKSetLength(_ value: Float) { LaterPluginSDK.keep(value, "length", of: self) }
    @objc(lengthPix) func laterSDKLengthPix() -> Float { LaterPluginSDK.keptIfSet("lengthPix", of: self) ?? laterSDKLength(inPixels: true) }
    @objc(setLengthPix:) func laterSDKSetLengthPix(_ value: Float) { LaterPluginSDK.keep(value, "lengthPix", of: self) }

    /// In cm2: 0 without pixel spacing.
    @objc(area) func laterSDKArea() -> Float { LaterPluginSDK.keptIfSet("area", of: self) ?? roiArea() }
    @objc(setArea:) func laterSDKSetArea(_ value: Float) { LaterPluginSDK.keep(value, "area", of: self) }
    @objc(areaPix) func laterSDKAreaPix() -> Float { LaterPluginSDK.keptIfSet("areaPix", of: self) ?? laterSDKAreaInPixels() }
    @objc(setAreaPix:) func laterSDKSetAreaPix(_ value: Float) { LaterPluginSDK.keep(value, "areaPix", of: self) }

    /// Between two points of the image, by the ROI's pixel spacing: in cm, or in pixels without it.
    @objc(LengthInCm:to:) func laterSDKLengthInCm(_ a: NSPoint, to b: NSPoint) -> Float { length(from: a, to: b, inPixel: false) }

    /// The same by a pixel spacing given, as -LengthFrom:to:inPixel: answers by the ROI's.
    @objc(LengthFrom:to:spacingX:spacingY:)
    static func laterSDKLength(from a: NSPoint, to b: NSPoint, spacingX: Double, spacingY: Double) -> Float {
        ROIPlanarGeometry.length(from: a, to: b, spacingX: spacingX, spacingY: spacingY, inPixels: false)
    }
    @objc(LengthInCmFrom:to:spacingX:spacingY:)
    static func laterSDKLengthInCm(from a: NSPoint, to b: NSPoint, spacingX: Double, spacingY: Double) -> Float {
        ROIPlanarGeometry.length(from: a, to: b, spacingX: spacingX, spacingY: spacingY, inPixels: false)
    }
    @objc(LengthInPixelsFrom:to:)
    static func laterSDKLengthInPixels(from a: NSPoint, to b: NSPoint) -> Float {
        ROIPlanarGeometry.length(from: a, to: b, spacingX: 0, spacingY: 0, inPixels: true)
    }
    @objc(formattedLengthForCM:) static func laterSDKFormattedLength(forCM centimetres: Float) -> String! { formattedLength(centimetres) }

    // MARK: Shape

    /// The rectangle around the ROI, in the image's pixels.
    @objc(boundRect) func laterSDKBoundRect() -> NSRect {
        switch _type {
        case .tROI:
            return _rect.standardized
        case .tOval:
            // The centre and the two radii.
            let radius = NSSize(width: abs(_rect.size.width), height: abs(_rect.size.height))
            return NSRect(x: _rect.origin.x - radius.width, y: _rect.origin.y - radius.height, width: 2 * radius.width, height: 2 * radius.height)
        case .tPlain:
            return NSRect(x: Int(_textureUpLeftCornerX), y: Int(_textureUpLeftCornerY),
                          width: Int(_textureDownRightCornerX - _textureUpLeftCornerX), height: Int(_textureDownRightCornerY - _textureUpLeftCornerY))
        default:
            let outline = ROI.points(of: _points)
            guard let first = outline.first else { return .zero }
            var low = first, high = first
            for point in outline {
                low = NSPoint(x: Swift.min(low.x, point.x), y: Swift.min(low.y, point.y))
                high = NSPoint(x: Swift.max(high.x, point.x), y: Swift.max(high.y, point.y))
            }
            return NSRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y)
        }
    }
    @objc(upperLeftCoordinate) func laterSDKUpperLeft() -> NSPoint { laterSDKBoundRect().origin }
    @objc(lowerRightCoordinate) func laterSDKLowerRight() -> NSPoint {
        let around = laterSDKBoundRect()
        return NSPoint(x: around.maxX, y: around.maxY)
    }

    /// The geometric centroid stands for the point the eye takes for the centre.
    @objc(visualCenter) func laterSDKVisualCenter() -> NSPoint { centroid() }

    /// Whether a point of the image is inside the ROI.
    @objc(isPointInside:) func laterSDKIsPointInside(_ point: NSPoint) -> Bool { (_pix ?? viewImage)?.isInROI(self, point) ?? false }
    /// The same for the column and the row of a pixel, the first two of `coordinates`.
    @objc(isInside:) func laterSDKIsInside(_ coordinates: UnsafeMutablePointer<Int32>?) -> Bool {
        guard let coordinates else { return false }
        return laterSDKIsPointInside(NSPoint(x: Int(coordinates[0]), y: Int(coordinates[1])))
    }
    @objc(isInside::) func laterSDKIsInside(_ coordinates: UnsafeMutablePointer<Int32>?, _ sliceInterval: Float) -> Bool { laterSDKIsInside(coordinates) }

    /// -valid, by the name later headers give it.
    @objc(isValid) func laterSDKIsValid() -> Bool { valid() }

    /// The same kind, shape, name and look.
    @objc(isEqualToROI:) func laterSDKIsEqual(to other: ROI?) -> Bool { other.map { $0 === self || $0.editSignature == editSignature } ?? false }

    /// A copy, as -copy answers it: a ROI of its own, asleep.
    @objc(duplicate) func laterSDKDuplicate() -> ROI? { copyROI(with: nil) }

    /// -clickInROI:::::, which tests the handles within the radius of the
    /// application and neither a hidden ROI nor one that cannot be selected.
    @objc(clickInROI:::::radius:)
    func laterSDKClick(_ point: NSPoint, _ offsetX: Float, _ offsetY: Float, _ scale: Float, _ testDrawRect: Bool, radius: Float) -> Int {
        click(inROI: point, offsetX, offsetY, scale, testDrawRect)
    }
    @objc(clickInROI:offsetx:offsety:scale:testDrawRect:radius:includeHidden:)
    func laterSDKClick(_ point: NSPoint, offsetx: Float, offsety: Float, scale: Float, testDrawRect: Bool, radius: Float, includeHidden: Bool) -> Int {
        click(inROI: point, offsetx, offsety, scale, testDrawRect)
    }
    @objc(clickInROI:offsetx:offsety:scale:testDrawRect:radius:includeHidden:includeNonSelectable:)
    func laterSDKClick(_ point: NSPoint, offsetx: Float, offsety: Float, scale: Float, testDrawRect: Bool, radius: Float, includeHidden: Bool, includeNonSelectable: Bool) -> Int {
        click(inROI: point, offsetx, offsety, scale, testDrawRect)
    }

    /// The handle under the pointer, -1 for none: what -setPointUnderMouse: sets.
    @objc(pointUnderMouse) func laterSDKPointUnderMouse() -> Int32 { PointUnderMouse }

    /// The lock a drawing of the ROI holds.
    @objc(lock) func laterSDKLock() { roiLock?.lock() }
    @objc(unlock) func laterSDKUnlock() { roiLock?.unlock() }

    // MARK: Brush

    /// The corners of the brush's texture, which the former SDK gave to read only.
    @objc(setTextureUpLeftCornerX:) func laterSDKSetTextureUpLeftCornerX(_ value: Int32) { _textureUpLeftCornerX = value }
    @objc(setTextureUpLeftCornerY:) func laterSDKSetTextureUpLeftCornerY(_ value: Int32) { _textureUpLeftCornerY = value }
    @objc(setTextureDownRightCornerX:) func laterSDKSetTextureDownRightCornerX(_ value: Int32) { _textureDownRightCornerX = value }
    @objc(setTextureDownRightCornerY:) func laterSDKSetTextureDownRightCornerY(_ value: Int32) { _textureDownRightCornerY = value }

    /// The bytes of the brush's texture, one for each of its pixels.
    @objc(textureBufferSize) func laterSDKTextureBufferSize() -> UInt {
        _textureBuffer == nil ? 0 : UInt(Swift.max(_textureWidth, 0)) * UInt(Swift.max(_textureHeight, 0))
    }

    // MARK: Text

    /// The lines of the label that have text, from the first.
    @objc(textualBoxLines) func laterSDKTextualBoxLines() -> [String] {
        let later = (7...10).map { LaterPluginSDK.kept("textualBoxLine\($0)", of: self, or: nil) as? String }
        return ([textualBoxLine1, textualBoxLine2, textualBoxLine3, textualBoxLine4, textualBoxLine5, textualBoxLine6] + later)
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// -description: the name and the measures, separated by tabs.
    @objc(niceDescription) func laterSDKNiceDescription() -> String { description }
    /// The names of the columns of -description.
    @objc(descriptionHeader) static func laterSDKDescriptionHeader() -> String { "Name\tMean\tMin\tMax\tTotal\tDev\tMedian\tUnit" }

    /// The height of the font of the labels, set with +setFontHeight:.
    @objc(fontHeight) static func laterSDKFontHeight() -> Float { fontHeight }

    private static func laterSDKFormatter(fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter
    }
    /// Decimal numbers with one, two and three fraction digits, in the user's locale.
    @objc(fmt1d) static func laterSDKFormatter1() -> NumberFormatter { laterSDKFormatter(fractionDigits: 1) }
    @objc(fmt2d) static func laterSDKFormatter2() -> NumberFormatter { laterSDKFormatter(fractionDigits: 2) }
    @objc(fmt3d) static func laterSDKFormatter3() -> NumberFormatter { laterSDKFormatter(fractionDigits: 3) }

    // MARK: Creation and archive

    /// A ROI of that kind for the image the view shows, with the image's
    /// pixel spacing and origin, as the tools of the viewer create theirs.
    @objc(initWithType:inView:)
    convenience init?(laterSDKType type: Int, inView view: DCMView?) {
        guard let kind = ToolMode(rawValue: Int16(truncatingIfNeeded: type)) else { return nil }
        let image = view.flatMap { unsafeBitCast($0, to: ROIDrawingView.self).curDCM }
        self.init(type: kind, Float(image?.pixelSpacingX ?? 0), Float(image?.pixelSpacingY ?? 0),
                  DCMPix.originCorrected(accordingToOrientation: image))
        _pix = image
        _curView = view
    }
    @objc(roiWithType:inView:) static func laterSDKROI(type: Int, inView view: DCMView?) -> ROI? { ROI(laterSDKType: type, inView: view) }

    /// The same with the pixel spacing and the origin given.
    @objc(initWithType:pixelSpacingX:pixelSpacingY:origin:dcmPix:dcmView:)
    convenience init?(laterSDKType type: Int, pixelSpacingX: Float, pixelSpacingY: Float, origin: NSPoint, dcmPix image: DCMPix?, dcmView view: DCMView?) {
        guard let kind = ToolMode(rawValue: Int16(truncatingIfNeeded: type)) else { return nil }
        self.init(type: kind, pixelSpacingX, pixelSpacingY, origin)
        _pix = image
        _curView = view
    }

    /// The archive of the ROI alone, as the files of ROIs hold each of theirs.
    @objc(writeToFile:) func laterSDKWrite(toFile path: String?) -> Bool {
        guard let path, let archive = data else { return false }
        return (try? archive.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    /// The ROI of an archive, or the first of an archive of several; nil for
    /// anything else, which the archive is not read to find out.
    @objc(unarchiveObjectWithData:) static func laterSDKUnarchive(_ archive: Data?) -> ROI? {
        let object = RestrictedUnarchiver.unarchiveObjectOrNil(with: archive, allowedClassNames: RestrictedUnarchiver.roiClassNames)
        return object as? ROI ?? (object as? [Any])?.first as? ROI
    }
    @objc(unarchiveObjectWithFile:) static func laterSDKUnarchive(file path: String?) -> ROI? {
        laterSDKUnarchive(path.flatMap { FileManager.default.contents(atPath: $0) })
    }
    @objc(readFromFile:) static func laterSDKRead(fromFile path: String?) -> ROI? { laterSDKUnarchive(file: path) }

    /// +resamplePoints:number:, along the outline back to its first point when it is closed.
    @objc(resamplePoints:number:closeROI:)
    static func laterSDKResample(_ points: [Any]?, number: Int32, closeROI: Bool) -> AnyObject? {
        var outline = points ?? []
        if closeROI, let first = outline.first { outline.append(first) }
        return resamplePoints(outline, number: number)
    }

    // MARK: Removal

    /// Takes the ROIs out of the views that show them, as the Delete key
    /// does for the selected ones: a locked ROI stays unless `evenIfLocked`.
    @objc(deleteROIs:postNotification:evenIfLocked:)
    static func laterSDKDelete(_ rois: [Any]?, postNotification: Bool, evenIfLocked: Bool) {
        let handed = Handed(value: (rois ?? []).compactMap { $0 as? ROI })
        guard !handed.value.isEmpty else { return }
        onMainActorSync {
            let removed = handed.value
            var views: [DCMView] = []
            for roi in removed {
                if evenIfLocked { roi.locked = false }
                if let view = roi.curView, !views.contains(where: { $0 === view }) { views.append(view) }
            }
            for view in views { view.deleteROIs(removed.filter { $0.curView === view }) }
        }
    }
    @objc(deleteROIs:postNotification:) static func laterSDKDelete(_ rois: [Any]?, postNotification: Bool) {
        laterSDKDelete(rois, postNotification: postNotification, evenIfLocked: false)
    }
    @objc(deleteROIs:) static func laterSDKDelete(_ rois: [Any]?) { laterSDKDelete(rois, postNotification: true, evenIfLocked: false) }
    @objc(deleteROI:) static func laterSDKDelete(roi: ROI?) { laterSDKDelete(roi.map { [$0] }, postNotification: true, evenIfLocked: false) }
}
