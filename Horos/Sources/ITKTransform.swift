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
import IsiXSegmentation

/// The resampling of a series through an affine transform, by ITK: the
/// moving series (the viewer given at creation) is sampled on the slices of a
/// reference series (Fusion > Resample, point registration), or one slice is
/// reoriented onto another's plane (gantry tilt correction). The grid is
/// IsiXSegmentation's AffineResampleGrid; ITK is reached through the adapter's
/// IsiXITKResampler. The new viewer of the result is in
/// ITKTransform+Viewer.swift. The Objective-C selectors are those of the
/// former Objective-C++ class.
@MainActor
@objc(ITKTransform)
public final class ITKTransform: NSObject {

    /// The viewer of the moving series, not retained, as before: the
    /// resampling closes it.
    weak var originalViewer: ViewerController?
    /// The moving series' volume, as ITK reads it.
    let volume: IsiXITKVolume

    /// The resampling of `viewer`'s series. nil without a series.
    @objc(initWithViewer:)
    public init?(viewer: ViewerController!) {
        guard let viewer,
              let volume = ITKVolumeImport.volume(pix: viewer.pixList(), voxels: viewer.volumePtr(), slice: -1, resampleData: false) else {
            return nil
        }
        self.originalViewer = viewer
        self.volume = volume
        super.init()
    }

    @objc(resampleWithParameters:firstObject:firstObjectOriginal:noOfImages:length:itkImage:)
    public class func resample(withParameters theParameters: UnsafeMutablePointer<Double>!, firstObject: DCMPix!,
                               firstObjectOriginal: DCMPix!, noOfImages: Int32, length: UnsafeMutablePointer<Int>!,
                               itkImage: IsiXITKVolume!) -> UnsafeMutablePointer<Float>? {
        return resample(withParameters: theParameters, firstObject: firstObject, firstObjectOriginal: firstObjectOriginal,
                        noOfImages: noOfImages, length: length, itkImage: itkImage, rescale: true)
    }

    /// The moving series (`itkImage`, whose first slice is
    /// `firstObjectOriginal`) through the affine transform of the 12
    /// `theParameters`, on `noOfImages` slices of the reference series whose
    /// first slice is `firstObject`: at the reference's size and pixel spacing
    /// when `rescale`, else at the moving series'. Voxels outside the moving
    /// series get its lowest value. A new malloc'ed buffer, its byte count in
    /// `length`; nil when it cannot be made.
    @objc(resampleWithParameters:firstObject:firstObjectOriginal:noOfImages:length:itkImage:rescale:)
    public class func resample(withParameters theParameters: UnsafeMutablePointer<Double>!, firstObject: DCMPix!,
                               firstObjectOriginal: DCMPix!, noOfImages: Int32, length: UnsafeMutablePointer<Int>!,
                               itkImage: IsiXITKVolume!, rescale: Bool) -> UnsafeMutablePointer<Float>? {
        guard let theParameters, let firstObject, let firstObjectOriginal, let itkImage else { return nil }

        var vectorReference = [Double](repeating: 0, count: 9), vectorOriginal = [Double](repeating: 0, count: 9)
        firstObject.orientationDouble(&vectorReference)
        firstObjectOriginal.orientationDouble(&vectorOriginal)

        // The DICOM origin is the centre of the first voxel, and so is an ITK
        // image's origin: it is passed as it is, in the series' own frame.
        let originConverted = AffineResampleGrid.rotated([firstObjectOriginal.originX, firstObjectOriginal.originY,
                                                          firstObjectOriginal.originZ], by: vectorOriginal)
        do {
            try itkImage.setOrigin(originConverted)
        } catch {
            NSLog("Resampling failed: %@", error.localizedDescription)
            return nil
        }

        // Output voxel (i, j, k) is shown at the DICOM position of the
        // reference's slice k.
        let grid = AffineResampleGrid.grid(rescale: rescale, imageCount: Int(noOfImages),
                                           referenceOrigin: [firstObject.originX, firstObject.originY, firstObject.originZ],
                                           referenceOrientation: vectorReference,
                                           referenceWidth: firstObject.pwidth, referenceHeight: firstObject.pheight,
                                           referenceSpacingX: firstObject.pixelSpacingX, referenceSpacingY: firstObject.pixelSpacingY,
                                           referenceInterval: firstObject.sliceInterval,
                                           originalWidth: firstObjectOriginal.pwidth, originalHeight: firstObjectOriginal.pheight,
                                           originalSpacingX: firstObjectOriginal.pixelSpacingX,
                                           originalSpacingY: firstObjectOriginal.pixelSpacingY)

        var splash: WaitRendering? = nil
        if noOfImages > 2 {
            splash = WaitRendering(NSLocalizedString("Resampling...", comment: ""))
        }
        splash?.showWindow(self)
        defer { splash?.close() }

        guard grid.byteCount >= 0, let fVolumePtr = malloc(max(grid.byteCount, 1))?.assumingMemoryBound(to: Float.self) else {
            return nil
        }
        do {
            try IsiXITKResampler.resample(itkImage, parameters: theParameters, origin: grid.origin, spacing: grid.spacing,
                                          size: grid.size, defaultValue: firstObjectOriginal.minValueOfSeries,
                                          into: fVolumePtr, length: grid.byteCount)
        } catch {
            NSLog("Resampling failed: %@", error.localizedDescription)
            free(fVolumePtr)
            return nil
        }
        length?.pointee = grid.byteCount
        return fVolumePtr
    }

