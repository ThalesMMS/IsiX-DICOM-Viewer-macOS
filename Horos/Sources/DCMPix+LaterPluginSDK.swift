//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

// Selectors of DCMPix that only later headers of the plugin SDK declare and
// the application has something behind. A plugin built with those headers
// sends them by name, from any thread.
extension DCMPix {
    /// -initWithPath::::::, which later headers give one more argument: the
    /// size of the pixels handed in, which the image does not need to keep.
    @objc(initWithPath::::size:::)
    convenience init?(laterSDKPath path: String?, _ position: Int, _ total: Int, _ pixels: UnsafeMutablePointer<Float>?, size: UInt, _ frame: Int, _ series: Int) {
        self.init(path: path, position, total, pixels, frame, series)
    }

    /// -initWithPath::::::isBonjour:imageObj:, in the same way.
    @objc(initWithPath::::size:::isBonjour:imageObj:)
    convenience init?(laterSDKPath path: String?, _ position: Int, _ total: Int, _ pixels: UnsafeMutablePointer<Float>?, size: UInt, _ frame: Int, _ series: Int,
                      isBonjour: Bool, imageObj: NSManagedObject?) {
        self.init(path: path, position, total, pixels, frame, series, isBonjour: isBonjour, imageObj: imageObj)
    }

    /// -computeROI::::::::, which later headers also give with the median
    /// of the values after their mean: the median the measure leaves in the ROI.
    @objc(computeROI:::::::::)
    func laterSDKComputeROI(_ roi: ROI?, _ mean: UnsafeMutablePointer<Float>?, _ median: UnsafeMutablePointer<Float>?,
                            _ total: UnsafeMutablePointer<Float>?, _ dev: UnsafeMutablePointer<Float>?, _ min: UnsafeMutablePointer<Float>?,
                            _ max: UnsafeMutablePointer<Float>?, _ skewness: UnsafeMutablePointer<Float>?, _ kurtosis: UnsafeMutablePointer<Float>?) {
        computeROI(roi, mean, total, dev, min, max, skewness, kurtosis)
        median?.pointee = roi.map { Float($0.median) } ?? 0
    }

    // The measures of a ROI that is a ball through several images. The
    // application has no such ROI: every measure asked for is zero, so that
    // the caller does not read what it never set, and the two dictionaries
    // are left as they were.
    private func laterSDKNoBallMeasure(_ measures: UnsafeMutablePointer<Float>?...) {
        FormerSDKFacade.inert("DCMPix", "-computeBallROI:", because: LaterPluginSDK.noFeature)
        for measure in measures { measure?.pointee = 0 }
    }
    @objc(computeBallROI::::::::)
    func laterSDKComputeBallROI(_ roi: ROI?, _ mean: UnsafeMutablePointer<Float>?, _ total: UnsafeMutablePointer<Float>?, _ dev: UnsafeMutablePointer<Float>?,
                                _ min: UnsafeMutablePointer<Float>?, _ max: UnsafeMutablePointer<Float>?, _ skewness: UnsafeMutablePointer<Float>?,
                                _ kurtosis: UnsafeMutablePointer<Float>?) {
        laterSDKNoBallMeasure(mean, total, dev, min, max, skewness, kurtosis)
    }
    @objc(computeBallROI::::::::::)
    func laterSDKComputeBallROI(_ roi: ROI?, _ mean: UnsafeMutablePointer<Float>?, _ total: UnsafeMutablePointer<Float>?, _ dev: UnsafeMutablePointer<Float>?,
                                _ min: UnsafeMutablePointer<Float>?, _ max: UnsafeMutablePointer<Float>?, _ skewness: UnsafeMutablePointer<Float>?,
                                _ kurtosis: UnsafeMutablePointer<Float>?, _ peakValue: AnyObject?, _ isoContour: AnyObject?) {
        laterSDKNoBallMeasure(mean, total, dev, min, max, skewness, kurtosis)
    }
    @objc(computeBallROI:::::::::::)
    func laterSDKComputeBallROI(_ roi: ROI?, _ mean: UnsafeMutablePointer<Float>?, _ median: UnsafeMutablePointer<Float>?, _ total: UnsafeMutablePointer<Float>?,
                                _ dev: UnsafeMutablePointer<Float>?, _ min: UnsafeMutablePointer<Float>?, _ max: UnsafeMutablePointer<Float>?,
                                _ skewness: UnsafeMutablePointer<Float>?, _ kurtosis: UnsafeMutablePointer<Float>?, _ peakValue: AnyObject?,
                                _ isoContour: AnyObject?) {
        laterSDKNoBallMeasure(mean, median, total, dev, min, max, skewness, kurtosis)
    }

    /// Sets the pixels inside the ROI, or outside it, to a value whatever
    /// they hold, in this image alone: the longer -fillROI:… with no limits.
    @objc(fillROI:newVal:outside:)
    func laterSDKFillROI(_ roi: ROI?, newVal: Float, outside: Bool) {
        fillROI(roi, newVal: newVal, minValue: -Float.greatestFiniteMagnitude, maxValue: Float.greatestFiniteMagnitude, outside: outside,
                orientationStack: 2, stackNo: 0, restore: false, addition: false)
    }

    // Setters of what the former SDK gave to read only.
    @objc(setGenerated:) func laterSDKSetGenerated(_ generated: Bool) { horos_generated = generated }
    @objc(setSpacingBetweenSlices:) func laterSDKSetSpacingBetweenSlices(_ spacing: Double) { horos_spacingBetweenSlices = spacing }
    /// The flip angle, which the image keeps as the text of its DICOM attribute.
    @objc(setFlipAngle:) func laterSDKSetFlipAngle(_ angle: Float) { horos_flipAngle = String(format: "%g", Double(angle)) as NSString }

    /// The image of a file, the first of its frames, which loads its own pixels when they are asked for.
    @objc(dcmPixWithPath:) static func laterSDKImage(withPath path: String?) -> DCMPix? {
        guard let path else { return nil }
        return DCMPix(path: path, 0, 1, nil, 0, 0)
    }
}
