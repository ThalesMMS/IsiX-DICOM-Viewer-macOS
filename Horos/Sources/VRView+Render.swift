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
import QuartzCore

// The frames of VRView and how they reach the screen: the frame's cycle
// (-drawRect:, its render and the first frame's completion), the renders
// without a frame (-render, -renderBlendedVolume), the Metal layer the picture
// is presented in and the size VTK's window is told, the 2D layer over it,
// stereo, the low-resolution frame, the view's frame and the Metal hook of the
// VTK adapter. A Swift extension of the class, with the same selectors.
//
// The @try of -drawRect: and of -horosRenderFrame are HorosObjCException,
// with the same log and the same failed frame.

extension VRView {

    // MARK: - Renders

    @objc(render)
    func render() {
        // This renders without going through drawRect:, which is the only place
        // that used to start the interactor. Ask for the window first, and stop if
        // there is none: the alternative is a context that belongs to nothing.
        if !prepareRenderWindow() {
            return
        }

        horos_vtk.castVolumeImageFused(false)
    }

    @objc(renderBlendedVolume)
    func renderBlendedVolume() {
        if !prepareRenderWindow() {
            return
        }

        horos_vtk.castVolumeImageFused(true)
    }

    @objc(displayVTKError)
    func displayVTKError() {
        if !horos_alertDisplayed {
            horos_alertDisplayed = true

            NSLog("C++ Exception during drawRect... not enough memory?")

            HorosAlertPanel.run(title: NSLocalizedString("Not enough memory", comment: ""),
                                message: NSLocalizedString("Cannot use the 3D engine.\r\rClose other studies or open a smaller series. Nothing was reduced silently.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

            window?.performClose(self)
        }
    }

    // MARK: - The frame

    public override func draw(_ aRect: NSRect) {
        if VRView.horos_drawLock == nil { VRView.horos_drawLock = NSRecursiveLock() }

        minimumStep = 0

        if let e = HorosObjCException.caught({
            // The frame's cycle: the first frame's preparation, the
            // render's outcome and the completion.
            let frame = VRFrameCycle.begin(firstFrame: self.horos_firstTime)
            self.horos_firstTime = false

            if frame.render(succeeded: self.horosRenderFrame(), errorShown: self.horos_alertDisplayed) {
                self.perform(#selector(self.displayVTKError), with: nil, afterDelay: 0.1)
            }

            if frame.finish() == .firstFrameDone {
                self.horosFinishFirstFrame()
            }

            self.horos_hasChanged = true
        }) {
            NSLog("Exception during drawRect: %@", e)
        }
    }

    /// The frame's drawing: the line measurements projected on the volume, the
    /// orientation text and VTK's render, stereo included. NO when VTK threw
    /// during the render, which the VTK adapter catches.
    @objc(horosRenderFrame)
    func horosRenderFrame() -> Bool {
        // An Objective-C exception on the way fails the frame too, as the C++
        // catch-all that wrapped it did.
        var rendered = true
        if HorosObjCException.caught({
            self.updateLineMeasurementProjections()
            self.computeOrientationText()

            if self.prepareRenderWindow() {
                rendered = (try? self.horos_vtk.renderWindow()) != nil
            }
        }) != nil {
            return false
        }
        return rendered
    }

    /// After the first frame: a 4D volume gets back the two marker pixels its
    /// preparation borrowed, and its 16-bit copy is converted again.
    @objc(horosFinishFirstFrame)
    func horosFinishFirstFrame() {
        if !horos_isRGB && (horos_controller?.viewer2D()?.maxMovieIndex() ?? 0) > 1 {
            let data = horos_data!
            let width = Int(horos_firstObject?.pwidth ?? 0)
            data[0 + width] = horos_firstPixel
            data[1 + width] = horos_secondPixel

            BrowserController.multiThreadedImageConvert("FTo16U", horos_srcf, horos_dst8, -horos_OFFSET16,
                                                        Float(1.0 / Double(horos_valueFactor)))
            applyMovieRangeGuardTo16BitVolume()
        }
    }

    @objc(displayLowRes)
    func displayLowRes() {
        let vtk = horos_vtk
        vtk.setVolumeMinimumImageSampleDistance(horos_LOD * lowResLODFactor)
        vtk.setBlendingMinimumImageSampleDistance(horos_LOD * lowResLODFactor)

        if needsDisplay {
            display()
        }

        vtk.setVolumeMinimumImageSampleDistance(horos_LOD)
        vtk.setBlendingMinimumImageSampleDistance(horos_LOD)
    }

    @objc(imageSampleDistance)
    func imageSampleDistance() -> Float {
        let vtk = horos_vtk
        if vtk.hasVolumeMapper {
            return Float(vtk.rayCastImageInfoFused(false).sampleDistance)
        } else {
            return 0
        }
    }

    @objc(blendingImageSampleDistance)
    func blendingImageSampleDistance() -> Float {
        let vtk = horos_vtk
        if vtk.hasBlendingMapper {
            return Float(vtk.rayCastImageInfoFused(true).sampleDistance)
        } else {
            return 0
        }
    }

    // MARK: - Presentation without OpenGL

    @objc(renderer)
    func renderer() -> UnsafeMutableRawPointer? { horos_vtk.rendererHandle }

    @objc(renderWindow)
    func renderWindow() -> UnsafeMutableRawPointer? { horos_vtk.renderWindowHandle }

    @objc(getVTKRenderWindow)
    func getVTKRenderWindow() -> UnsafeMutableRawPointer? { horos_vtk.renderWindowHandle }

    public override var wantsUpdateLayer: Bool { true }

    public override var isOpaque: Bool { true }

    public override func updateLayer() { draw(bounds) }

    // The frame is drawn by Metal into a layer of its own, the first of the view's
    // layer: the overlay's text and graphics are above it.
    @objc(horosPictureLayer)
    func horosPictureLayer() -> CAMetalLayer? {
        guard let host = layer else { return nil }
        var picture = (horos_horosPresenter as? VRPresenter)?.layer
        if picture == nil {
            let created = CAMetalLayer()
            created.device = PlanarHostRenderer.device
            // Shown with the transaction that shows the overlay, so the two never
            // show different frames.
            created.presentsWithTransaction = true
            created.isOpaque = true
            created.anchorPoint = .zero
            created.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            guard let presenter = VRPresenter(layer: created) else { return nil }
            horos_horosPresenter = presenter
            // HorosVRPresenter draws for the adapter (VTKAdapterDrawing.h).
            horos_vtk.setPresenter(presenter as AnyObject as? IsiXVTKFramePresenter)
            picture = created
        }
        guard let picture else { return nil }
        if picture.superlayer !== host || host.sublayers?.first !== picture {
            picture.removeFromSuperlayer()
            host.insertSublayer(picture, at: 0)
        }
        return picture
    }

    // VTK's window measured the view in pixels whenever it was asked; this one
    // is told, whenever the view's size or scale changes, and before a render.
    @objc(prepareRenderWindow) @discardableResult
    func prepareRenderWindow() -> Bool {
        // The view's frame is set by NSView's initializer, before the adapter exists.
        guard let vtk = horos_vtkIfAny else { return false }
        let scale: CGFloat = (window?.backingScaleFactor ?? 0) > 0 ? window!.backingScaleFactor : 1
        var size = window != nil ? convertToBacking(bounds.size) : bounds.size
        let stereo = horos_horosStereo as? StereoPresentation
        // The two eyes side by side render at half the width each.
        if let stereo { size = stereo.renderSize(forBacking: size) }
        let width = max(1, Int32(truncatingIfNeeded: lround(Double(size.width))))
        let height = max(1, Int32(truncatingIfNeeded: lround(Double(size.height))))
        // For text actors, the DPI as vtkCocoaGLView set it.
        vtk.setWindowWidth(width, height: height, dpi: lround(72.0 * Double(scale)))
        guard let window else { return false }

        if let picture = horosPictureLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.contentsScale = scale
            picture.frame = bounds
            // OpenGL put its bytes on the screen untouched, which is what a layer in
            // the screen's own colour space does.
            if let space = window.colorSpace?.cgColorSpace, picture.colorspace !== space {
                picture.colorspace = space
            }
            CATransaction.commit()
            let drawable = CGSize(width: CGFloat(width), height: CGFloat(height))
            if !picture.drawableSize.equalTo(drawable) {
                picture.drawableSize = drawable
            }
            stereo?.layout(picture: picture, bounds: bounds, scale: scale, renderSize: drawable)
        }
        return true
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        _ = prepareRenderWindow()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        _ = prepareRenderWindow()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        _ = prepareRenderWindow()
        needsDisplay = true
    }

    // Mouse moves reach the view whether or not it has the focus, as with
    // vtkCocoaGLView's tracking area.
    public override func updateTrackingAreas() {
        for area in trackingAreas where (area.owner as AnyObject?) === self && area.options.contains(.mouseMoved) {
            removeTrackingArea(area)
        }
        let moves = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
        addTrackingArea(moves)
        super.updateTrackingAreas()
    }

    // MARK: - The view's frame

    @objc(setFrame:rescaleLine:)
    func setFrame(_ r: NSRect, rescaleLine rescale: Bool) {
        if horos_controller?.style() != "noNib" {
            adaptLine2D(toResize: r, before: frame, cameraZoom: 1.0)
        }

        super.frame = r
    }

    public override var frame: NSRect {
        get { super.frame }
        set { setFrame(newValue, rescaleLine: false) }
    }

    @objc(ViewFrameDidChangeNotification:)
    func viewFrameDidChangeNotification(_ note: Notification) {
        horos_vtk.placeWindowText(belowTop: 15)
    }

    // NSView's -print:.
    public override func printView(_ sender: Any?) {
        bestRenderingMode = true

        _ = horos_controller?.perform(NSSelectorFromString("print:"), with: sender)
    }

    @objc(drawImage:inBounds:)
    func drawImage(_ image: NSImage?, inBounds rect: NSRect) {
        var rect = rect
        // We synchronise to make sure we're not drawing in two threads
        // simultaneously.

        NSColor.black.set()
        rect.fill()

        if let image {
            let imageBounds = NSRect(origin: .zero, size: image.size)
            let scaledHeight = Float(rect.width * imageBounds.height)
            let scaledWidth = Float(rect.height * imageBounds.width)

            if scaledHeight < scaledWidth {
                // rect is wider than image: fit height
                let horizMargin = Float(rect.width - CGFloat(scaledWidth) / imageBounds.height)
                rect.origin.x += CGFloat(horizMargin) / 2.0
                rect.size.width -= CGFloat(horizMargin)
            } else {
                // rect is taller than image: fit width
                let vertMargin = Float(rect.height - CGFloat(scaledHeight) / imageBounds.width)
                rect.origin.y += CGFloat(vertMargin) / 2.0
                rect.size.height -= CGFloat(vertMargin)
            }

            image.draw(in: rect, from: imageBounds, operation: .sourceOver, fraction: 1.0)
        }
    }

    @objc(squareView:)
    func squareView(_ sender: Any?) {
        let viewSize = UserDefaults.standard.integer(forKey: "VRDefaultViewSize")
        if viewSize == 1 { return }

        var selfFrame = window?.contentView?.frame ?? .zero

        selfFrame.size.height -= 30

        var newFrame = selfFrame
        let beforeFrame = selfFrame

        var border = CConversion.int(Double(selfFrame.size.height - 1))

        if CGFloat(border) > selfFrame.size.width { border = CConversion.int(Double(selfFrame.size.width)) }

        if viewSize == 2 { border = 512 }
        if viewSize == 3 { border = 768 }

        newFrame.size.width = CGFloat(border)
        newFrame.size.height = CGFloat(border)

        newFrame.origin.x = CGFloat(CConversion.int((Double(beforeFrame.size.width) - Double(border)) / 2))
        newFrame.origin.y = CGFloat(CConversion.int(10 + (Double(beforeFrame.size.height) - Double(border)) / 2))

        frame = newFrame

        window?.display()
    }

    // MARK: - Stereo

    @objc(horosSetStereoMode:)
    func horosSetStereoMode(_ requested: Int) {
        var stereo = horos_horosStereo as? StereoPresentation
        if stereo == nil {
            let created = StereoPresentation(view: self)
            horos_horosStereo = created
            // Not retained by the block: the view turns it off before it goes.
            created.turnOff = { [unowned(unsafe) self] in self.horosSetStereoMode(StereoMode.off.rawValue) }
            stereo = created
        }
        let mode = stereo!.switchTo(StereoMode(rawValue: requested) ?? .off)
        horos_vtk.setStereoMode(mode.rawValue, eyePresenter: stereo!.eyePresenter.map { $0 as AnyObject as? IsiXVTKFramePresenter } ?? nil)
        _ = prepareRenderWindow()
        needsDisplay = true
    }

    @objc(horosStereoMode)
    func horosStereoMode() -> Int {
        return (horos_horosStereo as? StereoPresentation)?.mode.rawValue ?? StereoMode.off.rawValue
    }

    // The Stereo menu: its items' tags are the modes; the toolbar button, which
    // is not a menu item, switches red/blue on and off.
    @objc(SwitchStereoMode:)
    func switchStereoMode(_ sender: Any?) {
        var mode = horosStereoMode() == StereoMode.off.rawValue ? StereoMode.redBlue.rawValue : StereoMode.off.rawValue
        let item = sender as? NSMenuItem
        if let item {
            mode = item.tag
        }
        horosSetStereoMode(mode)
        if let item {
            for other in item.menu?.items ?? [] where other.tag >= StereoMode.off.rawValue && other.tag <= StereoMode.oneScreen.rawValue {
                other.state = other.tag == horosStereoMode() ? .on : .off
            }
        }
    }

    // The eyes change sides: VTK's eye angle changes sign.
    @objc(invertedSides:)
    func invertedSides(_ sender: Any?) {
        let vtk = horos_vtk
        let inverted = vtk.cameraEyeAngle >= 0
        vtk.cameraEyeAngle = (inverted ? -1 : 1) * abs(vtk.cameraEyeAngle)
        if let sender = sender as? NSObject, sender.responds(to: #selector(setter: NSButton.state)) {
            sender.setValue(NSNumber(value: (inverted ? NSControl.StateValue.on : .off).rawValue), forKey: "state")
        }
        needsDisplay = true
    }

    @objc(horosSetStereoScreenHeight:distance:eyeSeparation:)
    func horosSetStereoScreenHeight(_ height: Double, distance: Double, eyeSeparation separation: Double) {
        let vtk = horos_vtk
        let sign: Double = vtk.cameraEyeAngle < 0 ? -1 : 1
        vtk.cameraViewAngle = StereoPresentation.viewAngle(screenHeight: height, distance: distance)
        vtk.cameraEyeAngle = sign * StereoPresentation.eyeAngle(separation: separation, distance: distance)
        needsDisplay = true
    }

    // MARK: - 2D layer

    // The 2D layer without VTK drawing it: the text actors, the 2D actors and
    // the orientation cube stay VTK objects that hold what to show, and the
    // overlay draws them over the volume (SceneOverlay.swift). The VTK adapter hides
    // them from VTK's render and hands them back after it.

    @objc(horosObserveOverlay)
    func horosObserveOverlay() {
        // Not retained by the block: the view forgets the observer before it goes.
        do {
            try horos_vtk.observeOverlay(handler: { [unowned(unsafe) self] _ in self.horosDrawOverlay() })
        } catch {
            NSLog("---- VRView: the 2D layer is not drawn: %@", error as NSError)
        }
    }

    @objc(horosForgetOverlay)
    func horosForgetOverlay() {
        horos_vtk.forgetOverlay()
    }

    /// Draws the view's visible 2D actors and the orientation cube in the overlay.
    @objc(horosDrawOverlay)
    func horosDrawOverlay() {
        // In stereo, the cube and the orientation letters go away, as they did
        // from the original stereo mode.
        let stereo = horosStereoMode() != 0
        HorosSceneOverlay.draw(horos_vtk.overlayFrameHidingOrientationLetters(stereo, cube: horos_orientationCubeShown && !stereo,
                                                                         picked: horos_display3DPoints ? horos_picked3DPoint : nil),
                          on: self)
    }

    // MARK: - The VTK adapter's Metal hook

    // The adapter has checked that the mapper is the view's, or the fused
    // series', and that the renderer is the view's.
    @objc(horosRenderMetalImageFused:)
    func horosRenderMetalImageFused(_ fused: Bool) -> Bool {
        // The MPR's hidden view is on the CPU engine; it asks for Metal plane by
        // plane, in volume rendering mode.
        let mprPlane = horos_controller?.style() == "noNib"
        if mprPlane ? !horosMPRVolumeMetal() : engine != 2 { return false }
        // The mapper and volume being rendered: the snapshots read the view's own.
        guard let scene = horos_vtk.renderingScene() else { return false }
        return horosRenderMetalImage(in: scene, fused: fused, mprPlane: mprPlane)
    }
}
