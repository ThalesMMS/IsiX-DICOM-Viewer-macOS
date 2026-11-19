//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Accelerate
import Foundation
import IsiXVolumeRendering

/// Selectors of the former Horos/OsiriX plug-in SDK on the fly-through
/// assistant: the steps of its work, which the SDK's header named one by one.
/// The assistant does them itself where it needs them; a plug-in that sends
/// one gets the same step of `FlyPathAssistant`. Those that take a
/// `std::vector<int>` are in FlyAssistant+LegacyPluginSDK.mm, which calls the
/// `isix…` methods below with the vector's storage.
extension FlyAssistant {
    private func vector(_ p: Point3D?) -> SIMD3<Float>? { p.map { SIMD3($0.x, $0.y, $0.z) } }

    // MARK: The distance map

    @objc(thresholdImage) public func legacyThresholdImage() { core.thresholdImage() }
    @objc(calculateSampleMetric:::) public func legacyCalculateSampleMetric(_ a: Float, _ b: Float, _ c: Float) -> Int32 { core.calculateSampleMetric(a, b, c) }
    @objc(resamplecrosssection:::) public func legacyResampleCrossSection(_ pt: Point3D?, _ dir: Point3D?, _ stepLength: Float) -> Int32 {
        guard let pt = vector(pt), let dir = vector(dir) else { return 0 }
        return core.resampleCrossSection(pt, dir, stepLength)
    }
    @objc(stepCostFrom:To:) public func legacyStepCost(from first: Int32, to second: Int32) -> Float { core.stepCost(to: Int(second)) }
    @objc(input3DCoords2LineCoords:::) public func legacyInputIndex(_ x: Int32, _ y: Int32, _ z: Int32) -> Int32 { core.inputIndex(x: x, y: y, z: z) }
    @objc(distMap3DCoords2LineCoords:::) public func legacyMapIndex(_ x: Int32, _ y: Int32, _ z: Int32) -> Int32 { core.mapIndex(x: x, y: y, z: z) }
    @objc(point:InVolumeX:Y:Z:) public func legacyPoint(_ p: Point3D?, inVolumeX x: Int32, y: Int32, z: Int32) -> Bool {
        vector(p).map { FlyPathAssistant.isPoint($0, insideVolume: SIMD3(x, y, z)) } ?? false
    }
    /// The voxels from `index` back to the seed of the search that wrote
    /// `labelmap`, added to `line` as OSIVoxels.
    @objc(trackCenterline:From:WithLabel:) public func legacyTrackCenterline(_ line: NSMutableArray?, from index: Int32, withLabel labelmap: UnsafeMutablePointer<UInt8>?) {
        guard let line, let labelmap else { return }
        for voxel in core.trackCenterline(from: Int(index), labelmap: labelmap) {
            line.add(OSIVoxel(x: Float(voxel.x), y: Float(voxel.y), z: Float(voxel.z), value: nil))
        }
    }

    // MARK: Morphology

    /// It made a Core Image median filter and applied nothing: the buffer stays as it is.
    @objc(medianFilter:) public func legacyMedianFilter(_ buffer: UnsafeMutablePointer<vImage_Buffer>?) {}
    @objc(mmOpening:::) public func legacyOpening(_ buffer: UnsafeMutablePointer<vImage_Buffer>?, _ x: vImagePixelCount, _ y: vImagePixelCount) {
        guard let buffer else { return }
        core.morphologicalOpening(&buffer.pointee, kernelHeight: Int(x), kernelWidth: Int(y))
    }
    @objc(mmClosing:::) public func legacyClosing(_ buffer: UnsafeMutablePointer<vImage_Buffer>?, _ x: vImagePixelCount, _ y: vImagePixelCount) {
        guard let buffer, x > 0, y > 0 else { return }
        core.morphologicalClosing(&buffer.pointee, kernelHeight: Int(x), kernelWidth: Int(y))
    }

    // MARK: The lumen's thresholds

    @objc(determineImageRange) public func legacyDetermineImageRange() { core.determineImageRange(); copyCoreState() }
    @objc(getInputMinMaxValues) public func legacyInputMinMaxValues() { core.determineInputMinMax(); copyCoreState() }
    @objc(computeHistogram) public func legacyComputeHistogram() { core.computeHistogram(); copyCoreState() }
    @objc(smoothHistogramWith:) public func legacySmoothHistogram(with window: UInt32) { core.smoothHistogram(window: Int(window)) }
    @objc(getLocalMinimaWith:from:) public func legacyLocalMinimum(with step: Int32, from value: vImagePixelCount) -> Int32 { core.localMinimum(step: step, from: value) }
    @objc(getLocalMaximaWith:from:) public func legacyLocalMaximum(with step: Int32, from value: vImagePixelCount) -> Int32 { core.localMaximum(step: step, from: value) }
    @objc(computeIntervalThresholdsFrom:) public func legacyComputeIntervalThresholds(from value: Float) { core.computeIntervalThresholds(from: value); copyCoreState() }
    @objc(autoComputeThresholdFromValue:) public func legacyAutoComputeThreshold(fromValue value: Float) { core.autoComputeThreshold(fromValue: value); copyCoreState() }
    @objc(autoComputeThresholdFromPoint:) public func legacyAutoComputeThreshold(fromPoint point: Point3D?) {
        if let point = vector(point) { core.autoComputeThreshold(atVoxel: point) }
        copyCoreState()
    }

    // MARK: A caller's histogram, for the std::vector selectors

    private func bins(_ start: UnsafeMutablePointer<Int32>?, _ count: Int) -> UnsafeMutableBufferPointer<Int32> {
        UnsafeMutableBufferPointer(start: start, count: start == nil ? 0 : max(count, 0))
    }
    @objc(isixAddSimpleHistogramTo:count:) public func isixAddSimpleHistogram(to start: UnsafeMutablePointer<Int32>?, count: Int) { core.addSimpleHistogram(to: bins(start, count)) }
    @objc(isixSmooth:count:window:) public func isixSmooth(_ start: UnsafeMutablePointer<Int32>?, count: Int, window: UInt32) { FlyPathAssistant.smooth(bins(start, count), window: Int(window)) }
    @objc(isixDetermineThresholdIntervalFrom:on:count:step:) public func isixDetermineThresholdInterval(from value: Int32, on start: UnsafeMutablePointer<Int32>?, count: Int, step: Int32) {
        core.determineThresholdInterval(from: value, on: UnsafeBufferPointer(bins(start, count)), step: step)
        copyCoreState()
    }
    @objc(isixLocalMinimumFrom:on:count:step:) public func isixLocalMinimum(from x: Int32, on start: UnsafeMutablePointer<Int32>?, count: Int, step: Int32) -> Int32 {
        FlyPathAssistant.localMinimum(from: x, on: UnsafeBufferPointer(bins(start, count)), step: step)
    }
    @objc(isixLocalMaximumFrom:on:count:step:) public func isixLocalMaximum(from x: Int32, on start: UnsafeMutablePointer<Int32>?, count: Int, step: Int32) -> Int32 {
        FlyPathAssistant.localMaximum(from: x, on: UnsafeBufferPointer(bins(start, count)), step: step)
    }
}