    /// The slice `firstObjectOriginal` reoriented onto the plane of
    /// `firstObject` through the affine transform of the 12 `theParameters`:
    /// the slice is imported twice, 1000 mm apart, and resampled onto one
    /// slice of `firstObject`'s size. A new malloc'ed buffer, its byte count
    /// in `length`.
    @objc(reorient2Dimage:firstObject:firstObjectOriginal:length:)
    public class func reorient2Dimage(_ theParameters: UnsafeMutablePointer<Double>!, firstObject: DCMPix!,
                                      firstObjectOriginal: DCMPix!, length: UnsafeMutablePointer<Int>!) -> UnsafeMutablePointer<Float>? {
        guard let firstObjectOriginal, let image = firstObjectOriginal.fImage else { return nil }
        let size = firstObjectOriginal.pwidth * firstObjectOriginal.pheight

        let twice = UnsafeMutablePointer<Float>.allocate(capacity: max(size * 2, 1))
        defer { twice.deallocate() }
        twice.update(from: image, count: size)
        (twice + size).update(from: image, count: size)

        let pair = NSArray(array: [firstObjectOriginal, firstObjectOriginal])
        guard let volume = ITKVolumeImport.volume(pix: pair, voxels: twice, slice: -2, resampleData: false) else { return nil }
        return resample(withParameters: theParameters, firstObject: firstObject, firstObjectOriginal: firstObjectOriginal,
                        noOfImages: 1, length: length, itkImage: volume)
    }

    @objc(computeAffineTransformWithParameters:resampleOnViewer:)
    public func computeAffineTransform(withParameters theParameters: UnsafeMutablePointer<Double>!,
                                       resampleOnViewer referenceViewer: ViewerController!) -> ViewerController! {
        return computeAffineTransform(withParameters: theParameters, resampleOnViewer: referenceViewer,
                                      rescale: UserDefaults.standard.bool(forKey: "RescaleDuring3DResampling"))
    }

    /// The moving series resampled on `referenceViewer`'s slices through the
    /// affine transform of the 12 `theParameters`, in a new viewer.
    @objc(computeAffineTransformWithParameters:resampleOnViewer:rescale:)
    public func computeAffineTransform(withParameters theParameters: UnsafeMutablePointer<Double>!,
                                       resampleOnViewer referenceViewer: ViewerController!, rescale: Bool) -> ViewerController! {
        guard let referenceViewer, let originalViewer,
              let firstObject = referenceViewer.pixList()?.firstObject as? DCMPix,
              let firstObjectOriginal = originalViewer.pixList()?.firstObject as? DCMPix else { return nil }
        let noOfImages = Int32(truncatingIfNeeded: referenceViewer.pixList()?.count ?? 0)
        var length = 0

        let resultBuff = ITKTransform.resample(withParameters: theParameters, firstObject: firstObject,
                                               firstObjectOriginal: firstObjectOriginal, noOfImages: noOfImages,
                                               length: &length, itkImage: volume, rescale: rescale)

        return createNewViewer(withBuffer: resultBuff, length: length, resampleOnViewer: referenceViewer, rescale: rescale)
    }
}
