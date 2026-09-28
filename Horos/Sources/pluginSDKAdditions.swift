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

/** Additional methods used by the Plugin SDK

 */
extension ViewerController {

    ///-----------------------------------
    /// @name Working with the Volume Window
    ///-----------------------------------

    /** Returns the Volume Window that is paired with the receiver.

     @return The Volume Window that is paired with the receiver.

     @see [OSIEnvironment volumeWindowForViewerController:]
     @see [OSIEnvironment openVolumeWindows]
     */
    @objc(volumeWindow)
    public func volumeWindow() -> OSIVolumeWindow! {
        return OSIEnvironment.shared().volumeWindow(for: self)
    }

    //- (OSIFloatVolumeData *)floatVolumeDataForMovieIndex:(long)index
    //{
    //	return [[[OSIFloatVolumeData alloc] initWithWithPixList:pixList[index] volume:volumeData[index]] autorelease];
    //}
}

/** Additional methods used by the Plugin SDK

 */
extension DCMPix {

    ///-----------------------------------
    /// @name Getting a Transformation Matrix
    ///-----------------------------------

    /** Returns a transformation matrix that converts pixel coordinates in the receiver to coordinates in Patient Space (Dicom space in mm).

     See also:

     [DCMView viewToPixTransform] defined in DCMView(CPRAdditions) in CPRMPRDCMView.h

     [DCMView pixToSubDrawRectTransform] defined in DCMView(CPRAdditions) in CPRMPRDCMView.h

     @return A transformation matrix that converts pixel coordinates in the receiver to coordinates in Patient Space (Dicom space in mm).
     */
    @objc(pixToDicomTransform)
    public func pixToDicomTransform() -> N3AffineTransform { // converts points in the DCMPix's coordinate space ("Slice Coordinates") into the DICOM space (patient space with mm units)
        var pixToDicomTransform: N3AffineTransform
        var spacingX: Double
        var spacingY: Double
        //    double spacingZ;
        var pixOrientation = [Double](repeating: 0, count: 9)

        self.orientationDouble(&pixOrientation)

        if self._testOrientationMatrix(&pixOrientation) == false {
            pixOrientation = [Double](repeating: 0, count: 9)
            pixOrientation[0] = 1; pixOrientation[4] = 1; pixOrientation[8] = 1
        }

        spacingX = self.pixelSpacingX
        spacingY = self.pixelSpacingY
        //    spacingZ = pix.sliceInterval;

        pixToDicomTransform = N3AffineTransformIdentity
        pixToDicomTransform.m41 = self.originX
        pixToDicomTransform.m42 = self.originY
        pixToDicomTransform.m43 = self.originZ
        pixToDicomTransform.m11 = pixOrientation[0]*spacingX
        pixToDicomTransform.m12 = pixOrientation[1]*spacingX
        pixToDicomTransform.m13 = pixOrientation[2]*spacingX
        pixToDicomTransform.m21 = pixOrientation[3]*spacingY
        pixToDicomTransform.m22 = pixOrientation[4]*spacingY
        pixToDicomTransform.m23 = pixOrientation[5]*spacingY
        pixToDicomTransform.m31 = pixOrientation[6]
        pixToDicomTransform.m32 = pixOrientation[7]
        pixToDicomTransform.m33 = pixOrientation[8]

        return pixToDicomTransform
    }

    /// The former DCMPix (PrivatePluginSDKAdditions) method, kept under its
    /// selector: returns YES if the orientation matrix's determinant is non-zero.
    @objc(_testOrientationMatrix:)
    fileprivate func _testOrientationMatrix(_ orientationMatrix: UnsafeMutablePointer<Double>) -> Bool {
        var transform: N3AffineTransform

        transform = N3AffineTransformIdentity
        transform.m11 = orientationMatrix[0]
        transform.m12 = orientationMatrix[1]
        transform.m13 = orientationMatrix[2]
        transform.m21 = orientationMatrix[3]
        transform.m22 = orientationMatrix[4]
        transform.m23 = orientationMatrix[5]
        transform.m31 = orientationMatrix[6]
        transform.m32 = orientationMatrix[7]
        transform.m33 = orientationMatrix[8]

        return N3AffineTransformDeterminant(transform) != 0.0
    }
}
