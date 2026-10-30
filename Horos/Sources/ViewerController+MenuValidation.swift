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

// The enablement of the 2D viewer's menu items: whether each command applies
// to the viewer as it is, and the check mark, key equivalent and image the
// items of the tools, presets, tiling and sync menus show. The selector is
// that of the former Objective-C method; the class declares
// NSMenuItemValidation here (ViewerController.h leaves it out for Swift, which
// would otherwise refuse this implementation). A message to nil answered nil,
// 0 or NO: the optional chains below answer the same. The disabled
// EXPORTTOOLBARITEM branch (every item enabled) is left out.

/// ToolsMenuIconSize, a macro of ViewerController.h that Swift does not import.
private let toolsMenuIconSize = NSMakeSize(28.0, 28.0)

extension ViewerController: NSMenuItemValidation {}

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

public extension ViewerController {

    /// The ROIs of the image shown: [roiList[curMovieIndex] objectAtIndex: [imageView curImage]].
    private func horosROIsOfCurrentImage() -> [ROI] {
        let slices = horos_roiList(at: Int(horos_curMovieIndex))
        let image = Int(horos_imageView?.curImage ?? 0)
        return ((slices?.object(at: image)) as? NSArray)?.compactMap { $0 as? ROI } ?? []
    }

    @objc(validateMenuItem:)
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        var valid = false

        if horos_windowWillClose { return false }

        if !(horos_fileList(at: 0)?.lastObject is NSManagedObject) { return false }

        if item.action == Selector(("togglePatientCrosshair:")) {
            item.state = PatientCrosshairController.shared.isVisible ? .on : .off
            return horos_imageView?.curDCM != nil
        }
        if item.action == Selector(("clearPatientCrosshair:")) {
            return PatientCrosshairController.shared.currentPoint != nil
        }

        let movieIndex = Int(horos_curMovieIndex)
        let maxMovieIndex = Int(horos_maxMovieIndex)

