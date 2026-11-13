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
import IsiXROI

// The ROI editing of the 2D viewer: volume, set pixels, rename, propagation,
// selection, groups and order of the ROIs. ViewerController keeps the
// selectors that plugins, nibs, menus and the other viewer files send, as
// façades; the work is done by the types below, which receive the viewer as
// an argument and never keep it:
//
// - ViewerROISelection selects, groups, locks and orders the ROIs of the image
//   shown, by the rules of ROISelection and ROIGroups (IsiXROI);
// - ViewerROIPropagation copies the selected ROIs to the images a
//   ROIPropagationPlan (IsiXROI) names;
// - ViewerROISetPixels sets the pixels inside or outside the ROIs as a
//   ROISetPixelsJob (IsiXROI) asks, the images side by side;
// - ViewerROIQueries finds the ROIs by name or comment and morphs them;
// - ViewerROIPanels runs the ROI sheets and opens the ROI windows;
// - ViewerROIToolPalette shows the ROI tool in the tool palette.
//
// The ROI lists of the viewer keep their identity (ViewerROISlices): roiList,
// roiList: and setRoiList:array: hand over the viewer's own mutable arrays,
// which plugins hold and change, and the ROIs found are given to plugins as
// mutable arrays, as they were.

/// ToolsMenuIconSize, a macro of ViewerController.h that Swift does not import.
fileprivate let ToolsMenuIconSize = NSMakeSize(28.0, 28.0)

/// `[a isEqualToString: b]`: two names written the same, code unit by code
/// unit; NO when either is nil.
fileprivate func sameText(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return a.utf16.elementsEqual(b.utf16)
}

/// The ROIs or names found, as the mutable array the former selectors
/// answered, which plugins may change.
fileprivate func roiArray(_ items: [Any]) -> NSMutableArray { NSMutableArray(array: items) }

/// C's float to int conversion on arm64: saturating, NaN to 0.
fileprivate func cInt32(_ x: Float) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

public extension ViewerController {
    // MARK: - ROI editing

    @objc(roiVolume:)
    func roiVolume(_ sender: Any!) {
        ViewerROIPanels.volume(ViewerSender.tag(sender), in: self)
    }

    @objc(roiSetPixelsSetup:)
    func roiSetPixelsSetup(_ sender: Any!) {
        ViewerROISetPixels.beginSheet(in: self)
    }

    @objc(recomputeROI:)
    func recomputeROI(_ note: Notification!) {
        if (note?.object as AnyObject?) === self { ViewerROISetPixels.recomputeROIs(in: self) }
        willChangeValue(forKey: "thicknessInMm")
        didChangeValue(forKey: "thicknessInMm")
    }

    @objc(roiSetPixelsCheckButton:)
    func roiSetPixelsCheckButton(_ sender: Any!) {
        ViewerROISetPixels.updateRestoreChoice(in: self)
    }

    @objc(roiSetPixels:)
    func roiSetPixels(_ sender: Any!) {
        ViewerROISetPixels.endSheet(ViewerSender.tag(sender), sender: sender, in: self)
    }

    /// Runs the fills and morphology filters described by `roiToProceed`
    /// ({action, curPix, roi, newValue, …}, as ViewerControllerOperation reads
    /// them) side by side, under the ROI lock.
    @objc(roiSetStartScheduler:)
    func roiSetStartScheduler(_ roiToProceed: NSMutableArray!) {
        ViewerROISetPixels.run(requests: (roiToProceed as? [NSDictionary]) ?? [], in: self)
    }

    @objc(roiSetPixels::::::::)
    func roiSetPixels(_ aROI: ROI!, _ allRois: Int16, _ propagateIn4D: Bool, _ outside: Bool, _ minValue: Float, _ maxValue: Float, _ newValue: Float, _ revert: Bool) {
        let job = ROISetPixelsJob(scope: ROISetPixelsJob.Scope(tag: Int(allRois)), propagateIn4D: propagateIn4D, outside: outside,
                                  minValue: minValue, maxValue: maxValue, newValue: newValue, revert: revert)
        ViewerROISetPixels.run(job, selected: aROI, in: self)
    }

    @objc(roiSetPixels:::::::)
    func roiSetPixels(_ aROI: ROI!, _ allRois: Int16, _ propagateIn4D: Bool, _ outside: Bool, _ minValue: Float, _ maxValue: Float, _ newValue: Float) {
        roiSetPixels(aROI, allRois, propagateIn4D, outside, minValue, maxValue, newValue, false)
    }

    @objc(endRoiRename:)
    func endRoiRename(_ sender: Any!) {
        ViewerROIPanels.endRename(ViewerSender.tag(sender), sender: sender, in: self)
    }

    @objc(roiRename:)
    func roiRename(_ sender: Any!) {
        add(toUndoQueue: "roi")
        ViewerROIPanels.beginSheet(horos_roiRenameWindow, in: self)
    }

    @objc(closeModal:)
    func closeModal(_ sender: Any!) {
        if ViewerSender.tag(sender) != 0 { NSApp.stopModal() } else { NSApp.abortModal() }
    }

    /// The ROIs the Apply panel's choice covers, once the panel is accepted.
    @objc(roiApplyWindow:)
    func roiApplyWindow(_ sender: Any!) -> NSArray! {
        roiArray(ViewerROIPanels.runApplyPanel(sender: sender, in: self))
    }

    @objc(roiDeleteAll:)
    func roiDeleteAll(_ sender: Any!) {
        ViewerROIPanels.deleteAllUnlocked(in: self)
    }

    @objc(roiPropagateSetup:)
    func roiPropagateSetup(_ sender: Any!) {
        ViewerROIPropagation.beginSheet(in: self)
    }

    @objc(roiHistogram:)
    func roiHistogram(_ sender: Any!) {
        ViewerROIPanels.showHistograms(in: self)
    }

    @objc(roiGetInfo:)
    func roiGetInfo(_ sender: Any!) {
        ViewerROIPanels.showInfo(in: self)
    }

    @objc(roiDefaults:)
    func roiDefaults(_ sender: Any!) {
        ViewerROIPanels.showDefaults(in: self)
    }

