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

// The geometry part of the "VOI LUT transformation" block of
// ViewerController's DICOM pipeline (4.1.1.3): the orientation of the series,
// the interval between its slices, the reversal of a descending stack (its
// slices, files and ROIs) so 3D texture mapping gets ascending data, the
// warnings for a tilted gantry and irregular slices, and the sheet that sets
// the interval and the orientation by hand. The geometry is IsiXImaging's
// SliceStack and SliceStackSpacing; here the viewer reads its DCMPix, applies
// the answers to them and to its orientation tool. The selectors are those of
// the former Objective-C methods.

/// `static float deg2rad = M_PI/180.0` of the former file: computed in double,
/// kept as a float.
fileprivate let degreesToRadians = Float(Double.pi / 180.0)

/// The nine orientation cosines of a DCMPix, in double.
fileprivate func orientationDouble(_ pix: DCMPix) -> [Double] {
    var vectors = [Double](repeating: 0, count: 9)
    pix.orientationDouble(&vectors)
    return vectors
}

fileprivate func origin(_ pix: DCMPix) -> [Double] {
    return [pix.originX, pix.originY, pix.originZ]
}

public extension ViewerController {

    /// The series' orthogonal orientation from its first slice's normal:
    /// 0 axial, 1 coronal, 2 sagittal. Also sets orientationVector.
    @objc(orthogonalOrientation)
    @discardableResult
    func orthogonalOrientation() -> Int16 {
        let pixList = DCMView.cleanedOutDcmPixArray(horos_pixList(at: Int(horos_curMovieIndex))) as? [DCMPix] ?? []
        guard let first = pixList.first else { return 0 }

        var vectors = [Float](repeating: 0, count: 9)
        first.orientation(&vectors)

        if let axis = SliceStack.dominantAxis(vectors[6], vectors[7], vectors[8]) {
            horos_orientationVector = SliceStackOrientation(axis: axis, component: Double(vectors[6 + axis])).rawValue
        }

        return SliceStackOrientation(rawValue: horos_orientationVector)?.orthogonalTag ?? 0
    }

    @objc(orientationVector)
    func orientationVector() -> Int16 {
        return horos_orientationVector
    }

    /// Warns about, or offers to correct, a gantry tilt found by
    /// -computeIntervalFlipNow:.
    @objc(displayWarningIfGantryTitled)
    func displayWarningIfGantryTitled() {
        guard horos_titledGantry else { return }
        // Asks, with "Do not ask again", unless the 3D preferences already answer.
        // (The OSIRIX_LIGHT branch, which only warned, is not compiled.)
        if GantryTiltPolicy.shouldCorrect(degrees: horos_titledGantryDegrees) {
            ViewerController.correctGangtryTilt(self)
        }
    }

    @objc(computeIntervalAsync)
    func computeIntervalAsync() {
        _ = computeIntervalFlipNow(NSNumber(value: false))
        horos_imageView?.needsDisplay = true
    }

    /// The signed interval from p1 to p2 along their slice normal; 0 when their
    /// orientations differ or are missing.
    @objc(computeIntervalForDCMPix:And:)
    nonisolated class func computeInterval(for p1: DCMPix!, and p2: DCMPix!) -> Float {
        guard let p1, let p2 else { return 0 }
        return SliceStack.interval(fromOrigin: origin(p1), orientation: orientationDouble(p1),
                                   toOrigin: origin(p2), orientation: orientationDouble(p2))
    }

