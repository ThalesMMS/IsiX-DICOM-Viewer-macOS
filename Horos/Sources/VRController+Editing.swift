/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork


import Cocoa

/// What the VR window does to the volume: the mouse tools, the scissors and
/// the bone removal (cuts of the 2D series' volume, which the undo buffer
/// keeps a 16-bit copy of), and the convolution filters, whose first one
/// keeps a copy of the volume to put back when the window closes.
extension VRController {

    // MARK: - Tools

    public override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setDefaultTool(_:)) {
            item.state = item.tag == Int(vrView?.currentTool().rawValue ?? -1) ? .on : .off
        }
        return true
    }

    @IBAction @objc(setDefaultTool:)
    public final func setDefaultTool(_ sender: Any!) {
        let tag: Int
        if let matrix = sender as? NSMatrix {
            tag = matrix.selectedCell()?.tag ?? 0
        } else {
            tag = (sender as AnyObject?)?.tag ?? 0
        }
        if tag >= 0, let tool = ToolMode(rawValue: numericCast(tag)) {
            setCurrentTool(tool)
        }
    }

    /// The tool of the mouse's left button. The bone removal asks for its
    /// region growing's values first outside a CT (once) or with Option; the
    /// scissors with Option ask for the value they cut to.
    @objc(setCurrentTool:)
    public final func setCurrentTool(_ newTool: ToolMode) {
        let option = NSApplication.shared.currentEvent?.modifierFlags.contains(.option) == true
        if newTool == .tBonesRemoval {
            if (viewer2DStorage?.modality() != "CT" && !growingSet) || option {
                editGrowingRegion(self)
                growingSet = true
            }
        }
        if newTool == .t3DCut && option, let sheet = editDeleteValue, let window {
            let copyValue = deleteValue
            window.beginSheet(sheet, completionHandler: nil)
            let result = NSApp.runModal(for: sheet)
            sheet.makeFirstResponder(nil)
            sheet.sheetParent?.endSheet(sheet)
            sheet.orderOut(self)
            if result == .stop {
                NSLog("deleteValue for 3DCut changed : %f", deleteValue)
            } else {
                deleteValue = copyValue
            }
        }
        vrView?.setCurrentTool(newTool)
        toolsMatrixOutlet?.selectCell(withTag: Int(vrView?.currentTool().rawValue ?? 0))
    }

    @IBAction @objc(roiDeleteAll:)
    public final func roiDeleteAll(_ sender: Any!) {
        viewer2DStorage?.roiDeleteAll(sender)
    }

    @IBAction @objc(endEditGrowingRegion:)
    public final func endEditGrowingRegion(_ sender: Any!) {
        let tag = (sender as AnyObject?)?.tag ?? 0
        growingRegionWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
        if tag == 0 {
            UserDefaults.standard.set(Float(1125), forKey: "VRGrowingRegionValue")
            UserDefaults.standard.set(Float(1750), forKey: "VRGrowingRegionInterval")
        }
    }

    @IBAction @objc(editGrowingRegion:)
    public final func editGrowingRegion(_ sender: Any!) {
        let first = pixLists[0]?.object(at: 0) as? DCMPix
        UserDefaults.standard.set(first?.minValueOfSeries ?? 0, forKey: "VRGrowingRegionMin")
        UserDefaults.standard.set(first?.maxValueOfSeries ?? 0, forKey: "VRGrowingRegionMax")
        if let sheet = growingRegionWindow { window?.beginSheet(sheet, completionHandler: nil) }
    }

    // MARK: - Scissors

    /// One slice of a scissors' cut, sent by the view's operations on their
    /// own threads: [slice, orientation, key, ROI, fused series, addition,
    /// value, clip minimum, clip maximum]. The plan checks the slice and the
    /// clip against the volume first.
    @objc(applyScissor:)
    public nonisolated final func applyScissor(_ object: NSArray!) {
        guard let object, object.count >= 9 else { return }
        func int(_ index: Int) -> Int { (object.object(at: index) as? NSNumber)?.intValue ?? 0 }
        var i = int(0)
        var stackOrientation = int(1)
        let c = int(2)
        let roi = object.object(at: 3) as? ROI
        let blendedSeries = int(4) != 0
        let addition = int(5) != 0
        var newVal = Float(int(6))
        var minClip = (object.object(at: 7) as? NSValue)?.pointValue ?? .zero
        var maxClip = (object.object(at: 8) as? NSValue)?.pointValue ?? .zero

        var outside = false
        var restore = false
        if c == NSCarriageReturnCharacter || c == NSEnterCharacter {
            outside = true
        } else if c == NSTabCharacter {
            restore = true
        }

        guard let targetList = blendedSeries ? blendingPixList : pixLists[Int(curMovieIndexStorage)], targetList.count >= 1,
              let probe = targetList.object(at: 0) as? DCMPix else { return }
        let plan = VRScissorBounds.plan(width: Int(probe.pwidth), height: Int(probe.pheight), sliceCount: targetList.count,
                                        orientation: stackOrientation, stackNo: i, restore: restore,
                                        clipMinX: minClip.x, clipMinY: minClip.y, clipMaxX: maxClip.x, clipMaxY: maxClip.y)
        if !plan.accepted { return }

        let index = plan.pixIndex
        i = plan.stackNo
        stackOrientation = plan.orientation
        restore = plan.restore
        minClip = NSPoint(x: plan.clipMinX, y: plan.clipMinY)
        maxClip = NSPoint(x: plan.clipMaxX, y: plan.clipMaxY)
        if index < 0 || index >= targetList.count { return }

        if !addition { newVal = deleteValue }

        (targetList.object(at: index) as? DCMPix)?.fillROI(roi, newVal: newVal, minValue: -Float.greatestFiniteMagnitude,
                                                        maxValue: Float.greatestFiniteMagnitude, outside: outside,
                                                        orientationStack: stackOrientation, stackNo: i, restore: restore,
                                                        addition: addition, spline: false, clipMin: minClip, clipMax: maxClip)
    }

    /// A 16-bit copy of every time's volume, for -undo:. A cut that follows a
    /// filter is noted: closing the window then asks before it undoes the filters.
    @objc(prepareUndo)
    public final func prepareUndo() {
        if !horosApplyingFilter { horosFilterRestore?.noteCut() }

        for i in 0..<Int(maxMovieIndex) {
            guard let list = pixLists[i], let firstObject = list.object(at: 0) as? DCMPix else { continue }
            let data = volumeData[i].map { UnsafeMutableRawPointer(mutating: $0.bytes) }
            let memSize = VRScissorBounds.undoByteCount(width: Int(firstObject.pwidth), height: Int(firstObject.pheight),
                                                        sliceCount: list.count)
            if memSize <= 0 {
                NSLog("Undo failed... not enough memory")
                continue
            }
            if undodata[i] == nil {
                undodata[i] = malloc(memSize)?.assumingMemoryBound(to: Float.self)
            }
            if let undo = undodata[i] {
                var srcf = vImage_Buffer(data: data, height: vImagePixelCount(Int(firstObject.pheight) * list.count),
                                         width: vImagePixelCount(firstObject.pwidth),
                                         rowBytes: Int(firstObject.pwidth) * MemoryLayout<Float>.size)
                var dst16 = vImage_Buffer(data: UnsafeMutableRawPointer(undo), height: vImagePixelCount(Int(firstObject.pheight) * list.count),
                                          width: vImagePixelCount(firstObject.pwidth),
                                          rowBytes: Int(firstObject.pwidth) * MemoryLayout<Int16>.size)
                BrowserController.multiThreadedImageConvert("FTo16U", &srcf, &dst16, -(vrView?.offset() ?? 0),
                                                            1.0 / (vrView?.valueFactor() ?? 1))
            } else {
                NSLog("Undo failed... not enough memory")
            }
        }
    }

    @IBAction @objc(undo:)
    public override final func undo(_ sender: Any!) {
        NSLog("undo")
        for i in 0..<Int(maxMovieIndex) {
            if let undo = undodata[i], let list = pixLists[i], let firstObject = list.object(at: 0) as? DCMPix {
                let data = volumeData[i].map { UnsafeMutableRawPointer(mutating: $0.bytes) }
                var src16 = vImage_Buffer(data: UnsafeMutableRawPointer(undo), height: vImagePixelCount(Int(firstObject.pheight) * list.count),
                                          width: vImagePixelCount(firstObject.pwidth),
                                          rowBytes: Int(firstObject.pwidth) * MemoryLayout<Int16>.size)
                var dstf = vImage_Buffer(data: data, height: vImagePixelCount(Int(firstObject.pheight) * list.count),
                                         width: vImagePixelCount(firstObject.pwidth),
                                         rowBytes: Int(firstObject.pwidth) * MemoryLayout<Float>.size)
                BrowserController.multiThreadedImageConvert("16UToF", &src16, &dstf, -(vrView?.offset() ?? 0),
                                                            1.0 / (vrView?.valueFactor() ?? 1))
            }
            NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: pixLists[i], userInfo: nil)
        }
    }

    // MARK: - Filters

    @IBAction @objc(applyConvolution:)
    public final func applyConvolution(_ sender: Any!) {
        // Filtering rebuilds the filter menus, which releases the item that
        // sent this: its title is read before.
        let title = ((sender as AnyObject?)?.value(forKey: "title") as? String) ?? ""
        if !horosKeepVolumeBeforeFilter() { return }
        horosApplyingFilter = true
        prepareUndo()
        horosApplyingFilter = false
        viewer2DStorage?.applyConvString(title)
        viewer2DStorage?.applyConvolutionOnSource(self)
        appliedConvolutionFilters?.add(title)
    }

    @objc(UpdateConvolutionMenu:)
    public final func updateConvolutionMenu(_ note: Notification!) {
        let keys = (UserDefaults.standard.dictionary(forKey: "Convolution") ?? [:]).keys
        let sortedKeys = keys.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
        guard let menu = convolutionMenu?.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: NSLocalizedString("Apply a filter", comment: ""), action: nil, keyEquivalent: "")
        for key in sortedKeys {
            menu.addItem(withTitle: key, action: #selector(applyConvolution(_:)), keyEquivalent: "")
        }
    }

    /// Every time's volume, the buffers the filters write into.
    final func horosFilterVolumes() -> [NSData] {
        (0..<Int(maxMovieIndex)).compactMap { volumeData[$0] }
    }

    /// Keeps a copy of the volume before the first filter. NO if the copy could
    /// not be made and the user chose not to filter the 2D series for good.
    final func horosKeepVolumeBeforeFilter() -> Bool {
        if horosFilterRestore != nil { return true }
        horosFilterRestore = VRFilterRestore(volumes: horosFilterVolumes())
        if horosFilterRestore != nil { return true }
        return HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                                   message: NSLocalizedString("There is not enough memory to keep a copy of the volume. The filter will stay in the 2D series after this window closes.", comment: ""),
                                   defaultButton: NSLocalizedString("Apply", comment: ""),
                                   alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)
            == HorosAlertPanel.defaultResponse
    }

    final func horosRestoreVolumeBeforeFilter() {
        guard let restore = horosFilterRestore else { return }
        _ = restore.restore(into: horosFilterVolumes())
        horosFilterRestore = nil
        appliedConvolutionFilters?.removeAllObjects()
        for i in 0..<Int(maxMovieIndex) {
            NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: pixLists[i], userInfo: nil)
        }
    }

    // The 2D series gets back the volume it had before the first filter, unless
    // a cut followed that filter: the user then chooses, since the cut goes too.
    final func horosSettleFiltersOnClose() {
        let action = VRFilterRestore.closeAction(hasCopy: horosFilterRestore != nil,
                                                 cutAfterFilter: horosFilterRestore?.cutAfterFilter ?? false,
                                                 viewerClosing: horosViewerClosing)
        if action == .restore {
            horosRestoreVolumeBeforeFilter()
        } else if action == .ask {
            let response = HorosAlertPanel.run(title: NSLocalizedString("Convolution Filters", comment: ""),
                                               message: NSLocalizedString("Convolution filters applied in the 3D window changed the 2D series. Restoring it removes the filters, and also the cuts made after the first filter.", comment: ""),
                                               defaultButton: NSLocalizedString("Restore 2D Series", comment: ""),
                                               alternateButton: NSLocalizedString("Keep in 2D Series", comment: ""), otherButton: nil)
            if response == HorosAlertPanel.defaultResponse { horosRestoreVolumeBeforeFilter() }
        }
        horosFilterRestore = nil
    }

    @objc(revertSeries:)
    public final func revertSeries(_ sender: Any!) {
        // A post-processed 2D series (MPR, reslicing...) cannot be read again
        // from its files: the copy kept before the first filter brings it back.
        if horosFilterRestore != nil && viewer2DStorage?.postprocessed() == true {
            horosRestoreVolumeBeforeFilter()
            if presetsPanel?.isVisible == true { displayPresetsForSelectedGroup() }
            return
        }
        // Read from the files again, the 2D series has no filter left to undo.
        horosFilterRestore = nil
        NotificationCenter.default.post(name: .OsirixRevertSeries, object: pixLists[Int(curMovieIndexStorage)], userInfo: nil)
        appliedConvolutionFilters?.removeAllObjects()
        if presetsPanel?.isVisible == true { displayPresetsForSelectedGroup() }
    }
}
