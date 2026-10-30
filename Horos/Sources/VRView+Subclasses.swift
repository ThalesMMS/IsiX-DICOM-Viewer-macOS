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

import AppKit
import IsiXVolumeRendering

// What the Swift subclasses of VRView (EndoscopyVRView.swift and
// VRPresetPreview.swift) reach of the class: values set without the side
// effects of the class's setters, and the 3D presets' previews' own VTK
// pipeline, which the view makes through its VTK adapter. The preview's
// pipeline was VRPresetPreview.mm's -setPixSource:: and -setMapper:, kept
// with the rest of the view's VTK code.

extension VRView {

    /// The nib's sheet of the DICOM export.
    var horosExportDCMWindow: NSWindow? { exportDCMWindow }

    /// The factor the full-size render is drawn at.
    func horosSetSuperSampling(_ value: Float) { horos_superSampling = value }

    /// The level of detail's value, set without rendering.
    func horosSetLODValue(_ value: Float) { horos_LOD = value }

    /// The engine's value, set without switching the engine.
    func horosSetEngineValue(_ value: Int32) { horos_engine = value }

    /// The volume's factor and offset into VTK's 16 bits.
    func horosSetValueFactor(_ factor: Float, offset: Float) {
        horos_valueFactor = factor
        horos_OFFSET16 = offset
    }

    /// A preset preview's pipeline: the importer, the transfer functions, the
    /// volume and its property, the crop box, the 2D actors and the camera, as
    /// the main view builds them, for a preview that shows the main view's
    /// volume through the mapper it adopts afterwards. 0, as -setPixSource:: answers.
    func horosBuildPresetPreviewPipeline(withPix pix: NSMutableArray, volume volumeData: UnsafeMutablePointer<Float>?) -> Int16 {
        let error: Int16 = 0

        window?.acceptsMouseMovedEvents = true

        _ = Unmanaged.passUnretained(pix).retain()
        horos_pixList = pix

        horos_data = volumeData

        let vtk = horos_vtk
        vtk.useOwnRenderer()

        let firstObject = unsafeBitCast(pix.object(at: 0) as AnyObject, to: DCMPix.self)
        horos_firstObject = firstObject
        var sliceThickness = Float(firstObject.sliceInterval)

        if sliceThickness == 0 {
            NSLog("slice interval = slice thickness!")
            sliceThickness = Float(firstObject.sliceThickness)
        }

        horos_wl = firstObject.wl
        horos_ww = firstObject.ww

        horos_isRGB = false
        if firstObject.isRGB {
            horos_isRGB = true
        }

        computeValueFactor()

        let isRGB = horos_isRGB
        // The Objective-C passed the pointer as it was, NULL included.
        let voxels = unsafeBitCast(isRGB ? UnsafeMutableRawPointer(horos_data) : UnsafeMutableRawPointer(horos_data8),
                                   to: UnsafeMutableRawPointer.self)
        do {
            try vtk.makePreviewImport(voxels, rgb: isRGB, width: firstObject.pwidth, height: firstObject.pheight,
                                      depth: pix.count)
        } catch {
            NSLog("horosBuildPresetPreviewPipeline: %@", error as NSError)
        }
        firstObject.orientation(horos_cosines)

        horos_factor = 1.0

        horos_needToFlip = false
        if sliceThickness < 0 {
            sliceThickness = abs(sliceThickness)
            NSLog("We should not be here....")
            horos_needToFlip = true
            NSLog("Flip !!")
        }

        // A float over a double: the quotient is a double, stored as a float.
        horos_factor = Float(Double(UserDefaults.standard.float(forKey: "superSampling")) / firstObject.pixelSpacingX)
        let factor = horos_factor
        if firstObject.pixelSpacingX == 0 || firstObject.pixelSpacingY == 0 {
            vtk.setImportSpacingX(1, y: 1, z: Double(sliceThickness))
        } else {
            vtk.setImportSpacingX(Double(factor) * firstObject.pixelSpacingX, y: Double(factor) * firstObject.pixelSpacingY,
                                  z: Double(factor * sliceThickness))
        }

        do {
            try vtk.makePreviewTransferFunctionsRGB(isRGB)
        } catch {
            NSLog("horosBuildPresetPreviewPipeline: %@", error as NSError)
        }

        setCLUT(nil, nil, nil)

        setShadingValues(0.15, 0.9, 0.3, 15)

        let nearest = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false

        horos_LOD = 1.0

        let wl = horos_wl, ww = horos_ww
        let text = ww < 50 ? String(format: "WL: %0.4f WW: %0.4f", Double(wl), Double(ww))
                           : String(format: "WL: %0.f WW: %0.f", Double(wl), Double(ww))
        _ = strlcpy(horos_WLWWString, text, 200)

        do {
            try vtk.makePreviewVolumeNearest(nearest, cosines: horos_cosines, factor: factor, originX: firstObject.originX,
                                             y: firstObject.originY, z: firstObject.originZ, windowText: horos_WLWWString)
        } catch {
            NSLog("horosBuildPresetPreviewPipeline: %@", error as NSError)
        }

        horos_firstTime = false

        saView(self)

        needsDisplay = true

        return error
    }

    /// A preview's own ray caster over the input of `source`, the main view's
    /// mapper (a vtkVolumeMapper *), with its blend mode and sampling; drawn by
    /// Metal like the main view's when `source` is. VTK's image display helper
    /// owns context-specific textures, shaders and VAOs: the input pipeline is
    /// shared with another view, not that rendering state. The adapter answers
    /// NO to no mapper, which is where the guard returns.
    func horosAdoptPreviewMapper(_ source: UnsafeMutableRawPointer?) {
        guard let source else { return }
        if horos_vtk.adoptPreviewMapper(of: source) {
            willChangeValue(forKey: "engine")
            horos_engine = 2
            didChangeValue(forKey: "engine")
        }
    }

    /// The renderer shows the volume, or stops showing it.
    func horosShowVolume(_ shown: Bool) {
        horos_vtk.showVolume(shown)
    }

    /// The mapper's minimum image sample distance set to the level of detail.
    func horosApplyLODToMapper() {
        horos_vtk.setVolumeMinimumImageSampleDistance(horos_LOD)
    }

    /// Forgets the 8-bit volume the main view lent the preview without freeing
    /// it (the main view frees it).
    func horosForgetSharedData8() {
        horos_data8 = nil
    }

    /// The arrow cursor, set as -setCursorForView: sets a tool's.
    func horosSetArrowCursor() {
        let c = NSCursor.arrow

        if c !== horos_cursor {
            horos_cursor = c
            window?.invalidateCursorRects(for: self)
            resetCursorRects()
            horos_cursor?.set()
        }
    }
}
