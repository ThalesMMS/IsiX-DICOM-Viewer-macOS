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
import IsiXImaging
import IsiXPreferences

/// What a slice read from its file again does not get back from it: the
/// slice interval its 2D viewer worked out, which the formats that are not
/// DICOM set again from their headers, and for a PET slice converted to SUV
/// the factor and the stored window level, which the file has in its own units.
private struct VRSliceKeptState {
    let sliceInterval: Double
    let suv: (factor: Float, level: Float, width: Float)?

    init(_ pix: DCMPix) {
        sliceInterval = pix.sliceInterval
        suv = pix.suvConverted ? (factor: pix.factorPET2SUV, level: pix.savedWL, width: pix.savedWW) : nil
    }

    /// Puts it back on `pix`, read again: a slice that was in SUV is converted
    /// again by its factor, as the 2D viewer converted it.
    func restore(into pix: DCMPix) {
        pix.sliceInterval = sliceInterval
        if let suv, let pixels = pix.fImage {
            PETSUVConversion.scale(pixels, count: pix.pheight * pix.pwidth, by: suv.factor)
            pix.suvConverted = true
            pix.factorPET2SUV = suv.factor
            pix.savedWL = suv.level
            pix.savedWW = suv.width
            pix.computePixMinPixMax()
        }
        pix.maxValueOfSeries = 0
        pix.minValueOfSeries = 0
    }
}

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
            processGraph.preferences.set(Float(1125), for: VolumeRenderingPreferences.vrGrowingRegionValue)
            processGraph.preferences.set(Float(1750), for: VolumeRenderingPreferences.vrGrowingRegionInterval)
        }
    }

    @IBAction @objc(editGrowingRegion:)
    public final func editGrowingRegion(_ sender: Any!) {
        let first = pixLists[0]?.object(at: 0) as? DCMPix
        processGraph.preferences.set(first?.minValueOfSeries ?? 0, for: VolumeRenderingPreferences.vrGrowingRegionMin)
        processGraph.preferences.set(first?.maxValueOfSeries ?? 0, for: VolumeRenderingPreferences.vrGrowingRegionMax)
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
    /// filter is noted: closing the window then asks before it undoes the
    /// filters. A cut with no copy before a filter is one that copy cannot take back.
    @objc(prepareUndo)
    public final func prepareUndo() {
        horosChangedWithoutFilterCopyBeforeUndoCopy = horosChangedWithoutFilterCopy
        horosCutAfterFilterBeforeUndoCopy = horosFilterRestore?.cutAfterFilter ?? false
        if !horosApplyingFilter {
            horosFilterRestore?.noteCut()
            if horosFilterRestore == nil { horosChangedWithoutFilterCopy = true }
        }

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

    /// The volume as the undo copy has it: before the last cut or filter. What
    /// the window noted of changes no copy takes back is as it was then too.
    @IBAction
    public override final func undo(_ sender: Any!) {
        NSLog("undo")
        for i in 0..<Int(maxMovieIndex) {
            if let undo = undodata[i], let list = pixLists[i], let firstObject = list.object(at: 0) as? DCMPix {
                horosChangedWithoutFilterCopy = horosChangedWithoutFilterCopyBeforeUndoCopy
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
        }
        // The cut the copy took back is no longer one the window asks about when it closes.
        if undodata.contains(where: { $0 != nil }) { horosFilterRestore?.restoreCutNote(horosCutAfterFilterBeforeUndoCopy) }
        horosAnnounceVolumes()
    }

    /// Every time of the volume changed: the windows on it (this one, the 2D
    /// viewer while it shows it, the other 3D windows) draw it again.
    /// `readFromFiles` says the slices were read from their files again, and
    /// whether a gantry tilt correction went with that: every window on the
    /// volume then forgets what it kept of the volume before.
    final func horosAnnounceVolumes(readFromFiles tiltGone: Bool? = nil) {
        let info = tiltGone.map { [VRController.horosReadFromFilesKey: $0] }
        for i in 0..<Int(maxMovieIndex) {
            NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: pixLists[i], userInfo: info)
        }
    }

    /// The key of a volume update that follows a reading of the slices from
    /// their files; its value, whether the gantry tilt correction is gone.
    static let horosReadFromFilesKey = "HorosVolumeReadFromFiles"

    /// The volume was read from its files again, by this window, by another
    /// 3D window on it or by the 2D viewer: it has no filter nor cut left to
    /// undo, and its slices the geometry of their files. The copy before the
    /// first filter and the undo copy are of the volume before, and putting
    /// one back would write over the volume read.
    final func horosVolumeWasReadFromFiles(tiltGone: Bool) {
        horosFilterRestore = nil
        appliedConvolutionFilters?.removeAllObjects()
        horosChangedWithoutFilterCopy = false
        horosRecordSliceGeometry()
        horosForgetUndo()
        horosVolumeReadAgain = tiltGone
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
        horosApplyFilter(named: title)
    }

    /// The stored filter `name` on the window's volume, added to its filters.
    /// While the 2D viewer shows the window's slices, its series is this
    /// volume, and the 2D viewer filters it ("apply on source"). After a change
    /// of plane it shows other slices: the window filters the volume it kept
    /// itself, as the 2D viewer would, and the 2D viewer's series is left alone.
    final func horosApplyFilter(named name: String) {
        if horosViewerShowsSeries() {
            viewer2DStorage?.applyConvString(name)
            viewer2DStorage?.applyConvolutionOnSource(self)
        } else if !horosFilterVolume(named: name) {
            return
        }
        if horosFilterRestore == nil { horosChangedWithoutFilterCopy = true }
        appliedConvolutionFilters?.add(name)
    }

    /// The stored filter `name` through every time of the window's volume
    /// (SeriesConvolution.filterVolume), then the windows on it draw it again.
    /// NO, after the 2D viewer's alert, for a filter that cannot be read.
    private final func horosFilterVolume(named name: String) -> Bool {
        let stored = PresetTable(ImagePresetPreferences.convolutionPresets, in: processGraph.preferences).entries?[name]
        guard let kernel = ConvolutionKernelBook.Kernel(stored: stored?.object) else {
            HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""),
                                message: NSLocalizedString("This convolution filter cannot be loaded.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return false
        }
        let convolution = SeriesConvolution()
        for i in 0..<Int(maxMovieIndex) {
            guard let slices = pixLists[i], let first = slices.firstObject as? DCMPix, let volume = volumeData[i] else { continue }
            convolution.filterVolume(UnsafeMutableRawPointer(mutating: volume.bytes), byteCount: volume.length,
                                     width: Int(first.pwidth), height: Int(first.pheight), depth: slices.count,
                                     kernel: kernel, colour: first.isRGB)
        }
        horosAnnounceVolumes()
        return true
    }

    @objc(UpdateConvolutionMenu:)
    public final func updateConvolutionMenu(_ note: Notification!) {
        let sortedKeys = PresetTable(ImagePresetPreferences.convolutionPresets, in: processGraph.preferences).names.sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
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
    /// not be made and the user chose not to filter for good. The alert names
    /// where -horosApplyFilter(named:) puts the filter: the 2D series while the
    /// 2D viewer shows the window's slices; otherwise the volume the window
    /// kept, which the 3D windows opened before a change of plane show too,
    /// and the 2D series does not change.
    final func horosKeepVolumeBeforeFilter() -> Bool {
        if horosFilterRestore != nil { return true }
        horosFilterRestore = VRFilterRestore(volumes: horosFilterVolumes())
        if horosFilterRestore != nil { return true }
        let message = horosViewerShowsSeries()
            ? NSLocalizedString("There is not enough memory to keep a copy of the volume. The filter will stay in the 2D series after this window closes.", comment: "")
            : NSLocalizedString("There is not enough memory to keep a copy of the volume. The filter will stay in this window's volume and, after this window closes, in the other 3D windows that show it. The 2D series does not change.", comment: "")
        return HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                                   message: message,
                                   defaultButton: NSLocalizedString("Apply", comment: ""),
                                   alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)
            == HorosAlertPanel.defaultResponse
    }

    final func horosRestoreVolumeBeforeFilter() {
        guard let restore = horosFilterRestore else { return }
        _ = restore.restore(into: horosFilterVolumes())
        horosFilterRestore = nil
        appliedConvolutionFilters?.removeAllObjects()
        horosAnnounceVolumes()
    }

    // The 2D series gets back the volume it had before the first filter, unless
    // a cut followed that filter: the user then chooses, since the cut goes too.
    // A 2D viewer that no longer shows the window's slices (a change of plane)
    // has no 2D series to give it back to, and the question would name one:
    // the volume the window kept, which the 3D windows opened before the
    // change still show, gets it back without a question when no cut followed
    // the filter, and keeps both otherwise.
    final func horosSettleFiltersOnClose() {
        let action = VRFilterRestore.closeAction(hasCopy: horosFilterRestore != nil,
                                                 cutAfterFilter: horosFilterRestore?.cutAfterFilter ?? false,
                                                 viewerClosing: horosViewerClosing)
        if action == .restore {
            horosRestoreVolumeBeforeFilter()
        } else if action == .ask && horosViewerShowsSeries() {
            let response = HorosAlertPanel.run(title: NSLocalizedString("Convolution Filters", comment: ""),
                                               message: NSLocalizedString("Convolution filters applied in the 3D window changed the 2D series. Restoring it removes the filters, and also the cuts made after the first filter.", comment: ""),
                                               defaultButton: NSLocalizedString("Restore 2D Series", comment: ""),
                                               alternateButton: NSLocalizedString("Keep in 2D Series", comment: ""), otherButton: nil)
            if response == HorosAlertPanel.defaultResponse { horosRestoreVolumeBeforeFilter() }
        }
        horosFilterRestore = nil
    }

    /// Whether the 2D viewer still shows the slices of this window. After a
    /// change of plane it shows others, and this window holds the former ones
    /// (PreviousSeriesHold): the revert it asks for reaches no viewer.
    final func horosViewerShowsSeries() -> Bool {
        guard let viewer = viewer2DStorage else { return false }
        let shown = pixLists[Int(curMovieIndexStorage)]
        return (0..<max(viewer.horos_movieCount, 0)).contains { viewer.horos_pixList(at: $0) === shown }
    }

    /// The gantry tilt correction the window's volume has: its 2D viewer's,
    /// which the 3D views say they show, unless the slices were read from
    /// their files again since and could not be corrected again.
    final func horosTiltCorrection() -> NSNumber? {
        horosVolumeReadAgain ? nil : GantryTiltPolicy.correctedDegrees(of: viewer2DStorage)
    }

    /// The volume was read again: the undo copy, made before the last cut,
    /// would put back what Revert Series took away.
    final func horosForgetUndo() {
        for i in 0..<Int(maxMovieIndex) {
            free(undodata[i])
            undodata[i] = nil
        }
    }

    /// Whether the window can read its slices from their files itself: they
    /// were read from them when it opened, and every one has its file, still
    /// the one it was decoded from. A file removed or rewritten since would
    /// give a slice of nothing or of other pixels, which no copy takes back:
    /// the copy before the first filter, if any, brings the volume back instead.
    final func horosSlicesReadableFromFiles() -> Bool {
        horosSlicesFromFiles && (0..<Int(maxMovieIndex)).allSatisfy { i in
            let slices = (pixLists[i] as? [DCMPix]) ?? []
            return !slices.isEmpty && slices.allSatisfy { $0.srcFile != nil && $0.loadedFileMatchesDisk() }
        }
    }

    /// Whether the 2D viewer, asked to read the slices it shows from their
    /// files, would refuse because one was removed or changed since it was
    /// read. The window then says so and changes nothing: its volume, the copy
    /// before the first filter and the undo copy are all that is left of the
    /// series, and a revert that went on would drop them for slices the files
    /// no longer give.
    final func horosRevertRefusedForChangedFiles() -> Bool {
        guard let viewer = viewer2DStorage, horosViewerShowsSeries(), !viewer.postprocessed() else { return false }
        viewer.checkEverythingLoaded()
        guard !ViewerLoadingWait(viewer: viewer).slicesMatchTheirFiles() else { return false }
        HorosAlertPanel.run(title: NSLocalizedString("Revert Series", comment: ""),
                            message: NSLocalizedString("Files of this dataset were removed or changed since it was read. You cannot restore it.", comment: ""),
                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        return true
    }

    /// Whether every slice of every time was decoded from its file, changed or
    /// removed since or not: it has one, and the record of the file it was
    /// decoded from, or no file left on the disk (a file missing when its
    /// slice was read leaves no record). A slice made in memory, by a plugin
    /// for instance, has no file, or no record of one: its pixels are no file's.
    final func horosSlicesCameFromFiles() -> Bool {
        (0..<Int(maxMovieIndex)).allSatisfy { i in
            ((pixLists[i] as? [DCMPix]) ?? []).allSatisfy { pix in
                guard let path = pix.srcFile else { return false }
                return pix.loadedFileRevision() != nil || FileRevision(path: path) == nil
            }
        }
    }

    /// The orientation, width and height of `pix`: what the 2D viewer's flips
    /// and rotations change in every slice of its series, with the pixels (the
    /// size tells a quarter turn of a slice whose file gives no orientation).
    static func horosSliceGeometry(of pix: DCMPix?) -> [Double] {
        guard let pix else { return [] }
        var orientation = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&orientation)
        return orientation + [Double(pix.pwidth), Double(pix.pheight)]
    }

    /// Records the geometry the window's first slice has now, as its file
    /// gave it: when the window opens, and once the slices are read again.
    final func horosRecordSliceGeometry() {
        horosSliceGeometryAsRead = VRController.horosSliceGeometry(of: pixLists[0]?.firstObject as? DCMPix)
    }

    /// Whether the window's slices keep the geometry they were read with. The
    /// 2D viewer's flips and rotations turn the slices it shows in place, every
    /// time at once, pixels and orientation; a change of plane then gives the
    /// 2D viewer other slices, and the window's stay turned. The gantry tilt
    /// correction moves the slices' origins only.
    final func horosSlicesKeepGeometryAsRead() -> Bool {
        VRController.horosSliceGeometry(of: pixLists[0]?.firstObject as? DCMPix) == horosSliceGeometryAsRead
    }

    /// Why the scissors cannot restore (Tab) the pixels inside an ROI, nil when
    /// they can. The restore reads the window's own slices from their files
    /// again (-prepareRestore), so they must be the files' pixels: read from
    /// them when the window opened, not post-processed since by the 2D viewer
    /// that still shows them, nor turned in place by it before a change of
    /// plane gave it others (-horosSlicesKeepGeometryAsRead), and every file
    /// unchanged (-horosSlicesReadableFromFiles). A slice made in memory has
    /// no file to give its pixels back: post-processed too. A change of plane
    /// post-processes the 2D viewer but gives it other slices: the window's
    /// are still the files'. A window opened without a 2D viewer has no record
    /// of where its slices came from and is not refused.
    final func horosScissorRestoreRefusal() -> String? {
        guard let viewer = viewer2DStorage else { return nil }
        let postProcessed = NSLocalizedString("This dataset has been post processed (reslicing, MPR, ...). You cannot restore it.", comment: "")
        if !horosSlicesFromFiles || (horosViewerShowsSeries() && viewer.postprocessed()) || !horosSlicesKeepGeometryAsRead() {
            return postProcessed
        }
        if horosSlicesReadableFromFiles() { return nil }
        return horosSlicesCameFromFiles()
            ? NSLocalizedString("Files of this dataset were removed or changed since it was read. You cannot restore it.", comment: "")
            : postProcessed
    }

    /// Every slice of every time read from its file again, into the volume the
    /// slices share, as the 2D viewer's revert reads the slices it shows: the
    /// cuts, the bone removal and the filters go. What the files do not give
    /// back is kept (VRSliceKeptState): the slice interval, and for a PET
    /// slice converted to SUV its factor, by which it is converted again, and
    /// its stored window level. A gantry tilt corrected before is corrected
    /// again: the files give the slices tilted, and the grid the 3D windows
    /// render, cut and place their points in is the corrected one. Then the
    /// windows on the volume draw it again.
    final func horosReadSlicesFromFiles() {
        let slices = (0..<Int(maxMovieIndex)).flatMap { (pixLists[$0] as? [DCMPix]) ?? [] }
        let kept = slices.map(VRSliceKeptState.init)
        let corrected = horosTiltCorrection() != nil
        let wait = WaitRendering(NSLocalizedString("Data loading...", comment: ""))
        wait?.start()

        for pix in slices { pix.revert() }
        SeriesDecoding.decode(slices)
        for (pix, state) in zip(slices, kept) { state.restore(into: pix) }
        var tiltGone = false
        if corrected {
            for i in 0..<Int(maxMovieIndex) {
                let time = (pixLists[i] as? [DCMPix]) ?? []
                if !GantryTiltSlices(slices: time).correct(progress: {}) { tiltGone = true }
            }
            // The correction clears the intervals, which the 2D viewer computes again; these slices it no longer shows.
            for (pix, state) in zip(slices, kept) { pix.sliceInterval = state.sliceInterval }
        }

        wait?.end()
        wait?.close()
        horosAnnounceVolumes(readFromFiles: tiltGone)
    }

    /// The voxels as the files or the copy before the first filter have them,
    /// then the presentation of a first opening (-restoreOpeningPresentation):
    /// the colour, opacity and 16-bit tables, the window level and the
    /// shading. The camera, the crop box and the clipping range stay.
    ///
    /// The 2D viewer reads the slices again when it still shows them as they
    /// came from their files (not a post-processed series: MPR, reslicing...).
    /// A change of plane gives it others and lets this window keep the former
    /// ones: the window reads them again itself when they came from their
    /// files (VolumeRevertSource). Otherwise the copy kept before the first
    /// filter brings the volume back, and without one nothing is asked of the
    /// 2D viewer. The presentation is restored in every case; the window warns
    /// only when the volume keeps a cut or a correction it could not take back.
    @objc(revertSeries:)
    public final func revertSeries(_ sender: Any!) {
        if horosRevertRefusedForChangedFiles() { return }
        let source = VolumeRevertSource(viewerShowsSlices: horosViewerShowsSeries(),
                                        viewerPostprocessed: viewer2DStorage?.postprocessed() == true,
                                        slicesFromFiles: horosSlicesReadableFromFiles(),
                                        hasFilterCopy: horosFilterRestore != nil)
        switch source {
        case .viewerReadsFiles:
            NotificationCenter.default.post(name: .OsirixRevertSeries, object: pixLists[Int(curMovieIndexStorage)], userInfo: nil)
        case .windowReadsFiles:
            horosReadSlicesFromFiles()
        case .filterCopy:
            horosRestoreVolumeBeforeFilter()
        case .nothing:
            break
        }
        if source != .nothing { horosForgetUndo() }
        let changesStay = source.keepsChanges(changedWithoutCopy: horosChangedWithoutFilterCopy,
                                              tiltCorrected: horosTiltCorrection() != nil)
        restoreOpeningPresentation()
        if presetsPanel?.isVisible == true { displayPresetsForSelectedGroup() }
        if changesStay {
            HorosAlertPanel.run(title: NSLocalizedString("Revert Series", comment: ""),
                                message: NSLocalizedString("The color tables, the window level and the shading were restored, but not the volume: the cuts and corrections made to it stay, because the 2D viewer no longer shows this series as it was read from its files.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }
}
