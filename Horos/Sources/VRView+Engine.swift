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
import IsiXPreferences

// The engines and modes of VRView: the rendering mode (volume, maximum,
// minimum, mean) of the volume and of the fused series, the engine that draws
// them (Metal, with VTK's ray cast mapper standing in for what Metal declines,
// or the CPU ray cast of the MPR's hidden view), the shading, the level of
// detail and the best rendering of the exports. A Swift extension of the
// class, with the same selectors and properties. The @try of
// -instantiateEngine: is HorosObjCException, with the same log.

extension VRView {

    // MARK: - Modes

    @objc(setBlendingMode:)
    func setBlendingMode(_ modeID: Int) {
        if horos_blendingController == nil { return }

        horos_vtk.setBlendingBlendMode(modeID)
    }

    @objc(mode)
    func mode() -> Int {
        return renderingMode
    }

    @objc(setRenderMode:)
    func setRenderMode(_ sender: Any?) {
        let modeID = (sender as AnyObject?)?.tag ?? 0
        setMode(modeID)
        setBlendingMode(modeID)
    }

    @objc(setMode:)
    func setMode(_ modeID: Int) {
        renderingMode = modeID

        // 0 volume, 1 maximum, 2 minimum, 3 mean: a minimum-intensity blend that
        // averages, a mode of the mapper.
        horos_vtk.setVolumeBlendMode(modeID)

        // A fused series follows the view's mode, as setBlendingEngine: sets it
        // when fusing; its opacity table below already does.
        setBlendingMode(modeID)

        setBlendingFactor(horos_blendingFactor)

        setWLWW(horos_wl, horos_ww)

        needsDisplay = true
    }

    // MARK: - Engines

    /// The engine: setting it prepares it under the wait window.
    @objc dynamic var engine: Int32 {
        get { horos_engine }
        set { setEngine(Int(newValue), showWait: true) }
    }

    /// The level of detail the LOD slider shows: setting it sets the LOD.
    @objc dynamic var lodDisplayed: Float {
        get { horos_lodDisplayed }
        set { setLOD(newValue) }
    }

    @objc(testGraphicBoard)
    static func testGraphicBoard() {
        let vramMB = Int32(truncatingIfNeeded: DefaultPreferences.gpuModelVRAMInfo())

        if UserDefaults.standard.integer(forKey: "VRAMAmount") != Int(vramMB) {
            if vramMB >= 2000 && AppController.hasMacOSXLion() {
                UserDefaults.standard.set(1, forKey: "VRDefaultViewSize") // full screen
            } else {
                UserDefaults.standard.set(0, forKey: "VRDefaultViewSize") // square
            }

            // The board decides the view size. The VR draws with Metal whatever the
            // board, and there is no engine left to choose.

            UserDefaults.standard.set(Int(vramMB), forKey: "VRAMAmount")

            NSLog("--- Changing Volume Rendering settings (vram: %d)", vramMB)
        }
    }

    @objc(allocateCPUMapper)
    func allocateCPUMapper() {
        horos_vtk.allocateVolumeMapper()
    }

    @objc(instantiateEngine:)
    func instantiateEngine(_ e: Int32) {
        if let exception = HorosObjCException.caught({ self.instantiate(engine: e) }) {
            NSLog("setEngine exception: %@", exception)
        }
    }

    /// The body of the @try of -instantiateEngine:.
    private func instantiate(engine e: Int32) {
        let vtk = horos_vtk
        // The crop in place - the box widget's or a saved camera's - carries
        // over to the new engine. Executing the crop callback re-applied the
        // widget's planes, and a camera's crop was lost at every switch.
        vtk.holdAppliedCrop()

        switch e {
        case 0, // FIXED RAY CAST
             2: // Metal image, with the same mapper for CPU fallback.
            allocateCPUMapper()

            horos_LOD = 2.0

            if ProcessInfo.processInfo.processorCount >= 4 {
                lowResLODFactor = 1.5
            } else {
                lowResLODFactor = 2.5
            }

        default:
            NSLog("Unknown Engine")
        }

        setLOD(horos_LOD)
        setMode(renderingMode) // VR or MIP ?

        if !horos_firstTime {
            if !vtk.applyHeldCrop() {
                vtk.executeCropCallback()
            }
        } else {
            if horos_controller?.style() != "noNib" {
                resetImage(self)
                vtk.placeCropBox()
            }
        }

        let LOD = horos_LOD
        vtk.setVolumeMinimumImageSampleDistance(LOD, sampleDistance: UserDefaults.standard.float(forKey: "BESTRENDERING"),
                                                maximumImageSampleDistance: LOD * lowResLODFactor)

        vtk.releaseHeldCrop()
    }

