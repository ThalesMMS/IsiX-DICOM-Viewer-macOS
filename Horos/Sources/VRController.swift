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

/// Window Controller for VR and MIP: the volume rendering window, its
/// toolbar, its panels (shading, 16-bit CLUT editor, 3D presets) and the 3D
/// points and ROI volumes it shows of its 2D viewer.
///
/// Implemented in Swift, split by responsibility over the files
/// VRController*.swift; the Objective-C name, the selectors, the outlets and
/// the bindings are those of the former class, the File's Owner of VR.xib.
/// The view, VRView, stays Objective-C++ over VTK.
///
/// A controller made by -initWithPix:::::style:mode: is handed over to its
/// window: -windowWillClose: autoreleases it, as the former class did.
@objc(VRController)
public class VRController: Window3DController, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation,
                           NSControlTextEditingDelegate {

    // MARK: - Outlets

    /// The `view` outlet: VRView. Its getter is -view, Window3DController's.
    final var vrView: VRView?
    @IBOutlet final var toolsView: NSView?
    @IBOutlet final var WLWWView: NSView?
    @IBOutlet final var CLUTEditorsView: NSView?
    @IBOutlet final var LODView: NSView?
    @IBOutlet final var ClippingRangeView: NSView?
    @IBOutlet final var BlendingView: NSView?
    @IBOutlet final var movieView: NSView?
    @IBOutlet final var shadingView: NSView?
    @IBOutlet final var perspectiveView: NSView?
    @IBOutlet final var modeView: NSView?
    @IBOutlet final var scissorStateView: NSView?
    @IBOutlet final var OrientationsView: NSView?
    @IBOutlet final var BackgroundColorView: NSView?
    @IBOutlet final var modeMatrix: NSMatrix?
    /// The `toolsMatrix` outlet; its getter is -toolsMatrix.
    final var toolsMatrixOutlet: NSMatrix?
    @IBOutlet final var shadingEditWindow: NSWindow?
    @IBOutlet final var growingRegionWindow: NSWindow?
    @IBOutlet final var shadingCheck: NSButton?
    @IBOutlet final var shadingValues: NSTextField?
    @IBOutlet final var convolutionView: NSView?
    @IBOutlet final var convolutionMenu: NSPopUpButton?
    @IBOutlet final var blendingPercentage: NSTextField?
    @IBOutlet final var blendingSlider: NSSlider?
    @IBOutlet final var movieTextSlide: NSTextField?
    @IBOutlet final var moviePlayStop: NSButton?
    @IBOutlet final var movieRateSlider: NSSlider?
    @IBOutlet final var moviePosSlider: NSSlider?
    /// The `clutOpacityDrawer` outlet; its getter is -clutOpacityDrawer.
    final var clutOpacityDrawerOutlet: HorosCLUTPanel?
    @IBOutlet final var clutOpacityView: CLUTOpacityView?
    @IBOutlet final var shadingPanel: NSPanel?
    @IBOutlet final var shadingsPresetsController: ShadingArrayController?
    @IBOutlet final var save3DSettingsWindow: NSWindow?
    @IBOutlet final var settingsCLUTTextField: NSTextField?
    @IBOutlet final var settingsOpacityTextField: NSTextField?
    @IBOutlet final var settingsShadingsTextField: NSTextField?
    @IBOutlet final var settingsWLWWTextField: NSTextField?
    @IBOutlet final var settingsConvolutionFilterTextField: NSTextField?
    @IBOutlet final var settingsProjectionTextField: NSTextField?
    @IBOutlet final var settingsBackgroundColorTextField: NSTextField?
    @IBOutlet final var settingsNameTextField: NSTextField?
    @IBOutlet final var settingsNewGroupNameTextField: NSTextField?
    @IBOutlet final var settingsNewGroupNameLabelTextField: NSTextField?
    @IBOutlet final var settingsGroupPopUpButton: NSPopUpButton?
    @IBOutlet final var settingsSaveButton: NSButton?
    @IBOutlet final var presetsPanel: NSWindow?
    @IBOutlet final var presetsGroupPopUpButton: NSPopUpButton?
    @IBOutlet final var presetsApplyButton: NSButton?
    @IBOutlet final var presetPreview1: VRPresetPreview?
    @IBOutlet final var presetPreview2: VRPresetPreview?
    @IBOutlet final var presetPreview3: VRPresetPreview?
    @IBOutlet final var presetPreview4: VRPresetPreview?
    @IBOutlet final var presetPreview5: VRPresetPreview?
    @IBOutlet final var presetPreview6: VRPresetPreview?
    @IBOutlet final var presetPreview7: VRPresetPreview?
    @IBOutlet final var presetPreview8: VRPresetPreview?
    @IBOutlet final var presetPreview9: VRPresetPreview?
    @IBOutlet final var presetName1: NSTextField?
    @IBOutlet final var presetName2: NSTextField?
    @IBOutlet final var presetName3: NSTextField?
    @IBOutlet final var presetName4: NSTextField?
    @IBOutlet final var presetName5: NSTextField?
    @IBOutlet final var presetName6: NSTextField?
    @IBOutlet final var presetName7: NSTextField?
    @IBOutlet final var presetName8: NSTextField?
    @IBOutlet final var presetName9: NSTextField?
    @IBOutlet final var nextPresetPageButton: NSButton?
    @IBOutlet final var previousPresetPageButton: NSButton?
    @IBOutlet final var numberOfPresetInGroupTextField: NSTextField?
    @IBOutlet final var presetsInfoPanel: NSWindow?
    @IBOutlet final var infoNameTextField: NSTextField?
    @IBOutlet final var infoCLUTTextField: NSTextField?
    @IBOutlet final var infoOpacityTextField: NSTextField?
    @IBOutlet final var infoShadingsTextField: NSTextField?
    @IBOutlet final var infoWLWWTextField: NSTextField?
    @IBOutlet final var infoConvolutionFilterTextField: NSTextField?
    @IBOutlet final var infoProjectionTextField: NSTextField?
    @IBOutlet final var infoBackgroundColorTextField: NSTextField?
    @IBOutlet final var infoBackgroundColorView: ColorView?
    @IBOutlet final var editDeleteValue: NSWindow?
    // The Stereo menu and its screen geometry.
    @IBOutlet final var stereoIconView: NSView?
    @IBOutlet final var VRGeometrieSettingsWindow: NSWindow?
    @IBOutlet final var distanceValue: NSTextField?
    @IBOutlet final var heightValue: NSTextField?
    @IBOutlet final var eyeDistance: NSTextField?

    @objc(setView:)
    final func setVRViewOutlet(_ view: VRView?) { vrView = view }
    @objc(setToolsMatrix:)
    final func setToolsMatrixOutlet(_ matrix: NSMatrix?) { toolsMatrixOutlet = matrix }
    @objc(setClutOpacityDrawer:)
    final func setClutOpacityDrawerOutlet(_ panel: HorosCLUTPanel?) { clutOpacityDrawerOutlet = panel }

    // MARK: - State

    // Read by the scissors' operations on their own threads, as the former
    // instance variables were: unsafe, set on the main thread before them.
    nonisolated(unsafe) final var styleName: String?
    nonisolated(unsafe) final var pixLists = [NSMutableArray?](repeating: nil, count: Int(MAX4D))
    nonisolated(unsafe) final var fileListStorage: NSArray?
    nonisolated(unsafe) final var volumeData = [NSData?](repeating: nil, count: Int(MAX4D))
    nonisolated(unsafe) final var curMovieIndexStorage: Int16 = 0
    nonisolated(unsafe) final var maxMovieIndex: Int16 = 0
    nonisolated(unsafe) final var blendingVolumeData: NSData?
    nonisolated(unsafe) final var blendingPixList: NSMutableArray?
    /// Not retained, as the former class did not: VRView drops the fusion when
    /// the fused viewer closes, and -CloseViewerNotification: forgets it.
    nonisolated(unsafe) final weak var blendingControllerStorage: ViewerController?
    nonisolated(unsafe) final var minimumValueStorage: Float = 0
    nonisolated(unsafe) final var maximumValueStorage: Float = 0
    nonisolated(unsafe) final var blendingMinimumValueStorage: Float = 0
    nonisolated(unsafe) final var blendingMaximumValueStorage: Float = 0

    /// The value the scissors write outside or inside the cut (the nib's
    /// sheet edits it through a binding).
    @objc nonisolated(unsafe) public dynamic var deleteValue: Float = 0

    final var growingSet = false
    final var toolbar: NSToolbar?
    final var blending = false
    final var lastMovieTime: TimeInterval = 0
    final var movieTimer: Timer?
    final var undodata = [UnsafeMutablePointer<Float>?](repeating: nil, count: Int(MAX4D))
    // Fly Thru: the adapter of the open fly-thru window, which retains it.
    final unowned(unsafe) var FTAdapter: VRFlyThruAdapter?
    // 3D Points
    nonisolated(unsafe) final var viewer2DStorage: ViewerController?
    final var roi2DPointsArray: NSMutableArray?
    final var sliceNumber2DPointsArray: NSMutableArray?
    final var x2DPointsArray: NSMutableArray?
    final var y2DPointsArray: NSMutableArray?
    final var z2DPointsArray: NSMutableArray?
    // ROIs Volumes
    nonisolated(unsafe) final var roiVolumeLists = [NSMutableArray?](repeating: nil, count: Int(MAX4D))
    final var renderingModeStorage: String?
    final var shadingEditable = false
    final var appliedConvolutionFilters: NSMutableArray?
    final var selectedPresetPreview: VRPresetPreview?
    final var presetPreviewArray: NSMutableArray?
    final var presetNameArray: NSMutableArray?
    final var presetPageNumber: Int32 = 0
    final var presetPageMax: Int32 = 0
    final var presetPageMin: Int32 = 0
    final var panelInstantiated = false
    final var presetsPanelUserDefinedOrigin = NSPoint.zero
    final var needToMovePresetsPanelToUserDefinedPosition = false
    final var firstTimeDisplayed = false
    final var flyThruRecordingTimeFrame: TimeInterval = 0

    // The shading presets' array controller that -horosObserveShadingSelection
    // observes, retained while it is observed; nil if the observer was not
    // added. The initializers add it only once they succeed, so a controller
    // that failed never did; deinit removes it only if it was added:
    // removing an observer that was not added raises. The retain keeps the
    // observed object alive until the observer is gone (in Endoscopy.xib the
    // controller and the array controller are top-level objects of the
    // EndoscopyViewer, which releases them when it goes, and the endoscopy's
    // controller outlived it).
    final var horosObservedShadings: ShadingArrayController?
    // The volume as it was before the first convolution filter of this
    // window, nil until one is applied. The filters are written into the
    // buffer this window shares with the 2D viewer; the copy is put back when
    // the window closes, so the 2D series does not keep them.
    final var horosFilterRestore: VRFilterRestore?
    // -prepareUndo is also called by a filter; only the other callers
    // (scissors and bone removal) are cuts.
    final var horosApplyingFilter = false
    // The 2D viewer is closing: there is no series left to restore.
    final var horosViewerClosing = false

    /// The context of the shading presets' observer.
    nonisolated(unsafe) static let shadingObservation = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    // MARK: - Initializers

    // The designated initializers are inherited: Endoscopy.xib creates an
    // empty EndoscopyVRController with -init, filled when the endoscopy
    // viewer gives it a volume.

    @objc(initWithPix:::::)
    public convenience init?(pix: NSMutableArray!, _ f: NSArray!, _ vData: NSData!, _ bC: ViewerController!,
                             _ vC: ViewerController!) {
        self.init(pix: pix, f, vData, bC, vC, style: "standard", mode: "VR")
    }

    /// The window of `pix` (and `vData`, its volume) in `m` style ("standard",
    /// "panel" or "noNib", the hidden renderer of the MPR and the CPR) and
    /// rendering mode ("VR" or "MIP"). nil, after an alert, when the volume
    /// cannot be rendered: too large for memory, no slice interval nor
    /// thickness, images of different sizes, no 3D engine.
    @objc(initWithPix:::::style:mode:)
    public convenience init?(pix: NSMutableArray!, _ f: NSArray!, _ vData: NSData!, _ bC: ViewerController!,
                             _ vC: ViewerController!, style m: String!, mode renderingMode: String!) {
        guard let firstObject = pix?.object(at: 0) as? DCMPix else { return nil }

        // What raised an Objective-C exception in the former @try (a VTK or nib
        // edge case, a DCMPix that throws) is logged and the window is not made:
        // nil, as the former initializer answered after N2LogException.
        var renderable = false
        if let e = HorosObjCException.caught({ renderable = VRController.volumeIsRenderable(pix, firstObject) }) {
            _N2LogExceptionImpl(e, false, VRController.initializerName)
            return nil
        }
        guard renderable else { return nil }

        self.init(windowNibName: "VR")

        var ready = false
        if let e = HorosObjCException.caught({ ready = self.adoptVolume(pix, f, vData, bC, vC, style: m, mode: renderingMode, firstObject: firstObject) }) {
            _N2LogExceptionImpl(e, false, VRController.initializerName)
            return nil
        }
        guard ready else { return nil }
    }

    private static let initializerName = "-[VRController initWithPix:::::style:mode:]"

    /// The checks of the initializer before the controller exists: the
    /// memory, the slice interval and the images' sizes. NO, after an alert,
    /// when the volume cannot be rendered.
    private static func volumeIsRenderable(_ pix: NSMutableArray, _ firstObject: DCMPix) -> Bool {
        // MEMORY TEST: the renderer needs the volume in shorts, and the
        // gradients a byte more per voxel. An oversized volume is named with
        // the matrix and the size that was refused.
        let needed = VolumeAllocation.byteCount(width: Int(firstObject.pwidth), height: Int(firstObject.pheight),
                                                slices: pix.count, bytesPerVoxel: MemoryLayout<Int16>.size + 1)
        guard let testPtr = malloc(needed) else {
            let message = String(format: NSLocalizedString("Cannot use the 3D engine: a %@ volume needs %@ of contiguous memory, and the request was refused. Nothing was reduced silently; close other studies or open a smaller series.", comment: ""),
                                 VolumeAllocation.describeMatrix(width: Int(firstObject.pwidth), height: Int(firstObject.pheight), slices: pix.count),
                                 VolumeAllocation.describe(byteCount: needed))
            HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""), message: message,
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }
        free(testPtr)

        UserDefaults.standard.set(Float(1125), forKey: "VRGrowingRegionValue")
        UserDefaults.standard.set(Float(1750), forKey: "VRGrowingRegionInterval")

        var sliceThickness = abs(firstObject.sliceInterval)
        if sliceThickness == 0 {
            sliceThickness = firstObject.sliceThickness
            if sliceThickness > 0 {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Slice interval", comment: ""),
                                            message: NSLocalizedString("I'm not able to find the slice interval. Slice interval will be equal to slice thickness.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Slice interval/thickness", comment: ""),
                                            message: NSLocalizedString("Problems with slice thickness/interval to do a 3D reconstruction.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return false
            }
        }

        // CHECK IMAGE SIZE
        for case let other as DCMPix in pix where other.pwidth != firstObject.pwidth || other.pheight != firstObject.pheight {
            _ = other
            HorosAlertPanel.runCritical(title: NSLocalizedString("Images size", comment: ""),
                                        message: NSLocalizedString("These images don't have the same height and width to allow a 3D reconstruction...", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }

        return true
    }

    /// The initializer once the controller exists: it takes the volume, then
    /// finishInit. NO, after an alert, when the 3D engine refuses it.
    private final func adoptVolume(_ pix: NSMutableArray, _ f: NSArray?, _ vData: NSData?, _ bC: ViewerController?,
                                   _ vC: ViewerController?, style m: String?, mode renderingMode: String?,
                                   firstObject: DCMPix) -> Bool {
        styleName = m
        renderingModeStorage = renderingMode
        curMovieIndexStorage = 0
        maxMovieIndex = 1
        fileListStorage = f
        pixLists[0] = pix
        volumeData[0] = vData
        viewer2DStorage = vC
        blendingControllerStorage = bC
        if let bC { blendingPixList = bC.pixList() }

        // Find Minimum Value
        if !firstObject.isRGB { computeMinMax() } else {
            minimumValueStorage = 0
            deleteValue = 0
        }

        guard finishInit(renderingMode: renderingMode) else {
            HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                                message: NSLocalizedString("Cannot use the 3D engine.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return false
        }
        return true
    }

    /// The rest of the initializer, once the volume is the controller's: the
    /// window, the view's volume, the fusion, the 3D points, the observers, the
    /// presets' slots and the toolbar. NO when the view refuses the volume.
    private final func finishInit(renderingMode: String?) -> Bool {
        window?.delegate = self
        if styleName == "panel" { window?.level = .floating }

        let err = vrView?.setPixSource(pixLists[0], volumeData[0].map { UnsafeMutablePointer(mutating: $0.bytes.assumingMemoryBound(to: Float.self)) }) ?? 0
        if err != 0 { return false }

        if let bC = blendingControllerStorage { // Blending! Activate image fusion
            vrView?.setBlendingPixSource(bC)
            blendingSlider?.isEnabled = true
            // The percentage is always shown, dimmed with the slider until a fusion is active.
            blendingPercentage?.isEnabled = true
            blendingPercentage?.stringValue = String(format: "%0.0f%%", 100.0 * (blendingSlider?.floatValue ?? 0) / 256.0)
            updateBlendingImage()
        }

        horos_curWLWWMenu = NSLocalizedString("Other", comment: "")

        roi2DPointsArray = NSMutableArray()
        sliceNumber2DPointsArray = NSMutableArray()
        x2DPointsArray = NSMutableArray()
        y2DPointsArray = NSMutableArray()
        z2DPointsArray = NSMutableArray()
        collect2DPoints(withColour: true)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(remove3DPoint(_:)), name: .OsirixRemoveROI, object: nil)
        nc.addObserver(self, selector: #selector(add3DPoint(_:)), name: .OsirixROISelected, object: nil)
        nc.addObserver(self, selector: #selector(updateWLWWMenu(_:)), name: .OsirixUpdateWLWWMenu, object: nil)
        nc.addObserver(self, selector: #selector(updateVolumeData(_:)), name: .OsirixUpdateVolumeData, object: nil)
        nc.post(name: .OsirixUpdateWLWWMenu, object: horos_curWLWWMenu, userInfo: nil)

        horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")
        nc.addObserver(self, selector: #selector(updateCLUTMenu(_:)), name: .OsirixUpdateCLUTMenu, object: nil)
        nc.post(name: .OsirixUpdateCLUTMenu, object: horos_curCLUTMenu, userInfo: nil)

        horos_curOpacityMenu = NSLocalizedString("Linear Table", comment: "")
        nc.addObserver(self, selector: #selector(updateOpacityMenu(_:)), name: .OsirixUpdateOpacityMenu, object: nil)
        nc.post(name: .OsirixUpdateOpacityMenu, object: horos_curOpacityMenu, userInfo: nil)

        nc.addObserver(self, selector: #selector(clutChanged(_:)), name: .OsirixCLUTChanged, object: nil)
        nc.addObserver(self, selector: #selector(updateConvolutionMenu(_:)), name: .OsirixUpdateConvolutionMenu, object: nil)
        nc.post(name: .OsirixUpdateConvolutionMenu, object: NSLocalizedString("No Filter", comment: ""), userInfo: nil)
        nc.addObserver(self, selector: #selector(closeViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)

        movieRateSlider?.isEnabled = false
        moviePosSlider?.isEnabled = false
        moviePlayStop?.isEnabled = false

        // The scissors and the bone removal artwork is plain black, which on a
        // dark toolbar reads as a disabled tool. Both tools are enabled; as
        // template images the matrix draws them in the text colour of the
        // appearance, like the other controls. Copies, so the named
        // images every VR window loads from the nib are left as they are.
        for cell in toolsMatrixOutlet?.cells ?? [] {
            let tag = cell.tag
            if (tag == Int(ToolMode.t3DCut.rawValue) || tag == Int(ToolMode.tBonesRemoval.rawValue)),
               let image = cell.image, !image.isTemplate, let artwork = image.copy() as? NSImage {
                artwork.isTemplate = true
                cell.image = artwork
            }
        }

        vrView?.updateScissorStateButtons()

        for m in 0..<Int(maxMovieIndex) {
            roiVolumeLists[m] = NSMutableArray()
        }
        computeROIVolumes()
        displayROIVolumes()
        nc.addObserver(self, selector: #selector(updateROIVolume(_:)), name: .OsirixROIVolumePropertiesChanged, object: nil)

        if renderingMode == "MIP" { setModeIndex(1) }

        if styleName == "panel" {
            vrView?.setRotate(true)
            vrView?.setLOD(1.0)
        }

        appliedConvolutionFilters = NSMutableArray()

        if styleName != "noNib" {
            NSLog("presets start")
            let previews = NSMutableArray()
            for preview in [presetPreview1, presetPreview2, presetPreview3, presetPreview4, presetPreview5,
                            presetPreview6, presetPreview7, presetPreview8, presetPreview9] {
                if let preview { previews.add(preview) }
            }
            presetPreviewArray = previews
            let names = NSMutableArray()
            for name in [presetName1, presetName2, presetName3, presetName4, presetName5, presetName6, presetName7,
                         presetName8, presetName9] {
                if let name { names.add(name) }
            }
            presetNameArray = names
            NSLog("presets end")
        }
        nc.addObserver(self, selector: #selector(presetsPanelWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowWillMoveNotification(_:)), name: NSWindow.willMoveNotification, object: nil)

        if styleName == "panel" {
            shouldCascadeWindows = false
            window?.setFrameAutosaveName("3D Panel")
            window?.setFrameUsingName("3D Panel")
        }

        horosObserveShadingSelection()
        setupToolbar()
        return true
    }

    /// The 2D points of the 2D viewer's ROIs as 3D points of the view, and
    /// their positions in the lists. The VR window gives them their ROI's
    /// thickness and colour; the endoscopy's, the view's default.
    final func collect2DPoints(withColour: Bool) {
        guard let viewer2D = viewer2DStorage else { return }
        let count = viewer2D.imageView()?.dcmPixList?.count ?? 0
        for i in 0..<count {
            guard let curRoiList = viewer2D.roiList()?[i] as? NSArray else { continue }
            for case let curROI as ROI in curRoiList where curROI.type == .t2DPoint {
                var location = [Float](repeating: 0, count: 3)
                let point = (curROI.points?.object(at: 0) as? MyPoint)
                (viewer2D.pixList()?[i] as? DCMPix)?.convertX(point?.x ?? 0, pixY: point?.y ?? 0, toDICOMCoords: &location, pixelCenter: true)
                let x = location[0], y = location[1], z = location[2]
                // add the 3D Point to the SR view
                if withColour {
                    vrView?.add3DPoint(Double(x), Double(y), Double(z), curROI.thickness,
                                       Float(Double(curROI.rgbcolor.red) / 65535.0), Float(Double(curROI.rgbcolor.green) / 65535.0),
                                       Float(Double(curROI.rgbcolor.blue) / 65535.0))
                } else {
                    vrView?.add3DPoint(Double(x), Double(y), Double(z))
                }
                // add the 2D Point to our list
                roi2DPointsArray?.add(curROI)
                sliceNumber2DPointsArray?.add(NSNumber(value: i))
                x2DPointsArray?.add(NSNumber(value: x))
                y2DPointsArray?.add(NSNumber(value: y))
                z2DPointsArray?.add(NSNumber(value: z))
            }
        }
    }

    // The shading presets' popup has no action: a preset chosen there is
    // applied through this observer.
    @objc(horosObserveShadingSelection)
    final func horosObserveShadingSelection() {
        guard horosObservedShadings == nil, let shadings = shadingsPresetsController else { return }
        shadings.addObserver(self, forKeyPath: "selectedObjects", options: [], context: Self.shadingObservation)
        horosObservedShadings = shadings
    }

    public nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                                                  context: UnsafeMutableRawPointer?) {
        if context == Self.shadingObservation && keyPath == "selectedObjects" {
            // The shadings' array controller changes its selection on the main thread.
            let applied = MainActor.assumeIsolated { () -> Bool in
                guard (object as AnyObject?) === shadingsPresetsController else { return false }
                applyShading(self)
                return true
            }
            if applied { return }
        }
        super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }

    isolated deinit {
        NSLog("Dealloc VRController")
        if let shadings = horosObservedShadings {
            shadings.removeObserver(self, forKeyPath: "selectedObjects", context: Self.shadingObservation)
            horosObservedShadings = nil
        }
        // Release Undo system
        for i in 0..<Int(maxMovieIndex) {
            free(undodata[i])
            undodata[i] = nil
        }
        save3DState()
        NotificationCenter.default.removeObserver(self)
        toolbar?.delegate = nil
        vrView?.prepareForRelease()
        for preview in [presetPreview1, presetPreview2, presetPreview3, presetPreview4, presetPreview5, presetPreview6,
                        presetPreview7, presetPreview8, presetPreview9, selectedPresetPreview] {
            preview?.prepareForRelease()
        }
    }

    // MARK: - Accessors

    @objc(style)
    public nonisolated final func style() -> String! { styleName }

    public nonisolated override func pixList() -> NSMutableArray! { pixLists[0] }

    @objc(curPixList)
    public nonisolated final func curPixList() -> NSMutableArray! { pixLists[Int(curMovieIndexStorage)] }

    public nonisolated override func fileList() -> [Any]! {
        fileListStorage.map { $0 as [AnyObject] }
    }

    /// The file list the window was given, the same object.
    @objc(horosFileList)
    public nonisolated final func horosFileList() -> NSArray? { fileListStorage }

    public override func view() -> Any! { vrView }

    /// The view, typed.
    public final var volumeView: VRView? { vrView }

    public override func viewer() -> ViewerController! { viewer2DStorage }

    @objc(viewer2D)
    public nonisolated final func viewer2D() -> ViewerController! { viewer2DStorage }

    public nonisolated override func blendingController() -> ViewerController! { blendingControllerStorage }

    @objc(minimumValue)
    public nonisolated final func minimumValue() -> Float { minimumValueStorage }

    @objc(maximumValue)
    public nonisolated final func maximumValue() -> Float { maximumValueStorage }

    @objc(blendingMinimumValue)
    public nonisolated final func blendingMinimumValue() -> Float { blendingMinimumValueStorage }

    @objc(blendingMaximumValue)
    public nonisolated final func blendingMaximumValue() -> Float { blendingMaximumValueStorage }

    @objc(curMovieIndex)
    public nonisolated final func curMovieIndex() -> Int16 { curMovieIndexStorage }

    public nonisolated override func is4D() -> Bool { maxMovieIndex > 1 }

    @objc(toolsMatrix)
    public final func toolsMatrix() -> NSMatrix! { toolsMatrixOutlet }

    @objc(clutOpacityDrawer)
    final func clutOpacityDrawer() -> HorosCLUTPanel! { clutOpacityDrawerOutlet }

    @objc(factor)
    public final func factor() -> Float { vrView?.factor() ?? 0 }

    @objc(currentStudy)
    public override nonisolated final func currentStudy() -> DicomStudy! { viewer2DStorage?.currentStudy() }

    @objc(currentSeries)
    public override nonisolated final func currentSeries() -> DicomSeries! { viewer2DStorage?.currentSeries() }

    @objc(currentImage)
    public override nonisolated final func currentImage() -> DicomImage! { viewer2DStorage?.currentImage() }

    @objc(curWW)
    public override nonisolated final func curWW() -> Float { viewer2DStorage?.curWW() ?? 0 }

    @objc(curWL)
    public override nonisolated final func curWL() -> Float { viewer2DStorage?.curWL() ?? 0 }

    @objc(renderingMode)
    public final func renderingMode() -> String? { renderingModeStorage }

    @objc(setRenderingMode:)
    public final func setRenderingMode(_ renderingMode: String?) {
        if renderingMode == "MIP" {
            setModeIndex(1)
        } else if renderingMode == "VR" {
            setModeIndex(0)
        }
    }

    /// The volume of the current movie frame, which the view renders. An
    /// NSObject, not an NSData: Swift would bridge the NSData to Data, which
    /// comes back as a new object each frame (a copy, for mutable data), and
    /// the renderer, which knows the volume it uploaded by identity, uploaded
    /// it again at every frame.
    @objc(horosVolumeData)
    public final func horosVolumeData() -> NSObject? { volumeData[Int(curMovieIndexStorage)] }

    // MARK: - Range

    /// The smallest and largest values of every time of the series (and of
    /// the fused series); a CT of more than 8192 values may be clipped to
    /// -1024 … 7168, as the preferences say, after a prompt.
    @objc(computeMinMax)
    public final func computeMinMax() {
        if Self.computeMinMaxDepth > 2 { return }
        Self.computeMinMaxDepth += 1
        defer { Self.computeMinMaxDepth -= 1 }

        guard let first = pixLists[0], first.count > 0, let firstPix = first.object(at: 0) as? DCMPix else { return }
        maximumValueStorage = firstPix.maxValueOfSeries
        minimumValueStorage = maximumValueStorage

        if let fused = blendingPixList, fused.count > 0, let fusedPix = fused.object(at: 0) as? DCMPix {
            blendingMinimumValueStorage = fusedPix.minValueOfSeries
            blendingMaximumValueStorage = fusedPix.maxValueOfSeries
        }

        for i in 0..<Int(maxMovieIndex) {
            guard let list = pixLists[i], list.count > 0, let pix = list.object(at: 0) as? DCMPix else { continue }
            if maximumValueStorage < pix.maxValueOfSeries { maximumValueStorage = pix.maxValueOfSeries }
            if minimumValueStorage > pix.minValueOfSeries { minimumValueStorage = pix.minValueOfSeries }
        }

        if maximumValueStorage - minimumValueStorage < 1 { maximumValueStorage = minimumValueStorage + 1 }

        clutOpacityView?.setHUmin(minimumValueStorage, HUmax: maximumValueStorage)
        deleteValue = minimumValueStorage

        if viewer2DStorage?.modality() == "CT" && maximumValueStorage - minimumValueStorage > 8192 && Self.computeMinMaxDepth == 1
            && MPROpenGeometry.shouldPresentHighDynamicPrompt(duringHiddenInit: styleName == "noNib") {
            // Resample leaves the values as they are: the volume view maps the
            // whole range onto its 16-bit scale (-[VRView computeValueFactor]).
            if HighDynamicRangePolicy.shouldClip() {
                NSLog("-- modality is CT && pixel dynamic > 8192 -> clip values to -1024 && +7168")
                NSLog("-- current maxValueOfSeries = %f", maximumValueStorage)
                NSLog("-- current minValueOfSeries = %f", minimumValueStorage)
                for x in 0..<Int(maxMovieIndex) {
                    guard let list = pixLists[x], list.count > 0, let volume = volumeData[x],
                          let pix = list.object(at: 0) as? DCMPix else { continue }
                    var srcf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: volume.bytes),
                                             height: vImagePixelCount(Int(pix.pheight) * list.count),
                                             width: vImagePixelCount(pix.pwidth),
                                             rowBytes: Int(pix.pwidth) * MemoryLayout<Float>.size)
                    vImageClip_PlanarF(&srcf, &srcf, 7168, -1024, vImage_Flags(kvImageNoFlags))
                }
                viewer2DStorage?.recomputePixMinMax()
                computeMinMax()
                NSLog("-- new maxValueOfSeries = %f", maximumValueStorage)
                NSLog("-- new minValueOfSeries = %f", minimumValueStorage)
            }
        }
    }

    /// The depth of computeMinMax's recursion (a clip computes the range again).
    @MainActor private static var computeMinMaxDepth = 0

    // MARK: - Window

    @objc(CloseViewerNotification:)
    public final func closeViewerNotification(_ note: Notification!) {
        if (note?.object as AnyObject?) === viewer2DStorage {
            horosViewerClosing = true
            offFullScreen()
            window?.close()
        } else if let fused = blendingControllerStorage, (note?.object as AnyObject?) === fused {
            // The fused series is closing: VRView drops the fusion on the same
            // notification, whichever observer runs first. Forget the closing
            // viewer, which this controller does not retain, and dim the Fusion
            // item as it was before the fusion.
            blendingControllerStorage = nil
            blendingPixList = nil
            blendingSlider?.isEnabled = false
            blendingPercentage?.isEnabled = false
            blendingPercentage?.stringValue = String(format: "%0.0f%%", 100.0 * (blendingSlider?.floatValue ?? 0) / 256.0)
        }
    }

    @objc(windowDidResize:)
    public override func windowDidResize(_ aNotification: Notification) {
        if styleName != "panel" { vrView?.squareView(self) }
    }

    @objc(windowWillClose:)
    public override func windowWillClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === window else { return }
        horos_windowWillClose = true
        window?.acceptsMouseMovedEvents = false

        horosSettleFiltersOnClose()

        NotificationCenter.default.post(name: .OsirixWindow3dClose, object: self, userInfo: nil)

        movieTimer?.invalidate()
        movieTimer = nil

        presetsPanel?.close()
        presetsInfoPanel?.close()

        // The Metal renderers and their GPU volumes go with the window.
        horosVolumeMetalDropRenderers()

        window?.delegate = nil

        // The reference the controller's creator handed over to its window.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if styleName != "panel" { vrView?.squareView(self) }
    }

    // The drawer's child panel fits the screen independently of the viewer.
    @objc(drawerDidClose:)
    public final func drawerDidClose(_ sender: Notification!) {
        window?.invalidateShadow()
    }

    @objc(drawerDidOpen:)
    public final func drawerDidOpen(_ sender: Notification!) {
        window?.invalidateShadow()
    }

    // MARK: - Unused actions of the nib

    @objc(endShadingEditing:)
    public final func endShadingEditing(_ sender: Any!) {
    }

    @objc(resetShading:)
    public final func resetShading(_ sender: Any!) {
    }
}