        switch item.action {
        case Selector(("seriesPopupSelect:")):
            buildSeriesPopup()
            valid = true
        case Selector(("displaySUV:")):
            if horos_imageView?.curDCM?.hasSUV ?? false { valid = true }
        case Selector(("flipDataSeries:")):
            if (horos_pixList(at: movieIndex)?.count ?? 0) > 1 { valid = true }
        case #selector(ViewerController.navigator(_:)):
            if (horos_imageView?.curDCM?.isRGB ?? false) && isDataVolumicIn4D(true) { valid = true }
        case #selector(ViewerController.threeDPanel(_:)):
            if isDataVolumicIn4D(true) { valid = true }
        case #selector(ViewerController.useVOILUT(_:)):
            if horos_imageView?.curDCM?.voilutApplied ?? false {
                item.state = .on
            } else {
                item.state = UserDefaults.standard.bool(forKey: "UseVOILUT") ? .on : .off
            }
            if horos_imageView?.curDCM?.voilut_table != nil { valid = true }
        case Selector(("resetWindowsState:")):
            for loopItem in ViewerController.getDisplayedStudies() ?? [] {
                if (loopItem as AnyObject).value(forKey: "windowsState") != nil { valid = true }
            }
        case Selector(("setAllKeyImages:")), Selector(("setAllNonKeyImages:")):
            // Some image is not a key image yet, or some is one.
            let wanted = item.action == Selector(("setAllNonKeyImages:"))
            if !horos_postprocessed {
                for x in 0..<max(maxMovieIndex, 0) {
                    for o in horos_fileList(at: x) ?? [] where objcBool((o as AnyObject).value(forKey: "isKeyImage")) == wanted {
                        valid = true
                        break
                    }
                }
            }
        case Selector(("findNextPreviousKeyImage:")):
            if !horos_postprocessed {
                let s = horos_imageView?.seriesObj()?.value(forKey: "study") as? DicomStudy
                if (s?.keyImages()?.count ?? 0) != 0 { valid = true }
            }
        case Selector(("loadWindowsState:")):
            if horos_imageView?.studyObj()?.value(forKey: "windowsState") != nil { valid = true }
        case Selector(("roiDeleteAllROIsWithSameName:")), Selector(("roiGetInfo:")), Selector(("roiHistogram:")),
             Selector(("roiVolume:")), Selector(("roiVolumeEraseRestore:")), Selector(("makeSelectedROIsUnselectable:")),
             #selector(ViewerController.morphoSelectedBrushROI(_:)), Selector(("convertBrushPolygon:")), Selector(("roiPropagateSetup:")),
             Selector(("roiPropagateSlab:")):
            if selectedROI() != nil { valid = true }
        case Selector(("blendWindows:")):
            if ViewerController.numberOf2DViewer() > 1 { valid = true }
        case Selector(("createLayerROIFromSelectedROI:")):
            if let r = selectedROI() {
                valid = ![ToolMode.tText, .tMesure, .t2DPoint, .tArrow].contains(r.type)
            }
        case #selector(ViewerController.generateGeometryFromSelectedLine(_:)):
            var line: ROI? = nil
            if let represented = item.representedObject as? ROI {
                line = represented
            } else {
                for case let roi as ROI in selectedROIs() ?? [] where roi.type == .tMesure && (roi.points?.count ?? 0) >= 2 {
                    line = roi
                    break
                }
            }
            valid = line != nil && line?.locked == false
        case #selector(ViewerController.measureBetweenSelectedSlices(_:)):
            var first: NSDictionary? = nil
            var second: NSDictionary? = nil
            valid = horosPickInterslicePreferred(nil, first: &first, second: &second)
        case Selector(("groupSelectedROIs:")):
            if (selectedROIs()?.count ?? 0) > 1 { valid = true }
        case Selector(("ungroupSelectedROIs:")):
            valid = horosROIsOfCurrentImage().contains { $0.groupID != 0 }
        case Selector(("lockSelectedROIs:")):
            valid = horosROIsOfCurrentImage().contains { !$0.locked }
        case Selector(("unlockSelectedROIs:")):
            valid = horosROIsOfCurrentImage().contains { $0.locked }
        case Selector(("makeAllROIsSelectable:")):
            valid = horosROIsOfCurrentImage().contains { !$0.selectable }
        case #selector(ViewerController.mergeBrushROI(_:)):
            // Every selected ROI a brush, in any order (ROIMenuEnablement).
            var types: [NSNumber] = []
            for case let i as ROI in selectedROIs() ?? [] { types.append(NSNumber(value: i.type.rawValue)) }
            valid = ROIMenuEnablement.mayMergeBrushROIs(types: types)
        case Selector(("showSelectedROIsOnAllImagesOfSeries:")):
            valid = canShowSelectedROIsOnAllImagesOfSeries()
        case Selector(("roiDeleteGeneratedROIs:")):
            for y in 0..<max(maxMovieIndex, 0) {
                let rois = horos_roiList(at: y)
                for x in 0..<(horos_pixList(at: y)?.count ?? 0) {
                    let slice = rois?.object(at: x) as? NSArray
                    for i in 0..<(slice?.count ?? 0) where objcEqual((slice?.object(at: i) as? ROI)?.comments, "morphing generated") {
                        valid = true
                        break
                    }
                }
            }
        case Selector(("roiSaveSeries:")), Selector(("roiSelectDeselectAll:")), #selector(ViewerController.roiDeleteAll(_:)),
             Selector(("roiRename:")), Selector(("setROIsImagesKeyImages:")):
            for y in 0..<max(maxMovieIndex, 0) {
                let rois = horos_roiList(at: y)
                for x in 0..<(horos_pixList(at: y)?.count ?? 0) where ((rois?.object(at: x) as? NSArray)?.count ?? 0) > 0 {
                    valid = true
                }
            }
        case Selector(("applyConvolutionOnSource:")):
            if !objcEqual(horos_curConvMenu, NSLocalizedString("No Filter", comment: "")) { valid = true }
        case Selector(("ConvertToBWMenu:")):
            if (horos_pixList(at: movieIndex)?.object(at: 0) as? DCMPix)?.isRGB == true { valid = true }
        case Selector(("ConvertToRGBMenu:")):
            if !((horos_pixList(at: movieIndex)?.object(at: 0) as? DCMPix)?.isRGB ?? false) { valid = true }
        case #selector(ViewerController.setImageTiling(_:)):
            valid = true
            let tag = ViewerImageTiling.tag(rows: horos_imageView?.rows ?? 0, columns: horos_imageView?.columns ?? 0)
            item.state = item.tag == tag ? .on : .off
        case Selector(("SyncSeries:")):
            valid = true
            item.state = ViewerController.horos_SYNCSERIES() ? .on : .off
        case Selector(("setKeyImage:")):
            valid = true
            item.state = keyImageCheck?.state ?? .off
        case Selector(("setROITool:")), #selector(ViewerController.setDefaultTool(_:)), Selector(("setDefaultToolMenu:")):
            valid = true

            let tool = ToolMode(rawValue: Int16(truncatingIfNeeded: item.tag))!
            let hotKeys: NSDictionary? = DCMView.hotKeyDictionary()
            item.keyEquivalentModifierMask = []
            item.keyEquivalent = ""

            for k in hotKeys?.allKeys ?? [] {
                let hotKey = ViewerController.getHotKeyEquivalent(toTool: tool)
                if hotKey >= 0, let key = k as? String,
                   objcInt((DCMView.hotKeyDictionary() as NSDictionary?)?.object(forKey: key)) == hotKey {
                    item.keyEquivalentModifierMask = []
                    item.keyEquivalent = key
                }
            }

            item.state = item.tag == Int(horos_imageView?.currentTool.rawValue ?? 0) ? .on : .off

            if item.image == nil {
                item.image = image(forROI: tool)
                item.image?.size = toolsMenuIconSize
            }
        case #selector(ViewerController.applyCLUT(_:)):
            valid = true
            item.state = objcEqual(item.title, horos_curCLUTMenu) ? .on : .off
        case Selector(("ApplyConv:")):
            valid = true
            item.state = objcEqual(item.title, horos_curConvMenu) ? .on : .off
        case #selector(ViewerController.applyOpacity(_:)):
            valid = true
            item.state = objcEqual(item.title, horos_curOpacityMenu) ? .on : .off
        case #selector(ViewerController.applyWLWW(_:)):
            valid = true
            item.state = ViewerPresetMenus.checksWLWWItem(title: item.title, current: horos_curWLWWMenu) ? .on : .off
        case #selector(ViewerController.increaseFontSize(_:)), #selector(ViewerController.decreaseFontSize(_:)):
            valid = DCMView.labelFontSizeMenuItemIsEnabled(item)
        default:
            valid = true
        }

        return valid
    }
}