    @objc(setEngine:showWait:)
    dynamic func setEngine(_ newEngine: Int, showWait: Bool) {
        // Nothing draws VTK's engines any more: a view on screen renders
        // with Metal, the ray cast mapper standing in for what Metal declines, and
        // the MPR's hidden view casts on the CPU. VTK's GPU mapper needed OpenGL.
        let newEngine = VRInteractionGeometry.drawnEngine(for: newEngine, hidden: horos_controller?.style() == "noNib")

        willChangeValue(forKey: "engine")
        horos_engine = Int32(truncatingIfNeeded: newEngine)
        didChangeValue(forKey: "engine")

        var www: WaitRendering? = nil

        if showWait { www = WaitRendering(NSLocalizedString("Preparing 3D data...", comment: "")) }
        www?.start()

        instantiateEngine(horos_engine)

        switch horos_engine {
        case 0, 2: horos_vtk.attachVolumeMapper()
        default: break
        }

        if horos_engine != 2 { horos_controller?.horosVolumeMetalRelease() }
        display()

        www?.end()
        www?.close()
    }

    // The engine, and with it the volume's mapper, is installed by the first
    // -setEngine:, which -set3DStateDictionary: makes when the controller loads
    // its 3D state. A controller that never loaded it has a volume with no
    // mapper, and the crop box clipped a null one.
    @objc(installEngineIfNeeded)
    func installEngineIfNeeded() {
        let vtk = horos_vtk
        if vtk.hasVolume && !vtk.volumeHasMapper {
            setEngine(2, showWait: false)
        }
    }

    @objc(setBlendingEngine:)
    func setBlendingEngine(_ engineID: Int) {
        setBlendingEngine(engineID, showWait: true)
    }

    @objc(setBlendingEngine:showWait:)
    func setBlendingEngine(_ engineID: Int, showWait: Bool) {
        if horos_blendingController == nil { return }
        let vtk = horos_vtk

        let engineID = VRInteractionGeometry.drawnEngine(for: engineID, hidden: horos_controller?.style() == "noNib")

        var www: WaitRendering? = nil

        if showWait { www = WaitRendering(NSLocalizedString("Preparing 3D data...", comment: "")) }
        www?.start()

        switch engineID {
        case 0, // RAY CAST
             2: // Metal, which renders the blended volume with the ray cast mapper
            // The fused series ray-casts in Metal too; VTK composes its image
            // over the volume's.
            vtk.attachBlendingMapper()
        default:
            break
        }

        setLOD(horos_LOD)

        setBlendingMode(renderingMode)

        if !horos_firstTime {
            // The fused series takes the crop in place, which a saved camera may
            // have set without moving the widget.
            if !vtk.reapplyAppliedCrop() {
                vtk.executeCropCallback()
            }
        } else {
            if horos_controller?.style() != "noNib" {
                resetImage(self)

                vtk.placeCropBox()
            }
        }

        display()

        www?.end()
        www?.close()
    }

    // MARK: - Shading

    @objc(setShadingValues::::)
    dynamic func setShadingValues(_ ambient: Float, _ diffuse: Float, _ specular: Float, _ specularpower: Float) {
        let vtk = horos_vtk
        if !vtk.hasProperty {
            return
        }

        vtk.setShadingAmbient(ambient, diffuse: diffuse, specular: specular, power: specularpower)
    }

    @objc(getShadingValues::::)
    func getShadingValues(_ ambient: UnsafeMutablePointer<Float>!, _ diffuse: UnsafeMutablePointer<Float>!,
                          _ specular: UnsafeMutablePointer<Float>!, _ specularpower: UnsafeMutablePointer<Float>!) {
        let vtk = horos_vtk
        if !vtk.hasProperty {
            return
        }

        vtk.getShadingAmbient(ambient, diffuse: diffuse, specular: specular, power: specularpower)
    }

    @objc(shading)
    func shading() -> Int {
        let vtk = horos_vtk
        if !vtk.hasProperty {
            return 0
        }

        return vtk.shade
    }

    @objc(activateShading:)
    func activateShading(_ on: Bool) {
        horos_vtk.shade = on ? 1 : 0
    }

    @objc(switchShading:)
    func switchShading(_ sender: Any?) {
        let on = ((sender as? NSObject)?.value(forKey: "state") as? Int) == NSControl.StateValue.on.rawValue
        horos_vtk.shade = on ? 1 : 0

        let www: WaitRendering? = WaitRendering(NSLocalizedString("Preparing 3D data...", comment: ""))
        www?.start()

        display()
        www?.end()
        www?.close()
    }

