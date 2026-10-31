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

import AppKit
import IsiXImaging

// The new series of a 2D viewer's reslice: for every time point, a new volume
// and its new slices, copies of the stack's first slice (its PET values
// included) with the geometry SeriesReslicePlan and SeriesReslice give. Their
// pixels are gathered from the stack on the process's SeriesResliceWorker,
// which this waits for: the reslice is a synchronous action of the viewer. The viewer then puts
// the new series in itself or in a new viewer (-processReslice::).

@MainActor enum ViewerSeriesReslice {

    /// The new slices, files and volume of one time point.
    struct Frame {
        let pixes: [DCMPix]
        let files: [Any]
        let volume: NSData
    }

    /// Every time point of `viewer` resliced along the rows (direction 0) or
    /// the columns of its slices, with the plan and the reference slice of its
    /// current time point, their pixels gathered on `worker`; nil when a stack
    /// is too small to reslice or a volume could not be allocated.
    static func frames(of viewer: ViewerController, direction: Int, worker: SeriesResliceWorker) -> [Frame]? {
        let stack = viewer.horos_pixArray(Int(viewer.horos_curMovieIndex))
        let referenceIndex = SeriesReslicePlan.referenceSliceIndex(sliceCount: stack.count)
        guard let first = stack.first, stack.indices.contains(referenceIndex) else { return nil }
        let reference = stack[referenceIndex]

        let plan = SeriesReslicePlan(direction: direction == 0 ? 0 : 1, sliceCount: stack.count,
                                     width: first.pwidth, height: first.pheight,
                                     spacingX: first.pixelSpacingX, spacingY: first.pixelSpacingY,
                                     sliceInterval: first.sliceInterval)
        if plan.squareAbandoned { NSLog("---- newY < [pixList[ curMovieIndex] count]") }

        var frames: [Frame] = []
        for movie in 0..<max(Int(viewer.horos_maxMovieIndex), 0) {
            guard let frame = frame(of: viewer, movie: movie, plan: plan, direction: direction, reference: reference,
                                    worker: worker) else { return nil }
            frames.append(frame)
        }
        return frames
    }

    /// Time point `movie` resliced.
    private static func frame(of viewer: ViewerController, movie: Int, plan: SeriesReslicePlan, direction: Int,
                              reference: DCMPix, worker: SeriesResliceWorker) -> Frame? {
        let source = viewer.horos_pixArray(movie)
        let sign = 1.0
        // The new slices take an even number of the stack's slices.
        let count = Int(Int32(truncatingIfNeeded: source.count) / 2 * 2)
        guard let firstPix = source.first, count > 0 else { return nil }
        let gathered = source.prefix(count).compactMap { $0.fImage.map { UnsafePointer($0) } }
        guard gathered.count == count else { return nil }

        let imageSize = 4 &* plan.width &* plan.height
        let size = plan.sliceCount &* imageSize
        guard let emptyData = malloc(size) else { return nil }
        let volume = NSData(bytesNoCopy: emptyData, length: size, freeWhenDone: true)
        let destinations = (0..<max(plan.sliceCount, 0)).map { (emptyData + imageSize * $0).assumingMemoryBound(to: Float.self) }

        NSLog("reslice start")
        let waitWindow = viewer.startWaitProgressWindow(NSLocalizedString("Reslicing...", comment: ""), plan.sliceCount)

        let firstFile = viewer.horos_fileList(at: movie)?.firstObject
        var pixes: [DCMPix] = [], files: [Any] = []
        var orientation = [Double](repeating: 0, count: 9)
        var origin = [Double](repeating: 0, count: 3)
        for (i, pixels) in destinations.enumerated() {
            let curPix = unsafeDowncast(firstPix.copy() as AnyObject, to: DCMPix.self)
            pixes.append(curPix)

            // SUV
            curPix.displaySUVValue = firstPix.displaySUVValue
            curPix.suvConverted = firstPix.suvConverted
            curPix.factorPET2SUV = firstPix.factorPET2SUV
            curPix.radiopharmaceuticalStartTime = firstPix.radiopharmaceuticalStartTime
            curPix.patientsWeight = firstPix.patientsWeight
            curPix.radionuclideTotalDose = firstPix.radionuclideTotalDose
            curPix.radionuclideTotalDoseCorrected = firstPix.radionuclideTotalDoseCorrected
            curPix.acquisitionTime = firstPix.acquisitionTime
            curPix.decayCorrection = firstPix.decayCorrection
            curPix.decayFactor = firstPix.decayFactor
            curPix.units = firstPix.units

            curPix.pwidth = plan.width
            curPix.pheight = plan.height
            curPix.fImage = pixels
            curPix.tot = plan.sliceCount
            curPix.frameNo = i
            curPix.id = i

            if let firstFile { files.append(firstFile) }

            // X: the rows of the stack's slices, Y: their columns; the new
            // slices' columns run along the stack's normal.
            reference.orientationDouble(&orientation)
            orientation = SeriesReslice.orientation(direction: direction == 0 ? 0 : 1, reference: orientation, sign: sign)
            curPix.setOrientationDouble(&orientation)	// Normal vector is recomputed in this procedure

            curPix.pixelSpacingX = plan.spacingX
            curPix.pixelSpacingY = plan.spacingY
            curPix.pixelRatio = plan.pixelRatio

            if direction == 0 {
                reference.convertDoubleX(0, pixY: Double(i), toDICOMCoords: &origin, pixelCenter: false)
            } else {
                reference.convertDoubleX(Double(i), pixY: 0, toDICOMCoords: &origin, pixelCenter: false)
            }
            curPix.setOriginDouble(&origin)
            curPix.computeSliceLocation()

            curPix.sliceThickness = direction == 0 ? firstPix.pixelSpacingY : firstPix.pixelSpacingX
            curPix.sliceInterval = 0

            viewer.waitIncrement(by: waitWindow, 1)
        }

        let job: SeriesResliceJob
        if direction == 0 {
            job = .rows(of: gathered, sourceWidth: firstPix.pwidth, plan: plan, sign: sign, into: destinations)
        } else {
            // The columns are read backwards from the last of the even slices.
            job = .columns(from: gathered[sign > 0 ? count - 1 : 0], count: count,
                           sliceFloatCount: Int(Int32(truncatingIfNeeded: firstPix.pwidth &* firstPix.pheight)),
                           rowFloats: Int(Int32(truncatingIfNeeded: firstPix.pwidth &* 4) / 4),
                           plan: plan, sign: sign, into: destinations)
        }
        worker.gatherAndWait(job)

        NSLog("reslice end")
        viewer.horos_postprocessed = true
        viewer.endWaitWindow(waitWindow)
        return Frame(pixes: pixes, files: files, volume: volume)
    }
}
