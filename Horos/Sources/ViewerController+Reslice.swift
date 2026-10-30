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

// The reslice of the 2D viewer's series is implemented in Swift: a Swift
// extension of ViewerController, which stays Objective-C, with the same
// selectors (-processReslice::, -waitForAProcessor, -resliceThread:). The
// dimensions, orientation and pixel loops of the new slices are in the
// IsiXImaging module (SeriesReslicePlan, SeriesReslice); this keeps what
// reads and writes the viewer, its DCMPix and its windows.
//
// A Y reslice gathers each new slice on a thread of its own, as many at a
// time as there are processors: the threads share one counter with the
// viewers' processorsLock (an NSConditionLock whose condition is 1 while a
// thread may start), as the former code did with a file-scope static.

/// The reslice threads running, every viewer included.
nonisolated(unsafe) fileprivate var numberOfThreadsForReslice: Int32 = 0

/// `[[dict valueForKey: key] intValue]`.
fileprivate func resliceInt(_ dict: NSDictionary?, _ key: String) -> Int32 {
    return (dict?.value(forKey: key) as? NSNumber)?.int32Value ?? 0
}

public extension ViewerController {

    /// Waits until a reslice thread may start and counts it. YES only when
    /// every processor already had a thread, which should not happen.
    @objc(waitForAProcessor)
    func waitForAProcessor() -> Bool {
        let processors = Int32(truncatingIfNeeded: ProcessInfo.processInfo.processorCount)
        let lock = horos_processorsLock
        lock?.lock(whenCondition: 1)
        let result = numberOfThreadsForReslice >= processors
        if !result {
            numberOfThreadsForReslice += 1
            lock?.unlock(withCondition: numberOfThreadsForReslice >= processors ? 0 : 1)
        } else {
            NSLog("waitForAProcessor ?? We should not be here...")
            lock?.unlock(withCondition: 0)
        }
        return result
    }

    /// Gathers one slice of a Y reslice (a column of every slice of the
    /// stack), on its own thread, and scales it to square pixels.
    @objc(resliceThread:)
    nonisolated func resliceThread(_ dict: NSDictionary!) {
        autoreleasepool {
            let i = Int(resliceInt(dict, "i"))
            let sign = Double(resliceInt(dict, "sign"))
            let newX = Int(resliceInt(dict, "newX"))
            let newY = Int(resliceInt(dict, "newY"))
            let square = (dict?.value(forKey: "square") as? NSNumber)?.boolValue ?? false
            let curPix = dict?.value(forKey: "curPix") as? DCMPix
            let curPixFImage = curPix?.fImage
            let rowFloats = Int(resliceInt(dict, "rowBytes") / 4)
            let j = Int(resliceInt(dict, "curMovieIndex"))

            let stack = horos_pixList(at: j)
            let stackCount = stack?.count ?? 0
            let count = Int(Int32(truncatingIfNeeded: stackCount) / 2 * 2)
            let source = (stack?.object(at: sign > 0 ? count - 1 : 0) as? DCMPix)?.fImage
            let first = stack?.object(at: 0) as? DCMPix
            let sliceFloatCount = Int(Int32(truncatingIfNeeded: (first?.pwidth ?? 0) &* (first?.pheight ?? 0)))

            if let source, let curPixFImage {
                SeriesReslice.gatherColumns(source, column: i, count: count, sliceFloatCount: sliceFloatCount,
                                            rowFloats: rowFloats, width: newX, into: curPixFImage, sign: sign)
            }
            if square, let image = curPix?.fImage {
                SeriesReslice.scaleRows(image, rows: stackCount, newRows: newY, width: newX)
            }

            let lock = horos_processorsLock
            lock?.lock()
            if numberOfThreadsForReslice >= 0 { numberOfThreadsForReslice -= 1 }
            lock?.unlock(withCondition: 1)
        }
    }

    /// The volume length measures of every time point (copies of them, for a
    /// new viewer) and the state that anchors them, which the resliced series
    /// gets back (-restoreVolumeLengthSnapshot:movieIndex:).
    private func volumeLengthSnapshots(copyingMeasures copies: Bool) -> [[AnyHashable: Any]] {
        var volumeSnapshots: [[AnyHashable: Any]] = []
        for movie in 0..<max(Int(horos_maxMovieIndex), 0) {
            var lengths = volumeLengthROIs(forMovieIndex: movie) as NSArray
            if copies { lengths = NSArray(array: lengths as [AnyObject], copyItems: true) }
            let state = (volumeLengthState(forMovieIndex: movie, create: true) as NSDictionary?)?.copy() as? NSDictionary ?? NSDictionary()
            volumeSnapshots.append(["rois": lengths, "state": state])
        }
        return volumeSnapshots
    }

