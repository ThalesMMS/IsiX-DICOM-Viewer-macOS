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

// Opening the 3D and MPR viewers of a 2D viewer: volume rendering (the window
// and the panel), surface rendering, the orthogonal MPR (and its PET-CT
// fusion), endoscopy, the oblique MPR, the CPR and the 3D region growing; and
// the checks before them. Each opening runs the checks IsiXImaging's
// VolumeEligibility gives it, in their order (volumic, the slice geometry,
// the 4D frames, the thickness and interval), brings forward a viewer already
// open on the same slices, found through the arrangement of the windows, or
// opens one with the window level, colour and opacity tables of the 2D
// viewer and places it on the 3D viewers' screen. The VTK and ITK viewers
// keep their Objective-C++ or Swift classes; they are created here through
// their initializers. A 3D viewer releases itself when its window closes:
// each one created here is handed over with that extra reference, as before.
// ViewerController keeps the former selectors as a façade over a launcher made
// for each call, which holds the viewer for that call only.

@MainActor struct ThreeDViewerLauncher {

    /// The 2D viewer whose series is reconstructed.
    let viewer: ViewerController
    /// The arrangement of the windows, which finds the viewers open on a series.
    let windowArranger: ViewerWindowArranger
    /// The application's preferences.
    let preferences: any PreferenceStore

    init(viewer: ViewerController, windowArranger: ViewerWindowArranger, preferences: any PreferenceStore) {
        self.viewer = viewer
        self.windowArranger = windowArranger
        self.preferences = preferences
    }

    // MARK: - Volume rendering

    /// The volume rendering panel (MIP), on the frame the player shows.
    func openVolumeRenderingPanel(_ sender: Any?) {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        guard passesChecks(.volumeRenderingPanel, sender: sender) else { return }

        viewer.displayAWarningIfNonTrueVolumicData()
        viewer.displayWarningIfGantryTitled()

        viewer.movieStop(viewer)

        if let open = openRenderer(style: "panel", modes: nil) {
            open.window?.makeKeyAndOrderFront(viewer)
            return
        }

        let movies = Int(viewer.horos_maxMovieIndex)
        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(viewer.horos_curMovieIndex), count: movies)
        guard let pix0 = viewer.horos_pixList(at: 0), let files0 = viewer.horos_fileList(at: 0),
              let volume0 = viewer.horos_volumeData(at: 0) as? NSData,
              let firstAtTime = viewer.horos_pixArray(time).first else { return }

        // Same ordering contract as the volume rendering window: time 0 first,
        // then the rest, so setMovieFrame: lands on the time the player shows.
        let renderer = makeVRController(pix0, files0, volume0, style: "panel", mode: "MIP")
        handOver(renderer)
        for i in 1..<max(movies, 1) {
            addMovie(i, to: renderer)
        }
        renderer?.setMovieFrame(time)

        if !firstAtTime.isRGB && viewerIsEqualToString(viewer.modality(), "PT") {
            if viewer.horos_imageView?.curDCM?.suvConverted ?? false {
                renderer?.setWLWW(3, 6)
            } else {
                renderer?.setWLWW(firstAtTime.maxValueOfSeries / 4, firstAtTime.maxValueOfSeries / 2)
            }
        }

        renderer?.load3DState()

        if viewerIsEqualToString(viewer.modality(), "PT") && !firstAtTime.isRGB {
            applyPETColourTable(to: renderer)
            renderer?.applyOpacityString("Logarithmic Table")
        } else {
            let shown = shownWindowLevel
            renderer?.setWLWW(shown.level, shown.width)
        }