    /// Whether the slices are not perpendicular to their stacking direction (a
    /// tilted gantry) beyond the "MinimumTitledGantryTolerance" preference;
    /// keeps the angle in titledGantryDegrees.
    @objc(isGantryTitled)
    @discardableResult
    func isGantryTitled() -> Bool {
        let pixList = horos_pixArray(0)
        guard pixList.count >= 3 else { return false }

        var step = [pixList[2].originX - pixList[1].originX, pixList[2].originY - pixList[1].originY, pixList[2].originZ - pixList[1].originZ]
        var vectors = orientationDouble(pixList[1])

        var angle = abs(step.withUnsafeMutableBufferPointer { stepBuffer in
            vectors.withUnsafeMutableBufferPointer { DCMView.angleBetweenVectorD(stepBuffer.baseAddress, andVectorD: $0.baseAddress! + 6) }
        })
        angle /= Double(degreesToRadians)

        var tilted = false
        if angle < 90 {
            if angle > Double(UserDefaults.standard.float(forKey: "MinimumTitledGantryTolerance")) {
                NSLog("---- titledGantry - Not a real 3D data set: %f degrees", angle)
                tilted = true
            } else if angle > 0.001 {
                NSLog("---- titledGantry (tolerated) - Not a real 3D data set: %f degrees", angle)
            }
            horos_titledGantryDegrees = Float(angle)
        }
        return tilted
    }

    /// Computes the interval between the slices of the current movie frame
    /// when it has none (or always when `flipNowNumber` is YES and everything
    /// is loaded): the orientation, the interval of every movie frame, and, with
    /// `flipNowNumber`, the reversal of a descending stack and the gantry tilt.
    /// Answers the first slice's interval.
    @objc(computeIntervalFlipNow:)
    @discardableResult
    func computeIntervalFlipNow(_ flipNowNumber: NSNumber!) -> Float {
        selectFirstTilingView()

        let z = Int(horos_curMovieIndex)
        let pixList = horos_pixArray(z)
        var flipNow = flipNowNumber?.boolValue ?? false
        if flipNow { flipNow = isEverythingLoaded() }

        var interval = pixList.first?.sliceInterval ?? 0
        if pixList.count > 1 && flipNow { interval = 0 }

        if interval == 0 && pixList.count > 2 {
            horos_titledGantry = false

            if let spacing = SliceStackSpacing(orientation1: orientationDouble(pixList[1]), orientation2: orientationDouble(pixList[2]),
                                               origin1: origin(pixList[1]), origin2: origin(pixList[2])) {
                interval = spacing.interval
                var interval3D = spacing.interval3D

                if let orientation = spacing.orientation {
                    horos_orientationVector = orientation.rawValue
                    let tool = orientation.orthogonalTag
                    horos_orientationMatrix?.selectCell(withTag: Int(tool))
                    if interval != 0 { horos_orientationMatrix?.isEnabled = true }
                    horos_currentOrientationTool = tool
                }

                if horos_originalOrientation == -1, let orientation = SliceStackOrientation(rawValue: horos_orientationVector) {
                    horos_originalOrientation = orientation.orthogonalTag
                }

                // Slices without a position: stacked along z by their spacing.
                let first = pixList[0]
                if interval == 0 && first.originX == 0 && first.originY == 0 && first.originZ == 0 {
                    interval = first.spacingBetweenSlices
                    if interval != 0 {
                        interval3D = -interval
                        horos_orientationVector = SliceStackOrientation.axialNegative.rawValue
                        horos_orientationMatrix?.isEnabled = true

                        var vectors: [Float] = [1, 0, 0, 0, 1, 0, 1, 0, 1]
                        var position: [Float] = [0, 0, 0]
                        for pix in pixList {
                            pix.setOrientation(&vectors)
                            pix.setOrigin(&position)
                            position[2] = Float(Double(position[2]) + interval)
                        }
                    }
                }

                if interval < 0 && flipNow {
                    // Flip the data for 3D texture mapping.
                    if pixList.allSatisfy({ $0.pheight == first.pheight && $0.pwidth == first.pwidth }) {
                        interval = SliceStackSpacing.reversedSliceInterval(interval: interval, interval3D: interval3D)
                        reverseSeries(sliceInterval: interval)

                        horos_subCtrlMaskID = pixList.count - horos_subCtrlMaskID - 1

                        flipDataSeries(self)
                    } else {
                        NSLog("sameSize = NO")
                    }
                } else {
                    interval = SliceStackSpacing.sliceInterval(interval: interval, interval3D: interval3D)

                    for x in 0..<horos_movieCount {
                        for pix in horos_pixArray(x) { pix.sliceInterval = interval }
                    }
                }

                if flipNow { horos_titledGantry = isGantryTitled() }
            }
        }

        _ = horos_blending?.computeInterval()

        return Float(horos_pixArray(Int(horos_curMovieIndex)).first?.sliceInterval ?? 0)
    }