    /// Reslices every time point of the series along the rows (direction 0)
    /// or the columns of its slices, into this viewer or a new one, which
    /// keeps the volume length measures, the brushes (a new viewer; this one
    /// gets them from -setOrientation:), the colour and opacity tables.
    @objc(processReslice::)
    func processReslice(_ directionm: Int, _ newViewer: Bool) -> Bool {
        let movie = Int(horos_curMovieIndex)
        let stack: NSArray = horos_pixList(at: movie) ?? NSMutableArray()
        var firstPix = stack.object(at: 0) as! DCMPix
        let previousCLUT = horos_curCLUTMenu
        let previousOpacity = horos_curOpacityMenu

        let plan = SeriesReslicePlan(direction: directionm == 0 ? 0 : 1, sliceCount: stack.count,
                                     width: firstPix.pwidth, height: firstPix.pheight,
                                     spacingX: firstPix.pixelSpacingX, spacingY: firstPix.pixelSpacingY,
                                     sliceInterval: firstPix.sliceInterval)
        if plan.squareAbandoned { NSLog("---- newY < [pixList[ curMovieIndex] count]") }
        let newTotal = plan.sliceCount, newX = plan.width, newY = plan.height
        let lastPix = stack.object(at: SeriesReslicePlan.referenceSliceIndex(sliceCount: stack.count)) as! DCMPix
        let sign = 1.0

        let imageSize = 4 &* newX &* newY
        let size = newTotal &* imageSize

        let xPix = NSMutableArray(), xFiles = NSMutableArray(), xData = NSMutableArray()
        var succeed = true
        var orientation = [Double](repeating: 0, count: 9)
        var origin = [Double](repeating: 0, count: 3)

        var j = 0
        while j < Int(horos_maxMovieIndex) && succeed {
            let source: NSArray = horos_pixList(at: j) ?? NSMutableArray()
            firstPix = source.object(at: 0) as! DCMPix

            // CREATE A NEW SERIES WITH ALL IMAGES !
            guard let emptyData = malloc(size) else { succeed = false; break }
            let newPixList = NSMutableArray(), newDcmList = NSMutableArray()
            let newData = NSData(bytesNoCopy: emptyData, length: size, freeWhenDone: true)

            NSLog("reslice start")
            let waitWindow = startWaitProgressWindow(NSLocalizedString("Reslicing...", comment: ""), newTotal)

            for i in 0..<max(newTotal, 0) {
                let curPix = (source.object(at: 0) as! DCMPix).copy() as! DCMPix
                newPixList.add(curPix)

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

                curPix.pwidth = newX
                curPix.pheight = newY
                curPix.fImage = (emptyData + imageSize * (newPixList.count - 1)).assumingMemoryBound(to: Float.self)
                curPix.tot = newTotal
                curPix.frameNo = newPixList.count - 1
                curPix.id = newPixList.count - 1

                if let files = horos_fileList(at: j), files.count > 0 {
                    newDcmList.add(files.object(at: 0))
                }

                if directionm == 0 {		// X - RESLICE
                    let count = Int(Int32(truncatingIfNeeded: source.count) / 2 * 2)
                    let pwidth = (source.object(at: 0) as! DCMPix).pwidth
                    let slices = (0..<count).map { UnsafePointer((source.object(at: $0) as! DCMPix).fImage!) }
                    SeriesReslice.gatherRows(slices, row: i, sourceWidth: pwidth, width: newX, into: curPix.fImage, sign: sign)
                    if plan.square {
                        SeriesReslice.scaleRows(curPix.fImage, rows: count, newRows: newY, width: newX)
                    }

                    lastPix.orientationDouble(&orientation)
                    orientation = SeriesReslice.orientation(direction: 0, reference: orientation, sign: sign)
                    curPix.setOrientationDouble(&orientation)	// Normal vector is recomputed in this procedure

                    curPix.pixelSpacingX = plan.spacingX
                    curPix.pixelSpacingY = plan.spacingY
                    curPix.pixelRatio = plan.pixelRatio

                    lastPix.convertDoubleX(0, pixY: Double(i), toDICOMCoords: &origin, pixelCenter: false)
                    curPix.setOriginDouble(&origin)
                    curPix.computeSliceLocation()

                    curPix.sliceThickness = firstPix.pixelSpacingY
                    curPix.sliceInterval = 0
                } else {						// Y - RESLICE
                    let rowBytes = firstPix.pwidth &* 4

                    _ = waitForAProcessor()
                    let d = NSDictionary(objects: [NSNumber(value: i), NSNumber(value: sign), NSNumber(value: newX), NSNumber(value: newY),
                                                   NSNumber(value: plan.square), NSNumber(value: Int32(truncatingIfNeeded: rowBytes)), curPix,
                                                   NSNumber(value: Int32(j))],
                                         forKeys: ["i", "sign", "newX", "newY", "square", "rowBytes", "curPix", "curMovieIndex"] as [NSString])
                    Thread.detachNewThreadSelector(#selector(resliceThread(_:)), toTarget: self, with: d)

                    lastPix.orientationDouble(&orientation)
                    // Y Vector = Normal Vector
                    orientation = SeriesReslice.orientation(direction: 1, reference: orientation, sign: sign)
                    curPix.setOrientationDouble(&orientation)	// Normal vector is recomputed in this procedure

                    curPix.pixelSpacingX = plan.spacingX
                    curPix.pixelSpacingY = plan.spacingY
                    curPix.pixelRatio = plan.pixelRatio

                    lastPix.convertDoubleX(Double(i), pixY: 0, toDICOMCoords: &origin, pixelCenter: false)
                    curPix.setOriginDouble(&origin)
                    curPix.computeSliceLocation()

                    curPix.sliceThickness = firstPix.pixelSpacingX
                    curPix.sliceInterval = 0
                }

                waitIncrement(by: waitWindow, 1)
            }

            // The threads of a Y reslice are done when none is counted.
            let lock = horos_processorsLock
            var finished = false
            repeat {
                lock?.lock(whenCondition: 1)
                if numberOfThreadsForReslice <= 0 {
                    finished = true
                    lock?.unlock(withCondition: 1)
                } else {
                    lock?.unlock(withCondition: 0)
                }
            } while !finished

            NSLog("reslice end")

            xData.add(newData)
            xFiles.add(newDcmList)
            xPix.add(newPixList)

            horos_postprocessed = true

            endWaitWindow(waitWindow)
            j += 1
        }

        if succeed {
            let mx = Int(horos_maxMovieIndex)
            let volumeSnapshots = volumeLengthSnapshots(copyingMeasures: newViewer)
            var reslicedViewer: ViewerController? = self
            // -setOrientation: carries the brushes of this viewer after its flips;
            // a new viewer gets them here.
            let brushes = newViewer ? BrushReslice.capture(from: self) : nil
            for j in 0..<max(mx, 0) {
                let pixes = xPix.object(at: j) as? NSMutableArray, files = xFiles.object(at: j) as? NSMutableArray, data = xData.object(at: j) as? NSData
                if j == 0 {
                    if newViewer {
                        // CREATE A SERIES
                        let new2DViewer = self.newWindow(pixes, files, data)
                        // -newWindow::: hands over the +1 of the viewer's alloc, which the
                        // former code kept: the viewer releases itself when it closes.
                        if let new2DViewer { _ = Unmanaged.passRetained(new2DViewer) }
                        reslicedViewer = new2DViewer
                        new2DViewer?.setImageIndex((pixes?.count ?? 0) / 2)
                        new2DViewer?.window?.makeKeyAndOrderFront(self)
                    } else {
                        changeImageData(pixes, files, data, false)
                    }
                } else {
                    reslicedViewer?.addMovieSerie(pixes, files, data)
                }
                reslicedViewer?.restoreVolumeLengthSnapshot(volumeSnapshots[j], movieIndex: j)
            }

            reslicedViewer?.setPostprocessed(true)
            if let reslicedViewer { brushes?.apply(to: reslicedViewer) }

            reslicedViewer?.computeInterval()
            reslicedViewer?.setWindowTitle(self)
            let middle = ((xPix.object(at: 0) as? NSArray)?.count ?? 0) / 2
            reslicedViewer?.imageView()?.setIndex(middle)
            reslicedViewer?.imageView()?.sendSyncMessage(0)
            reslicedViewer?.adjustSlider()

            reslicedViewer?.applyCLUTString(previousCLUT)
            reslicedViewer?.applyOpacityString(previousOpacity)
        }

        return succeed
    }
}
