/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXROI

// The ROI measures of DCMPix: the pixels and locations inside a ROI, a line's
// profile, the point test, the statistics and the calcium cofactor. The class
// stays Objective-C; these are its methods, with the same selectors, declared
// for Objective-C callers in DCMPix+ROI.h. The rasterization (the clip, the
// scanline fill, Bresenham's line, the brush texture) is IsiXROI's: here the
// image's buffers and the ROI's points are handed to it.

/// What DCMPix asks a ROI, sent as the messages the Objective-C methods sent:
/// a ROI subclass or a stand-in answers them as it did, and a message to nil
/// answers nil, NO or 0. The protocol only names the selectors.
@objc protocol DCMPixROIMessages {
    var type: ToolMode { get }
    var points: NSMutableArray? { get }
    func splinePoints() -> NSMutableArray?
    var isSpline: Bool { get }
    var textureBuffer: UnsafeMutablePointer<UInt8>? { get }
    var textureWidth: Int32 { get }
    var textureHeight: Int32 { get }
    var textureUpLeftCornerX: Int32 { get }
    var textureUpLeftCornerY: Int32 { get }
    var median: Double { get set }
}

/// What DCMPix asks a point of a ROI (a MyPoint), as messages.
@objc protocol DCMPixPointMessages {
    var point: NSPoint { get }
    var x: Float { get }
    var y: Float { get }
}

/// The ROI, as the messages it is sent; nil stays nil.
@inline(__always)
func roiMessages(_ roi: ROI?) -> DCMPixROIMessages? {
    unsafeBitCast(roi, to: DCMPixROIMessages?.self)
}

/// An element of a ROI's points, as the messages it is sent.
@inline(__always)
func pointMessages(_ object: Any) -> DCMPixPointMessages {
    unsafeBitCast(object as AnyObject, to: DCMPixPointMessages.self)
}

extension DCMPix {

    /// The ROI's points (or spline points) on the pixel grid.
    fileprivate static func pixelPoints(_ points: NSArray) -> [ROIPixelPoint] {
        points.map { ROIPixelPoint(pointMessages($0).point) }
    }

    /// The brush texture of `roi` on this image.
    static func texture(_ roi: DCMPixROIMessages) -> ROITexture {
        ROITexture(bytes: UnsafePointer(roi.textureBuffer), width: Int(roi.textureWidth), height: Int(roi.textureHeight),
                   originX: Int(roi.textureUpLeftCornerX), originY: Int(roi.textureUpLeftCornerY))
    }

