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

// Opening the 3D and MPR viewers from the 2D viewer: volume rendering (the
// window and the panel), surface rendering, the orthogonal MPR (and its
// PET-CT fusion), endoscopy, the oblique MPR, the CPR and the 3D region
// growing. Each action checks the data (volumic, the slice geometry, the 4D
// frames, the thickness and interval), brings forward a viewer already open
// on the same slices, or opens one with the window level, colour and opacity
// tables of this viewer and places it. The VTK and ITK viewers keep their
// Objective-C++ or Swift classes; they are created here through their
// initializers. A 3D viewer releases itself when its window closes: each one
// created here is handed over with that extra reference, as before. The
// selectors are those of the former Objective-C methods.

public extension ViewerController {

    /// The volume rendering panel (MIP), on the frame the player shows.
    @objc(Panel3D:)
    func panel3D(_ sender: Any!) {
        checkEverythingLoaded()
        clear8bitRepresentations()

        if !isDataVolumicIn4D(true) {
            alert(NSLocalizedString("Volume Rendering", comment: ""), NSLocalizedString("Volume Rendering requires volumic data.", comment: ""))
            return
        }
        if refuseFourDReconstruction(withTitle: NSLocalizedString("Volume Rendering", comment: "")) {
            return
        }

        if needsThicknessAndInterval() {
            setThicknessInterval(sender)
            return
        }

        displayAWarningIfNonTrueVolumicData()
        displayWarningIfGantryTitled()

        movieStop(self)

        var viewer = openRenderer(style: "panel", modes: nil)

        if let viewer {
            viewer.window?.makeKeyAndOrderFront(self)
            return
        }

        let movies = Int(horos_maxMovieIndex)
        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(horos_curMovieIndex), count: movies)
        guard let pix0 = horos_pixList(at: 0), let files0 = horos_fileList(at: 0), let volume0 = horos_volumeData(at: 0) as? NSData,
              let pixTime = horos_pixList(at: time) else { return }

        // Same ordering contract as openVRViewerForMode: time 0 first, then
        // the rest, so setMovieFrame: lands on the time the player shows.
        viewer = makeVRController(pix0, files0, volume0, style: "panel", mode: "MIP")
        handOver(viewer)
        for i in 1..<max(movies, 1) {
            addMovie(i, to: viewer)
        }
        viewer?.setMovieFrame(time)

        if !(pixTime.object(at: 0) as! DCMPix).isRGB && viewerIsEqualToString(modality(), "PT") {
            if horos_imageView?.curDCM?.suvConverted ?? false {
                viewer?.setWLWW(3, 6)
            } else {
                let first = pixTime.object(at: 0) as! DCMPix
                viewer?.setWLWW(first.maxValueOfSeries / 4, first.maxValueOfSeries / 2)
            }
        }

        viewer?.load3DState()

        if viewerIsEqualToString(modality(), "PT") && !(pixTime.object(at: 0) as! DCMPix).isRGB {
            applyPETColourTable(to: viewer)
            viewer?.applyOpacityString("Logarithmic Table")
        } else {
            var wl: Float = 0, ww: Float = 0
            horos_imageView?.getWLWW(&wl, &ww)
            viewer?.setWLWW(wl, ww)
        }