    @objc(roiPropagateSlab:)
    func roiPropagateSlab(_ sender: Any!) {
        ViewerROIPropagation.propagateThroughSlab(in: self)
    }

    /// The ROI lists of the current time point: the viewer's own array.
    @objc(roiList)
    func roiList() -> NSMutableArray! {
        horos_roiList(at: Int(horos_curMovieIndex))
    }

    /// The ROI lists of time point `i`, clamped to the time points (and to
    /// the first slot without any).
    @objc(roiList:)
    func roiList(_ i: Int) -> NSMutableArray! {
        horos_roiList(at: ROIPropagationPlan.movieIndex(i, movieCount: Int(horos_maxMovieIndex)))
    }

    /// Stores `a` as the ROI lists of time point `i`, clamped as -roiList:
    /// clamps it, through the setter that retains the new array before it
    /// releases the one it held.
    @objc(setRoiList:array:)
    func setRoiList(_ i: Int, array a: NSMutableArray!) {
        horos_setRoiList(a, at: ROIPropagationPlan.movieIndex(i, movieCount: Int(horos_maxMovieIndex)))
    }

    @objc(roiPropagate:)
    func roiPropagate(_ sender: Any!) {
        ViewerROIPropagation.endSheet(ViewerSender.tag(sender), sender: sender, in: self)
    }

    /// Shows a ROI tool in the palette's last cell and selects that cell,
    /// without choosing the tool for a mouse button.
    func showROIToolInPalette(_ roitype: ToolMode) {
        ViewerROIToolPalette.show(roitype, in: self)
    }

    @objc(setROIToolTag:)
    func setROIToolTag(_ roitype: ToolMode) {
        ViewerROIToolPalette.choose(roitype, in: self)
    }

    @objc(setROITool:)
    func setROITool(_ sender: Any!) {
        ViewerROIToolPalette.choose(from: sender, in: self)
    }

    /// The names of the ROIs of the current time point, each once.
    @objc(roiNames)
    func roiNames() -> NSArray! {
        roiArray(ViewerROIQueries.names(in: self))
    }

    @objc(roisWithComment:)
    func rois(withComment comment: String!) -> NSArray! {
        roiArray(ViewerROIQueries.rois(in: self, movie: Int(horos_curMovieIndex)) { sameText($0.comments, comment) })
    }

    @objc(roisWithName:)
    func rois(withName name: String!) -> NSArray! {
        rois(withName: name, in4D: false)
    }

    @objc(roisWithName:in4D:)
    func rois(withName name: String!, in4D: Bool) -> NSArray! {
        let movies = in4D ? Array(0..<Int(horos_maxMovieIndex)) : [Int(horos_curMovieIndex)]
        return roiArray(movies.flatMap { movie -> [ROI] in ViewerROIQueries.rois(in: self, movie: movie) { sameText($0.name, name) } })
    }

    @objc(roisWithName:forMovieIndex:)
    func rois(withName name: String!, forMovieIndex m: Int32) -> NSArray! {
        roiArray(ViewerROIQueries.rois(in: self, movie: Int(m)) { sameText($0.name, name) })
    }

    @objc(isoContourROI:numberOfPoints:)
    func isoContourROI(_ a: ROI!, numberOfPoints nof: Int32) -> ROI! {
        ViewerROIQueries.isoContour(a, points: nof, in: self)
    }

    @objc(roiMorphingBetween:and:ratio:)
    func roiMorphingBetween(_ a: ROI!, and b: ROI!, ratio: Float) -> ROI! {
        ViewerROIQueries.morphing(between: a, and: b, ratio: ratio, in: self)
    }

    /// Observed for OsirixROIChangeNotification; nothing to do since the
    /// curved MPR left.
    @objc(roiChange:)
    func roiChange(_ note: Notification!) {}

    @objc(selectedROI)
    func selectedROI() -> ROI! {
        ViewerROISelection.selected(in: self)
    }

    @objc(selectedROIs)
    func selectedROIs() -> NSMutableArray! {
        roiArray(ViewerROISelection.selectedROIs(in: self))
    }

    @objc(setMode:toROIGroupWithID:)
    func setMode(_ mode: Int, toROIGroupWithID groupID: TimeInterval) {
        ViewerROISelection.setMode(mode, toGroup: groupID, in: self)
    }

    @objc(selectROI:deselectingOther:)
    func select(_ roi: ROI!, deselectingOther deselectOther: Bool) {
        ViewerROISelection.select(roi, deselectingOthers: deselectOther, in: self)
    }

    @objc(deselectAllROIs)
    func deselectAllROIs() {
        ViewerROISelection.deselectAll(in: self)
    }

    @objc(setSelectedROIsGrouped:)
    func setSelectedROIsGrouped(_ grouped: Bool) {
        ViewerROISelection.setGrouped(grouped, in: self)
    }

    @objc(groupSelectedROIs)
    func groupSelectedROIs() {
        setSelectedROIsGrouped(true)
    }

    @objc(ungroupSelectedROIs)
    func ungroupSelectedROIs() {
        setSelectedROIsGrouped(false)
    }

    @objc(groupSelectedROIs:)
    func groupSelectedROIs(_ sender: Any!) {
        groupSelectedROIs()
    }

    @objc(ungroupSelectedROIs:)
    func ungroupSelectedROIs(_ sender: Any!) {
        ungroupSelectedROIs()
    }

    @objc(setSelectedROIsLocked:)
    func setSelectedROIsLocked(_ locked: Bool) {
        ViewerROISelection.changeSelected(in: self) { $0.locked = locked }
    }

    @objc(lockSelectedROIs:)
    func lockSelectedROIs(_ sender: Any!) {
        setSelectedROIsLocked(true)
    }

    @objc(unlockSelectedROIs:)
    func unlockSelectedROIs(_ sender: Any!) {
        setSelectedROIsLocked(false)
    }

    @objc(makeSelectedROIsUnselectable:)
    func makeSelectedROIsUnselectable(_ sender: Any!) {
        ViewerROISelection.changeSelected(in: self) { $0.selectable = false }
    }

    @objc(makeAllROIsSelectable:)
    func makeAllROIsSelectable(_ sender: Any!) {
        ViewerROISelection.makeAllSelectable(in: self)
    }

