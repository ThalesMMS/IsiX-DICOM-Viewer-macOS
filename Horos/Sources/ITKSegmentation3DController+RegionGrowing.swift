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

import Cocoa
import IsiXSegmentation

// The preview and the computation of the region growing window, through
// ITKSegmentation3D: from the seed, with the chosen algorithm and parameters,
// on the current image or the whole volume, in every time point when the
// growing propagates in 4D. A preview grows the "Segmentation Preview" ROI,
// unless a click grows the named ROI directly; a computation grows the named
// ROI, in the viewer or in a copy of it.
extension ITKSegmentation3DController {

    /// The name of the ROI a preview grows.
    static var previewName: String { NSLocalizedString("Segmentation Preview", comment: "") }

    /// The values of the parameter fields, as text.
    private var parameterTexts: [String] {
        guard let params else { return [] }
        return (0 ..< params.numberOfRows).compactMap { params.cell(atRow: $0, column: 0)?.stringValue }
    }

    /// The parameters of `algorithm`, read from its fields as floats.
    private func parametersArray(_ algorithm: RegionGrowingAlgorithm) -> NSMutableArray {
        let parametersArray = NSMutableArray(capacity: algorithm.parameterCount)
        for i in 0 ..< algorithm.parameterCount {
            parametersArray.add(NSNumber(value: params?.cell(atRow: i, column: 0)?.floatValue ?? 0))
        }
        return parametersArray
    }

    /// The ROI type the preference names, as the filter takes it.
    private var growingRegionROIType: ToolMode {
        let raw = UserDefaults.standard.integer(forKey: "growingRegionROIType")
        return ToolMode(rawValue: ToolMode.RawValue(truncatingIfNeeded: raw))!
    }

    /// The resolution of the slider, as the filter takes it.
    private var growingResolution: Int {
        RegionGrowingRules.roiResolution(sliderMaxValue: roiResolution?.maxValue ?? 0, sliderValue: roiResolution?.intValue ?? 0)
    }

    /// Grows the preview from the seed, when previews are on or a click grows
    /// the ROI directly.
    @IBAction @objc(preview:)
    func preview(_ sender: Any!) {
        let defaults = UserDefaults.standard
        defaults.set(RegionGrowingRules.roundedInterval(defaults.float(forKey: "growingRegionInterval")), forKey: "growingRegionInterval")

        guard let viewer = viewerController else { return }

        let name = RegionGrowingRules.previewROIName(fromViewerClick: (sender as AnyObject?) === viewer,
                                                     growingModeTag: growingMode?.selectedCell()?.tag ?? 0,
                                                     directlyGenerate: defaults.bool(forKey: "segmentationDirectlyGenerate"),
                                                     typedName: newNameField?.stringValue ?? "", previewName: Self.previewName)

        viewer.roiDelete(withName: Self.previewName)

        if !RegionGrowingRules.previews(previewGrowingRegion: defaults.bool(forKey: "previewGrowingRegion"),
                                        directlyGenerate: defaults.bool(forKey: "segmentationDirectlyGenerate")) { return }

        if !RegionGrowingRules.parametersProvided(parameterTexts) {
            return
        }

        if seed.x == 0 && seed.y == 0 {
            return
        }

        let previousMovieIndex = viewer.curMovieIndex()

        let slice = RegionGrowingRules.previewSlice(preview3D: defaults.bool(forKey: "preview3DGrowingRegion"),
                                                    currentImage: Int(viewer.imageView()?.curImage ?? 0))

        for i in 0 ..< Int32(viewer.maxMovieIndex()) {
            if defaults.bool(forKey: "growingRegionPropagateIn4D") {
                viewer.setMovieIndex(Int16(truncatingIfNeeded: i))
            }

            if i == Int32(viewer.curMovieIndex()), let itk = ITKSegmentation3D(viewer.pixList(), viewer.volumePtr(), slice) {
                // an array for the parameters
                let algorithm = selectedAlgorithm

                itk.regionGrowing3D(viewer,
                                    nil,
                                    slice,
                                    seed,
                                    Int32(algorithm.rawValue),
                                    parametersArray(algorithm) as? [Any],
                                    pixelsSet?.cell(withTag: 0)?.state == .on,
                                    pixelsValue?.cell(withTag: 0)?.floatValue ?? 0,
                                    pixelsSet?.cell(withTag: 1)?.state == .on,
                                    pixelsValue?.cell(withTag: 1)?.floatValue ?? 0,
                                    growingRegionROIType,
                                    growingResolution,
                                    name,
                                    // previews never merge existing ROIs
                                    RegionGrowingRules.mergesExistingROIs(name: name, previewName: Self.previewName,
                                                                          preference: defaults.bool(forKey: "mergeWithExistingROIs")))
            }
        }

        if defaults.bool(forKey: "growingRegionPropagateIn4D") {
            viewer.setMovieIndex(previousMovieIndex)
        }
    }