    // MARK: - Level of detail

    @objc(LOD)
    func lod() -> Float {
        return horos_LOD
    }

    @objc(setLOD:)
    func setLOD(_ f: Float) {
        let vtk = horos_vtk
        willChangeValue(forKey: "lodDisplayed")
        horos_lodDisplayed = f
        didChangeValue(forKey: "lodDisplayed")

        horos_LOD = f

        if horos_engine == 0 {
            if horos_controller?.style() == "noNib" {
                if horos_LOD < 1.0 {
                    horos_LOD = 1.0
                }
            } else {
                if horos_LOD < 1.3 {
                    horos_LOD = 1.3
                }
            }
        }

        let LOD = horos_LOD
        let best = UserDefaults.standard.float(forKey: "BESTRENDERING")
        vtk.setVolumeAutoAdjustSampleDistances(true)
        vtk.setVolumeMinimumImageSampleDistance(LOD, sampleDistance: best, maximumImageSampleDistance: LOD * lowResLODFactor)

        vtk.setBlendingAutoAdjustSampleDistances(true)
        vtk.setBlendingMinimumImageSampleDistance(LOD, sampleDistance: best, maximumImageSampleDistance: LOD * lowResLODFactor)

        needsDisplay = true
    }

    @objc(setLODLow:)
    func setLODLow(_ l: Bool) {
        let vtk = horos_vtk
        let LOD = horos_LOD
        if l {
            vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)
        } else {
            vtk.setVolumeMinimumImageSampleDistance(LOD)
        }

        if l {
            vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)
        } else {
            vtk.setBlendingMinimumImageSampleDistance(LOD)
        }

        needsDisplay = true
    }

    // MARK: - Best rendering

    @objc(endRenderImageWithBestQuality)
    func endRenderImageWithBestQuality() {
        let vtk = horos_vtk
        // Standard Rendering...

        vtk.setVolumeMinimumImageSampleDistance(horos_LOD)
        vtk.setVolumeSampleDistance(UserDefaults.standard.float(forKey: "BESTRENDERING"))

        if horos_blendingController != nil {
            vtk.setBlendingMinimumImageSampleDistance(horos_LOD)
            vtk.setBlendingSampleDistance(UserDefaults.standard.float(forKey: "BESTRENDERING"))
        }

        vtk.showCornerText(true)

        horos_splash?.setCancel(false)

        if horos_splash?.aborted() ?? false { display() }
    }

    @objc(renderImageWithBestQuality:waitDialog:)
    func renderImage(withBestQuality best: Bool, waitDialog wait: Bool) {
        return renderImage(withBestQuality: best, waitDialog: wait, display: true)
    }

    @objc(renderImageWithBestQuality:waitDialog:display:)
    func renderImage(withBestQuality best: Bool, waitDialog wait: Bool, display: Bool) {
        let vtk = horos_vtk
        horos_splash?.setCancel(true)

        // REMOVE CROPPING BOX

        vtk.hideCropBox()

        vtk.removeOutline()
        vtk.showCornerText(false)

        // RAY CASTING SETTINGS
        if best {
            if (NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) || horos_projectionMode == 2 {
                vtk.setVolumeMinimumImageSampleDistance(1.0)
                vtk.setVolumeSampleDistance(1.0)

                if horos_blendingController != nil {
                    vtk.setBlendingMinimumImageSampleDistance(1.0)
                    vtk.setBlendingSampleDistance(1.0)
                }

                NSLog("resol = 1.0")
            } else {
                vtk.setVolumeMinimumImageSampleDistance(UserDefaults.standard.float(forKey: "BESTRENDERING"))
                vtk.setVolumeSampleDistance(UserDefaults.standard.float(forKey: "BESTRENDERING"))

                if horos_blendingController != nil {
                    vtk.setBlendingMinimumImageSampleDistance(UserDefaults.standard.float(forKey: "BESTRENDERING"))
                    vtk.setBlendingSampleDistance(UserDefaults.standard.float(forKey: "BESTRENDERING"))
                }
            }
        }

        if display {
            if !wait { horos_noWaitDialog = true }

            if IsiXVTKVolumeView.volumeRenderingSuppressed {
                render()
            } else {
                self.display()
            }

            if !wait { horos_noWaitDialog = false }
        }

        horos_bestRenderingWasGenerated = true
    }

    @objc(bestRendering:)
    func bestRendering(_ sender: Any?) {
        NSLog("start Best")
        renderImage(withBestQuality: true, waitDialog: true)
        endRenderImageWithBestQuality()
        NSLog("end Best")
    }
}