    @objc(bringToFrontROI:)
    func bring(toFrontROI roi: ROI!) {
        ViewerROISelection.bringToFront(roi, in: self)
    }

    @objc(sendToBackROI:)
    func send(toBack roi: ROI!) {
        ViewerROISelection.sendToBack(roi, in: self)
    }
}

// MARK: - The ROIs shown

/// The ROIs of the image a viewer shows, in its current time point: the
/// viewer's own list, read as ROIs and changed in place.
@MainActor struct ViewerShownROIs {
    private let slices: ViewerROISlices?
    /// The index of the image shown.
    let index: Int

    init(_ viewer: ViewerController) {
        slices = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex))
        index = Int(viewer.horos_imageView?.curImage ?? 0)
    }

    /// The ROIs of the image, in the order of its list.
    var rois: [ROI] { slices?.rois(at: index) ?? [] }

    /// The selected ROIs of the image, in the order of its list.
    var selected: [ROI] {
        let rois = self.rois
        return ROISelection(modes: rois.map(\.roImode)).selectedIndexes.map { rois[$0] }
    }

    /// Puts `order` in the image's list itself, which keeps its identity.
    func replace(with order: [ROI]) {
        slices?.list(at: index)?.setArray(order)
    }

    /// Whether the image has a list.
    var hasList: Bool { slices?.list(at: index) != nil }
}

/// The image `slice` of time point `movie`, nil past the series.
@MainActor fileprivate func viewerPix(_ viewer: ViewerController, _ movie: Int, _ slice: Int) -> DCMPix? {
    guard let list = viewer.horos_pixList(at: movie), slice >= 0, slice < list.count else { return nil }
    return list[slice] as? DCMPix
}

/// The number of images of time point `movie`.
@MainActor fileprivate func viewerPixCount(_ viewer: ViewerController, _ movie: Int) -> Int {
    viewer.horos_pixList(at: movie)?.count ?? 0
}

/// The ROIs of every image of time point `movie`, in their order.
@MainActor fileprivate func viewerSeriesROIs(_ viewer: ViewerController, movie: Int) -> [ROI] {
    let slices = ViewerROISlices(viewer, movie: movie)
    return (0..<viewerPixCount(viewer, movie)).flatMap { slices?.rois(at: $0) ?? [] }
}

