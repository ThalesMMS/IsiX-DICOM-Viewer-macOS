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

// The SUV (standardized uptake value) of the PET series of the 2D viewer is
// implemented in Swift: a Swift extension of ViewerController, which stays
// Objective-C, with the same selectors (-displaySUV:, -updateSUVValues:,
// -endDisplaySUV:, -editSUVinjectionTime: with -ok: and -cancel:,
// -convertPETtoSUV, -factorPET2SUV, -recomputePixMinMax). When the values
// allow a conversion, the factor and the scaling of the pixels are in
// IsiXImaging (PETSUVConversion).

/// `[date timeIntervalSinceDate: other]` as Objective-C sends it, `other`
/// nil included (an injection time without an acquisition time).
fileprivate func timeInterval(_ date: NSDate, since other: NSDate?) -> TimeInterval {
    let selector = #selector(NSDate.timeIntervalSince(_:))
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?) -> Double
    return unsafeBitCast(date.method(for: selector), to: Send.self)(date, selector, other)
}

public extension ViewerController {

    /// Ends the injection time sheet without a date.
    @objc(cancel:)
    @IBAction func cancel(_ sender: Any!) {
        NSApp.stopModal()
        injectionDateTime = nil
    }

    /// Ends the injection time sheet with its date.
    @objc(ok:)
    @IBAction func ok(_ sender: Any!) {
        NSApp.stopModal()
    }

    /// Edits, in a sheet over the SUV sheet, the start time of the
    /// radiopharmaceutical (tag 0) or the acquisition time (tag 1) of every
    /// slice.
    @objc(editSUVinjectionTime:)
    @IBAction func editSUVinjectionTime(_ sender: Any!) {
        let tag = ViewerSender.tag(sender)
        if tag == 0 {
            injectionDateTime = horos_imageView?.curDCM?.radiopharmaceuticalStartTime
        }
        if tag == 1 {
            injectionDateTime = horos_imageView?.curDCM?.acquisitionTime
        }

        if let injectionWindow = horos_injectionTimeWindow {
            horos_displaySUVWindow?.beginSheet(injectionWindow, completionHandler: nil)

            _ = NSApp.runModal(for: injectionWindow)
            injectionWindow.sheetParent?.endSheet(injectionWindow)
            injectionWindow.orderOut(self)
        }

        if let date = injectionDateTime {
            if tag == 0 {
                horos_editedRadiopharmaceuticalStartTime = date
            }
            if tag == 1 {
                horos_editedAcquisitionTime = date
            }

            forEachPETSlice { p in
                if tag == 0 { p.radiopharmaceuticalStartTime = date }
                if tag == 1 { p.acquisitionTime = date }
            }

            if tag == 0 {
                horos_suvForm?.cell(at: 3)?.objectValue = date
            }
            if tag == 1 {
                horos_suvForm?.cell(at: 4)?.objectValue = date
            }
        }
    }

    /// The factor of the last conversion to SUV.
    @objc(factorPET2SUV)
    func factorPET2SUV() -> Float {
        return horos_factorPET2SUV
    }

    /// Recomputes the minimum and maximum of every slice, and of the series.
    @objc(recomputePixMinMax)
    func recomputePixMinMax() {
        forEachPETSlice { p in
            p.computePixMinPixMax()
            p.minValueOfSeries = 0
            p.maxValueOfSeries = 0
        }
    }