    /// Reverses every movie frame: its volume buffer, the order of its slices,
    /// files and ROIs, and gives the slices `sliceInterval`.
    private func reverseSeries(sliceInterval interval: Double) {
        for x in 0..<horos_movieCount {
            guard let pixList = horos_pixList(at: x), let first = pixList.firstObject as? DCMPix, let volume = first.fImage else { continue }
            let count = pixList.count, sliceFloats = first.pwidth * first.pheight

            flipData(UnsafeMutableRawPointer(volume).assumingMemoryBound(to: CChar.self), count, first.pwidth, first.pheight)

            for i in 0..<count {
                let pix = pixList.object(at: i) as? DCMPix
                pix?.fImage = volume + (count - 1 - i) * sliceFloats
                pix?.sliceInterval = interval
            }

            // The three lists have a slice each: reversed over the slices' count.
            for list in [pixList, horos_fileList(at: x), horos_roiList(at: x)] {
                guard let list else { continue }
                for i in 0..<min(count, list.count) / 2 {
                    list.exchangeObject(at: i, withObjectAt: list.count - i - 1)
                }
            }
        }

        for x in 0..<horos_movieCount {
            guard let pixList = horos_pixList(at: x) else { continue }
            for i in 0..<pixList.count {
                guard let pix = pixList.object(at: i) as? DCMPix else { continue }
                viewerSetArrayPix(pix, pixList, Int(truncatingIfNeeded: i))
                pix.id = i
            }
        }
    }