/// Shows the critical alert of a ROI command.
@MainActor fileprivate func viewerROIAlert(_ title: String, _ message: String) {
    HorosAlertPanel.runCritical(title: NSLocalizedString(title, comment: ""), message: NSLocalizedString(message, comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
}

// MARK: - Selection, groups and order

/// The selection, the groups, the locks and the order of the ROIs of the
/// image a viewer shows.
@MainActor enum ViewerROISelection {

    /// The ROI the commands of one ROI start from: the last selected one or,
    /// with none selected, the only ROI of the image, which becomes selected.
    static func selected(in viewer: ViewerController) -> ROI? {
        let rois = ViewerShownROIs(viewer).rois
        guard let current = ROISelection(modes: rois.map(\.roImode)).current else { return nil }
        let roi = rois[current.index]
        if current.selectsIt {
            roi.roImode = ROI_selected
            viewer.horos_imageView?.display()
        }
        return roi
    }

    /// The selected ROIs of the image shown, in the order of its list.
    static func selectedROIs(in viewer: ViewerController) -> [ROI] {
        ViewerShownROIs(viewer).selected
    }

    /// Gives `mode` to the ROIs of `group` on the image shown; a ROI being
    /// modified leaves the others of its group selected.
    static func setMode(_ mode: Int, toGroup group: TimeInterval, in viewer: ViewerController) {
        guard group != ROIGroups.ungrouped else { return }
        let mode = ROISelection.groupMode(mode)
        for roi in ViewerShownROIs(viewer).rois where roi.groupID == group {
            roi.roImode = mode
        }
    }

    /// Selects `roi` and its group, brought to the front, after deselecting
    /// the other ROIs of the image when asked.
    static func select(_ roi: ROI?, deselectingOthers: Bool, in viewer: ViewerController) {
        if deselectingOthers { deselectAll(in: viewer) }
        guard let roi else { return }
        roi.roImode = ROI_selected
        viewer.setMode(ROI_selected, toROIGroupWithID: roi.groupID)
        viewer.bring(toFrontROI: roi)
    }

    static func deselectAll(in viewer: ViewerController) {
        for roi in ViewerShownROIs(viewer).rois {
            roi.roImode = ROI_sleep
        }
    }

    /// Applies `change` to the selected ROIs of the image shown, as one undo step.
    static func changeSelected(in viewer: ViewerController, _ change: (ROI) -> Void) {
        viewer.add(toUndoQueue: "roi")
        ViewerShownROIs(viewer).selected.forEach(change)
    }

    /// Puts the selected ROIs in a new group, or in none, as one undo step.
    static func setGrouped(_ grouped: Bool, in viewer: ViewerController) {
        let group = ROIGroups.groupID(grouping: grouped, now: Date.timeIntervalSinceReferenceDate)
        changeSelected(in: viewer) { $0.groupID = group }
    }

    static func makeAllSelectable(in viewer: ViewerController) {
        viewer.add(toUndoQueue: "roi")
        for roi in ViewerShownROIs(viewer).rois {
            roi.selectable = true
        }
    }

    /// Brings `roi` to the front of the image's list, with its group.
    static func bringToFront(_ roi: ROI?, in viewer: ViewerController) {
        let shown = ViewerShownROIs(viewer)
        guard let roi else { return raiseForNil(shown) }
        shown.replace(with: ROIGroups.broughtToFront(shown.rois, roi, group: { $0.groupID }, same: { $0 === $1 }))
    }

    /// Sends `roi` to the back of the image's list, with its group.
    static func sendToBack(_ roi: ROI?, in viewer: ViewerController) {
        let shown = ViewerShownROIs(viewer)
        guard let roi else { return raiseForNil(shown) }
        shown.replace(with: ROIGroups.sentToBack(shown.rois, roi, group: { $0.groupID }, same: { $0 === $1 }))
    }

    /// Inserting a nil ROI in the image's list raised.
    private static func raiseForNil(_ shown: ViewerShownROIs) {
        if shown.hasList { viewerRaiseNilInsertion() }
    }
}

// MARK: - Propagation

/// The copies of the selected ROIs to other images: across the series, the
/// thick slab or the time points.
@MainActor enum ViewerROIPropagation {

    /// Opens the Propagate sheet when the series has more than one image and
    /// a ROI is selected, as one undo step.
    static func beginSheet(in viewer: ViewerController) {
        guard viewerPixCount(viewer, Int(viewer.horos_curMovieIndex)) > 1 else {
            return viewerROIAlert("ROIs Propagate Error", "There is only one image in this series. Nothing to propagate!")
        }
        viewer.add(toUndoQueue: "roi")
        guard viewer.selectedROI() != nil else {
            return viewerROIAlert("ROIs Propagate Error", "No ROI(s) selected to propagate on the series!")
        }
        if viewer.horos_maxMovieIndex <= 1 { viewer.horos_roiPropaDim?.cell(withTag: 1)?.isEnabled = false }
        ViewerROIPanels.beginSheet(viewer.horos_roiPropaWindow, in: viewer)
    }

    /// Closes the sheet and, when it was accepted (`tag` 1), propagates the
    /// selected ROIs as it asks: across the series, to every image or up to
    /// an image number, or across the time points; copies or the ROIs themselves.
    static func endSheet(_ tag: Int, sender: Any?, in viewer: ViewerController) {
        viewer.horos_roiPropaWindow?.orderOut(sender)
        ViewerROIPanels.endSheet(viewer.horos_roiPropaWindow, tag)
        guard tag == 1 else { return }

        let movie = Int(viewer.horos_curMovieIndex)
        let shown = ViewerShownROIs(viewer)
        let copies = (viewer.horos_roiPropaCopy?.selectedCell()?.tag ?? 0) == 1
        switch viewer.horos_roiPropaDim?.selectedCell()?.tag ?? 0 {
        case 0:
            let count = viewerPixCount(viewer, movie)
            guard count > 1 else {
                return viewerROIAlert("ROIs Propagate Error", "There is only one image in this series. Nothing to propagate!")
            }
            let selected = shown.selected
            var range = 0..<count
            if (viewer.horos_roiPropaMode?.selectedCell()?.tag ?? 0) == 1 {
                // The image number typed in the panel, float converted to int as C did.
                let imageNumber = Int(cInt32(viewer.horos_roiPropaDest?.floatValue ?? 0))
                range = ROIPropagationPlan.imageRange(current: shown.index, imageNumber: imageNumber, count: count,
                                                      flipped: viewer.horos_imageView?.flippedData ?? false)
            }
            guard !selected.isEmpty else {
                return viewerROIAlert("ROIs Propagate Error", "No ROI(s) selected to propagate on the series!")
            }
            apply(.series(movie: movie, current: shown.index, range: range, copies: copies), selected, in: viewer)
        case 1: // 4D Dimension
            let selected = shown.selected
            guard !selected.isEmpty else {
                return viewerROIAlert("ROIs Propagate Error", "No ROI(s) selected to propagate on the series!")
            }
            apply(.timePoints(movie: movie, movieCount: Int(viewer.horos_maxMovieIndex), slice: shown.index, copies: copies),
                  selected, in: viewer)
        default:
            break
        }
    }

    /// Copies the selected ROIs to the other images of the thick slab shown,
    /// as one undo step.
    static func propagateThroughSlab(in viewer: ViewerController) {
        let movie = Int(viewer.horos_curMovieIndex)
        let shown = ViewerShownROIs(viewer)
        let stack = Int(viewerPix(viewer, movie, shown.index)?.stack ?? 0)
        guard stack >= 2 else {
            return viewerROIAlert("ROIs Propagate Error", "This function is only usefull if you use Thick Slab!")
        }
        let count = viewerPixCount(viewer, movie)
        guard count > 1 else {
            return viewerROIAlert("ROIs Propagate Error", "There is only one image in this series. Nothing to propagate!")
        }
        viewer.add(toUndoQueue: "roi")
        let selected = shown.selected
        let farEnd = ThickSlabRange.farEndIndex(currentIndex: shown.index, stack: stack, count: count,
                                                flippedData: viewer.horos_imageView?.flippedData ?? false)
        guard !selected.isEmpty else {
            return viewerROIAlert("ROIs Propagate Error", "No ROI(s) selected to propagate on the series!")
        }
        apply(.slab(movie: movie, current: shown.index, range: ROIPropagationPlan.slabRange(current: shown.index, farEnd: farEnd)),
              selected, in: viewer)
    }

    /// Adds `rois`, or copies of them, to the images of `plan`, and shows the
    /// image again.
    static func apply(_ plan: ROIPropagationPlan, _ rois: [ROI], in viewer: ViewerController) {
        for destination in plan.destinations {
            guard let list = ViewerROISlices(viewer, movie: destination.movie)?.list(at: destination.slice) else { continue }
            for roi in rois {
                guard plan.copies else {
                    list.add(roi)
                    continue
                }
                let copy = roi.copy() as? ROI
                if plan.unaliasesCopies { copy?.isAliased = false }
                viewerArrayAdd(copy, to: list)
            }
        }
        if let imageView = viewer.horos_imageView {
            imageView.setIndex(imageView.curImage)
        }
    }
}

// MARK: - Set pixels

/// One fill of the Set Pixels sheet: an image, inside or outside one of its
/// ROIs or whole. Run on another thread while the main thread waits; the
/// image and the ROI are only touched by the fills of that image.
struct ViewerROIPixelFill: @unchecked Sendable {
    let pix: DCMPix
    let roi: ROI?
    let job: ROISetPixelsJob
    /// The index of the image in its series.
    let slice: Int

    func run() {
        pix.fillROI(roi, newVal: job.newValue, minValue: job.minValue, maxValue: job.maxValue, outside: job.outside,
                    orientationStack: 2, stackNo: slice, restore: job.revert, addition: false)
    }

    /// Runs `fills` side by side and returns when they are all done.
    static func runSideBySide(_ fills: [ViewerROIPixelFill]) {
        DispatchQueue.concurrentPerform(iterations: fills.count) { fills[$0].run() }
    }

    /// Runs the operations side by side and returns when they are all done.
    static func runSideBySide(_ operations: [ViewerControllerOperation]) {
        DispatchQueue.concurrentPerform(iterations: operations.count) { operations[$0].start() }
    }
}

/// The Set Pixels sheet and its fills, and the ROIs measured again after them.
@MainActor enum ViewerROISetPixels {

    /// Fills the sheet from the series and the selection and opens it: the
    /// inside or outside choice is only offered with a ROI selected.
    static func beginSheet(in viewer: ViewerController) {
        let selectedRoi = viewer.selectedROI()

        let first = viewerPix(viewer, 0, 0)
        viewer.horos_maxValueText?.floatValue = first?.maxValueOfSeries ?? 0
        viewer.horos_minValueText?.floatValue = first?.minValueOfSeries ?? 0
        viewer.horos_newValueText?.floatValue = first?.minValueOfSeries ?? 0

        if selectedRoi == nil {
            viewer.horos_InOutROI?.isEnabled = false
            viewer.horos_InOutROI?.selectCell(withTag: 1)

            viewer.horos_AllROIsRadio?.cell(withTag: 1)?.isEnabled = false
            viewer.horos_AllROIsRadio?.cell(withTag: 0)?.isEnabled = false

            viewer.horos_AllROIsRadio?.selectCell(withTag: 2)
        } else {
            viewer.horos_InOutROI?.isEnabled = true

            viewer.horos_AllROIsRadio?.selectCell(withTag: 0)
            viewer.horos_AllROIsRadio?.cell(withTag: 1)?.isEnabled = true
            viewer.horos_AllROIsRadio?.cell(withTag: 0)?.isEnabled = true
        }

        viewer.horos_setROI4DSeries?.isEnabled = viewer.horos_maxMovieIndex != 1

        viewer.roiSetPixelsCheckButton(viewer)

        ViewerROIPanels.beginSheet(viewer.horos_roiSetPixWindow, in: viewer)
    }

    /// Offers "restore" only where the pixels read from disk can be put back:
    /// one time point, an unprocessed series, no value bounds, inside the
    /// ROIs and not every pixel.
    static func updateRestoreChoice(in viewer: ViewerController) {
        var restoreAvailable = true
        if (viewer.horos_setROI4DSeries?.state.rawValue ?? 0) != 0 && viewer.horos_maxMovieIndex > 1 { restoreAvailable = false }
        if viewer.horos_postprocessed { restoreAvailable = false }
        if (viewer.horos_checkMaxValue?.state.rawValue ?? 0) != 0 || (viewer.horos_checkMinValue?.state.rawValue ?? 0) != 0 {
            restoreAvailable = false
        }
        if (viewer.horos_InOutROI?.selectedCell()?.tag ?? 0) != 0 { restoreAvailable = false }
        if (viewer.horos_AllROIsRadio?.selectedCell()?.tag ?? 0) == 2 { restoreAvailable = false } // All pixels

        if restoreAvailable {
            viewer.horos_newValueMatrix?.cell(withTag: 1)?.isEnabled = true
        } else {
            viewer.horos_newValueMatrix?.cell(withTag: 1)?.isEnabled = false
            viewer.horos_newValueMatrix?.selectCell(withTag: 0)
        }
    }

    /// Closes the sheet and, when it was accepted (`tag` 1), sets the pixels
    /// it asks for, then the window level and every ROI are computed again.
    static func endSheet(_ tag: Int, sender: Any?, in viewer: ViewerController) {
        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            viewer.saveROI(movie)
        }

        viewer.horos_roiSetPixWindow?.orderOut(sender)
        ViewerROIPanels.endSheet(viewer.horos_roiSetPixWindow, tag)
        guard tag == 1 else { return }

        // The last selected ROI of the image shown.
        let selected = ViewerShownROIs(viewer).selected.last

        let outside = (viewer.horos_InOutROI?.selectedCell()?.tag ?? 0) != 0
        let allRois = Int16(truncatingIfNeeded: viewer.horos_AllROIsRadio?.selectedCell()?.tag ?? 0)

        var minValue: Float = -Float.greatestFiniteMagnitude
        var maxValue: Float = Float.greatestFiniteMagnitude
        if viewer.horos_checkMaxValue?.state == .on { maxValue = viewer.horos_maxValueText?.floatValue ?? 0 }
        if viewer.horos_checkMinValue?.state == .on { minValue = viewer.horos_minValueText?.floatValue ?? 0 }

        let propagateIn4D = viewer.horos_setROI4DSeries?.state == .on
        let newValue = viewer.horos_newValueText?.floatValue ?? 0
        let revertToSaved = (viewer.horos_newValueMatrix?.selectedTag() ?? 0) != 0

        viewer.roiSetPixels(selected, allRois, propagateIn4D, outside, minValue, maxValue, newValue, revertToSaved)

        // The window level again, then every ROI measured again.
        var level: Float = 0, width: Float = 0
        viewer.horos_imageView?.getWLWW(&level, &width)
        viewer.horos_imageView?.setWLWW(level, width)
        recomputeROIs(in: viewer, level: level, width: width)

        ViewerROIEdits.post(.OsirixUpdateVolumeData, viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex)))
    }

    /// Measures every ROI of every time point again and, with a window level,
    /// gives it to every image.
    static func recomputeROIs(in viewer: ViewerController, level: Float? = nil, width: Float = 0) {
        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            let slices = ViewerROISlices(viewer, movie: movie)
            for slice in 0..<viewerPixCount(viewer, movie) {
                for roi in slices?.rois(at: slice) ?? [] {
                    roi.recompute()
                }
                if let level { viewerPix(viewer, movie, slice)?.changeWLWW(level, width) }
            }
        }
    }

    /// Sets the pixels `job` asks for, inside or outside the ROIs named as
    /// `selected`, on the images of the current time point (and of every time
    /// point in 4D), side by side; with `revert`, the pixels read from disk.
    static func run(_ job: ROISetPixelsJob, selected: ROI?, in viewer: ViewerController) {
        viewer.checkEverythingLoaded()

        let splash = WaitRendering(NSLocalizedString("Filtering...", comment: ""))
        splash?.showWindow(viewer)

        NSLog("startSetPixel")

        let movie = Int(viewer.horos_curMovieIndex)
        let slices = ViewerROISlices(viewer, movie: movie)
        let roisBySlice = (0..<viewerPixCount(viewer, movie)).map { slices?.rois(at: $0) ?? [] }
        let fills = job.fills(movie: movie, movieCount: Int(viewer.horos_maxMovieIndex),
                              roiNames: roisBySlice.map { $0.map(\.name) }, selectedName: selected?.name)
        let work = fills.compactMap { fill -> ViewerROIPixelFill? in
            guard let pix = viewerPix(viewer, fill.movie, fill.slice) else { return nil }
            return ViewerROIPixelFill(pix: pix, roi: fill.roi.map { roisBySlice[fill.slice][$0] }, job: job, slice: fill.slice)
        }

        let first = viewerPix(viewer, movie, 0)
        var restoreReady = true
        if job.revert {
            restoreReady = first?.prepareRestore() ?? false
        }
        if restoreReady && !work.isEmpty {
            viewer.horos_roiLock?.lock()
            ViewerROIPixelFill.runSideBySide(work)
            viewer.horos_roiLock?.unlock()
        }
        if job.revert {
            first?.freeRestore()
        }

        splash?.close()

        if !restoreReady {
            NSLog("roiSetPixels: restore cache unavailable - pixels left unchanged")
            viewerROIAlert("Restore Content", "The original pixel data of this series could not be reloaded from disk. The images were left unchanged.")
        }

        NSLog("endSetPixel")
    }

    /// Runs the requests ({action, curPix, roi, …}) as ViewerControllerOperation
    /// reads them, side by side, under the ROI lock.
    static func run(requests: [NSDictionary], in viewer: ViewerController) {
        guard !requests.isEmpty else { return }
        let operations = requests.map { ViewerControllerOperation(controller: viewer, dict: $0) }
        viewer.horos_roiLock?.lock()
        ViewerROIPixelFill.runSideBySide(operations)
        viewer.horos_roiLock?.unlock()
    }
}