    /// Converts the values of every slice not converted yet to SUV, and the
    /// window level and width with them.
    @objc(convertPETtoSUV)
    func convertPETtoSUV() {
        let cur = horos_imageView?.curDCM
        guard PETSUVConversion.canConvert(isRGB: cur?.isRGB ?? false, units: cur?.units, philipsFactor: cur?.philipsFactor ?? 0,
                                          radionuclideTotalDoseCorrected: cur?.radionuclideTotalDoseCorrected ?? 0,
                                          patientsWeight: cur?.patientsWeight ?? 0, hasSUV: cur?.hasSUV ?? false) else { return }

        var updatewlww = false
        // The Objective-C left this factor undefined when the current slice
        // was already converted; 1 leaves the window level and width as they are.
        var updatefactor = 1.0

        if cur?.suvConverted == false {
            updatewlww = true
            updatefactor = PETSUVConversion.factor(units: cur?.units, philipsFactor: cur?.philipsFactor ?? 0, patientsWeight: cur?.patientsWeight ?? 0,
                                                   radionuclideTotalDoseCorrected: cur?.radionuclideTotalDoseCorrected ?? 0,
                                                   decayFactor: cur?.decayFactor ?? 0)
        }

        forEachPETSlice { pix in
            if !pix.suvConverted {
                let factor = Float(PETSUVConversion.factor(units: pix.units, philipsFactor: pix.philipsFactor, patientsWeight: pix.patientsWeight,
                                                           radionuclideTotalDoseCorrected: pix.radionuclideTotalDoseCorrected,
                                                           decayFactor: pix.decayFactor))
                horos_factorPET2SUV = factor
                if let imageData = pix.fImage {
                    PETSUVConversion.scale(imageData, count: pix.pheight * pix.pwidth, by: factor)
                }

                pix.suvConverted = true
                pix.factorPET2SUV = factor
            }

            pix.computePixMinPixMax()
        }

        NSLog("Convert to SUV - factor: %f", Double(horos_factorPET2SUV))

        forEachPETSlice { p in
            p.maxValueOfSeries = 0
            p.minValueOfSeries = 0

            p.savedWL = Float(Double(p.savedWL) * updatefactor)
            p.savedWW = Float(Double(p.savedWW) * updatefactor)
            p.displaySUVValue = true
        }

        if updatewlww {
            var cwl: Float = 0, cww: Float = 0

            horos_imageView?.getWLWW(&cwl, &cww)

            if UserDefaults.standard.integer(forKey: "DEFAULTPETWLWW") != 0 {
                horos_imageView?.updatePresentationStateFromSeries()
            } else {
                horos_imageView?.setWLWW(Float(Double(cwl) * updatefactor), Float(Double(cww) * updatefactor))
            }
        }

        NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: horos_pixList(at: Int(horos_curMovieIndex)), userInfo: nil)

