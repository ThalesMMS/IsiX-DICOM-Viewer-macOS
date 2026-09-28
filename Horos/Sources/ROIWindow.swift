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

/// `[a isEqualToString: b]`: NO when either is nil, and a comparison of the
/// UTF-16 units, where Swift's == would also match canonically equivalent
/// strings.
private func objcEqualStrings(_ a: String?, _ b: String?) -> Bool {
    guard let a = a, let b = b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// The NSException that HorosObjCException caught.
private func caughtException(_ error: Error) -> NSException {
    let nsError = error as NSError
    if let exception = nsError.userInfo[HorosObjCExceptionKey] as? NSException {
        return exception
    }
    return NSException(name: NSExceptionName(rawValue: nsError.localizedFailureReason ?? NSExceptionName.genericException.rawValue),
                       reason: nsError.localizedDescription, userInfo: nil)
}

/// Window Controller for ROI
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/ROIWindow.h> are those of the former class.
///
/// As before, the controller owns itself while its window is open: code that
/// makes one does not release it, and -windowWillClose: autoreleases it. The
/// name timer also retains it until the window closes.
@objc(ROIWindow)
public final class ROIWindow: NSWindowController, NSComboBoxDataSource {
    /// Not retained, as before. `unowned(unsafe)` and not `weak`: the ROI's
    /// removal notification comes from its -dealloc and is compared with it.
    private unowned(unsafe) var roi: ROI?
    /// Not retained, as before; compared by identity with the object of the
    /// viewer's close notification.
    private unowned(unsafe) var curController: ViewerController?

    private var closing = false

    /// The "All with same name" check box. Its outlet has the name of the
    /// -allWithSameName method, so the nib sets it through -setAllWithSameName:.
    private var allWithSameNameButton: NSButton?

    @IBOutlet var name: NSComboBox!
    /// A MyNSTextView in the nib.
    @IBOutlet var comments: NSTextView!
    @IBOutlet var colorButton: NSColorWell!
    @IBOutlet var thicknessSlider: NSSlider!
    @IBOutlet var opacitySlider: NSSlider!
    /// The outlet named `recalibrate`, beside the -recalibrate: action.
    @IBOutlet @objc(recalibrate) var recalibrateButton: NSButton!
    @IBOutlet var xyPlot: NSButton!
    @IBOutlet var exportToXMLButton: NSButton!
    @IBOutlet var recalibrateWindow: NSWindow!
    @IBOutlet var recalibrateValue: NSTextField!

    private var roiNames: NSArray?

    private var getName: Timer?

    private var previousName: String?

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(setAllWithSameName:)
    func setAllWithSameName(_ button: NSButton?) {
        allWithSameNameButton = button
    }

    @objc(comboBoxWillPopUp:)
    public func comboBoxWillPopUp(_ notification: NSNotification!) {
        NSLog("will display...")
        let updatedNames = curController?.generateROINamesArray()?.copy() as? NSArray
        roiNames = updatedNames
        let comboBox = notification.object as? NSComboBox
        comboBox?.dataSource = self

        comboBox?.noteNumberOfItemsChanged()
        comboBox?.reloadData()
    }

    public func comboBox(_ aComboBox: NSComboBox, indexOfItemWithStringValue aString: String) -> Int {
        if roiNames == nil { roiNames = curController?.generateROINamesArray()?.copy() as? NSArray }

        let names = roiNames ?? NSArray()
        for i in 0..<names.count {
            if let name = names.object(at: i) as? NSString, name.isEqual(to: aString) { return i }
        }

        return NSNotFound
    }

    public func numberOfItems(in aComboBox: NSComboBox) -> Int {
        if roiNames == nil { roiNames = curController?.generateROINamesArray()?.copy() as? NSArray }
        return roiNames?.count ?? 0
    }

    public func comboBox(_ aComboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        if index >= 0 {
            if roiNames == nil { roiNames = curController?.generateROINamesArray()?.copy() as? NSArray }
            if let names = roiNames, index < names.count { return names.object(at: index) }
        }

        return nil
    }

    @IBAction @objc(roiSaveCurrent:)
    public func roiSaveCurrent(_ sender: Any!) {
        let panel = NSSavePanel()

        // [NSMutableArray arrayWithObject:curROI] raised without a ROI, which
        // ended the action.
        guard let current = roi else { return }
        let selectedROIs = NSMutableArray(object: current)

        panel.canSelectHiddenExtension = false
        panel.allowedFileTypes = ["roi"]

        panel.nameFieldStringValue = (selectedROIs.object(at: 0) as? ROI)?.name ?? ""

        panel.begin { result in
            if result != NSApplication.ModalResponse.OK {
                return
            }

            if let path = panel.url?.path {
                _ = NSArchiver.archiveRootObject(selectedROIs, toFile: path)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        previousName = nil
        roiNames = nil
    }

    @objc(CloseViewerNotification:)
    func CloseViewerNotification(_ note: NSNotification!) {
        if (note.object as AnyObject?) === curController {
            close()
        }
    }

    @objc(removeROI:)
    func removeROI(_ note: NSNotification!) {
        if (note.object as AnyObject?) === roi {
            // The removal notification can be sent from ROI dealloc. Do not write back to it.
            roi = nil
            close()
        }
    }

    @IBAction @objc(recalibrate:)
    public func recalibrate(_ sender: Any!) {
        var pixels: Float = 0
        let length: Float = (roi?.points?.count ?? 0) >= 2 ? (roi?.mesureLength(&pixels) ?? 0) : 0
        if !pixels.isFinite || pixels <= 0 || !length.isFinite {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                        message: NSLocalizedString("Use a measurement line with a finite, nonzero length to calibrate the image.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        recalibrateValue.stringValue = String(format: "%0.3f", Double(length))
        NSApp.beginSheet(recalibrateWindow, modalFor: window!,
                         modalDelegate: self, didEnd: nil, contextInfo: nil)
        let result = NSApp.runModal(for: recalibrateWindow).rawValue
        NSApp.endSheet(recalibrateWindow)
        recalibrateWindow.orderOut(nil)
        if result == 0 { return }

        var requestedLength: Float = 0
        var valid = HorosCalibrationFloat(recalibrateValue.stringValue, NSLocale.current, &requestedLength) && requestedLength > 0
        let resolution = Double(requestedLength) * 10.0 / Double(pixels) // Entered length is in cm; spacing is in mm.
        valid = valid && resolution.isFinite && resolution > 0 && resolution <= Double(Float.greatestFiniteMagnitude) && Float(resolution) > 0
        let images = curController?.pixList() ?? NSMutableArray()
        let verticalSpacings = NSMutableArray(capacity: images.count)
        // Validate the entire series before changing any image, including aspect-ratio overflow.
        for case let pix as DCMPix in images {
            let previousX = pix.pixelSpacingX
            let previousY = pix.pixelSpacingY
            let vertical = previousX == 0 ? resolution : previousY * resolution / previousX
            valid = valid && previousX.isFinite && previousX >= 0 &&
                vertical.isFinite && vertical > 0 && vertical <= Double(Float.greatestFiniteMagnitude) && Float(vertical) > 0
            verticalSpacings.add(NSNumber(value: vertical))
        }
        if !valid {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                        message: NSLocalizedString("Enter a positive, finite length that produces valid pixel spacing for every image.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        for i in 0..<images.count {
            let pix = images.object(at: i) as! DCMPix
            pix.pixelSpacingX = Double(Float(resolution))
            pix.pixelSpacingY = Double((verticalSpacings.object(at: i) as! NSNumber).floatValue)
        }
        // Calibration changes physical units, not the ROI's image coordinates.
        // Update every ROI now; waiting for a draw leaves off-screen measurements stale.
        let seriesROIs = curController?.roiList() ?? NSMutableArray()
        for i in 0..<min(images.count, seriesROIs.count) {
            let pix = images.object(at: i) as! DCMPix
            for case let roi as ROI in (seriesROIs.object(at: i) as? NSArray) ?? NSArray() {
                roi.pixelSpacingX = pix.pixelSpacingX
                roi.pixelSpacingY = pix.pixelSpacingY
            }
        }
        NotificationCenter.default.post(name: NSNotification.Name.OsirixRecomputeROI, object: curController, userInfo: nil)
        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateView, object: curController, userInfo: nil)
    }

    @IBAction @objc(acceptSheet:)
    public func acceptSheet(_ sender: Any!) {
        // [sender tag]: the OK and Cancel buttons of the sheet.
        let tag = (sender as? NSView)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: tag))
    }

    @objc(allWithSameName)
    public func allWithSameName() -> Bool {
        return allWithSameNameButton?.state == .on
    }

    /// Stores the fields in the ROI, as the former @try did; returns what
    /// was raised, the ROI keeping its previous name and comments.
    private func storeNameAndComments() -> NSException? {
        let editedROI = roi
        do {
            try HorosObjCException.perform {
                // stringWithString is very important - see NSText string !
                // The String -string returns still wraps the text view's
                // storage, and bridges back to it: NSString(string:) copies it.
                editedROI?.comments = NSString(string: self.comments.string) as String
                editedROI?.name = self.name.stringValue
            }
            return nil
        } catch {
            return caughtException(error)
        }
    }

    @objc(setROI::)
    public func setROI(_ iroi: ROI!, _ c: ViewerController!) {
        if roi === iroi { return }

        if let e = storeNameAndComments() {
            NSLog("ROIWindow setROI: keeping previous name/comments after exception: %@ %@", e.name.rawValue, e.reason ?? "(null)")
        }

        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: roi, userInfo: nil)

        curController = c
        roi = iroi

        let rgb = roi?.rgbcolor ?? RGBColor()
        // Match setColor: so applying the displayed color does not convert device RGB again.
        let color = NSColor(calibratedRed: CGFloat(Double(rgb.red) / 65535.0), green: CGFloat(Double(rgb.green) / 65535.0), blue: CGFloat(Double(rgb.blue) / 65535.0), alpha: 1.0)

        colorButton?.color = color

        thicknessSlider?.floatValue = roi?.thickness ?? 0
        opacitySlider?.floatValue = roi?.opacity ?? 0

        name?.stringValue = roi?.name ?? ""
        name?.selectText(self)
        comments?.string = roi?.comments ?? ""

        if roi?.type == .tMesure { recalibrateButton?.isEnabled = true } else { recalibrateButton?.isEnabled = false }

        if roi?.type == .tMesure { xyPlot?.isEnabled = true } else { xyPlot?.isEnabled = false }

        if roi?.type == .tLayerROI { exportToXMLButton?.isEnabled = false } else { exportToXMLButton?.isEnabled = true }
    }

    @objc(roiChange:)
    func roiChange(_ notification: NSNotification!) {
    }

    @objc(getName:)
    func getName(_ theTimer: Timer!) {
        if objcEqualStrings(name?.stringValue, previousName) == false {
            setTextData(name)
            previousName = name?.stringValue
        }
    }

    @objc(initWithROI::)
    public convenience init(roi iroi: ROI!, _ c: ViewerController!) {
        self.init(windowNibName: "ROI")

        window?.setFrameAutosaveName("ROIInfoWindow")
        NotificationCenter.default.addObserver(self, selector: #selector(roiChange(_:)), name: NSNotification.Name.OsirixROIChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(removeROI(_:)), name: NSNotification.Name.OsirixRemoveROI, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(CloseViewerNotification(_:)), name: NSNotification.Name.OsirixCloseViewer, object: nil)

        getName = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(getName(_:)), userInfo: nil, repeats: true)

        setROI(iroi, c)
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: NSNotification!) {
        // Removal and viewer-close notifications can precede the window delegate callback.
        if closing { return }
        closing = true
        NotificationCenter.default.removeObserver(self)
        window?.acceptsMouseMovedEvents = false

        getName?.invalidate()
        getName = nil

        ROI.saveDefaultSettings()

        if let e = storeNameAndComments() {
            NSLog("ROIWindow windowWillClose: keeping previous name/comments after exception: %@ %@", e.name.rawValue, e.reason ?? "(null)")
        }
        roi = nil
        curController = nil

        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: roi, userInfo: nil)

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @objc(setAllMatchingROIsToSameParamsAs:withNewName:)
    func setAllMatchingROIsToSameParams(as iROI: ROI!, withNewName newName: String!) {
        setAllMatchingROIsToSameParams(as: iROI, matchingName: iROI?.name, withNewName: newName)
    }

    /// Raises, as the former method rethrew, what failed after restoring the
    /// names it had changed.
    @objc(setAllMatchingROIsToSameParamsAs:matchingName:withNewName:)
    func setAllMatchingROIsToSameParams(as iROI: ROI!, matchingName: String!, withNewName newName: String!) {
        do {
            try applyToMatchingROIs(as: iROI, matchingName: matchingName, withNewName: newName)
        } catch {
            caughtException(error).raise()
        }
    }

    /// The former method's body. What its @try caught is thrown to Swift
    /// callers, after the renames already applied are undone.
    private func applyToMatchingROIs(as iROI: ROI!, matchingName: String!, withNewName newName: String!) throws {
        let roiSeriesList = curController?.roiList() ?? NSMutableArray()
        let oldName = matchingName
        let renamed = NSMutableArray()

        do {
            try HorosObjCException.perform {
                for case let roiImageList as NSArray in roiSeriesList {
                    for case let candidate as ROI in roiImageList {
                        if candidate === self.roi { continue }

                        if objcEqualStrings(candidate.name, oldName) {
                            candidate.rgbcolor = iROI?.rgbcolor ?? RGBColor()
                            candidate.thickness = iROI?.thickness ?? 0
                            candidate.opacity = iROI?.opacity ?? 0
                            if newName != nil {
                                candidate.name = newName
                                renamed.add(candidate)
                            }
                            NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: candidate, userInfo: nil)
                        }
                    }
                }
            }
        } catch {
            // A failure (typically NSMallocException under memory pressure) must not leave the series with
            // two names for the same structure: undo the renames already applied, then let the caller report.
            for case let roi as ROI in renamed {
                do { try HorosObjCException.perform { roi.name = oldName } }
                catch { NSLog("ROIWindow: unable to restore name of %@: %@", roi, caughtException(error).reason ?? "(null)") }
            }
            throw error
        }
    }

    @objc(presentRenameFailure:previousName:)
    func presentRenameFailure(_ exception: NSException!, previousName: String!) {
        NSLog("ROIWindow: renaming failed (%@: %@); name kept as %@", exception.name.rawValue, exception.reason ?? "(null)", previousName ?? "(null)")

        if let previousName = previousName {
            name?.stringValue = previousName
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = NSLocalizedString("ROI Rename Error", comment: "")
        alert.informativeText = exception.name == .mallocException
            ? NSLocalizedString("There is not enough memory to rename the ROI. The previous name was kept.", comment: "")
            : String(format: NSLocalizedString("The ROI could not be renamed. The previous name was kept.\n\n%@", comment: ""), exception.reason ?? "")
        alert.runModal()
    }

    @objc(removeAllROIsWithName:)
    func removeAllROIsWithName(_ roiName: String!) {
        let roiSeriesList = curController?.roiList() ?? NSMutableArray()

        for case let roiImageList as NSMutableArray in roiSeriesList {
            var j = 0

            while j < roiImageList.count {
                let roi = roiImageList.object(at: j) as? ROI

                if objcEqualStrings(roi?.name, roiName) {
                    roiImageList.removeObject(at: j)
                    j -= 1
                }
                j += 1
            }
        }
        curController?.imageView()?.needsDisplay = true

        windowWillClose(nil)
    }

    @IBAction @objc(setTextData:)
    public func setTextData(_ sender: Any!) {
        let newName = (sender as? NSControl)?.stringValue
        let previous = roi?.name
        let edited = roi

        do {
            try HorosObjCException.perform { edited?.name = newName }

            if allWithSameName() {
                do {
                    try applyToMatchingROIs(as: edited, matchingName: previous, withNewName: newName)
                } catch {
                    // The matching ROIs were restored by the callee; restore the edited ROI as well.
                    do { try HorosObjCException.perform { edited?.name = previous } }
                    catch { NSLog("ROIWindow: unable to restore name of %@: %@", edited.map { $0 as CVarArg } ?? ("(null)" as NSString), caughtException(error).reason ?? "(null)") }
                    throw error
                }
            }
        } catch {
            presentRenameFailure(caughtException(error), previousName: previous)
            return
        }

        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: roi, userInfo: nil)
    }

    @IBAction @objc(setThickness:)
    public func setThickness(_ sender: NSSlider!) {
        roi?.thickness = sender.floatValue
        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: roi, userInfo: nil)

        if allWithSameName() { setAllMatchingROIsToSameParams(as: roi, withNewName: roi?.name) }
    }

    @IBAction @objc(setOpacity:)
    public func setOpacity(_ sender: NSSlider!) {
        roi?.opacity = sender.floatValue
        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: roi, userInfo: nil)

        if allWithSameName() { setAllMatchingROIsToSameParams(as: roi, withNewName: roi?.name) }
    }

    @IBAction @objc(setColor:)
    public func setColor(_ sender: NSColorWell!) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0

        sender.color.usingColorSpaceName(.calibratedRGB)?.getRed(&r, green: &g, blue: &b, alpha: nil)

        var c = RGBColor()

        c.red = roiChartUInt16(Double(r) * 65535.0)
        c.green = roiChartUInt16(Double(g) * 65535.0)
        c.blue = roiChartUInt16(Double(b) * 65535.0)

        roi?.rgbcolor = c
        NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: roi, userInfo: nil)

        if allWithSameName() { setAllMatchingROIsToSameParams(as: roi, withNewName: roi?.name) }

        comments?.textColor = nil
    }

    @objc(addROIValues:dictionary:)
    class func addROIValues(_ r: ROI!, dictionary d: NSMutableDictionary!) {
        if let name = r?.name, (name as NSString).length > 0 {
            d?.setObject(name, forKey: "Name" as NSString)
        }

        if let comments = r?.comments, (comments as NSString).length > 0 {
            d?.setObject(comments, forKey: "Comments" as NSString)
        }

        let roiPoints = NSMutableArray()
        for case let p as MyPoint in r?.points ?? NSMutableArray() {
            roiPoints.add(NSStringFromPoint(p.point))
        }

        d?.setObject(roiPoints, forKey: "ROIPoints" as NSString)

        // Each is computed twice, as before.
        if r?.dataString() != nil {
            d?.setObject(r.dataString() as Any, forKey: "DataSummary" as NSString)
        }

        if r?.dataValues() != nil {
            d?.setObject(r.dataValues() as Any, forKey: "DataValues" as NSString)
        }
    }

    @IBAction @objc(exportData:)
    public func exportData(_ sender: Any!) {
        var physicalLength = roi is HorosVolumeLengthROI
        if allWithSameName() {
            for case let slice as NSArray in curController?.roiList() ?? NSMutableArray() {
                for case let other as ROI in slice {
                    if objcEqualStrings(other.name, roi?.name) && other is HorosVolumeLengthROI { physicalLength = true }
                }
            }
        }
        if physicalLength {
            HorosAlertPanel.run(title: NSLocalizedString("Export to XML", comment: ""),
                                message: NSLocalizedString("XML cannot preserve a Length between slices. Use Export ROIs as JSON or save the ROI archive instead.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        if roi?.type == .tPlain {
            let confirm = HorosAlertPanel.runInformational(title: NSLocalizedString("Export to XML", comment: ""), message: NSLocalizedString("Exporting this kind of ROI to XML will only export the contour line.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)
            if confirm == 0 { return }
        } else if roi?.type == .tLayerROI {
            HorosAlertPanel.run(title: NSLocalizedString("Export to XML", comment: ""), message: NSLocalizedString("This kind of ROI can not be exported to XML.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = false
        panel.allowedFileTypes = ["xml"]
        panel.nameFieldStringValue = roi?.name ?? ""

        panel.begin { result in
            if result != NSApplication.ModalResponse.OK {
                return
            }

            let xml = NSMutableDictionary()

            if self.allWithSameName() {
                let roiSeriesList = self.curController?.roiList() ?? NSMutableArray()
                let roiArray = NSMutableArray()

                for i in 0..<roiSeriesList.count {
                    let roiImageList = roiSeriesList.object(at: i) as? NSArray ?? NSArray()

                    for case let roi as ROI in roiImageList {
                        if objcEqualStrings(roi.name, self.roi?.name) {
                            let roiData = NSMutableDictionary()

                            ROIWindow.addROIValues(roi, dictionary: roiData)
                            roiData.setObject(NSNumber(value: Int32(truncatingIfNeeded: i) &+ 1), forKey: "Slice" as NSString)

                            roiArray.add(roiData)
                        }
                    }
                }

                xml.setObject(roiArray, forKey: "ROI array" as NSString)
            } else { // Output curROI only
                ROIWindow.addROIValues(self.roi, dictionary: xml)
            }

            if let url = panel.url {
                _ = xml.write(to: url, atomically: true)
            }
        }
    }

    @IBAction @objc(histogram:)
    public func histogram(_ sender: Any!) {
        let winList = NSApp.windows
        var found = false

        for loopItem in winList {
            if let controller = loopItem.windowController, controller.windowNibName == "Histogram" {
                if (controller as AnyObject).curROI?() === roi {
                    found = true
                    controller.window?.makeKeyAndOrderFront(self)
                }
            }
        }

        if found == false {
            if (roi?.points?.count ?? 0) > 0 {
                let roiWin = HistoWindow(roi: roi)
                // [[HistoWindow alloc] initWithROI:] was not released: the
                // controller releases itself when its window closes.
                _ = Unmanaged.passRetained(roiWin)
                roiWin.showWindow(self)
            } else {
                HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Cannot create an histogram from this ROI.", comment: ""), defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        }
    }

    @IBAction @objc(plot:)
    public func plot(_ sender: Any!) {
        let winList = NSApp.windows
        var found = false

        for loopItem in winList {
            if let controller = loopItem.windowController, controller.windowNibName == "Plot" {
                if (controller as AnyObject).curROI?() === roi {
                    found = true
                    controller.window?.makeKeyAndOrderFront(self)
                }
            }
        }

        if found == false {
            let roiWin = PlotWindow(roi: roi)
            // [[PlotWindow alloc] initWithROI:] was not released: the
            // controller releases itself when its window closes.
            _ = Unmanaged.passRetained(roiWin)
            roiWin.showWindow(self)
        }
    }

    @objc(curROI)
    public func curROI() -> ROI! {
        return roi
    }
}
