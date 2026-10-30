//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation

// The operations on a loaded image, for the Objective-C image object that
// keeps its buffers and window in instance variables: flat class methods over
// its pointers and values. The work is the value types beside this file.

@objc(IsiXImageArithmetic)
public final class ImageArithmeticBridge: NSObject {
    @objc(productOf:and:width:height:offset:)
    public static func product(_ input: UnsafePointer<Float>, _ other: UnsafePointer<Float>, width: Int, height: Int,
                               offset: CGPoint) -> UnsafeMutablePointer<Float>? {
        ImageArithmetic.product(input, other, width: width, height: height, offset: offset)
    }

    @objc(differenceOf:and:width:height:offset:absolute:)
    public static func difference(_ input: UnsafePointer<Float>, _ other: UnsafePointer<Float>, width: Int, height: Int,
                                  offset: CGPoint, absolute: Bool) -> UnsafeMutablePointer<Float>? {
        ImageArithmetic.difference(input, other, width: width, height: height, offset: offset, absolute: absolute)
    }
}

@objc(IsiXMaskSubtraction)
public final class MaskSubtractionBridge: NSObject {
    @objc(zeroForPercent:z:)
    public static func zero(percent: Float, z: Float) -> Float {
        SubtractionSliders(percent: percent, gamma: 1, zero: z).zero
    }

    /// The window of a subtracted image, held to 2...512, and its gamma and zero.
    @objc(holdLevel:width:gamma:zero:)
    public static func hold(level: UnsafeMutablePointer<Float>, width: UnsafeMutablePointer<Float>,
                            gamma: UnsafeMutablePointer<Float>, zero: UnsafeMutablePointer<Float>) {
        let window = SubtractionSliders.window(level: level.pointee, width: width.pointee)
        level.pointee = window.level
        width.pointee = window.width
        gamma.pointee = window.gamma
        zero.pointee = window.zero
    }

    @objc(rangeOfFrame:mask:count:)
    public static func range(frame: UnsafePointer<Float>, mask: UnsafePointer<Float>, count: Int) -> CGPoint {
        MaskSubtractionImage.range(frame: frame, mask: mask, count: count)
    }

    @objc(subtractFrame:mask:width:height:offset:percent:zero:range:)
    public static func subtract(frame: UnsafePointer<Float>, mask: UnsafePointer<Float>, width: Int, height: Int,
                                offset: CGPoint, percent: Float, zero: Float, range: CGPoint) -> UnsafeMutablePointer<Float>? {
        var sliders = SubtractionSliders(percent: percent, gamma: 1, zero: 0)
        sliders.zero = zero
        return MaskSubtractionImage.subtract(frame: frame, mask: mask, width: width, height: height, offset: offset,
                                             sliders: sliders, range: range)
    }
}

@objc(IsiXImageWindow)
public final class ImageWindowBridge: NSObject {
    /// Sets `level` and `width` to the window a request asks for; NO when it
    /// asks for the full window.
    @objc(requestLevel:width:fullWidth:slope:)
    public static func request(level: UnsafeMutablePointer<Float>, width: UnsafeMutablePointer<Float>,
                               fullWidth: Float, slope: Float) -> Bool {
        guard let window = ImageWindow.requested(level: level.pointee, width: width.pointee, fullWidth: fullWidth, slope: slope) else {
            return false
        }
        level.pointee = window.level
        width.pointee = window.width
        return true
    }

    @objc(fullWindowOf:count:isRGB:level:width:)
    public static func full(_ pixels: UnsafePointer<Float>, count: Int, isRGB: Bool,
                            level: UnsafeMutablePointer<Float>, width: UnsafeMutablePointer<Float>) {
        let window = ImageWindow.full(pixels, count: count, isRGB: isRGB)
        level.pointee = window.level
        width.pointee = window.width
    }
}

@objc(IsiXWindowRendering)
public final class WindowRenderingBridge: NSObject {
    @objc(renderLinear:into:width:height:level:window:)
    public static func linear(_ pixels: UnsafePointer<Float>, into picture: UnsafeMutablePointer<UInt8>, width: Int, height: Int,
                              level: Float, window: Float) {
        WindowRendering.linear(pixels, into: picture, width: width, height: height, level: level, window: window)
    }