// MARK: - Finding and morphing

/// The ROIs of a viewer found by name or comment, and the ROIs made between two.
@MainActor enum ViewerROIQueries {

    /// The names of the ROIs of the current time point, each once, in the
    /// order they come; a ROI without a name raises, as adding its nil name did.
    static func names(in viewer: ViewerController) -> [String] {
        var names: [String] = []
        for roi in viewerSeriesROIs(viewer, movie: Int(viewer.horos_curMovieIndex)) {
            guard let name = roi.name else {
                viewerRaiseNilInsertion()
                continue
            }
            if !names.contains(where: { sameText($0, name) }) { names.append(name) }
        }
        return names
    }

    /// The ROIs of time point `movie` that `matching` accepts, each given the
    /// image it is on.
    static func rois(in viewer: ViewerController, movie: Int, matching: (ROI) -> Bool) -> [ROI] {
        let slices = ViewerROISlices(viewer, movie: movie)
        var found: [ROI] = []
        for slice in 0..<viewerPixCount(viewer, movie) {
            for roi in slices?.rois(at: slice) ?? [] where matching(roi) {
                roi.pix = viewerPix(viewer, movie, slice)
                found.append(roi)
            }
        }
        return found
    }

    /// `roi` as a polygon of `points` points: a polygon or a pencil resampled,
    /// a brush through its contour; nil for another kind of ROI.
    static func isoContour(_ roi: ROI?, points: Int32, in viewer: ViewerController) -> ROI? {
        var roi = roi
        switch roi?.type {
        case .tCPolygon?, .tOPolygon?, .tPencil?:
            break
        case .tPlain?:
            roi = viewer.convertBrushROItoPolygon(roi, numPoints: points)
        default:
            return nil
        }
        roi?.points = ROI.resamplePoints(roi?.splinePoints() as? [Any], number: points)
        return roi
    }