        viewer?.window?.setFrameOrigin(window?.screen?.visibleFrame.origin ?? .zero)
        viewer?.showWindow(self)
        viewer?.window?.makeKeyAndOrderFront(self)
        viewer?.window?.display()
        retitle(viewer)
    }

    /// The 3D region growing, on volumic data, or in 2D otherwise.
    @objc(segmentationTest:)
    func segmentationTest(_ sender: Any!) {
        let volumicData = isDataVolumicIn4D(false)

        if !volumicData {
            // Force 2D mode
            UserDefaults.standard.set(0, forKey: "growingRegionType")
        } else {
            displayAWarningIfNonTrueVolumicData()
        }

        clear8bitRepresentations()

        var ci = computeInterval()

        if (horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0) <= 1 { ci = 1 }

        let first = horos_pixList(at: 0)?.object(at: 0) as? DCMPix
        if ci == 0 || (first?.pixelSpacingX ?? 0) == 0 || (first?.pixelSpacingY ?? 0) == 0
            || (NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false) {
            setThicknessInterval(sender)
        } else if let itk = ITKSegmentation3DController.segmentationController(forViewer: self) {
            // The window this viewer already has.
            itk.showWindow(self)
            itk.window?.makeKeyAndOrderFront(self)
        } else {
            let itk = ITKSegmentation3DController(viewer: self)
            handOver(itk)
            itk.showWindow(self)
            itk.window?.makeKeyAndOrderFront(self)
        }
    }

    /// The volume rendering window in `mode` ("VR" or "MIP"): the one open in
    /// that mode on these slices, or a new one on every frame, showing the
    /// frame the player shows, prepared and ready to be shown; nil when the
    /// frames cannot be reconstructed.
    @objc(openVRViewerForMode:)
    func openVRViewer(forMode mode: String!) -> VRController! {
        checkEverythingLoaded()
        clear8bitRepresentations()
        movieStop(self)
        if fourDReconstructionRefusalReason() != nil {
            return nil
        }

        if let viewer = openRenderer(style: "standard", modes: ["VR", "MIP"]) {
            return viewer
        }

        let movies = Int(horos_maxMovieIndex)
        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(horos_curMovieIndex), count: movies)
        guard let pix0 = horos_pixList(at: 0), let files0 = horos_fileList(at: 0), let volume0 = horos_volumeData(at: 0) as? NSData,
              let pixTime = horos_pixList(at: time) else { return nil }

        // Time 0 first, then the remaining times in order: the renderer indexes
        // its own movie slots the way this viewer does, so the shared index is
        // a valid subscript there too.
        let viewer = makeVRController(pix0, files0, volume0, style: "standard", mode: mode)
        handOver(viewer)
        for i in 1..<max(movies, 1) {
            addMovie(i, to: viewer)
        }
        viewer?.setMovieFrame(time)

        if viewerIsEqualToString(modality(), "PT") && !(pixTime.object(at: 0) as! DCMPix).isRGB {
            if horos_imageView?.curDCM?.suvConverted ?? false {
                viewer?.setWLWW(2, 6)
            } else {
                let first = pixTime.object(at: 0) as! DCMPix
                viewer?.setWLWW(first.maxValueOfSeries / 2, first.maxValueOfSeries)
            }

            applyPETColourTable(to: viewer)
            viewer?.applyOpacityString("Logarithmic Table")
        } else {
            var wl: Float = 0, ww: Float = 0
            horos_imageView?.getWLWW(&wl, &ww)
            viewer?.setWLWW(wl, ww)
        }

        prepareNewVRViewer(viewer)
        return viewer
    }

    /// What a new volume rendering window needs before it can be shown, the
    /// same for the 3D Viewer menu and for any other caller of
    /// -openVRViewerForMode: (a plugin among them): this viewer's colour table
    /// and window level, the window placed on the 3D viewers' screen, and the
    /// saved 3D state loaded. Loading the state installs the rendering engine
    /// and frames the camera on the volume; a window created without it has a
    /// camera that frames nothing, and the volume has no mapper.
    private func prepareNewVRViewer(_ viewer: VRController?) {
        viewer?.applyCLUTString(horos_backCurCLUTMenu ?? horos_curCLUTMenu)
        var wl: Float = 0, ww: Float = 0
        horos_imageView?.getWLWW(&wl, &ww)
        viewer?.setWLWW(wl, ww)
        place3DViewerWindow(viewer)
        viewer?.load3DState()
    }

    /// Volume rendering (tag 3: MIP), in a window of its own.
    @objc(VRViewer:)
    func vrViewer(_ sender: Any!) {
        checkEverythingLoaded()
        clear8bitRepresentations()

        if !isDataVolumicIn4D(true) {
            alert(NSLocalizedString("Volume Rendering", comment: ""), NSLocalizedString("Volume Rendering requires volumic data.", comment: ""))
            return
        }
        if refuseFourDReconstruction(withTitle: NSLocalizedString("Volume Rendering", comment: "")) {
            return
        }

        if needsThicknessAndInterval() {
            setThicknessInterval(sender)
            return
        }

        displayAWarningIfNonTrueVolumicData()

        displayWarningIfGantryTitled()

        if !viewerIsEqualToString(horos_curConvMenu, NSLocalizedString("No Filter", comment: "")) {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Convolution", comment: ""),
                                                message: NSLocalizedString("Should I apply current convolution filter on raw data? 2D/3D post-processing viewers can only display raw data.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                otherButton: nil) == HorosAlertDefaultResponse {
                applyConvolutionOnSource(self)
            }
        }

        movieStop(self)

        if let viewer = openRenderer(style: "standard", modes: nil) {
            viewer.window?.makeKeyAndOrderFront(self)
            viewer.setModeIndex(ViewerSender.tag(sender) == 3 ? 1 : 0)
            return
        }

        // No window open in this style: the one made here comes prepared.
        let viewer = openVRViewer(forMode: ViewerSender.tag(sender) == 3 ? "MIP" : "VR")
        viewer?.showWindow(self)
        viewer?.window?.makeKeyAndOrderFront(self)
        viewer?.window?.display()
        retitle(viewer)
    }

    /// The surface rendering open on these slices, or a new one on the frame
    /// shown.
    @objc(openSRViewer)
    internal func openSRViewer() -> SRController! {
        checkEverythingLoaded()
        clear8bitRepresentations()
        if let found = AppController.shared()?.FindViewer("SR", horos_pixList(at: 0)) {
            return unsafeBitCast(found as AnyObject, to: SRController.self)
        }
        let time = FourDSeriesGuard.wrappedIndex(Int(horos_curMovieIndex), count: Int(horos_maxMovieIndex))
        guard let pix = horos_pixList(at: time), let files = horos_fileList(at: time), let volume = horos_volumeData(at: time) as? NSData else {
            return nil
        }
        let viewer = makeSRController(pix, files, volume)
        handOver(viewer)
        return viewer
    }

    /// Surface rendering.
    @objc(SRViewer:)
    func srViewer(_ sender: Any!) {
        checkEverythingLoaded()
        clear8bitRepresentations()

        if !isDataVolumicIn4D(true) {
            alert(NSLocalizedString("Surface Rendering", comment: ""), NSLocalizedString("Surface Rendering requires volumic data.", comment: ""))
            return
        }
        if refuseFourDReconstruction(withTitle: NSLocalizedString("Surface Rendering", comment: "")) {
            return
        }

        if needsThicknessAndInterval() {
            setThicknessInterval(sender)
            return
        }

        displayAWarningIfNonTrueVolumicData()
        displayWarningIfGantryTitled()

        movieStop(self)

        if let found = AppController.shared()?.FindViewer("SR", horos_pixList(at: 0)) {
            (found as? NSWindowController)?.window?.makeKeyAndOrderFront(self)
            return
        }

        let viewer = openSRViewer()
        place3DViewerWindow(viewer)
        viewer?.showWindow(self)
        viewer?.window?.makeKeyAndOrderFront(self)
        viewer?.changeSettings(self)
        retitle(viewer)
    }

    /// The orthogonal MPR open on these slices (its PET-CT fusion with a
    /// fused series), or a new one on the frame the player shows, with this
    /// viewer's tables and window level.
    @objc(openOrthogonalMPRViewer)
    func openOrthogonalMPRViewer() -> OrthogonalMPRViewer! {
        checkEverythingLoaded()
        clear8bitRepresentations()

        // With a fused series the viewer found is the PET-CT one, returned
        // under this type as before.
        if let found = AppController.shared()?.FindViewer(horos_blending != nil ? "PETCT" : "OrthogonalMPR", horos_pixList(at: 0)) {
            return unsafeBitCast(found as AnyObject, to: OrthogonalMPRViewer.self)
        }

        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(horos_curMovieIndex), count: Int(horos_maxMovieIndex))
        guard let pix = horos_pixList(at: time), let files = horos_fileList(at: time), let volume = horos_volumeData(at: time) as? NSData else {
            return nil
        }
        let viewer = OrthogonalMPRViewer(pixList: pix, files, volume, self, nil)
        handOver(viewer)

        let sww = horos_imageView?.curWW ?? 0
        let swl = horos_imageView?.curWL ?? 0

        let c = horos_backCurCLUTMenu ?? horos_curCLUTMenu

        if !(pix.object(at: 0) as! DCMPix).isRGB {
            if viewerIsEqualToString(modality(), "PT")
                || (UserDefaults.standard.bool(forKey: "clutNM") && viewerIsEqualToString(modality(), "NM")) {
                applyPETColourTable(to: viewer)
            } else {
                viewer?.applyCLUTString(c)
            }
        } else {
            viewer?.applyCLUTString(c)
        }

        viewer?.applyOpacityString(horos_curOpacityMenu)

        viewer?.setWLWW(swl, sww)

        return viewer
    }

    /// The orthogonal MPR of this series fused with its PET series: the one
    /// open, or a new one when the two planes are parallel (an alert
    /// otherwise), on the frame the player shows and the overlay's matching
    /// frame.
    @objc(openOrthogonalMPRPETCTViewer)
    func openOrthogonalMPRPETCTViewer() -> OrthogonalMPRPETCTViewer! {
        checkEverythingLoaded()
        clear8bitRepresentations()

        if let found = AppController.shared()?.FindViewer("PETCT", horos_pixList(at: 0)) {
            return unsafeBitCast(found as AnyObject, to: OrthogonalMPRPETCTViewer.self)
        }

        guard let blending = horos_blending else { return nil }

        var orientA = [Float](repeating: 0, count: 9), orientB = [Float](repeating: 0, count: 9)
        horos_imageView?.curDCM?.orientation(&orientA)
        blending.imageView()?.curDCM?.orientation(&orientB)

        let angle = orientA.withUnsafeMutableBufferPointer { a in
            orientB.withUnsafeMutableBufferPointer { b in DCMView.angleBetweenVector(a.baseAddress! + 6, andVector: b.baseAddress! + 6) }
        }
        if angle > UserDefaults.standard.float(forKey: "PARALLELPLANETOLERANCE") { // Planes are not parallel!
            HorosAlertPanel.runCritical(title: NSLocalizedString("2D Planes", comment: ""),
                                        message: NSLocalizedString("These 2D planes are not parallel, you cannot use the 2D Orthogonal MPR viewer. Instead, try the 3D MPR viewer.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        let movies = Int(horos_maxMovieIndex)
        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(horos_curMovieIndex), count: movies)
        guard let pix = horos_pixList(at: time), let files = horos_fileList(at: time), let volume = horos_volumeData(at: time) as? NSData else {
            return nil
        }
        let overlayTime = FourDSeriesGuard.fusionOverlayIndex(hostTime: time, hostCount: movies, overlayCount: Int(blending.maxMovieIndex()))
        if Int(blending.curMovieIndex()) != overlayTime {
            blending.setMovieIndex(Int16(truncatingIfNeeded: overlayTime))
        }
        let viewer = OrthogonalMPRPETCTViewer(pixList: pix, files, volume, self, blending)
        handOver(viewer)
        place3DViewerWindow(viewer)

        let c = horos_backCurCLUTMenu ?? horos_curCLUTMenu

        viewer?.CTController?.applyCLUTString(c)
        viewer?.PETController?.applyCLUTString(blending.curCLUTMenu())
        viewer?.PETCTController?.applyCLUTString(c)

        viewer?.CTController?.applyOpacityString(horos_curOpacityMenu)
        viewer?.PETController?.applyOpacityString(blending.curOpacityMenu())
        viewer?.PETCTController?.applyOpacityString(horos_curOpacityMenu)

        let fusion = viewer?.PETCTController
        for view in [fusion?.originalView(), fusion?.xReslicedView(), fusion?.yReslicedView()] {
            (view as? OrthogonalMPRPETCTView)?.setCurCLUTMenu(blending.curCLUTMenu())
        }
        for view in [fusion?.originalView(), fusion?.xReslicedView(), fusion?.yReslicedView()] {
            (view as? OrthogonalMPRPETCTView)?.setCurOpacityMenu(blending.curOpacityMenu())
        }

        viewer?.showWindow(self)

        var wl: Float = 0, ww: Float = 0
        horos_imageView?.getWLWW(&wl, &ww)
        viewer?.CTController?.setWLWW(wl, ww)
        blending.imageView()?.getWLWW(&wl, &ww)
        viewer?.PETController?.setWLWW(wl, ww)

        viewer?.setBlendingMode(UserDefaults.standard.integer(forKey: "DEFAULTPETFUSION"))

        return viewer
    }

    /// The orthogonal MPR (PET-CT with a fused series).
    @objc(orthogonalMPRViewer:)
    func orthogonalMPRViewer(_ sender: Any!) {
        checkEverythingLoaded()
        clear8bitRepresentations()

        if needsThicknessAndInterval() {
            setThicknessInterval(sender)
            return
        }

        if !isDataVolumicIn4D(true) {
            alert(NSLocalizedString("MPR", comment: ""), NSLocalizedString("MPR requires volumic data.", comment: ""))
            return
        }
        // A series that passes the volumic check can still be one this
        // reconstruction cannot resample - mixed matrices, mixed orientations, a
        // non-finite interval. The oblique MPR already names those; this
        // door drew empty planes instead.
        let geometry = reconstructionOpeningDecision()
        if !(geometry?.accepted ?? false) {
            alert(NSLocalizedString("MPR", comment: ""), geometry?.diagnosis ?? "")
            return
        }
        if refuseFourDReconstruction(withTitle: NSLocalizedString("MPR", comment: "")) {
            return
        }
        let blending = horos_blending
        if blending != nil && refuseFourDFusion(withTitle: NSLocalizedString("PET-CT Fusion", comment: "")) {
            return
        }

        displayAWarningIfNonTrueVolumicData()
        displayWarningIfGantryTitled()

        blending?.displayAWarningIfNonTrueVolumicData()
        blending?.displayWarningIfGantryTitled()

        movieStop(self)

        if let found = AppController.shared()?.FindViewer(blending != nil ? "PETCT" : "OrthogonalMPR", horos_pixList(at: 0)) {
            (found as? NSWindowController)?.window?.makeKeyAndOrderFront(self)
            return
        }

        if blending != nil {
            let pcviewer = openOrthogonalMPRPETCTViewer()
            let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(horos_curMovieIndex), count: Int(horos_maxMovieIndex))
            let studyDate = (horos_fileList(at: time)?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.study.date") as? Date
            let date = studyDate.map { UserDefaults.dateTimeFormatter().string(from: $0) }

            pcviewer?.window?.title = "\(described(pcviewer?.window?.title)): \(described(date)) - \(described(window?.title))"
        } else {
            let viewer = openOrthogonalMPRViewer()

            place3DViewerWindow(viewer)
            viewer?.showWindow(self)

            var wl: Float = 0, ww: Float = 0
            horos_imageView?.getWLWW(&wl, &ww)
            viewer?.setWLWW(wl, ww)

            let studyDate = (horos_fileList(at: 0)?.object(at: 0) as AnyObject?)?.value(forKeyPath: "series.study.date") as? Date
            viewer?.window?.title = "\(described(viewer?.window?.title)): \(described(UserDefaults.formatDateTime(studyDate))) - \(described(window?.title))"
        }
    }

    /// The endoscopy viewer open on these slices, or a new one on the frame
    /// the player shows.
    @objc(openEndoscopyViewer)
    func openEndoscopyViewer() -> EndoscopyViewer! {
        checkEverythingLoaded()
        clear8bitRepresentations()

        if let found = AppController.shared()?.FindViewer("Endoscopy", horos_pixList(at: 0)) {
            return unsafeBitCast(found as AnyObject, to: EndoscopyViewer.self)
        }

        let time = FourDSeriesGuard.alignedTimeIndex(requested: Int(horos_curMovieIndex), count: Int(horos_maxMovieIndex))
        guard let pix = horos_pixList(at: time), let files = horos_fileList(at: time), let volume = horos_volumeData(at: time) as? NSData else {
            return nil
        }
        let viewer = EndoscopyViewer(pixList: pix, files, volume, horos_blending, self)
        handOver(viewer)
        return viewer
    }

    /// The endoscopy viewer.
    @objc(endoscopyViewer:)
    func endoscopyViewer(_ sender: Any!) {
        checkEverythingLoaded()
        clear8bitRepresentations()

        if !isDataVolumicIn4D(true) {
            alert(NSLocalizedString("Endoscopy", comment: ""), NSLocalizedString("Endoscopy requires volumic data.", comment: ""))
            return
        }
        if refuseFourDReconstruction(withTitle: NSLocalizedString("Endoscopy", comment: "")) {
            return
        }

        if needsThicknessAndInterval() {
            setThicknessInterval(sender)
            return
        }

        displayAWarningIfNonTrueVolumicData()
        displayWarningIfGantryTitled()

        movieStop(self)

        if let found = AppController.shared()?.FindViewer("Endoscopy", horos_pixList(at: 0)) {
            (found as? NSWindowController)?.window?.makeKeyAndOrderFront(self)
            return
        }

        let viewer = openEndoscopyViewer()
        place3DViewerWindow(viewer)
        viewer?.showWindow(self)
        retitle(viewer)
    }

    /// The oblique MPR open on these slices, or a new one on every frame; nil
    /// when the frames cannot be reconstructed.
    @objc(openMPRViewer)
    func openMPRViewer() -> MPRController! {
        checkEverythingLoaded()
        clear8bitRepresentations()
        if fourDReconstructionRefusalReason() != nil {
            return nil
        }

        if let found = AppController.shared()?.FindViewer("MPR", horos_pixList(at: 0)) {
            return unsafeBitCast(found as AnyObject, to: MPRController.self)
        }

        let viewer = MPRController(dcmPixList: horos_pixList(at: 0), filesList: horos_fileList(at: 0), volumeData: horos_volumeData(at: 0) as? NSData,
                                   viewerController: self, fusedViewerController: horos_blending)
        handOver(viewer)
        for i in 1..<max(Int(horos_maxMovieIndex), 1) {
            viewer?.addMoviePixList(horos_pixList(at: i), horos_volumeData(at: i) as? NSData)
        }

        return viewer
    }

    /// The oblique MPR. From the Series Selection item of an MPR (`sender`),
    /// the new MPR takes the frame of the one it replaces.
    @objc(mprViewer:)
    func mprViewer(_ sender: Any!) {
        checkEverythingLoaded()
        clear8bitRepresentations()

        let geometry = reconstructionOpeningDecision()
        let interval = computeInterval()
        let firstPix = horos_pixList(at: 0)?.object(at: 0) as? DCMPix

        if viewerIsEqualToString(geometry?.phase, "calibrate") || interval == 0
            || (firstPix?.pixelSpacingX ?? 0) == 0 || (firstPix?.pixelSpacingY ?? 0) == 0
            || (NSApplication.shared.currentEvent?.modifierFlags.contains(.shift) ?? false) {
            setThicknessInterval(sender)
            return
        }
        if !(geometry?.accepted ?? false) {
            alert(NSLocalizedString("MPR", comment: ""), geometry?.diagnosis ?? "")
            return
        }

        if !isDataVolumicIn4D(true) {
            alert(NSLocalizedString("MPR", comment: ""), NSLocalizedString("MPR requires volumic data.", comment: ""))
            return
        }
        if refuseFourDReconstruction(withTitle: NSLocalizedString("MPR", comment: "")) {
            return
        }

        displayAWarningIfNonTrueVolumicData()
        displayWarningIfGantryTitled()

        movieStop(self)

        let found = AppController.shared()?.FindViewer("MPR", horos_pixList(at: 0)) as? NSWindowController

        // The Series Selection item of an MPR asks for the new series here and
        // closes itself afterwards: the MPR that replaces it takes its frame.
        let replacedMPRWindow = (sender as? MPRController)?.window

        if let found {
            if let replacedMPRWindow, found !== (sender as AnyObject?) {
                found.window?.setFrame(replacedMPRWindow.frame, display: true)
            }
            found.window?.makeKeyAndOrderFront(self)
            return
        }

        let viewer = openMPRViewer()
        if let replacedMPRWindow {
            viewer?.window?.setFrame(replacedMPRWindow.frame, display: false)
        } else {
            place3DViewerWindow(viewer)
        }
        viewer?.showWindow(self)
        retitle(viewer)
        DispatchQueue.main.async {
            viewer?.showWindow(self)
            viewer?.showWindow(self)
        }
    }

    /// The CPR open on these slices, or a new one on every frame; nil when
    /// the frames cannot be reconstructed.
    @objc(openCPRViewer)
    func openCPRViewer() -> CPRController! {
        checkEverythingLoaded()
        clear8bitRepresentations()
        if fourDReconstructionRefusalReason() != nil {
            return nil
        }

        if let found = AppController.shared()?.FindViewer("CPR", horos_pixList(at: 0)) {
            return unsafeBitCast(found as AnyObject, to: CPRController.self)
        }

        let viewer = CPRController(dcmPixList: horos_pixList(at: 0), filesList: horos_fileList(at: 0), volumeData: horos_volumeData(at: 0) as? NSData,
                                   viewerController: self, fusedViewerController: horos_blending)
        handOver(viewer)
        for i in 1..<max(Int(horos_maxMovieIndex), 1) {
            viewer?.addMoviePixList(horos_pixList(at: i), horos_volumeData(at: i) as? NSData)
        }

        return viewer
    }

    /// The CPR (curved MPR), on volumic black and white data.
    @objc(cprViewer:)
    func cprViewer(_ sender: Any!) {
        checkEverythingLoaded()
        clear8bitRepresentations()

        if needsThicknessAndInterval() {
            setThicknessInterval(sender)
            return
        }

        if !isDataVolumicIn4D(true) || (horos_imageView?.curDCM?.isRGB ?? false) {
            alert(NSLocalizedString("CPR", comment: ""), NSLocalizedString("CPR requires volumic data and BW images.", comment: ""))
            return
        }
        // The curved path a TAVR plan is drawn on is resampled from the same
        // volume, so the same geometry has to hold. Without this the CPR opened
        // on a series it could not resample and showed empty planes.
        let geometry = reconstructionOpeningDecision()
        if !(geometry?.accepted ?? false) {
            alert(NSLocalizedString("CPR", comment: ""), geometry?.diagnosis ?? "")
            return
        }
        if refuseFourDReconstruction(withTitle: NSLocalizedString("CPR", comment: "")) {
            return
        }

        displayAWarningIfNonTrueVolumicData()
        displayWarningIfGantryTitled()

        movieStop(self)

        if let found = AppController.shared()?.FindViewer("CPR", horos_pixList(at: 0)) {
            (found as? NSWindowController)?.window?.makeKeyAndOrderFront(self)
            return
        }

        let waitWindow = startWaitWindow(NSLocalizedString("Loading...", comment: ""))
        let viewer = openCPRViewer()
        place3DViewerWindow(viewer)
        viewer?.showWindow(self)
        retitle(viewer)
        DispatchQueue.main.async {
            viewer?.showWindow(self)
            viewer?.showWindow(self)
            self.endWaitWindow(waitWindow)
        }
    }
}

extension ViewerController {

    /// The volume rendering open on these slices in `style` (and, with
    /// `modes`, in one of those modes), its window not closing; the last one
    /// listed wins, as before.
    fileprivate func openRenderer(style: String, modes: [String]?) -> VRController? {
        var viewer: VRController?
        for case let candidate as NSWindowController in AppController.shared()?.FindRelatedViewers(horos_pixList(at: 0)) ?? [] {
            // Not a viewer whose window is closing, as -[AppController FindViewer::].
            guard viewerIsEqualToString(candidate.windowNibName, "VR") else { continue }
            let renderer = unsafeDowncast(candidate, to: VRController.self)
            guard !renderer.windowWillClose() else { continue }
            if viewerIsEqualToString(renderer.style(), style)
                && (modes == nil || modes!.contains { viewerIsEqualToString(renderer.renderingMode(), $0) }) {
                viewer = renderer
            }
        }
        return viewer
    }

    /// [[VRController alloc] initWithPix:::::style:mode:], given the
    /// viewer's own file list: Swift would pass the NSArray parameter a copy.
    fileprivate func makeVRController(_ pix: NSMutableArray, _ files: NSMutableArray, _ volume: NSData, style: String, mode: String?) -> VRController? {
        typealias Initializer = @convention(c) (Unmanaged<AnyObject>, Selector, NSMutableArray, NSArray, NSData,
                                                ViewerController?, ViewerController?, NSString, NSString?) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString("initWithPix:::::style:mode:")
        let blending = horos_blending, owner = self
        guard let made = initialize(VRController.self, selector, { (implementation: IMP, instance: Unmanaged<AnyObject>) in
            unsafeBitCast(implementation, to: Initializer.self)(instance, selector, pix, files, volume, blending, owner,
                                                               style as NSString, mode as NSString?)
        }) else { return nil }
        return unsafeDowncast(made, to: VRController.self)
    }

    /// [[SRController alloc] initWithPix:::::], given the viewer's own file
    /// list.
    fileprivate func makeSRController(_ pix: NSMutableArray, _ files: NSMutableArray, _ volume: NSData) -> SRController? {
        typealias Initializer = @convention(c) (Unmanaged<AnyObject>, Selector, NSMutableArray, NSArray, NSData,
                                                ViewerController?, ViewerController?) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString("initWithPix:::::")
        let blending = horos_blending, owner = self
        guard let made = initialize(SRController.self, selector, { (implementation: IMP, instance: Unmanaged<AnyObject>) in
            unsafeBitCast(implementation, to: Initializer.self)(instance, selector, pix, files, volume, blending, owner)
        }) else { return nil }
        return unsafeDowncast(made, to: SRController.self)
    }

    /// `[[cls alloc] init...]`: `call` sends the initializer to the allocated
    /// instance (which it consumes) and returns its retained result.
    fileprivate func initialize(_ cls: AnyClass, _ selector: Selector,
                                _ call: (IMP, Unmanaged<AnyObject>) -> Unmanaged<AnyObject>?) -> AnyObject? {
        guard let method = class_getInstanceMethod(cls, selector),
              let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        return call(method_getImplementation(method), allocated)?.takeRetainedValue()
    }

    /// [renderer addMoviePixList: pixList[i] :volumeData[i]], with the frame's
    /// own volume data: Swift would pass the Data parameter a copy of it.
    fileprivate func addMovie(_ i: Int, to renderer: VRController?) {
        _ = renderer?.perform(NSSelectorFromString("addMoviePixList::"), with: horos_pixList(at: i), with: horos_volumeData(at: i))
    }

    /// The PET colour table of the preferences ("B/W Inverse" or the default
    /// PET table) on `viewer`.
    fileprivate func applyPETColourTable(to viewer: AnyObject?) {
        let defaults = UserDefaults.standard
        let table = viewerIsEqualToString(defaults.string(forKey: "PET Clut Mode"), "B/W Inverse") ? "B/W Inverse" : defaults.string(forKey: "PET Default CLUT")
        _ = viewer?.perform(NSSelectorFromString("ApplyCLUTString:"), with: table)
    }

    /// A 3D viewer releases itself when its window closes: the one created
    /// here keeps the reference its creator held in Objective-C.
    fileprivate func handOver(_ controller: AnyObject?) {
        guard let controller else { return }
        _ = Unmanaged.passRetained(controller)
    }

    /// `viewer`'s title followed by this viewer's: "<3D title>: <2D title>".
    fileprivate func retitle(_ viewer: NSWindowController?) {
        viewer?.window?.title = "\(described(viewer?.window?.title)): \(described(window?.title))"
    }

    /// A string as %@ prints it: "(null)" for none.
    fileprivate func described(_ string: String?) -> String {
        string ?? "(null)"
    }

    fileprivate func alert(_ title: String, _ message: String) {
        HorosAlertPanel.run(title: title, message: message, defaultButton: nil, alternateButton: nil, otherButton: nil)
    }
}