    /// The values of the pixels inside `roi`, malloc'd (the caller frees them),
    /// their number in `numberOfValues` and, if asked, their (x, y) in
    /// `locations` (malloc'd too). The image measured is the one measurements
    /// use (-computefImageForMeasurement), or the 8-bit ARGB one for a colour
    /// image or a thick slab VR; an ARGB pixel counts as the mean of its colours.
    @objc(getROIValue:::)
    public dynamic func getROIValue(_ numberOfValues: UnsafeMutablePointer<Int>?, _ roi: ROI?,
                            _ locations: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?) -> UnsafeMutablePointer<Float>! {
        // Several paths below return without reaching the assignment at the
        // end, and both callers read these before testing the result.
        let roi = roiMessages(roi)
        numberOfValues?.pointee = 0
        locations?.pointee = nil

        var count = 0
        var values: UnsafeMutablePointer<Float>?
        var isRGBImage = isRGB
        var computed: UnsafeMutablePointer<Float>?
        var withoutPoints = false

        do {
            try HorosObjCException.perform {
                if self.thickSlabVRActivated() {
                    isRGBImage = true
                } else {
                    computed = self.computefImageForMeasurement()
                }
                if isRGBImage {
                    computed = UnsafeMutableRawPointer(self.baseAddr).map { $0.assumingMemoryBound(to: Float.self) }
                }
                guard let roi else { return }
                let width = self.horos_width, height = self.horos_height

                if roi.type == .tPlain {
                    let texture = DCMPix.texture(roi)
                    let room = texture.width * texture.height
                    values = malloc(room * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
                    if let locations {
                        locations.pointee = malloc(room * 2 * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
                    }
                    if let values, let computed {
                        count = ROIBrushRaster.sample(texture, image: computed, imageWidth: width, imageHeight: height, isRGB: isRGBImage,
                                                      values: values, locations: locations?.pointee)
                    }
                    return
                }

                let splinePoints = roi.splinePoints() ?? NSMutableArray()
                if splinePoints.count == 0 {
                    withoutPoints = true
                    return
                }
                self.checkLoad()

                var points = DCMPix.pixelPoints(splinePoints)
                let clip = points.contains { $0.x < 0 || $0.y < 0 || $0.x >= width || $0.y >= height }

                if points.count == 1 {
                    values = malloc(MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
                    if let locations {
                        locations.pointee = malloc(2 * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
                    }
                    let point = points[0]
                    if clip {
                        values?[0] = 0
                    } else if let computed {
                        let index = point.y &* width &+ point.x
                        if isRGBImage {
                            let pixel = UnsafeMutableRawPointer(computed).assumingMemoryBound(to: UInt8.self) + index * 4
                            values?[0] = Float(Double(Int(pixel[1]) + Int(pixel[2]) + Int(pixel[3])) / 3.0)
                        } else {
                            values?[0] = computed[index]
                        }
                    }
                    if let location = locations?.pointee {
                        location[0] = Float(point.x)
                        location[1] = Float(point.y)
                    }
                    count = 1
                    return
                }

                if clip {
                    points = ROIPolygonClip.clip(points, min: .zero, max: NSPoint(x: Double(width), y: Double(height)))
                }
                guard points.count > 2 else { return }

                // The box of the points, on the image.
                var upLeftX = points[0].x, upLeftY = points[0].y, downRightX = upLeftX, downRightY = upLeftY
                for point in points {
                    upLeftX = min(upLeftX, point.x); upLeftY = min(upLeftY, point.y)
                    downRightX = max(downRightX, point.x); downRightY = max(downRightY, point.y)
                }
                upLeftX = min(max(upLeftX, 0), width); downRightX = min(max(downRightX, 0), width)
                upLeftY = min(max(upLeftY, 0), height); downRightY = min(max(downRightY, 0), height)

                let room = ((downRightX - upLeftX) + 2) * ((downRightY - upLeftY) + 2)
                values = malloc(room * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
                if let locations {
                    locations.pointee = malloc(room * 2 * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
                }
                // Measurement reads this 2D buffer at slice zero. MPR planes
                // have pixels without an owning pixArray.
                if let values, let computed {
                    count = ROIPolygonFill.sample(points, image: computed, width: width, height: height, isRGB: isRGBImage,
                                                  values: values, locations: locations?.pointee, capacity: room,
                                                  outOfRange: DCMPix.logEdgeOutOfRange)
                }
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(exception, true, "-[DCMPix getROIValue:::]")
            }
        }

        if let computed, !isRGBImage, computed != self.fImage {
            free(computed)
        }
        if withoutPoints { return nil }
        numberOfValues?.pointee = count
        return values
    }

    /// The scanline fill met a vertex outside its edge table.
    static func logEdgeOutOfRange(_ y1: Int, _ y2: Int) {
        N2LogStackTraceMessage(String(format: "ras_FillPolygon: vertex outside the edge table (%ld, %ld)", y1, y2))
    }

    /// The values along a line ROI, from its first point to its second, as
    /// -getPixelValueX:Y: reads them (zero off the image), malloc'd.
    @objc(getLineROIValue::)
    public dynamic func getLineROIValue(_ numberOfValues: UnsafeMutablePointer<Int>?, _ roi: ROI?) -> UnsafeMutablePointer<Float>! {
        let roi = roiMessages(roi)
        let points = roi?.points ?? NSMutableArray()
        checkLoad()

        // A ROI's points: the first two make the line (an NSRangeException with fewer, as before).
        var floats: [(Float, Float)] = [(0, 0), (0, 0)]
        if roi != nil {
            for k in 0..<2 {
                let point = pointMessages(points.object(at: k))
                floats[k] = (point.x, point.y)
            }
        }
        let width = horos_width, height = horos_height
        let line = ROILineRaster.pixels(fromX: ROIRasterConversion.int32(Double(floats[0].0)), y: ROIRasterConversion.int32(Double(floats[0].1)),
                                        toX: ROIRasterConversion.int32(Double(floats[1].0)), y: ROIRasterConversion.int32(Double(floats[1].1)))
        var count = 0
        let values = malloc(line.x.count * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
        if let values {
            for i in line.x.indices {
                let x = line.x[i], y = line.y[i]
                values[count] = y >= 0 && y < height && x >= 0 && x < width ? getPixelValueX(x, y: y) : 0
                count += 1
            }
        }
        numberOfValues?.pointee = count
        return values
    }

    /// Whether the image point `pt` is inside `roi`: a painted pixel of a
    /// brush, the box of a rectangle, the even-odd rule for the others.
    @objc(isInROI::)
    public dynamic func isInROI(_ roi: ROI?, _ pt: NSPoint) -> Bool {
        checkLoad()
        guard let roi = roiMessages(roi) else { return false }
        if roi.type == .tPlain {
            return DCMPix.texture(roi).contains(pt)
        }
        let splinePoints = roi.splinePoints() ?? NSMutableArray()
        let first = pointMessages(splinePoints.object(at: 0))
        var minX = ROIRasterConversion.long(first.x), maxX = minX
        var minY = ROIRasterConversion.long(first.y), maxY = minY
        // Compared as floats, kept truncated: the C compared a long with a float.
        for object in splinePoints {
            let point = pointMessages(object)
            if Float(minX) > point.x { minX = ROIRasterConversion.long(point.x) }
            if Float(maxX) < point.x { maxX = ROIRasterConversion.long(point.x) }
            if Float(minY) > point.y { minY = ROIRasterConversion.long(point.y) }
            if Float(maxY) < point.y { maxY = ROIRasterConversion.long(point.y) }
        }
        if pt.x < Double(minX) || pt.x > Double(maxX) { return false }
        if pt.y < Double(minY) || pt.y > Double(maxY) { return false }
        if roi.type == .tROI { return true }

        let polygon = splinePoints.map { pointMessages($0).point }
        return ROIPolygonContainment.contains(polygon, x: Float(ROIRasterConversion.long(Double(pt.x))),
                                              y: Float(ROIRasterConversion.long(Double(pt.y))))
    }

    /// The calcium scoring cofactor of a brush ROI (zero for another kind).
    @objc(calciumCofactorForROI:threshold:)
    public dynamic func calciumCofactor(for roi: ROI?, threshold: Int32) -> Int32 {
        checkLoad()
        guard let roi = roiMessages(roi), roi.type == .tPlain else { return 0 }
        guard let image = horos_fImage else { return 1 }
        return ROIBrushRaster.calciumCofactor(DCMPix.texture(roi), image: image, imageWidth: horos_width, imageHeight: horos_height,
                                              isRGB: isRGB, threshold: threshold)
    }

    @objc(computeROI::::::)
    public dynamic func computeROI(_ roi: ROI?, _ mean: UnsafeMutablePointer<Float>?, _ total: UnsafeMutablePointer<Float>?,
                           _ dev: UnsafeMutablePointer<Float>?, _ min: UnsafeMutablePointer<Float>?, _ max: UnsafeMutablePointer<Float>?) {
        computeROI(roi, mean, total, dev, min, max, nil, nil)
    }

    /// The statistics of the pixels inside `roi`: mean, total, deviation,
    /// minimum and maximum, the skewness and kurtosis when the preference
    /// asks for them (zero otherwise), and the ROI's median. The arithmetic
    /// is IsiXROI's.
    @objc(computeROI::::::::)
    public dynamic func computeROI(_ roi: ROI?, _ mean: UnsafeMutablePointer<Float>?, _ total: UnsafeMutablePointer<Float>?,
                           _ dev: UnsafeMutablePointer<Float>?, _ min: UnsafeMutablePointer<Float>?, _ max: UnsafeMutablePointer<Float>?,
                           _ skewness: UnsafeMutablePointer<Float>?, _ kurtosis: UnsafeMutablePointer<Float>?) {
        var skewness = skewness, kurtosis = kurtosis
        if !UserDefaults.standard.bool(forKey: "ROIComputeSkewnessAndKurtosis") {
            skewness?.pointee = 0
            kurtosis?.pointee = 0
            skewness = nil
            kurtosis = nil
        }

        var count = 0
        let values = getROIValue(&count, roi, nil)

        // The pixels go to IsiXROI as its own samples: the arithmetic does not see DCMPix.
        let samples = ROIPixelSamples(values: values.map { UnsafePointer($0) }, count: count)
        let statistics = ROIPixelStatistics(samples: samples, deviation: dev != nil, higherMoments: skewness != nil || kurtosis != nil)

        dev?.pointee = statistics.deviation
        max?.pointee = statistics.maximum
        min?.pointee = statistics.minimum
        total?.pointee = statistics.total
        mean?.pointee = statistics.mean
        kurtosis?.pointee = statistics.kurtosis
        skewness?.pointee = statistics.skewness

        roiMessages(roi)?.median = ROIPixelStatistics.median(of: samples)

        free(values)
    }

    @objc(moment:length:mean:order:)
    public static dynamic func moment(_ x: UnsafeMutablePointer<Float>?, length: Int, mean: Double, order: Int32) -> Double {
        ROIPixelStatistics.moment(of: ROIPixelSamples(values: x.map { UnsafePointer($0) }, count: length), mean: mean, order: order)
    }

    /// The third central moment divided by the third power of the standard deviation.
    @objc(skewness:length:mean:)
    public static dynamic func skewness(_ data: UnsafeMutablePointer<Float>?, length: Int, mean: Double) -> Double {
        ROIPixelStatistics.skewness(of: ROIPixelSamples(values: data.map { UnsafePointer($0) }, count: length), mean: mean)
    }

    /// The fourth central moment divided by the fourth power of the standard deviation.
    @objc(kurtosis:length:mean:)
    public static dynamic func kurtosis(_ data: UnsafeMutablePointer<Float>?, length: Int, mean: Double) -> Double {
        ROIPixelStatistics.kurtosis(of: ROIPixelSamples(values: data.map { UnsafePointer($0) }, count: length), mean: mean)
    }
}