    /// The ROI between `a` and `b` at `ratio`: a length between two lengths,
    /// otherwise a polygon (a brush when `a` is one) between their contours.
    /// The inputs are copied before they are turned into polygons, and stay
    /// as they were.
    static func morphing(between a: ROI?, and b: ROI?, ratio: Float, in viewer: ViewerController) -> ROI? {
        if a?.type == .tMesure && b?.type == .tMesure {
            let measure = viewer.horos_unretainedNewROI(.tMesure)
            measure?.addPoint(ROI.pointBetweenPoint(a?.point(at: 0) ?? .zero, and: b?.point(at: 0) ?? .zero, ratio: ratio))
            measure?.addPoint(ROI.pointBetweenPoint(a?.point(at: 1) ?? .zero, and: b?.point(at: 1) ?? .zero, ratio: ratio))
            styled(measure, like: a)
            return measure
        }

        let input = a
        let first = polygon(a?.copy() as? ROI)
        let second = polygon(b?.copy() as? ROI)

        // MAX of two NSUInteger, stored in an int, and a third more.
        var maxPoints = Int32(truncatingIfNeeded: max(first?.points?.count ?? 0, second?.points?.count ?? 0))
        maxPoints += maxPoints / 3

        first?.isAliased = false
        second?.isAliased = false

        // A brush becomes a polygon through its contour; both get maxPoints points.
        guard let a = isoContour(first, points: maxPoints, in: viewer),
              let b = isoContour(second, points: maxPoints, in: viewer) else { return nil }

        let aPoints = a.points ?? []
        let bPoints = b.points ?? []
        if aPoints.count != Int(maxPoints) || bPoints.count != Int(maxPoints) {
            NSLog("***** NoOfPoints !")
            return nil
        }

        var made = viewer.horos_unretainedNewROI(a.type == .tOPolygon ? .tOPolygon : .tCPolygon)
        for index in 0..<aPoints.count {
            let point = ROI.pointBetweenPoint((aPoints[index] as? MyPoint)?.point ?? .zero, and: (bPoints[index] as? MyPoint)?.point ?? .zero,
                                              ratio: ratio)
            made?.points?.add(MyPoint.point(point))
        }

        if input?.type == .tPlain {
            made = viewer.convertPolygonROItoBrush(made)
        }
        styled(made, like: input)
        return made
    }