    /// Grows the named ROI from the seed, in the viewer or in a copy of it
    /// filled with the outside value, for undo in the viewer.
    @IBAction @objc(compute:)
    func compute(_ sender: Any!) {
        if !RegionGrowingRules.parametersProvided(parameterTexts) {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Segmentation Error", comment: ""),
                                            message: NSLocalizedString("Please provide a value for each parameter.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        if seed.x == 0 && seed.y == 0 {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Segmentation Error", comment: ""),
                                            message: NSLocalizedString("Select a starting point by clicking in the image.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        guard let viewer = viewerController else { return }
        let defaults = UserDefaults.standard

        viewer.roiDelete(withName: Self.previewName)

        viewer.add(toUndoQueue: "roi")

        let previousMovieIndex = viewer.curMovieIndex()

        let slice = RegionGrowingRules.computeSlice(growingModeTag: growingMode?.selectedCell()?.tag ?? 0,
                                                    currentImage: Int(viewer.imageView()?.curImage ?? 0))

        for i in 0 ..< Int32(viewer.maxMovieIndex()) {
            if defaults.bool(forKey: "growingRegionPropagateIn4D") {
                viewer.setMovieIndex(Int16(truncatingIfNeeded: i))
            }

            if i == Int32(viewer.curMovieIndex()), let itk = ITKSegmentation3D(viewer.pixList(), viewer.volumePtr(), slice) {
                var v: ViewerController?

                if outputResult?.selectedCell()?.tag == 1 {
                    if resultsViewer == nil {
                        let currentImageIndex = Int(viewer.imageView()?.curImage ?? 0)
                        resultsViewer = duplicateCurrent2DViewerWindow()
                        viewer.imageView()?.setIndex(currentImageIndex)

                        if pixelsSet?.cell(withTag: 1)?.state == .on, let resultsViewer { // FILL THE IMAGE WITH THE VALUE
                            let value = pixelsValue?.cell(withTag: 1)?.floatValue ?? 0
                            for case let curPix as DCMPix in resultsViewer.pixList() ?? NSMutableArray() {
                                curPix.fImage?.update(repeating: value, count: curPix.pwidth * curPix.pheight)
                            }
                        }
                    }

                    v = resultsViewer
                }

                // an array for the parameters
                let algorithm = selectedAlgorithm

                itk.regionGrowing3D(viewer,
                                    v,
                                    slice,
                                    seed,
                                    Int32(algorithm.rawValue),
                                    parametersArray(algorithm) as? [Any],
                                    pixelsSet?.cell(withTag: 0)?.state == .on,
                                    pixelsValue?.cell(withTag: 0)?.floatValue ?? 0,
                                    pixelsSet?.cell(withTag: 1)?.state == .on,
                                    pixelsValue?.cell(withTag: 1)?.floatValue ?? 0,
                                    growingRegionROIType,
                                    growingResolution,
                                    newNameField?.stringValue ?? "",
                                    defaults.bool(forKey: "mergeWithExistingROIs"))

                if let v {
                    var wl: Float = 0, ww: Float = 0

                    v.needsDisplayUpdate()
                    viewer.imageView()?.getWLWW(&wl, &ww)
                    v.imageView()?.setWLWW(wl, ww)
                }
            }
        }

        if defaults.bool(forKey: "growingRegionPropagateIn4D") {
            viewer.setMovieIndex(previousMovieIndex)
        }

        viewer.window?.makeKeyAndOrderFront(self) // For easier undo/redo on ViewerController
    }

    /// A new viewer of a copy of the series, the window of the results. It is
    /// -copyViewerWindow's viewer, taken through the method's body: the copy
    /// family's name would make Swift release a viewer that keeps itself.
    @objc(duplicateCurrent2DViewerWindow)
    func duplicateCurrent2DViewerWindow() -> ViewerController? {
        return viewerController?.horosDuplicatedViewerWindow()
    }
}