    /// Reverses the order of `no` slices of x × y floats from `ptr`.
    @objc(flipData::::)
    func flipData(_ ptr: UnsafeMutablePointer<CChar>!, _ no: Int, _ x: Int, _ y: Int) {
        NSLog("flip data")
        guard let ptr else { return }
        SliceStack.reverseSlices(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Float.self), sliceCount: no, sliceFloatCount: x * y)
    }

    /// Shows the series in the reverse order (the menu's and toolbar's flip),
    /// keeping the thick slab mode and the image on screen.
    @objc(flipDataSeries:)
    func flipDataSeries(_ sender: Any!) {
        if horos_windowWillClose { return }

        let activatedFusionState = horos_activatedFusion?.state ?? .off
        let previousFusion = horos_popFusion?.selectedTag() ?? 0
        let previousCurImage = Int(horos_imageView?.curImage ?? 0)

        horos_imageView?.drawing = false

        horos_seriesView?.setFlippedData(!(horos_imageView?.flippedData ?? false))
        setFusionMode(0)

        horos_imageView?.setIndex(Int(truncatingIfNeeded: (horos_pixList(at: 0)?.count ?? 0) - 1 - previousCurImage))

        adjustSlider()

        horos_imageView?.sendSyncMessage(0)

        if activatedFusionState == .on { setFusionMode(previousFusion) }

        horos_imageView?.drawing = true

        horos_popFusion?.selectItem(withTag: previousFusion)

        horos_imageView?.sendSyncMessage(0)
    }

    /// Warns once about slices at irregular intervals, or that do not make a
    /// volume, before a 3D or measurement that depends on them.
    @objc(displayAWarningIfNonTrueVolumicData)
    func displayAWarningIfNonTrueVolumicData() {
        // Lets this try to correct the scout image first (GE scan).
        _ = isDataVolumicIn4D(true)

        guard !horos_nonVolumicDataWarningDisplayed else { return }

        // Positions along the slice normal, against a relative tolerance and
        // half a pixel: see HorosSliceIntervalRegularity.
        let pixList = horos_pixArray(0)
        var origins: [NSNumber] = []
        origins.reserveCapacity(3 * pixList.count)
        for pix in pixList {
            origins.append(NSNumber(value: pix.originX))
            origins.append(NSNumber(value: pix.originY))
            origins.append(NSNumber(value: pix.originZ))
        }
        var vectors = [Double](repeating: 0, count: 9)
        let first = pixList.first
        first?.orientationDouble(&vectors)
        let spacing = min(first?.pixelSpacingX ?? 0, first?.pixelSpacingY ?? 0)
        let regularity = SliceIntervalRegularity.regularity(origins: origins,
                                                            normal: [NSNumber(value: vectors[6]), NSNumber(value: vectors[7]), NSNumber(value: vectors[8])],
                                                            pixelSpacing: spacing)

        if regularity.isIrregular {
            HorosAlertPanel.runInformational(title: NSLocalizedString("Warning!", comment: ""),
                                             message: String(format: NSLocalizedString("These slices have a non regular slice interval, varying from %.3f mm to %.3f mm. This will produce distortion in 3D representations, and in measurements.", comment: ""),
                                                             regularity.minimumInterval, regularity.maximumInterval),
                                             defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        } else if !isDataVolumicIn4D(true) {
            HorosAlertPanel.runInformational(title: NSLocalizedString("Warning!", comment: ""),
                                             message: NSLocalizedString("These slices doesn't represent a true 3D volumic data. This will produce distortion in 3D representations, and in measurements.", comment: ""),
                                             defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        horos_nonVolumicDataWarningDisplayed = true
    }

    /// -computeIntervalFlipNow: YES, unless it is already running.
    @objc(computeInterval)
    @discardableResult
    func computeInterval() -> Float {
        guard !horos_computeInterval else { return 0 }
        horos_computeInterval = true
        let interval = computeIntervalFlipNow(NSNumber(value: true))
        horos_computeInterval = false
        return interval
    }

    /// The end of the slice interval sheet: OK (1) opens the 3D viewer the
    /// sheet was asked for, by the tag of `contextInfo`, the menu item.
    @objc(sheetDidEnd:returnCode:contextInfo:)
    func sheetDidEnd(_ sheet: NSWindow!, returnCode: Int32, contextInfo: Any!) {
        guard returnCode == 1 else { return }
        // (OSIRIX_LIGHT, not compiled, opened none of them.)
        switch ViewerSender.tag(contextInfo) {
        case 10: mprViewer(contextInfo)             // 3D MPR
        case 1: cprViewer(contextInfo)              // 3D curved MPR
        case 8: orthogonalMPRViewer(contextInfo)    // 2D orthogonal MPR
        case 3: vrViewer(contextInfo)               // MIP
        case 4: vrViewer(contextInfo)               // VR
        case 5: srViewer(contextInfo)               // SR
        case 9: endoscopyViewer(contextInfo)        // Endoscopy
        default: break
        }
    }

    /// The end of the slice interval sheet: OK checks and applies its fields
    /// (interval, pixel spacing, orientation, origin) to every slice, then the
    /// sheet's handler opens the 3D viewer that asked for it.
    @objc(endThicknessInterval:)
    func endThicknessInterval(_ sender: Any!) {
        let tag = ViewerSender.tag(sender)
        var interval: Float = 0, xSpacing: Float = 0, ySpacing: Float = 0
        var v = [Float](repeating: 0, count: 9), o = [Float](repeating: 0, count: 3)
        if tag != 0 {
            let locale = Locale.current
            func parse(_ text: String?, _ value: inout Float) -> Bool {
                guard let parsed = text.flatMap({ CalibrationNumber.parse($0, locale: locale) }) else { return false }
                value = parsed
                return true
            }
            var valid = parse(horos_customInterval?.stringValue, &interval) && parse(horos_customXSpacing?.stringValue, &xSpacing) &&
                parse(horos_customYSpacing?.stringValue, &ySpacing) &&
                xSpacing > 0 && ySpacing > 0 &&
                (interval != 0 || (horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0) <= 1)
            for i in 0..<6 { valid = parse(horos_customVectors?.cell(withTag: i)?.stringValue, &v[i]) && valid }
            for i in 0..<3 { valid = parse(horos_customOrigin?.cell(withTag: i)?.stringValue, &o[i]) && valid }
            if !valid {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                            message: NSLocalizedString("Enter finite numeric values. Pixel spacing must be positive, and the slice interval must be nonzero for a series with multiple images.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }
        }

        // An ordered-out sheet has no sheetParent any more: keep it to end the sheet below.
        let sheet = horos_ThickIntervalWindow
        let intervalParent = sheet?.sheetParent
        sheet?.orderOut(sender)

        if tag != 0 {
            let normal = SliceStack.normal(v)
            v[6] = normal[0]; v[7] = normal[1]; v[8] = normal[2]
            let axis = SliceStack.dominantAxis(v[6], v[7], v[8]) ?? 2

            for i in 0..<horos_movieCount {
                for pix in horos_pixArray(i) {
                    pix.sliceInterval = 0
                    pix.pixelSpacingX = Double(xSpacing)
                    pix.pixelSpacingY = Double(ySpacing)
                    if xSpacing != 0 && ySpacing != 0 { pix.pixelRatio = Double(ySpacing / xSpacing) }
                    pix.setOrientation(&v)
                    pix.setOrigin(&o)
                    pix.computeSliceLocation()

                    o[axis] += interval
                }
            }

            if let imageView = horos_imageView { imageView.setIndex(imageView.curImage) }

            _ = computeInterval()
        }

        // The handler opens the 3D viewer that asked for the interval.
        if let sheet { intervalParent?.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: tag)) }
    }

    /// The normal of the orientation typed in the slice interval sheet.
    @objc(updateZVector:)
    func updateZVector(_ sender: Any!) {
        var v = [Float](repeating: 0, count: 9)
        for i in 0..<9 { v[i] = horos_customVectors?.cell(withTag: i)?.floatValue ?? 0 }

        let normal = SliceStack.normal(v)
        for i in 6..<9 { horos_customVectors?.cell(withTag: i)?.floatValue = normal[i - 6] }
    }

    /// The axial orientation in the slice interval sheet.
    @objc(setAxialOrientation:)
    func setAxialOrientation(_ sender: Any!) {
        horos_customInterval?.selectText(self)

        let v: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        for i in 0..<9 { horos_customVectors?.cell(withTag: i)?.floatValue = v[i] }
    }

    /// Opens the slice interval sheet with the first slice's values; on OK
    /// its end opens the 3D viewer `sender` asked for.
    @objc(SetThicknessInterval:)
    func setThicknessInterval(_ sender: Any!) {
        horosLoadViewerPanels()

        guard let p = horos_pixArray(Int(horos_curMovieIndex)).first else { return }

        // Always fill the field, zero included, so a cancelled edit cannot survive reopening.
        horos_customInterval?.floatValue = Float(p.sliceInterval != 0 ? p.sliceInterval : p.spacingBetweenSlices)

        horos_customXSpacing?.floatValue = Float(p.pixelSpacingX)
        horos_customYSpacing?.floatValue = Float(p.pixelSpacingY)

        var v = [Float](repeating: 0, count: 9)
        p.orientation(&v)

        if v[0] == 0 && v[1] == 0 && v[2] == 0 {
            v = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        }

        for i in 0..<9 { horos_customVectors?.cell(withTag: i)?.floatValue = v[i] }

        let o: [Float] = [Float(p.originX), Float(p.originY), Float(p.originZ)]
        for i in 0..<3 { horos_customOrigin?.cell(withTag: i)?.floatValue = o[i] }

        guard let sheet = horos_ThickIntervalWindow else { return }
        window?.beginSheet(sheet) { returnCode in
            self.sheetDidEnd(sheet, returnCode: Int32(truncatingIfNeeded: returnCode.rawValue), contextInfo: sender)
        }
    }
}