    /// `roi` as a polygon with the same points: a length gets a middle point
    /// and opens, a rectangle (no longer a spline) and an oval close.
    private static func polygon(_ roi: ROI?) -> ROI? {
        switch roi?.type {
        case .tMesure?:
            roi?.points?.insert(MyPoint.point(ROI.pointBetweenPoint(roi?.point(at: 0) ?? .zero, and: roi?.point(at: 1) ?? .zero, ratio: 0.5)), at: 1)
            roi?.type = .tOPolygon
        case .tROI?, .tOval?:
            let points = roi?.points
            if roi?.type == .tROI { roi?.isSpline = false }
            roi?.type = .tCPolygon
            roi?.points = points
        default:
            break
        }
        return roi
    }

    /// The colour, opacity, thickness and name of `model`.
    private static func styled(_ roi: ROI?, like model: ROI?) {
        roi?.rgbcolor = model?.rgbcolor ?? RGBColor()
        roi?.opacity = model?.opacity ?? 0
        roi?.thickness = model?.thickness ?? 0
        roi?.name = model?.name
    }
}

// MARK: - Panels and windows

/// The ROI sheets of the viewer and the ROI windows it opens.
@MainActor enum ViewerROIPanels {

    /// Opens `sheet` on the viewer's window.
    static func beginSheet(_ sheet: NSWindow?, in viewer: ViewerController) {
        guard let sheet, let window = viewer.window else { return }
        window.beginSheet(sheet, completionHandler: nil)
    }

