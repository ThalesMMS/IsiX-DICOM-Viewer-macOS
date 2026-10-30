/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXImaging

/// The point-set registration of a viewer onto another: the model points of
/// one, the sensor points of the other, and the similarity that carries the
/// first onto the second (PointSetRegistration, IsiXImaging).
///
/// Implemented in Swift: the Objective-C name and the selectors are those of
/// the former class, which computed the registration with VTK's
/// vtkLandmarkTransform.
@objc(HornRegistration)
final class HornRegistration: NSObject {
    private var modelPoints: [SIMD3<Double>] = []
    private var sensorPoints: [SIMD3<Double>] = []

    @objc(addModelPointX:Y:Z:)
    func addModelPointX(_ x: Double, y: Double, z: Double) {
        modelPoints.append(SIMD3(x, y, z))
    }

    @objc(addSensorPointX:Y:Z:)
    func addSensorPointX(_ x: Double, y: Double, z: Double) {
        sensorPoints.append(SIMD3(x, y, z))
    }

    @objc(addModelPoint:)
    func addModelPoint(_ point: UnsafePointer<Double>) {
        modelPoints.append(SIMD3(point[0], point[1], point[2]))
    }

    @objc(addSensorPoint:)
    func addSensorPoint(_ point: UnsafePointer<Double>) {
        sensorPoints.append(SIMD3(point[0], point[1], point[2]))
    }

    /// The number of point pairs, or -1 when the two sets differ; to be
    /// asked once every point has been added.
    @objc func numberOfPoint() -> Int16 {
        let modelCount = Int16(truncatingIfNeeded: modelPoints.count)
        let sensorCount = Int16(truncatingIfNeeded: sensorPoints.count)
        return modelCount == sensorCount ? modelCount : -1
    }

    /// The registration's rotation, row by row, in `matrixResult[0...8]` and
    /// its translation in `matrixResult[9...11]`. Nothing without points.
    @objc(computeVTK:)
    func computeVTK(_ matrixResult: UnsafeMutablePointer<Double>!) {
        let count = Int(numberOfPoint())
        guard count > 0, let matrixResult,
              let matrix = PointSetRegistration.similarity(model: Array(modelPoints.prefix(count)),
                                                           sensor: Array(sensorPoints.prefix(count))) else { return }
        let values = PointSetRegistration.rotationAndTranslation(matrix)
        for row in 0..<3 {
            for column in 0..<3 { matrixResult[3 * row + column] = values[3 * row + column] }
            NSLog("%f %f %f", matrixResult[3 * row], matrixResult[3 * row + 1], matrixResult[3 * row + 2])
        }
        for i in 9..<12 { matrixResult[i] = values[i] }
    }

    /// The rotation and translation of the former etkRegistration, which no
    /// longer computes: NULL, as they always were.
    @objc func rotation() -> UnsafeMutablePointer<Double>? { nil }
    @objc func translation() -> UnsafeMutablePointer<Double>? { nil }
}