        setWindowTitle(self)
    }

    /// Puts back ConvertPETtoSUVautomatically, which -endDisplaySUV: turns
    /// off while a series is reverted.
    @objc(restoreConvertPETtoSUVautomaticallyValue:)
    func restoreConvertPETtoSUVautomaticallyValue(_ valueToRestore: NSNumber!) {
        UserDefaults.standard.set(valueToRestore.boolValue, forKey: "ConvertPETtoSUVautomatically")
    }

    /// Ends the SUV sheet; its OK button (tag 1) applies the weight, dose
    /// and times to every slice, then converts the pixels to SUV, displays
    /// SUV values or does neither (SUVCONVERSION).
    @objc(endDisplaySUV:)
    @IBAction func endDisplaySUV(_ sender: Any!) {
        let tag = ViewerSender.tag(sender)
        let defaults = UserDefaults.standard
        if tag == 1 {
            updateSUVValues(self)

            let savedDefault = defaults.bool(forKey: "ConvertPETtoSUVautomatically")
            defaults.set(false, forKey: "ConvertPETtoSUVautomatically")

            if horos_imageView?.curDCM?.suvConverted == true {
                revertSeries(self)

                forEachPETSlice { p in
                    if let time = horos_editedAcquisitionTime { p.acquisitionTime = time }
                    if let time = horos_editedRadiopharmaceuticalStartTime { p.radiopharmaceuticalStartTime = time }
                }
            }

            // Why this? Because SUV conversion happen on the main thread in the finishLoadImageData...
            perform(#selector(restoreConvertPETtoSUVautomaticallyValue(_:)), with: NSNumber(value: savedDefault), afterDelay: 2)

            forEachPETSlice { p in p.displaySUVValue = false }

            let form = horos_suvForm
            if (form?.cell(at: 0)?.floatValue ?? 0) > 0 {
                forEachPETSlice { p in
                    p.patientsWeight = form?.cell(at: 0)?.floatValue ?? 0
                    p.radionuclideTotalDose = Float(Double(form?.cell(at: 1)?.floatValue ?? 0) * 1000000.0)
                    p.radiopharmaceuticalStartTime = form?.cell(at: 3)?.objectValue as? Date
                    p.computeTotalDoseCorrected()
                }

                let conversion = horos_suvConversion?.selectedCell()?.tag ?? 0
                defaults.set(conversion, forKey: "SUVCONVERSION")

                switch conversion {
                case 1: // Convert all pixels to SUV
                    convertPETtoSUV()
                case 2: // Display SUV
                    forEachPETSlice { p in p.displaySUVValue = true }
                    fallthrough
                case 0: // Do nothing
                    forEachPETSlice { p in
                        p.maxValueOfSeries = 0
                        p.minValueOfSeries = 0
                    }
                default:
                    break
                }

                horos_displaySUVWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
            } else {
                _ = HorosAlertPanel.run(title: NSLocalizedString("SUV Error", comment: ""),
                                        message: NSLocalizedString("These values (weight and dose) are not correct.", comment: ""),
                                        defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        } else {
            horos_displaySUVWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
        }

        NotificationCenter.default.post(name: .OsirixRecomputeROI, object: self, userInfo: nil)
    }

    /// Applies the dose and the injection time of the SUV sheet to every
    /// slice, unless the injection is not before the acquisition.
    @objc(updateSUVValues:)
    @IBAction func updateSUVValues(_ sender: Any!) {
        let form = horos_suvForm
        let newDate = form?.cell(at: 3)?.objectValue as? NSDate
        let newInjectedDose = Float(Double(form?.cell(at: 1)?.floatValue ?? 0) * 1000000.0)
        let cur = horos_imageView?.curDCM

        let interval = newDate.map { timeInterval($0, since: cur?.acquisitionTime as NSDate?) } ?? 0
        if -interval <= 0 {
            _ = HorosAlertPanel.run(title: NSLocalizedString("SUV Error", comment: ""),
                                    message: NSLocalizedString("Injection time CANNOT be after acquisition time !", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)

            if let start = cur?.radiopharmaceuticalStartTime {
                form?.cell(at: 3)?.objectValue = start
            }
        } else {
            forEachPETSlice { p in
                p.radionuclideTotalDose = newInjectedDose
                p.radiopharmaceuticalStartTime = form?.cell(at: 3)?.objectValue as? Date
                p.computeTotalDoseCorrected()
            }

            form?.cell(at: 1)?.stringValue = String(format: "%2.3f", Double(cur?.radionuclideTotalDose ?? 0) / 1000000.0)

            form?.cell(at: 2)?.stringValue = String(format: "%2.3f", Double(cur?.radionuclideTotalDoseCorrected ?? 0) / 1000000.0)

            if let start = cur?.radiopharmaceuticalStartTime {
                form?.cell(at: 3)?.objectValue = start
            }
        }
    }

    /// Opens the SUV sheet with the values of the current slice.
    @objc(displaySUV:)
    func displaySUV(_ sender: Any!) {
        horosLoadViewerPanels()

        horos_suvConversion?.selectCell(withTag: UserDefaults.standard.integer(forKey: "SUVCONVERSION"))

        let cur = horos_imageView?.curDCM
        if cur?.hasSUV != true {
            _ = HorosAlertPanel.run(title: NSLocalizedString("SUV Error", comment: ""),
                                    message: NSLocalizedString("Cannot compute SUV on these data.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
        } else {
            let form = horos_suvForm
            form?.cell(at: 0)?.stringValue = String(format: "%2.3f", Double(cur?.patientsWeight ?? 0))
            form?.cell(at: 1)?.stringValue = String(format: "%2.3f", Double(cur?.radionuclideTotalDose ?? 0) / 1000000.0)
            form?.cell(at: 2)?.stringValue = String(format: "%2.3f", Double(cur?.radionuclideTotalDoseCorrected ?? 0) / 1000000.0)

            if let start = cur?.radiopharmaceuticalStartTime {
                form?.cell(at: 3)?.objectValue = start
            }

            if let acquisition = cur?.acquisitionTime {
                form?.cell(at: 4)?.objectValue = acquisition
            }

            form?.cell(at: 5)?.stringValue = String(format: "%2.2f", Double(cur?.halflife ?? 0) / 60.0)

            horos_editedRadiopharmaceuticalStartTime = nil
            horos_editedAcquisitionTime = nil

            if let sheet = horos_displaySUVWindow {
                window?.beginSheet(sheet, completionHandler: nil)
            }
        }
    }

    /// Runs `body` on every slice of every time point.
    private func forEachPETSlice(_ body: (DCMPix) -> Void) {
        var y = 0
        while y < Int(horos_maxMovieIndex) {
            for case let p as DCMPix in horos_pixList(at: y) ?? NSMutableArray() {
                body(p)
            }
            y += 1
        }
    }
}