    @objc(render:into:width:height:level:window:table:threads:)
    public static func throughTable(_ pixels: UnsafePointer<Float>, into picture: UnsafeMutablePointer<UInt8>, width: Int,
                                    height: Int, level: Float, window: Float, table: UnsafePointer<Float>, threads: Int) {
        WindowRendering.throughTable(pixels, into: picture, width: width, height: height, level: level, window: window,
                                     table: table, threads: threads)
    }

    @objc(renderColour:into:width:height:level:window:table:)
    public static func colour(_ pixels: UnsafeRawPointer, into picture: UnsafeMutableRawPointer, width: Int, height: Int,
                              level: Float, window: Float, table: UnsafePointer<Float>?) {
        WindowRendering.colour(pixels, into: picture, width: width, height: height,
                               table: WindowRendering.colourTable(level: level, window: window, table: table))
    }

    @objc(invert:count:)
    public static func invert(_ picture: UnsafeMutablePointer<UInt8>, count: Int) {
        WindowRendering.invert(picture, count: count)
    }
}

@objc(IsiXImageConvolution)
public final class ImageConvolutionBridge: NSObject {
    /// The filtered image, in a new buffer the caller frees: grey floats, or
    /// ARGB bytes when `colour` is YES.
    @objc(filter:width:height:colour:weights:size:normalization:)
    public static func filter(_ pixels: UnsafeMutablePointer<Float>, width: Int, height: Int, colour: Bool,
                              weights: UnsafePointer<Float>, size: Int, normalization: Float) -> UnsafeMutablePointer<Float>? {
        let convolution = ImageConvolution(weights: weights, size: size, normalization: normalization)
        if colour {
            return convolution.filtered(argb: pixels, width: width, height: height)?.assumingMemoryBound(to: Float.self)
        }
        return convolution.filtered(pixels, width: width, height: height)
    }
}

@objc(IsiXSUVComputation)
public final class SUVComputationBridge: NSObject {
    /// Sets `dose` to the corrected dose, and `decayFactor` when the
    /// correction decides it.
    @objc(correctDose:decayFactor:decayCorrection:halflife:injection:acquisition:)
    public static func correct(dose: UnsafeMutablePointer<Float>, decayFactor: UnsafeMutablePointer<Float>, decayCorrection: String?,
                               halflife: Float, injection: Date?, acquisition: Date?) {
        let corrected = SUVComputation.correctedDose(decayCorrection: decayCorrection, dose: dose.pointee, halflife: halflife,
                                                     injection: injection, acquisition: acquisition)
        dose.pointee = corrected.dose
        if let factor = corrected.decayFactor { decayFactor.pointee = factor }
    }

    /// Whether the image has SUV; `correctsDose` says whether the dose
    /// correction has to run for it.
    @objc(hasSUVWithUnits:decayCorrection:philipsFactor:decayFactor:halflife:injection:acquisition:dose:isRGB:correctsDose:)
    public static func hasSUV(units: String?, decayCorrection: String?, philipsFactor: Float, decayFactor: Float, halflife: Float,
                              injection: Date?, acquisition: Date?, dose: Float, isRGB: Bool,
                              correctsDose: UnsafeMutablePointer<ObjCBool>) -> Bool {
        let availability = SUVComputation.availability(units: units, decayCorrection: decayCorrection, philipsFactor: philipsFactor,
                                                       decayFactor: decayFactor, halflife: halflife,
                                                       hasInjectionAndAcquisition: injection != nil && acquisition != nil,
                                                       dose: dose, isRGB: isRGB)
        correctsDose.pointee = ObjCBool(availability.correctsDose)
        return availability.hasSUV
    }

    @objc(appliedFactorConverted:factor:)
    public static func appliedFactor(converted: Bool, factor: Float) -> Float {
        SUVComputation.appliedFactor(converted: converted, factor: factor)
    }
}