        renderer?.window?.setFrameOrigin(viewer.window?.screen?.visibleFrame.origin ?? .zero)
        renderer?.showWindow(viewer)
        renderer?.window?.makeKeyAndOrderFront(viewer)
        renderer?.window?.display()
        retitle(renderer)
    }

    /// The volume rendering window in `mode` ("VR" or "MIP"): the one open in
    /// that mode on these slices, or a new one on every frame, showing the
    /// frame the player shows, prepared and ready to be shown; nil when the
    /// frames cannot be reconstructed.
    func volumeRenderingWindow(mode: String?) -> VRController? {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()
        viewer.movieStop(viewer)
        if fourDReconstructionRefusalReason() != nil {
            return nil
        }

        if let open = openRenderer(style: "standard", modes: ["VR", "MIP"]) {
            return open
        }

        let movies = Int(viewer.horos_maxMovieIndex)
        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(viewer.horos_curMovieIndex), count: movies)
        guard let pix0 = viewer.horos_pixList(at: 0), let files0 = viewer.horos_fileList(at: 0),
              let volume0 = viewer.horos_volumeData(at: 0) as? NSData,
              let firstAtTime = viewer.horos_pixArray(time).first else { return nil }

        // Time 0 first, then the remaining times in order: the renderer indexes
        // its own movie slots the way this viewer does, so the shared index is
        // a valid subscript there too.
        let renderer = makeVRController(pix0, files0, volume0, style: "standard", mode: mode)
        handOver(renderer)
        for i in 1..<max(movies, 1) {
            addMovie(i, to: renderer)
        }
        renderer?.setMovieFrame(time)

        if viewerIsEqualToString(viewer.modality(), "PT") && !firstAtTime.isRGB {
            if viewer.horos_imageView?.curDCM?.suvConverted ?? false {
                renderer?.setWLWW(2, 6)
            } else {
                renderer?.setWLWW(firstAtTime.maxValueOfSeries / 2, firstAtTime.maxValueOfSeries)
            }

            applyPETColourTable(to: renderer)
            renderer?.applyOpacityString("Logarithmic Table")
        } else {
            let shown = shownWindowLevel
            renderer?.setWLWW(shown.level, shown.width)
        }

        prepareNewRenderer(renderer)
        return renderer
    }

    /// What a new volume rendering window needs before it can be shown, the
    /// same for the 3D Viewer menu and for any other caller of
    /// -openVRViewerForMode: (a plugin among them): the 2D viewer's colour
    /// table and window level, the window placed on the 3D viewers' screen,
    /// and the saved 3D state loaded. Loading the state installs the rendering
    /// engine and frames the camera on the volume; a window created without it
    /// has a camera that frames nothing, and the volume has no mapper.
    private func prepareNewRenderer(_ renderer: VRController?) {
        renderer?.applyCLUTString(viewer.horos_backCurCLUTMenu ?? viewer.horos_curCLUTMenu)
        let shown = shownWindowLevel
        renderer?.setWLWW(shown.level, shown.width)
        place(renderer)
        renderer?.load3DState()
    }

    /// Volume rendering (tag 3: MIP), in a window of its own.
    func openVolumeRendering(_ sender: Any?) {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        guard passesChecks(.volumeRendering, sender: sender) else { return }

        viewer.displayAWarningIfNonTrueVolumicData()

        viewer.displayWarningIfGantryTitled()

        if !viewerIsEqualToString(viewer.horos_curConvMenu, NSLocalizedString("No Filter", comment: "")) {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Convolution", comment: ""),
                                                message: NSLocalizedString("Should I apply current convolution filter on raw data? 2D/3D post-processing viewers can only display raw data.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                otherButton: nil) == HorosAlertDefaultResponse {
                viewer.applyConvolutionOnSource(viewer)
            }
        }

        viewer.movieStop(viewer)

        let mip = ViewerSender.tag(sender) == 3
        if let open = openRenderer(style: "standard", modes: nil) {
            open.window?.makeKeyAndOrderFront(viewer)
            open.setModeIndex(mip ? 1 : 0)
            return
        }

        // No window open in this style: the one made here comes prepared.
        let renderer = volumeRenderingWindow(mode: mip ? "MIP" : "VR")
        renderer?.showWindow(viewer)
        renderer?.window?.makeKeyAndOrderFront(viewer)
        renderer?.window?.display()
        retitle(renderer)
    }

    // MARK: - Surface rendering

    /// The surface rendering open on these slices, or a new one on the frame
    /// shown.
    func surfaceRenderingWindow() -> SRController? {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()
        if let found = windowArranger.findViewer(nibName: "SR", pixList: viewer.horos_pixList(at: 0)) as? SRController {
            return found
        }
        let time = FourDSeriesGuard.wrappedIndex(Int(viewer.horos_curMovieIndex), count: Int(viewer.horos_maxMovieIndex))
        guard let pix = viewer.horos_pixList(at: time), let files = viewer.horos_fileList(at: time),
              let volume = viewer.horos_volumeData(at: time) as? NSData else {
            return nil
        }
        let made = makeSRController(pix, files, volume)
        handOver(made)
        return made
    }

    /// Surface rendering.
    func openSurfaceRendering(_ sender: Any?) {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        guard passesChecks(.surfaceRendering, sender: sender) else { return }

        viewer.displayAWarningIfNonTrueVolumicData()
        viewer.displayWarningIfGantryTitled()

        viewer.movieStop(viewer)

        if bringForward(nibName: "SR") { return }

        let made = surfaceRenderingWindow()
        place(made)
        made?.showWindow(viewer)
        made?.window?.makeKeyAndOrderFront(viewer)
        made?.changeSettings(viewer)
        retitle(made)
    }

    // MARK: - Orthogonal MPR

    /// The orthogonal MPR open on these slices (its PET-CT fusion with a
    /// fused series), or a new one on the frame the player shows, with the 2D
    /// viewer's tables and window level.
    func orthogonalMPRWindow() -> OrthogonalMPRViewer? {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        // With a fused series the viewer found is the PET-CT one, returned
        // under this type as before.
        let nibName = viewer.horos_blending != nil ? "PETCT" : "OrthogonalMPR"
        if let found = windowArranger.findViewer(nibName: nibName, pixList: viewer.horos_pixList(at: 0)) {
            return (found as? OrthogonalMPRViewer) ?? handedOutUnchecked(found)
        }

        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(viewer.horos_curMovieIndex), count: Int(viewer.horos_maxMovieIndex))
        guard let pix = viewer.horos_pixList(at: time), let files = viewer.horos_fileList(at: time),
              let volume = viewer.horos_volumeData(at: time) as? NSData else {
            return nil
        }
        let made = OrthogonalMPRViewer(pixList: pix, files, volume, viewer, nil)
        handOver(made)

        let sww = viewer.horos_imageView?.curWW ?? 0
        let swl = viewer.horos_imageView?.curWL ?? 0

        let table = viewer.horos_backCurCLUTMenu ?? viewer.horos_curCLUTMenu

        let isRGB = viewer.horos_pixArray(time).first?.isRGB ?? false
        if !isRGB && (viewerIsEqualToString(viewer.modality(), "PT")
                      || (preferences[ViewerPreferences.petCLUTForNM] && viewerIsEqualToString(viewer.modality(), "NM"))) {
            applyPETColourTable(to: made)
        } else {
            made?.applyCLUTString(table)
        }

        made?.applyOpacityString(viewer.horos_curOpacityMenu)

        made?.setWLWW(swl, sww)

        return made
    }

    /// The orthogonal MPR of this series fused with its PET series: the one
    /// open, or a new one when the two planes are parallel (an alert
    /// otherwise), on the frame the player shows and the overlay's matching
    /// frame.
    func orthogonalPETCTWindow() -> OrthogonalMPRPETCTViewer? {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        if let found = windowArranger.findViewer(nibName: "PETCT", pixList: viewer.horos_pixList(at: 0)) as? OrthogonalMPRPETCTViewer {
            return found
        }

        guard let blending = viewer.horos_blending else { return nil }

        var orientA = [Float](repeating: 0, count: 9), orientB = [Float](repeating: 0, count: 9)
        viewer.horos_imageView?.curDCM?.orientation(&orientA)
        blending.imageView()?.curDCM?.orientation(&orientB)

        let angle = orientA.withUnsafeMutableBufferPointer { a in
            orientB.withUnsafeMutableBufferPointer { b in DCMView.angleBetweenVector(a.baseAddress! + 6, andVector: b.baseAddress! + 6) }
        }
        if angle > preferences[ViewerPreferences.parallelPlaneTolerance] { // Planes are not parallel!
            HorosAlertPanel.runCritical(title: NSLocalizedString("2D Planes", comment: ""),
                                        message: NSLocalizedString("These 2D planes are not parallel, you cannot use the 2D Orthogonal MPR viewer. Instead, try the 3D MPR viewer.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        let movies = Int(viewer.horos_maxMovieIndex)
        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(viewer.horos_curMovieIndex), count: movies)
        guard let pix = viewer.horos_pixList(at: time), let files = viewer.horos_fileList(at: time),
              let volume = viewer.horos_volumeData(at: time) as? NSData else {
            return nil
        }
        let overlayTime = FourDSeriesGuard.fusionOverlayIndex(hostTime: time, hostCount: movies, overlayCount: Int(blending.maxMovieIndex()))
        if Int(blending.curMovieIndex()) != overlayTime {
            blending.setMovieIndex(Int16(truncatingIfNeeded: overlayTime))
        }
        let made = OrthogonalMPRPETCTViewer(pixList: pix, files, volume, viewer, blending)
        handOver(made)
        place(made)

        let table = viewer.horos_backCurCLUTMenu ?? viewer.horos_curCLUTMenu

        made?.CTController?.applyCLUTString(table)
        made?.PETController?.applyCLUTString(blending.curCLUTMenu())
        made?.PETCTController?.applyCLUTString(table)

        made?.CTController?.applyOpacityString(viewer.horos_curOpacityMenu)
        made?.PETController?.applyOpacityString(blending.curOpacityMenu())
        made?.PETCTController?.applyOpacityString(viewer.horos_curOpacityMenu)

        let fusion = made?.PETCTController
        for view in [fusion?.originalView(), fusion?.xReslicedView(), fusion?.yReslicedView()] {
            (view as? OrthogonalMPRPETCTView)?.setCurCLUTMenu(blending.curCLUTMenu())
        }
        for view in [fusion?.originalView(), fusion?.xReslicedView(), fusion?.yReslicedView()] {
            (view as? OrthogonalMPRPETCTView)?.setCurOpacityMenu(blending.curOpacityMenu())
        }

        made?.showWindow(viewer)

        var wl: Float = 0, ww: Float = 0
        viewer.horos_imageView?.getWLWW(&wl, &ww)
        made?.CTController?.setWLWW(wl, ww)
        blending.imageView()?.getWLWW(&wl, &ww)
        made?.PETController?.setWLWW(wl, ww)

        made?.setBlendingMode(preferences[ViewerPreferences.defaultPETFusion])

        return made
    }

    /// The orthogonal MPR (PET-CT with a fused series).
    func openOrthogonalMPR(_ sender: Any?) {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        // A series that passes the volumic check can still be one this
        // reconstruction cannot resample - mixed matrices, mixed orientations, a
        // non-finite interval: the geometry check names those, as for the
        // oblique MPR, instead of drawing empty planes.
        guard passesChecks(.orthogonalMPR, sender: sender) else { return }
        let blending = viewer.horos_blending

        viewer.displayAWarningIfNonTrueVolumicData()
        viewer.displayWarningIfGantryTitled()

        blending?.displayAWarningIfNonTrueVolumicData()
        blending?.displayWarningIfGantryTitled()

        viewer.movieStop(viewer)

        if bringForward(nibName: blending != nil ? "PETCT" : "OrthogonalMPR") { return }

        if blending != nil {
            let fused = orthogonalPETCTWindow()
            let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(viewer.horos_curMovieIndex), count: Int(viewer.horos_maxMovieIndex))
            let date = studyDate(ofFrame: time).map { UserDefaults.dateTimeFormatter().string(from: $0) }

            fused?.window?.title = "\(described(fused?.window?.title)): \(described(date)) - \(described(viewer.window?.title))"
        } else {
            let made = orthogonalMPRWindow()

            place(made)
            made?.showWindow(viewer)

            let shown = shownWindowLevel
            made?.setWLWW(shown.level, shown.width)

            made?.window?.title = "\(described(made?.window?.title)): \(described(UserDefaults.formatDateTime(studyDate(ofFrame: 0)))) - \(described(viewer.window?.title))"
        }
    }

    // MARK: - Endoscopy

    /// The endoscopy viewer open on these slices, or a new one on the frame
    /// the player shows.
    func endoscopyWindow() -> EndoscopyViewer? {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        if let found = windowArranger.findViewer(nibName: "Endoscopy", pixList: viewer.horos_pixList(at: 0)) as? EndoscopyViewer {
            return found
        }

        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(viewer.horos_curMovieIndex), count: Int(viewer.horos_maxMovieIndex))
        guard let pix = viewer.horos_pixList(at: time), let files = viewer.horos_fileList(at: time),
              let volume = viewer.horos_volumeData(at: time) as? NSData else {
            return nil
        }
        let made = EndoscopyViewer(pixList: pix, files, volume, viewer.horos_blending, viewer)
        handOver(made)
        return made
    }

    /// The endoscopy viewer.
    func openEndoscopy(_ sender: Any?) {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        guard passesChecks(.endoscopy, sender: sender) else { return }

        viewer.displayAWarningIfNonTrueVolumicData()
        viewer.displayWarningIfGantryTitled()

        viewer.movieStop(viewer)

        if bringForward(nibName: "Endoscopy") { return }

        let made = endoscopyWindow()
        place(made)
        made?.showWindow(viewer)
        retitle(made)
    }

    // MARK: - Oblique MPR

    /// The oblique MPR open on these slices, or a new one on every frame; nil
    /// when the frames cannot be reconstructed.
    func obliqueMPRWindow() -> MPRController? {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()
        if fourDReconstructionRefusalReason() != nil {
            return nil
        }

        if let found = windowArranger.findViewer(nibName: "MPR", pixList: viewer.horos_pixList(at: 0)) as? MPRController {
            return found
        }

        let made = MPRController(dcmPixList: viewer.horos_pixList(at: 0), filesList: viewer.horos_fileList(at: 0),
                                 volumeData: viewer.horos_volumeData(at: 0) as? NSData,
                                 viewerController: viewer, fusedViewerController: viewer.horos_blending)
        handOver(made)
        for i in 1..<max(Int(viewer.horos_maxMovieIndex), 1) {
            made?.addMoviePixList(viewer.horos_pixList(at: i), viewer.horos_volumeData(at: i) as? NSData)
        }

        return made
    }

    /// The oblique MPR. From the Series Selection item of an MPR (`sender`),
    /// the new MPR takes the frame of the one it replaces.
    func openObliqueMPR(_ sender: Any?) {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        guard passesChecks(.obliqueMPR, sender: sender) else { return }

        viewer.displayAWarningIfNonTrueVolumicData()
        viewer.displayWarningIfGantryTitled()

        viewer.movieStop(viewer)

        let found = windowArranger.findViewer(nibName: "MPR", pixList: viewer.horos_pixList(at: 0))

        // The Series Selection item of an MPR asks for the new series here and
        // closes itself afterwards: the MPR that replaces it takes its frame.
        let replacedMPRWindow = (sender as? MPRController)?.window

        if let found {
            if let replacedMPRWindow, found !== (sender as AnyObject?) {
                found.window?.setFrame(replacedMPRWindow.frame, display: true)
            }
            found.window?.makeKeyAndOrderFront(viewer)
            return
        }

        let made = obliqueMPRWindow()
        if let replacedMPRWindow {
            made?.window?.setFrame(replacedMPRWindow.frame, display: false)
        } else {
            place(made)
        }
        made?.showWindow(viewer)
        retitle(made)
        let owner = viewer
        DispatchQueue.main.async {
            made?.showWindow(owner)
            made?.showWindow(owner)
        }
    }

    // MARK: - Curved MPR

    /// The CPR open on these slices, or a new one on every frame; nil when
    /// the frames cannot be reconstructed.
    func curvedMPRWindow() -> CPRController? {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()
        if fourDReconstructionRefusalReason() != nil {
            return nil
        }

        if let found = windowArranger.findViewer(nibName: "CPR", pixList: viewer.horos_pixList(at: 0)) as? CPRController {
            return found
        }

        let made = CPRController(dcmPixList: viewer.horos_pixList(at: 0), filesList: viewer.horos_fileList(at: 0),
                                 volumeData: viewer.horos_volumeData(at: 0) as? NSData,
                                 viewerController: viewer, fusedViewerController: viewer.horos_blending)
        handOver(made)
        for i in 1..<max(Int(viewer.horos_maxMovieIndex), 1) {
            made?.addMoviePixList(viewer.horos_pixList(at: i), viewer.horos_volumeData(at: i) as? NSData)
        }

        return made
    }

    /// The CPR (curved MPR), on volumic black and white data. The curved path
    /// a TAVR plan is drawn on is resampled from the same volume, so the same
    /// geometry has to hold: without it the CPR opened on a series it could
    /// not resample and showed empty planes.
    func openCurvedMPR(_ sender: Any?) {
        viewer.checkEverythingLoaded()
        viewer.clear8bitRepresentations()

        guard passesChecks(.curvedMPR, sender: sender) else { return }

        viewer.displayAWarningIfNonTrueVolumicData()
        viewer.displayWarningIfGantryTitled()

        viewer.movieStop(viewer)

        if bringForward(nibName: "CPR") { return }

        let waitWindow = viewer.startWaitWindow(NSLocalizedString("Loading...", comment: ""))
        let made = curvedMPRWindow()
        place(made)
        made?.showWindow(viewer)
        retitle(made)
        let owner = viewer
        DispatchQueue.main.async {
            made?.showWindow(owner)
            made?.showWindow(owner)
            owner.endWaitWindow(waitWindow)
        }
    }

    // MARK: - Region growing

    /// The 3D region growing, on volumic data, or in 2D otherwise.
    func openRegionGrowing(_ sender: Any?) {
        let volumicData = viewer.isDataVolumicIn4D(false)

        if !volumicData {
            // Force 2D mode
            preferences.set(0, for: VolumeRenderingPreferences.growingRegionType)
        } else {
            viewer.displayAWarningIfNonTrueVolumicData()
        }

        viewer.clear8bitRepresentations()

        var interval = viewer.computeInterval()

        if viewer.horos_pixArray(Int(viewer.horos_curMovieIndex)).count <= 1 { interval = 1 }

        let first = viewer.horos_pixArray(0).first
        if interval == 0 || (first?.pixelSpacingX ?? 0) == 0 || (first?.pixelSpacingY ?? 0) == 0 || shiftHeld {
            viewer.setThicknessInterval(sender)
        } else if let open = ITKSegmentation3DController.segmentationController(forViewer: viewer) {
            // The window this viewer already has.
            open.showWindow(viewer)
            open.window?.makeKeyAndOrderFront(viewer)
        } else {
            let made = ITKSegmentation3DController(viewer: viewer)
            handOver(made)
            made.showWindow(viewer)
            made.window?.makeKeyAndOrderFront(viewer)
        }
    }

    // MARK: - Checks

    /// Runs the checks of `reconstruction`, in their order, until one
    /// refuses: the thickness and interval sheet opens (with `sender`) when it
    /// asks for them, an alert says why otherwise. True when every check
    /// passed.
    private func passesChecks(_ reconstruction: VolumeEligibility.Reconstruction, sender: Any?) -> Bool {
        for check in VolumeEligibility.checks(for: reconstruction, fused: viewer.horos_blending != nil) {
            guard let refusal = refusal(of: check) else { continue }
            switch refusal {
            case .askThicknessAndInterval:
                viewer.setThicknessInterval(sender)
            case .notVolumic:
                alert(Self.title(of: reconstruction), Self.volumicRequirement(of: reconstruction))
            case .notVolumicBlackAndWhite:
                alert(Self.title(of: reconstruction), NSLocalizedString("CPR requires volumic data and BW images.", comment: ""))
            case .geometry(let diagnosis), .fourDFrames(let diagnosis):
                alert(Self.title(of: reconstruction), diagnosis)
            case .fourDFusion(let reason):
                alert(NSLocalizedString("PET-CT Fusion", comment: ""), reason)
            }
            return false
        }
        return true
    }

    /// What `check` finds in the series now, or nil when it passes.
    private func refusal(of check: VolumeEligibility.Check) -> VolumeEligibility.Refusal? {
        switch check {
        case .thicknessAndInterval:
            return needsThicknessAndInterval() ? .askThicknessAndInterval : nil
        case .volumic:
            return viewer.isDataVolumicIn4D(true) ? nil : .notVolumic
        case .volumicBlackAndWhite:
            return !viewer.isDataVolumicIn4D(true) || (viewer.horos_imageView?.curDCM?.isRGB ?? false) ? .notVolumicBlackAndWhite : nil
        case .geometry:
            let geometry = reconstructionOpeningDecision()
            return VolumeEligibility.geometryRefusal(accepted: geometry.accepted, diagnosis: geometry.diagnosis)
        case .calibratedGeometry:
            let geometry = reconstructionOpeningDecision()
            let interval = viewer.computeInterval()
            let first = viewer.horos_pixArray(0).first
            return VolumeEligibility.obliqueMPRRefusal(phase: geometry.phase, accepted: geometry.accepted, diagnosis: geometry.diagnosis,
                                                       interval: Double(interval), pixelSpacingX: first?.pixelSpacingX ?? 0,
                                                       pixelSpacingY: first?.pixelSpacingY ?? 0, shiftHeld: shiftHeld)
        case .fourDFrames:
            return fourDReconstructionRefusalReason().map { .fourDFrames(reason: $0) }
        case .fourDFusion:
            return fourDFusionRefusalReason(forOverlay: viewer.horos_blending).map { .fourDFusion(reason: $0) }
        }
    }

    /// Whether the slice thickness and interval are to be asked first: no
    /// interval, no pixel spacing, or Shift held. The interval is computed
    /// first, as it always was, and then the first slice is read.
    func needsThicknessAndInterval() -> Bool {
        let interval = viewer.computeInterval()
        let first = viewer.horos_pixArray(0).first
        return VolumeEligibility.needsThicknessAndInterval(interval: Double(interval), pixelSpacingX: first?.pixelSpacingX ?? 0,
                                                           pixelSpacingY: first?.pixelSpacingY ?? 0, shiftHeld: shiftHeld)
    }

    /// Whether Shift is held in the event being handled.
    private var shiftHeld: Bool {
        NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false
    }

    /// Why the 4D frames cannot be reconstructed together (too many, a frame
    /// with inconsistent slices, a frame unlike the first), or nil.
    func fourDReconstructionRefusalReason() -> String? {
        let count = Int(viewer.horos_maxMovieIndex)
        if count < 1 {
            return FourDSeriesGuard.reconstructionRefusal(comparing: nil, to: nil, at: 0)
        }
        if let capacity = FourDSeriesGuard.capacityReason(at: count - 1, capacity: Int(MAX4D)) {
            return capacity
        }
        if let slices = FourDSeriesGuard.reasonForInconsistentSlices(viewer.horos_pixList(at: 0), atTime: 0) {
            return slices
        }
        let reference = FourDSeriesGuard.geometry(fromPixList: viewer.horos_pixList(at: 0), volume: viewer.horos_volumeData(at: 0) as? NSData)
        if let first = FourDSeriesGuard.reconstructionRefusal(comparing: reference, to: reference, at: 0) {
            return first
        }
        for i in 1..<max(count, 1) {
            if let timeSlices = FourDSeriesGuard.reasonForInconsistentSlices(viewer.horos_pixList(at: i), atTime: i) {
                return timeSlices
            }
            let candidate = FourDSeriesGuard.geometry(fromPixList: viewer.horos_pixList(at: i), volume: viewer.horos_volumeData(at: i) as? NSData)
            if let reason = FourDSeriesGuard.reconstructionRefusal(comparing: candidate, to: reference, at: i) {
                return reason
            }
        }
        return nil
    }

    /// Why `overlay` cannot be fused frame by frame with the 2D viewer, or
    /// nil (also without an overlay).
    func fourDFusionRefusalReason(forOverlay overlay: ViewerController?) -> String? {
        guard let overlay else { return nil }
        if let overlayReason = overlay.fourDReconstructionRefusalReason() {
            return overlayReason
        }
        return FourDSeriesGuard.fusionRefusal(hostTimes: Int(viewer.horos_maxMovieIndex), overlayTimes: Int(overlay.maxMovieIndex()))
    }

    /// Shows `reason` under `title`; false without a reason.
    func refuse(_ reason: String?, title: String?) -> Bool {
        guard let reason else { return false }
        HorosAlertPanel.run(title: title, message: reason, defaultButton: nil, alternateButton: nil, otherButton: nil)
        return true
    }

    /// The geometry every reconstruction door has to agree about: valid input
    /// gives the expected planes, incompatible input a specific error, for the
    /// oblique and orthogonal MPR and the CPR alike.
    func reconstructionOpeningDecision() -> MPROpenDecision {
        let interval = viewer.computeInterval()
        // The first slice is read as before: a missing list gives no slice, an
        // empty one raises.
        let firstPix = viewer.horos_pixList(at: 0)?.object(at: 0) as? DCMPix
        let slices = viewer.horos_pixArray(0)

        let scan = ReconstructionGeometryScan.scan(slices.map { pix -> ReconstructionGeometryScan.Slice in
            var orientation = [Float](repeating: 0, count: 9)
            pix.orientation(&orientation)
            return ReconstructionGeometryScan.Slice(width: Int(pix.pwidth), height: Int(pix.pheight), orientation: orientation,
                                                    originX: Double(pix.originX), originY: Double(pix.originY), originZ: Double(pix.originZ))
        }, interval: interval)

        var roiCount = 0
        for case let sliceROIs as [Any] in viewer.horos_roiList(at: Int(viewer.horos_curMovieIndex)) ?? [] {
            roiCount += sliceROIs.count
        }

        return MPROpenGeometry.opening(withSliceCount: Int(Int32(truncatingIfNeeded: slices.count)),
                                       spacingX: Double(firstPix?.pixelSpacingX ?? 0), spacingY: Double(firstPix?.pixelSpacingY ?? 0),
                                       sliceInterval: Double(interval),
                                       minInterval: scan.minInterval, maxInterval: scan.maxInterval,
                                       width: Int(firstPix?.pwidth ?? 0), height: Int(firstPix?.pheight ?? 0),
                                       mismatchedSlices: scan.mismatchedSlices,
                                       roiCount: Int(Int32(truncatingIfNeeded: roiCount)),
                                       mismatchedOrientations: scan.mismatchedOrientations)
    }

    // MARK: - Windows

    /// The screen a 3D viewer of `other` opens on: `other`'s, or another one
    /// with the "ThreeDViewerOnAnotherScreen" preference.
    func screen(for other: ViewerController?) -> NSScreen? {
        let own = other?.window?.screen
        let screens = NSScreen.screens
        if let index = ThreeDViewerScreen.index(viewerScreenOrigin: own?.frame.origin ?? .zero,
                                                 screenOrigins: screens.map { $0.frame.origin },
                                                 onAnotherScreen: preferences[VolumeRenderingPreferences.threeDViewerOnAnotherScreen]) {
            return screens[index]
        }
        return own
    }

    /// Gives `window`'s window the visible frame of the 2D viewer's 3D screen.
    func place(_ window: NSWindowController?) {
        window?.window?.setFrame(screen(for: viewer)?.visibleFrame ?? .zero, display: false)
    }

    /// Brings forward the viewer of `nibName` open on these slices; false
    /// when there is none.
    private func bringForward(nibName: String) -> Bool {
        guard let found = windowArranger.findViewer(nibName: nibName, pixList: viewer.horos_pixList(at: 0)) else { return false }
        found.window?.makeKeyAndOrderFront(viewer)
        return true
    }

    /// The volume rendering open on these slices in `style` (and, with
    /// `modes`, in one of those modes), its window not closing; the last one
    /// listed wins, as before.
    private func openRenderer(style: String, modes: [String]?) -> VRController? {
        var found: VRController?
        for candidate in windowArranger.findRelatedViewers(pixList: viewer.horos_pixList(at: 0)) {
            // Not a viewer whose window is closing, as the arranger's findViewer.
            guard viewerIsEqualToString(candidate.windowNibName, "VR") else { continue }
            let renderer = unsafeDowncast(candidate, to: VRController.self)
            guard !renderer.windowWillClose() else { continue }
            if viewerIsEqualToString(renderer.style(), style)
                && (modes == nil || modes!.contains { viewerIsEqualToString(renderer.renderingMode(), $0) }) {
                found = renderer
            }
        }
        return found
    }

    /// `found` handed out as an orthogonal MPR without a check: with a fused
    /// series the viewer found is the PET-CT one, which -openOrthogonalMPRViewer
    /// has always returned under the orthogonal MPR's type.
    private func handedOutUnchecked(_ found: NSWindowController) -> OrthogonalMPRViewer {
        Unmanaged<OrthogonalMPRViewer>.fromOpaque(Unmanaged.passUnretained(found).toOpaque()).takeUnretainedValue()
    }

    /// The study date of the first file of movie frame `index`.
    private func studyDate(ofFrame index: Int) -> Date? {
        (viewer.horos_fileList(at: index)?.firstObject as? DicomImage)?.series?.study?.date
    }

    // MARK: - Making the viewers

    /// [[VRController alloc] initWithPix:::::style:mode:], given the viewer's
    /// own slice and file lists: Swift would pass the NSArray parameter a copy.
    private func makeVRController(_ pix: AnyObject, _ files: AnyObject, _ volume: NSData, style: String, mode: String?) -> VRController? {
        typealias Initializer = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject, AnyObject, NSData,
                                                ViewerController?, ViewerController?, NSString, NSString?) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString("initWithPix:::::style:mode:")
        let blending = viewer.horos_blending, owner = viewer
        guard let made = initialize(VRController.self, selector, { (implementation: IMP, instance: Unmanaged<AnyObject>) in
            unsafeBitCast(implementation, to: Initializer.self)(instance, selector, pix, files, volume, blending, owner,
                                                               style as NSString, mode as NSString?)
        }) else { return nil }
        return unsafeDowncast(made, to: VRController.self)
    }

    /// [[SRController alloc] initWithPix:::::], given the viewer's own slice
    /// and file lists.
    private func makeSRController(_ pix: AnyObject, _ files: AnyObject, _ volume: NSData) -> SRController? {
        typealias Initializer = @convention(c) (Unmanaged<AnyObject>, Selector, AnyObject, AnyObject, NSData,
                                                ViewerController?, ViewerController?) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString("initWithPix:::::")
        let blending = viewer.horos_blending, owner = viewer
        guard let made = initialize(SRController.self, selector, { (implementation: IMP, instance: Unmanaged<AnyObject>) in
            unsafeBitCast(implementation, to: Initializer.self)(instance, selector, pix, files, volume, blending, owner)
        }) else { return nil }
        return unsafeDowncast(made, to: SRController.self)
    }

    /// `[[cls alloc] init...]`: `call` sends the initializer to the allocated
    /// instance (which it consumes) and returns its retained result.
    private func initialize(_ cls: AnyClass, _ selector: Selector,
                            _ call: (IMP, Unmanaged<AnyObject>) -> Unmanaged<AnyObject>?) -> AnyObject? {
        guard let method = class_getInstanceMethod(cls, selector),
              let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        return call(method_getImplementation(method), allocated)?.takeRetainedValue()
    }

    /// [renderer addMoviePixList: pixList[i] :volumeData[i]], with the frame's
    /// own volume data: Swift would pass the Data parameter a copy of it.
    private func addMovie(_ i: Int, to renderer: VRController?) {
        _ = renderer?.perform(NSSelectorFromString("addMoviePixList::"), with: viewer.horos_pixList(at: i), with: viewer.horos_volumeData(at: i))
    }

    // MARK: - What the 3D viewer receives

    /// The window level the 2D viewer's image shows, read when asked.
    private var shownWindowLevel: (level: Float, width: Float) {
        var wl: Float = 0, ww: Float = 0
        viewer.horos_imageView?.getWLWW(&wl, &ww)
        return (wl, ww)
    }

    /// The PET colour table of the preferences ("B/W Inverse" or the default
    /// PET table) on `target`.
    private func applyPETColourTable(to target: AnyObject?) {
        let table = viewerIsEqualToString(preferences[ViewerPreferences.petCLUTMode], "B/W Inverse")
            ? "B/W Inverse" : preferences[ViewerPreferences.petDefaultCLUT]
        _ = target?.perform(NSSelectorFromString("ApplyCLUTString:"), with: table)
    }

    /// A 3D viewer releases itself when its window closes: the one created
    /// here keeps the reference its creator held in Objective-C.
    private func handOver(_ controller: AnyObject?) {
        guard let controller else { return }
        _ = Unmanaged.passRetained(controller)
    }

    /// `window`'s title followed by the 2D viewer's: "<3D title>: <2D title>".
    private func retitle(_ window: NSWindowController?) {
        window?.window?.title = "\(described(window?.window?.title)): \(described(viewer.window?.title))"
    }

    /// A string as %@ prints it: "(null)" for none.
    private func described(_ string: String?) -> String {
        string ?? "(null)"
    }

    private func alert(_ title: String, _ message: String) {
        HorosAlertPanel.run(title: title, message: message, defaultButton: nil, alternateButton: nil, otherButton: nil)
    }

    /// The title of `reconstruction`'s alerts.
    private static func title(of reconstruction: VolumeEligibility.Reconstruction) -> String {
        switch reconstruction {
        case .volumeRenderingPanel, .volumeRendering: return NSLocalizedString("Volume Rendering", comment: "")
        case .surfaceRendering: return NSLocalizedString("Surface Rendering", comment: "")
        case .endoscopy: return NSLocalizedString("Endoscopy", comment: "")
        case .orthogonalMPR, .obliqueMPR: return NSLocalizedString("MPR", comment: "")
        case .curvedMPR: return NSLocalizedString("CPR", comment: "")
        }
    }

    /// What `reconstruction` says when a time point is not a volume.
    private static func volumicRequirement(of reconstruction: VolumeEligibility.Reconstruction) -> String {
        switch reconstruction {
        case .volumeRenderingPanel, .volumeRendering: return NSLocalizedString("Volume Rendering requires volumic data.", comment: "")
        case .surfaceRendering: return NSLocalizedString("Surface Rendering requires volumic data.", comment: "")
        case .endoscopy: return NSLocalizedString("Endoscopy requires volumic data.", comment: "")
        case .orthogonalMPR, .obliqueMPR: return NSLocalizedString("MPR requires volumic data.", comment: "")
        case .curvedMPR: return NSLocalizedString("CPR requires volumic data and BW images.", comment: "")
        }
    }
}