    /// Ends `sheet` with `code`.
    static func endSheet(_ sheet: NSWindow?, _ code: Int) {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: code))
    }

    /// The ROIs a choice of the Rename or Apply panel covers.
    static func rois(_ scope: ROISelection.Scope, in viewer: ViewerController) -> [ROI] {
        switch scope {
        case .image:
            return ViewerShownROIs(viewer).rois
        case .series:
            return (0..<Int(viewer.horos_maxMovieIndex)).flatMap { viewerSeriesROIs(viewer, movie: $0) }
        case .selected:
            return ViewerShownROIs(viewer).selected
        case .sameNameAsSelected:
            guard let name = ViewerShownROIs(viewer).selected.first?.name else { return [] }
            return rois(.series, in: viewer).filter { sameText($0.name, name) }
        }
    }

    /// Computes the volume of the selected ROI's name (`tag` 0), or generates
    /// the ROIs missing between them (`tag` 1), after saving every time point.
    static func volume(_ tag: Int, in viewer: ViewerController) {
        _ = viewer.computeInterval()
        viewer.displayAWarningIfNonTrueVolumicData()

        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            viewer.saveROI(movie)
        }

        guard let selected = viewer.selectedROI() else {
            return viewerROIAlert("ROIs Volume Error", "Select a ROI to compute volume of all ROIs with the same name.")
        }

        // The slice locations must be available and evenly spaced.
        var preLocation: Float = 0, interval: Float = 0
        for case let pix as DCMPix in viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex)) ?? [] {
            if preLocation != 0 {
                // double - float - float, computed in double as C did.
                if interval != 0 && fabs(pix.sliceLocation - Double(preLocation) - Double(interval)) > 1.0 {
                    return viewerROIAlert("ROIs Volume Error", "Slice Interval is not constant!")
                }
                interval = Float(pix.sliceLocation - Double(preLocation))
            }
            preLocation = Float(pix.sliceLocation)
        }

        NSLog("Slice Interval : %f", Double(interval))

        if tag == 0 && interval == 0 { // Compute Volume
            return viewerROIAlert("ROIs Volume Error", "Slice Locations not available to compute a volume.")
        }

        viewer.add(toUndoQueue: "roi")

        let splash = WaitRendering(NSLocalizedString("Preparing data...", comment: ""))
        splash?.showWindow(viewer)

        if tag == 0 {
            if let controller = ROIVolumeController(roi: selected, viewer: viewer) {
                // Not released: the controller releases itself when its window closes.
                _ = Unmanaged.passRetained(controller)
                controller.showWindow(viewer)
                controller.window?.center()
            }
        } else if tag == 1 {
            _ = viewer.computeVolume(selected, points: nil, generateMissingROIs: true, generatedROIs: nil, computeData: nil, error: nil)
        }

        splash?.close()

        if tag == 1 {
            reportMissingROIs(named: selected.name, in: viewer)
        }
    }

    /// Says why Generate Missing ROIs generated nothing for the ROIs called
    /// `name`: the ROIs of one object drawn under several names, nothing
    /// missing, which is no error, or ROIs that outline no area.
    private static func reportMissingROIs(named name: String?, in viewer: ViewerController) {
        let movie = Int(viewer.horos_curMovieIndex)
        let slices = ViewerROISlices(viewer, movie: movie)
        var images: [Int] = []
        var generated = 0
        for image in 0..<viewerPixCount(viewer, movie) {
            for roi in slices?.rois(at: image) ?? [] where sameText(roi.name, name) && roi.isValidForVolume() {
                if sameText(roi.comments, "morphing generated") {
                    generated += 1
                } else {
                    images.append(image)
                }
            }
        }

        switch ROIMissingGeneration.outcome(sourceImages: images, generatedCount: generated) {
        case .generated:
            break
        case .singleImage:
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""),
                                        message: String(format: NSLocalizedString("Only one image has a ROI named “%@”, so there is nothing to generate in between. Generate Missing ROIs fills the images between ROIs of the same name: select the ROIs of the object in the ROI Manager and give them one name.", comment: "Generate Missing ROIs: the ROI name"), name ?? ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        case .nothingMissing:
            _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Generate Missing ROIs", comment: ""),
                                                 message: String(format: NSLocalizedString("Every image between the first and the last ROI named “%@” already has one. There is nothing to generate.", comment: "Generate Missing ROIs: the ROI name"), name ?? ""),
                                                 defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        case .notGenerated:
            viewerROIAlert("ROIs Volume Error", "The missing ROIs were not created : this feature does not work with ROIs that don't contain an area.")
        }
    }

    /// Closes the Rename sheet and, when it was accepted (`tag` 1), renames
    /// the ROIs of its choice, each announced.
    static func endRename(_ tag: Int, sender: Any?, in viewer: ViewerController) {
        viewer.horos_roiRenameWindow?.orderOut(sender)
        endSheet(viewer.horos_roiRenameWindow, tag)
        guard tag == 1, let scope = ROISelection.Scope(rawValue: viewer.horos_roiRenameMatrix?.selectedCell()?.tag ?? 0),
              scope != .sameNameAsSelected else { return }
        for roi in rois(scope, in: viewer) {
            roi.name = viewer.horos_roiRenameName?.stringValue
            ViewerROIEdits.post(.OsirixROIChange, roi)
        }
    }

    /// Runs the Apply panel, modal on the viewer, and answers the ROIs its
    /// choice covers when it is accepted; none otherwise.
    static func runApplyPanel(sender: Any?, in viewer: ViewerController) -> [ROI] {
        beginSheet(viewer.horos_roiApplyWindow, in: viewer)
        let result = viewer.horos_roiApplyWindow.map { NSApp.runModal(for: $0) }
        endSheet(viewer.horos_roiApplyWindow, 0)
        viewer.horos_roiApplyWindow?.orderOut(sender)

        guard result == .stop, let scope = ROISelection.Scope(rawValue: viewer.horos_roiApplyMatrix?.selectedCell()?.tag ?? 0) else {
            return []
        }
        return rois(scope, in: viewer)
    }

    /// Deletes the unlocked ROIs of every image and time point, each
    /// announced, as one undo step.
    static func deleteAllUnlocked(in viewer: ViewerController) {
        viewer.add(toUndoQueue: "roi")
        viewer.horos_imageView?.stopROIEditingForce(true)

        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            guard let slices = ViewerROISlices(viewer, movie: movie) else { continue }
            for index in 0..<slices.count {
                guard let list = slices.list(at: index) else { continue }
                for roi in slices.rois(at: index).reversed() where !roi.locked {
                    ViewerROIEdits.post(.OsirixRemoveROI, roi)
                    list.remove(roi)
                }
            }
        }

        if let imageView = viewer.horos_imageView {
            imageView.setIndex(imageView.curImage)
        }
    }

    /// Brings to the front the windows of nib `nib` whose controller is not
    /// closing and shows `roi` (any of them without one); whether there was one.
    private static func bringWindows(nib: String, showing roi: ROI?, in viewer: ViewerController) -> Bool {
        var found = false
        for window in NSApp.windows {
            let controller = window.windowController
            guard controller?.windowNibName == nib && !horosWindowControllerIsClosing(controller) else { continue }
            if let roi, ((controller as AnyObject?)?.curROI?() as AnyObject?) !== roi { continue }
            found = true
            controller?.window?.makeKeyAndOrderFront(viewer)
            if roi == nil { break }
        }
        return found
    }

    /// Shows the histogram of every selected ROI of the image shown, in its
    /// window if one is open.
    static func showHistograms(in viewer: ViewerController) {
        for roi in ViewerShownROIs(viewer).selected where !bringWindows(nib: "Histogram", showing: roi, in: viewer) {
            let window = HistoWindow(roi: roi)
            // Not released: the controller releases itself when its window closes.
            _ = Unmanaged.passRetained(window)
            window.showWindow(viewer)
        }
    }

    /// Shows the information of the first selected ROI of the image shown, in
    /// its window if one is open.
    static func showInfo(in viewer: ViewerController) {
        // NSUInteger <= short: the comparison C made, in unsigned long.
        let shown = ViewerShownROIs(viewer)
        if UInt(viewer.horos_roiList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0) <= UInt(bitPattern: shown.index) { return }
        guard let roi = shown.selected.first, !bringWindows(nib: "ROI", showing: roi, in: viewer) else { return }
        let window = ROIWindow(roi: roi, viewer)
        // Not released: the controller releases itself when its window closes.
        _ = Unmanaged.passRetained(window)
        window.showWindow(viewer)
    }

    /// Shows the ROI defaults window, the one open if there is one.
    static func showDefaults(in viewer: ViewerController) {
        guard !bringWindows(nib: "ROIDefaults", showing: nil, in: viewer) else { return }
        let window = ROIDefaultsWindow(controller: viewer)
        // Not released: the controller releases itself when its window closes.
        _ = Unmanaged.passRetained(window)
        window.showWindow(viewer)
    }
}

// MARK: - Tool palette

/// The ROI tool of the viewer's tool palette.
@MainActor enum ViewerROIToolPalette {

    /// Shows `tool` in the palette's last cell and selects that cell, without
    /// choosing the tool for a mouse button.
    static func show(_ tool: ToolMode, in viewer: ViewerController) {
        let cell = viewer.horos_toolsMatrix?.cell(atRow: 0, column: 5)
        cell?.tag = Int(tool.rawValue)
        // The image is computed before the message, as Objective-C evaluated
        // the argument even for a nil cell.
        let image = viewer.image(forROI: tool)
        cell?.image = image
        cell?.image?.size = ToolsMenuIconSize

        viewer.horos_toolsMatrix?.selectCell(atRow: 0, column: 5)
    }

    /// Shows `tool` in the palette and makes it the default tool.
    static func choose(_ tool: ToolMode, in viewer: ViewerController) {
        show(tool, in: viewer)
        viewer.setDefaultToolMenu(viewer.horos_toolsMatrix?.selectedCell())
    }

    /// The tool of `sender`'s tag: with the middle button chosen in the
    /// toolbar, it is that button's and the left button keeps its own; a menu
    /// item also makes it the default tool.
    static func choose(from sender: Any?, in viewer: ViewerController) {
        let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: ViewerSender.tag(sender)))!
        if viewer.middleButtonSelectedInToolbar {
            show(tool, in: viewer)
            viewer.setDefaultTool(sender)
            return
        }
        choose(tool, in: viewer)
        if sender is NSMenuItem {
            viewer.setDefaultTool(sender)
        }
    }
}
