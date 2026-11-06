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
import IsiXPreferences

// The enablement of the 2D viewer's menu items: whether each command applies
// to the viewer as it is, and the check mark, key equivalent and image the
// items of the tools, presets, tiling and sync menus show. What the
// validation decides for an item is a ViewerMenuItemState, a value applied to
// the item afterwards. The viewer stays the items' validator (the selector of
// the former Objective-C method) and hands each item here with itself. The
// disabled EXPORTTOOLBARITEM branch (every item enabled) is left out.

/// ToolsMenuIconSize, a macro of ViewerController.h that Swift does not import.
private let toolsMenuIconSize = NSMakeSize(28.0, 28.0)

/// [object boolValue]: NO for nil or an object that does not answer it.
private func objcBool(_ object: Any?) -> Bool {
    if let number = object as? NSNumber { return number.boolValue }
    if let string = object as? NSString { return string.boolValue }
    return false
}

/// [object intValue] of an NSNumber or an NSString: 0 for anything else.
private func objcInt(_ object: Any?) -> Int32 {
    if let number = object as? NSNumber { return number.int32Value }
    if let string = object as? NSString { return string.intValue }
    return 0
}

/// [a isEqualToString: b]: NO when either is nil; the characters compared one
/// by one, as NSString compares them.
private func objcEqual(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// What the validation decided for one item of the viewer's menus.
struct ViewerMenuItemState: Sendable, Equatable {
    /// Whether the command applies to the viewer.
    var isEnabled = false
    /// The item's check mark, the raw value of its state (on, off or mixed);
    /// nil leaves it as it is.
    var checkState: Int? = nil
    /// The item's key equivalent, without modifiers; nil leaves both as they are.
    var keyEquivalent: String? = nil
    /// The tool whose picture the item shows when it has none of its own.
    var toolImage: ToolMode? = nil

    init(isEnabled: Bool = false, isChecked: Bool? = nil) {
        self.isEnabled = isEnabled
        if let isChecked { self.isChecked = isChecked }
    }

    /// The check mark on or off.
    var isChecked: Bool {
        get { checkState == NSControl.StateValue.on.rawValue }
        set { checkState = (newValue ? NSControl.StateValue.on : .off).rawValue }
    }

    /// Gives `item` the check mark, key equivalent and picture decided.
    @MainActor func apply(to item: NSMenuItem, in viewer: ViewerController) {
        if let keyEquivalent {
            item.keyEquivalentModifierMask = []
            item.keyEquivalent = keyEquivalent
        }
        if let checkState { item.state = NSControl.StateValue(rawValue: checkState) }
        if let toolImage, item.image == nil {
            item.image = viewer.image(forROI: toolImage)
            item.image?.size = toolsMenuIconSize
        }
    }
}

@MainActor struct ViewerMenuValidation {

    private let graph: ViewerSessionGraph

    /// The menu validation of the viewer whose graph is `graph`.
    init(_ graph: ViewerSessionGraph) {
        self.graph = graph
    }

    /// Validates `item` for `viewer`: decides its state and gives it to the item.
    func validate(_ item: NSMenuItem, in viewer: ViewerController) -> Bool {
        let state = state(of: item, in: viewer)
        state.apply(to: item, in: viewer)
        return state.isEnabled
    }

    /// The ROIs of the image shown: [roiList[curMovieIndex] objectAtIndex: [imageView curImage]].
    private func roisOfCurrentImage(in viewer: ViewerController) -> [ROI] {
        let slices = viewer.horos_roiList(at: Int(viewer.horos_curMovieIndex))
        let image = Int(viewer.horos_imageView?.curImage ?? 0)
        return (slices?.object(at: image) as? [Any] ?? []).compactMap { $0 as? ROI }
    }

    /// Whether some slice of some movie frame has a ROI that `matches`.
    private func someROI(in viewer: ViewerController, _ matches: (ROI) -> Bool = { _ in true }) -> Bool {
        for y in 0..<max(Int(viewer.horos_maxMovieIndex), 0) {
            let rois = viewer.horos_roiList(at: y)
            for x in 0..<(viewer.horos_pixList(at: y)?.count ?? 0) {
                let slice = (rois?.object(at: x) as? [Any] ?? []).compactMap { $0 as? ROI }
                if slice.contains(where: matches) { return true }
            }
        }
        return false
    }

    /// The key that chooses `tool`, as the hot keys give it; "" when none does.
    private func hotKey(choosing tool: ToolMode) -> String {
        let hotKey = ViewerController.getHotKeyEquivalent(toTool: tool)
        guard hotKey >= 0, let hotKeys = DCMView.hotKeyDictionary() else { return "" }
        var found = ""
        // The last key of the dictionary that chooses it, as the menu always showed.
        for case let key as String in hotKeys.allKeys where objcInt(hotKeys.object(forKey: key)) == hotKey {
            found = key
        }
        return found
    }

    /// What `item` shows for `viewer`, and whether it is enabled.
    func state(of item: NSMenuItem, in viewer: ViewerController) -> ViewerMenuItemState {
        if viewer.horos_windowWillClose { return ViewerMenuItemState() }

        if !(viewer.horos_fileList(at: 0)?.lastObject is NSManagedObject) { return ViewerMenuItemState() }

        if item.action == #selector(ViewerController.togglePatientCrosshair(_:)) {
            return ViewerMenuItemState(isEnabled: viewer.horos_imageView?.curDCM != nil, isChecked: PatientCrosshairController.shared.isVisible)
        }
        if item.action == #selector(ViewerController.clearPatientCrosshair(_:)) {
            return ViewerMenuItemState(isEnabled: PatientCrosshairController.shared.currentPoint != nil)
        }

        let movieIndex = Int(viewer.horos_curMovieIndex)
        let maxMovieIndex = Int(viewer.horos_maxMovieIndex)
        let imageView = viewer.horos_imageView
        var state = ViewerMenuItemState()

        switch item.action {
        case #selector(ViewerController.seriesPopupSelect(_:)):
            viewer.buildSeriesPopup()
            state.isEnabled = true
        case #selector(ViewerController.displaySUV(_:)):
            state.isEnabled = imageView?.curDCM?.hasSUV ?? false
        case #selector(ViewerController.flipDataSeries(_:)):
            state.isEnabled = (viewer.horos_pixList(at: movieIndex)?.count ?? 0) > 1
        case #selector(ViewerController.navigator(_:)):
            state.isEnabled = (imageView?.curDCM?.isRGB ?? false) && viewer.isDataVolumicIn4D(true)
        case #selector(ViewerController.threeDPanel(_:)):
            state.isEnabled = viewer.isDataVolumicIn4D(true)
        case #selector(ViewerController.useVOILUT(_:)):
            state.isChecked = (imageView?.curDCM?.voilutApplied ?? false) || graph.preferences[ViewerPreferences.useVOILUT]
            state.isEnabled = imageView?.curDCM?.voilut_table != nil
        case #selector(ViewerController.resetWindowsState(_:)):
            state.isEnabled = (ViewerController.getDisplayedStudies() ?? []).contains { ($0 as? DicomStudy)?.windowsState != nil }
        case #selector(ViewerController.setAllKeyImages(_:)), #selector(ViewerController.setAllNonKeyImages(_:)):
            // Some image is not a key image yet, or some is one.
            let wanted = item.action == #selector(ViewerController.setAllNonKeyImages(_:))
            if !viewer.horos_postprocessed {
                for x in 0..<max(maxMovieIndex, 0) {
                    for o in viewer.horos_fileList(at: x) ?? [] where objcBool((o as? DicomImage)?.isKeyImage()) == wanted {
                        state.isEnabled = true
                        break
                    }
                }
            }
        case #selector(ViewerController.findNextPreviousKeyImage(_:)):
            if !viewer.horos_postprocessed {
                state.isEnabled = (imageView?.seriesObj()?.study?.keyImages()?.count ?? 0) != 0
            }
        case #selector(ViewerController.loadWindowsState(_:)):
            state.isEnabled = imageView?.studyObj()?.windowsState != nil
        case #selector(ViewerController.roiDeleteAllROIsWithSameName(_:)), #selector(ViewerController.roiGetInfo(_:)), #selector(ViewerController.roiHistogram(_:)),
             #selector(ViewerController.roiVolume(_:)), #selector(ViewerController.roiVolumeEraseRestore(_:)), #selector(ViewerController.makeSelectedROIsUnselectable(_:)),
             #selector(ViewerController.morphoSelectedBrushROI(_:)), #selector(ViewerController.convertBrushPolygon(_:)),
             #selector(ViewerController.roiPropagateSetup(_:)), #selector(ViewerController.roiPropagateSlab(_:)):
            state.isEnabled = viewer.selectedROI() != nil
        case #selector(ViewerController.blendWindows(_:)):
            state.isEnabled = ViewerController.numberOf2DViewer() > 1
        case #selector(ViewerController.createLayerROIFromSelectedROI(_:)):
            if let r = viewer.selectedROI() {
                state.isEnabled = ![ToolMode.tText, .tMesure, .t2DPoint, .tArrow].contains(r.type)
            }
        case #selector(ViewerController.generateGeometryFromSelectedLine(_:)):
            var line: ROI? = nil
            if let represented = item.representedObject as? ROI {
                line = represented
            } else {
                for case let roi as ROI in viewer.selectedROIs() ?? [] where roi.type == .tMesure && (roi.points?.count ?? 0) >= 2 {
                    line = roi
                    break
                }
            }
            state.isEnabled = line != nil && line?.locked == false
        case #selector(ViewerController.measureBetweenSelectedSlices(_:)):
            // The pair the measure would take, as the measure asks for it.
            var first: NSDictionary?, second: NSDictionary?
            state.isEnabled = viewer.horosPickInterslicePreferred(nil, first: &first, second: &second)
        case #selector(ViewerController.groupSelectedROIs(_:)):
            state.isEnabled = (viewer.selectedROIs()?.count ?? 0) > 1
        case #selector(ViewerController.ungroupSelectedROIs(_:)):
            state.isEnabled = roisOfCurrentImage(in: viewer).contains { $0.groupID != 0 }
        case #selector(ViewerController.lockSelectedROIs(_:)):
            state.isEnabled = roisOfCurrentImage(in: viewer).contains { !$0.locked }
        case #selector(ViewerController.unlockSelectedROIs(_:)):
            state.isEnabled = roisOfCurrentImage(in: viewer).contains { $0.locked }
        case #selector(ViewerController.makeAllROIsSelectable(_:)):
            state.isEnabled = roisOfCurrentImage(in: viewer).contains { !$0.selectable }
        case #selector(ViewerController.mergeBrushROI(_:)):
            // Every selected ROI a brush, in any order (ROIMenuEnablement).
            var types: [NSNumber] = []
            for case let i as ROI in viewer.selectedROIs() ?? [] { types.append(NSNumber(value: i.type.rawValue)) }
            state.isEnabled = ROIMenuEnablement.mayMergeBrushROIs(types: types)
        case #selector(ViewerController.showSelectedROIsOnAllImagesOfSeries(_:)):
            state.isEnabled = viewer.canShowSelectedROIsOnAllImagesOfSeries()
        case #selector(ViewerController.roiDeleteGeneratedROIs(_:)):
            state.isEnabled = someROI(in: viewer) { objcEqual($0.comments, "morphing generated") }
        case #selector(ViewerController.roiSaveSeries(_:)), #selector(ViewerController.roiSelectDeselectAll(_:)), #selector(ViewerController.roiDeleteAll(_:)),
             #selector(ViewerController.roiRename(_:)), #selector(ViewerController.setROIsImagesKeyImages(_:)):
            state.isEnabled = someROI(in: viewer)
        case #selector(ViewerController.applyConvolutionOnSource(_:)):
            state.isEnabled = !objcEqual(viewer.horos_curConvMenu, NSLocalizedString("No Filter", comment: ""))
        case #selector(ViewerController.convertToBWMenu(_:)):
            state.isEnabled = (viewer.horos_pixList(at: movieIndex)?.object(at: 0) as? DCMPix)?.isRGB == true
        case #selector(ViewerController.convertToRGBMenu(_:)):
            state.isEnabled = !((viewer.horos_pixList(at: movieIndex)?.object(at: 0) as? DCMPix)?.isRGB ?? false)
        case #selector(ViewerController.setImageTiling(_:)):
            state.isEnabled = true
            state.isChecked = item.tag == ViewerImageTiling.tag(rows: imageView?.rows ?? 0, columns: imageView?.columns ?? 0)
        case #selector(ViewerController.syncSeries(_:)):
            state.isEnabled = true
            state.isChecked = ViewerController.horos_SYNCSERIES()
        case #selector(ViewerController.setKeyImage(_:)):
            state.isEnabled = true
            state.checkState = (viewer.keyImageCheck?.state ?? .off).rawValue
        case #selector(ViewerController.setROITool(_:)), #selector(ViewerController.setDefaultTool(_:)), #selector(ViewerController.setDefaultToolMenu(_:)):
            state.isEnabled = true
            let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: item.tag))!
            state.keyEquivalent = hotKey(choosing: tool)
            state.isChecked = item.tag == Int(imageView?.currentTool.rawValue ?? 0)
            state.toolImage = tool
        case #selector(ViewerController.applyCLUT(_:)):
            state.isEnabled = true
            state.isChecked = objcEqual(item.title, viewer.horos_curCLUTMenu)
        case #selector(ViewerController.applyConv(_:)):
            state.isEnabled = true
            state.isChecked = objcEqual(item.title, viewer.horos_curConvMenu)
        case #selector(ViewerController.applyOpacity(_:)):
            state.isEnabled = true
            state.isChecked = objcEqual(item.title, viewer.horos_curOpacityMenu)
        case #selector(ViewerController.applyWLWW(_:)):
            state.isEnabled = true
            state.isChecked = ViewerPresetMenus.checksWLWWItem(title: item.title, current: viewer.horos_curWLWWMenu)
        case #selector(ViewerController.increaseFontSize(_:)), #selector(ViewerController.decreaseFontSize(_:)):
            state.isEnabled = DCMView.labelFontSizeMenuItemIsEnabled(item)
        default:
            state.isEnabled = true
        }

        return state
    }
}
