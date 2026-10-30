//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import QuartzCore
import IsiXVolumeRendering

/// A VTK scene presented by Metal, without VTK's OpenGL view: what VTKView and
/// vtkCocoaGLView gave the surface and ROI volume views. The scene
/// (IsiXVTKScene, the VTK adapter) keeps the camera and the props and renders
/// through the adapter's render window and renderer, which draw with the
/// view's VRPresenter into a CAMetalLayer. The mouse moves the camera through
/// the adapter's interactor as VTK's trackball style did, and the 2D actors,
/// the orientation cube and a picked prop's outline are drawn on the
/// annotation overlay.
@objc(HorosSceneView)
class HorosSceneView: NSView {
    /// The renderer, the render window and the interactor.
    let scene: IsiXVTKScene
    private var presenter: VRPresenter?
    /// The Stereo menu's mode and the right eye's picture.
    private var stereo: StereoPresentation?
    /// The prop the last pick found, or nil.
    private(set) var pickedActor: IsiXVTKActor?

    /// Whether the annotated orientation cube is drawn in the top right corner.
    @objc var horosOrientationCubeShown = false {
        didSet { needsDisplay = true }
    }

    override init(frame: NSRect) {
        scene = HorosSceneView.makeScene()
        super.init(frame: frame)
        setUpScene()
    }

    required init?(coder: NSCoder) {
        scene = HorosSceneView.makeScene()
        super.init(coder: coder)
        setUpScene()
    }

    private static func makeScene() -> IsiXVTKScene {
        do {
            return try IsiXVTKScene.make()
        } catch {
            // VTK could not make its objects: there is nothing to show.
            fatalError("The 3D scene could not be created: \(error)")
        }
    }

    private func setUpScene() {
        scene.setDeltaTransform { delta in PreciseMouse.appliedDelta(delta) }
        // The overlay after each render, as VTK drew its 2D actors last.
        scene.setRenderEndHandler { [weak self] in self?.horosDrawOverlay() }
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        _ = prepareRenderWindow()
    }

    isolated deinit {
        stereo?.turnOff = nil
        stereo?.switchTo(.off)
        scene.setRenderEndHandler(nil)
    }

    // MARK: VTK objects, for the Objective-C++ that asks a view for them

    /// The vtkRenderer * and vtkRenderWindow *, as vtkCocoaGLView gave them.
    @objc func renderer() -> UnsafeMutableRawPointer? { scene.vtkRenderer }
    @objc func renderWindow() -> UnsafeMutableRawPointer? { scene.vtkRenderWindow }
    @objc func getVTKRenderWindow() -> UnsafeMutableRawPointer? { scene.vtkRenderWindow }

    /// Kept for callers of VTKView's: nothing to unlink any more.
    @objc func prepareForRelease() {}
    @objc func removeAllActors() { scene.removeAllViewProps() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override var isOpaque: Bool { true }
    override func updateLayer() { draw(bounds) }

    override func draw(_ dirtyRect: NSRect) {
        if prepareRenderWindow() { renderScene() }
    }

    /// Renders the scene; a failure goes to -horosRenderFailed:.
    func renderScene() {
        do {
            try scene.render()
        } catch {
            horosRenderFailed(error)
        }
    }

    /// A render that VTK could not finish. Logged here.
    @objc func horosRenderFailed(_ error: Error) {
        NSLog("---- 3D scene: the render failed: %@", String(describing: error))
    }

    // MARK: The Metal picture

    /// The frame is drawn by Metal into a layer of its own, the first of the
    /// view's layer: the overlay's text and graphics are above it.
    private func pictureLayer() -> CAMetalLayer? {
        guard let host = layer else { return nil }
        var picture = presenter?.layer
        if picture == nil {
            let made = CAMetalLayer()
            made.device = PlanarHostRenderer.device
            made.presentsWithTransaction = true
            made.isOpaque = true
            made.anchorPoint = .zero
            made.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            guard let madePresenter = VRPresenter(layer: made) else { return nil }
            presenter = madePresenter
            scene.setPresenter(HorosSceneView.framePresenter(madePresenter))
            picture = made
        }
        guard let picture else { return nil }
        if picture.superlayer !== host || host.sublayers?.first !== picture {
            picture.removeFromSuperlayer()
            host.insertSublayer(picture, at: 0)
        }
        return picture
    }

    /// The presenter as the adapter knows it: VRPresenter adopts
    /// IsiXVTKFramePresenter in Objective-C (VTKAdapterDrawing.h).
    private static func framePresenter(_ presenter: VRPresenter?) -> IsiXVTKFramePresenter? {
        guard let presenter else { return nil }
        return (presenter as AnyObject) as? IsiXVTKFramePresenter
    }

    /// Brings the window's size in line with the view's, in pixels. NO when
    /// there is nothing to render into.
    @objc @discardableResult
    func prepareRenderWindow() -> Bool {
        let scale = (window?.backingScaleFactor ?? 0) > 0 ? window!.backingScaleFactor : 1
        var size = window != nil ? convertToBacking(bounds.size) : bounds.size
        // The two eyes side by side render at half the width each.
        if let stereo { size = stereo.renderSize(forBacking: size) }
        let width = max(1, Int(lround(Double(size.width)))), height = max(1, Int(lround(Double(size.height))))
        scene.setWidth(width, height: height)
        // For text actors, as vtkCocoaGLView set it.
        scene.dpi = lround(72.0 * Double(scale))
        guard let window else { return false }

        if let picture = pictureLayer() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.contentsScale = scale
            picture.frame = bounds
            if let space = window.colorSpace?.cgColorSpace, picture.colorspace !== space {
                picture.colorspace = space
            }
            CATransaction.commit()
            let drawable = CGSize(width: width, height: height)
            if picture.drawableSize != drawable { picture.drawableSize = drawable }
            stereo?.layout(picture: picture, bounds: bounds, scale: scale, renderSize: drawable)
        }
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        prepareRenderWindow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        prepareRenderWindow()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        prepareRenderWindow()
        needsDisplay = true
    }

    /// Mouse moves reach the view whether or not it has the focus, as with
    /// vtkCocoaGLView's tracking area.
    override func updateTrackingAreas() {
        for area in trackingAreas where area.owner === self && area.options.contains(.mouseMoved) {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    // MARK: Stereo

    @objc(horosSetStereoMode:)
    func horosSetStereoMode(_ requested: Int) {
        if stereo == nil {
            let made = StereoPresentation(view: self)
            made.turnOff = { [weak self] in self?.horosSetStereoMode(StereoMode.off.rawValue) }
            stereo = made
        }
        guard let stereo else { return }
        let was = stereo.mode != .off
        let mode = stereo.switchTo(StereoMode(rawValue: requested) ?? .off)
        scene.setStereoMode(mode.rawValue, eyePresenter: HorosSceneView.framePresenter(stereo.eyePresenter))
        if was != (mode != .off) { horosStereoDidChange(mode != .off) }
        prepareRenderWindow()
        needsDisplay = true
    }

    /// The Stereo menu's mode in effect; two screens fall back to one on one screen.
    @objc func horosStereoMode() -> Int { stereo?.mode.rawValue ?? StereoMode.off.rawValue }

    /// Called when stereo goes on or off: what a subclass hides in stereo.
    @objc(horosStereoDidChange:)
    dynamic func horosStereoDidChange(_ on: Bool) {}

    /// The Stereo menu: its items' tags are the modes of StereoPresentation; a
    /// sender that is not a menu item switches red/blue on and off, as the
    /// toolbar button did.
    @IBAction @objc(SwitchStereoMode:)
    func switchStereoMode(_ sender: Any?) {
        var mode = horosStereoMode() == StereoMode.off.rawValue ? StereoMode.redBlue.rawValue : StereoMode.off.rawValue
        let item = sender as? NSMenuItem
        if let item { mode = item.tag }
        horosSetStereoMode(mode)
        if let menu = item?.menu {
            for entry in menu.items where entry.tag >= StereoMode.off.rawValue && entry.tag <= StereoMode.oneScreen.rawValue {
                entry.state = entry.tag == horosStereoMode() ? .on : .off
            }
        }
    }

    /// The eyes change sides: VTK's eye angle changes sign.
    @IBAction @objc(invertedSides:)
    func invertedSides(_ sender: Any?) {
        let camera = scene.camera
        let inverted = camera.eyeAngle >= 0
        camera.eyeAngle = (inverted ? -1 : 1) * abs(camera.eyeAngle)
        if let control = sender as? NSObject, control.responds(to: NSSelectorFromString("setState:")) {
            control.setValue(inverted ? NSControl.StateValue.on.rawValue : NSControl.StateValue.off.rawValue, forKey: "state")
        }
        needsDisplay = true
    }

    /// Sets the view and eye angles for a screen `height` high seen from
    /// `distance`, the eyes `separation` apart, in the same unit.
    @objc(horosSetStereoScreenHeight:distance:eyeSeparation:)
    func horosSetStereoScreen(height: Double, distance: Double, eyeSeparation separation: Double) {
        let camera = scene.camera
        let sign: Double = camera.eyeAngle < 0 ? -1 : 1
        camera.viewAngle = StereoPresentation.viewAngle(screenHeight: height, distance: distance)
        camera.eyeAngle = sign * StereoPresentation.eyeAngle(separation: separation, distance: distance)
        needsDisplay = true
    }

    /// The right eye's half of the view is the left eye's scene too.
    private func eyePoint(_ backing: NSPoint) -> NSPoint {
        var point = backing
        let width = CGFloat(scene.width)
        if horosStereoMode() == StereoMode.oneScreen.rawValue && point.x >= width { point.x -= width }
        return point
    }

    // MARK: Events, as vtkCocoaGLView handed them to VTK

    /// Hands a mouse event to the interactor as vtkCocoaGLView did: its
    /// position in pixels from the bottom left, control or command as control.
    func horosInvokeVTKEvent(_ vtkEvent: IsiXVTKMouseEvent, for event: NSEvent) {
        let backing = eyePoint(convertToBacking(convert(event.locationInWindow, from: nil)))
        let flags = event.modifierFlags
        var repeatCount = 0
        if event.type != .scrollWheel && event.type != .mouseMoved {
            repeatCount = event.clickCount > 1 ? event.clickCount - 1 : 0
        }
        scene.setEvent(x: Int32(backing.x), y: Int32(backing.y),
                       control: !flags.intersection([.control, .command]).isEmpty,
                       shift: flags.contains(.shift), repeat: Int32(repeatCount))
        scene.setAltKey(flags.contains(.option))
        scene.invokeEvent(vtkEvent)
    }

    override func mouseDown(with event: NSEvent) { horosInvokeVTKEvent(.leftButtonPress, for: event) }
    override func mouseUp(with event: NSEvent) { horosInvokeVTKEvent(.leftButtonRelease, for: event) }
    override func rightMouseDown(with event: NSEvent) { horosInvokeVTKEvent(.rightButtonPress, for: event) }
    override func rightMouseUp(with event: NSEvent) { horosInvokeVTKEvent(.rightButtonRelease, for: event) }
    override func otherMouseDown(with event: NSEvent) { horosInvokeVTKEvent(.middleButtonPress, for: event) }
    override func otherMouseUp(with event: NSEvent) { horosInvokeVTKEvent(.middleButtonRelease, for: event) }
    override func mouseMoved(with event: NSEvent) { horosInvokeVTKEvent(.move, for: event) }
    override func mouseDragged(with event: NSEvent) { horosInvokeVTKEvent(.move, for: event) }
    override func rightMouseDragged(with event: NSEvent) { horosInvokeVTKEvent(.move, for: event) }
    override func otherMouseDragged(with event: NSEvent) { horosInvokeVTKEvent(.move, for: event) }

    override func scrollWheel(with event: NSEvent) {
        if event.deltaY > 0 { horosInvokeVTKEvent(.wheelForward, for: event) }
        else if event.deltaY < 0 { horosInvokeVTKEvent(.wheelBackward, for: event) }
    }

    /// The keys VTK's trackball style answered with something the scene
    /// shows: 'r' resets the camera and 'p' picks. The others changed nothing shown.
    override func keyDown(with event: NSEvent) {
        guard let character = event.characters?.utf16.first else { return }
        if character == 27 && horosStereoMode() == StereoMode.twoScreens.rawValue {
            horosSetStereoMode(StereoMode.off.rawValue)
        } else if character == UInt16(UInt8(ascii: "r")) || character == UInt16(UInt8(ascii: "R")) {
            scene.resetCamera()
            needsDisplay = true
        } else if character == UInt16(UInt8(ascii: "p")) || character == UInt16(UInt8(ascii: "P")) {
            let point = eyePoint(convertToBacking(convert(event.locationInWindow, from: nil)))
            horosPick(x: point.x, y: point.y)
        }
    }

    override func keyUp(with event: NSEvent) {}

    // MARK: Pick and overlay

    /// The actors 'p' can pick; none here.
    @objc dynamic func horosPickableActors() -> [IsiXVTKActor] { [] }

    @objc func horosClearPick() {
        pickedActor = nil
        needsDisplay = true
    }

    /// Picks the pickable actor nearest the viewer under a position in pixels
    /// from the bottom left, as vtkPropPicker did for spheres.
    @objc(horosPickAtX:y:)
    func horosPick(x: Double, y: Double) {
        pickedActor = nil
        let from = scene.worldPoint(ofDisplayX: x, y: y, z: 0), to = scene.worldPoint(ofDisplayX: x, y: y, z: 1)
        let candidates = horosPickableActors().filter { $0.visible && $0.pickable }
        let boxes = candidates.map { actor -> SceneSpherePick.Box in
            let b = actor.bounds
            return SceneSpherePick.Box(xmin: b.xmin, xmax: b.xmax, ymin: b.ymin, ymax: b.ymax, zmin: b.zmin, zmax: b.zmax)
        }
        if let index = SceneSpherePick.nearest(from: SIMD3(from.x, from.y, from.z), to: SIMD3(to.x, to.y, to.z), boxes: boxes) {
            pickedActor = candidates[index]
        }
        needsDisplay = true
    }

    // MARK: Captures

    /// Copies the small logo's pixels that are not black into the bottom right
    /// of `rgb`, ten pixels from the right edge, as the 3D exports carry it.
    static func stampLogo(on rgb: UnsafeMutablePointer<UInt8>, width: Int, height: Int, rowBytes: Int) {
        guard let logo = NSImage(named: "SmallLogo.tif"), let tiff = logo.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let source = rep.bitmapData else { return }
        for i in 0..<rep.pixelsHigh {
            var src = source + i * rep.bytesPerRow
            var dst = rgb + (height - rep.pixelsHigh + i) * rowBytes + ((width - 10) * 3 - rep.bytesPerRow)
            var x = rep.bytesPerRow / 3
            while x > 0 {
                x -= 1
                if src[0] != 0 || src[1] != 0 || src[2] != 0 {
                    dst[0] = src[0]
                    dst[1] = src[1]
                    dst[2] = src[2]
                }
                dst += 3
                src += 3
            }
        }
    }

    /// An image of `rgb`'s pixels, `spp` samples of `bpp` bits each.
    static func image(rgb: UnsafeMutablePointer<UInt8>?, width: Int, height: Int, spp: Int, bpp: Int,
                      logo: Bool = false) -> NSImage {
        let image = NSImage()
        guard let rgb, width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: bpp,
                                         samplesPerPixel: spp, hasAlpha: false, isPlanar: false,
                                         colorSpaceName: spp == 3 ? .calibratedRGB : .calibratedWhite,
                                         bytesPerRow: width * bpp * spp / 8, bitsPerPixel: bpp * spp),
              let bitmap = rep.bitmapData else { return image }
        memcpy(bitmap, rgb, height * width * bpp * spp / 8)
        if logo { stampLogo(on: bitmap, width: width, height: height, rowBytes: rep.bytesPerRow) }
        image.addRepresentation(rep)
        return image
    }

    /// Adds the files a 3D export wrote to the database, and sends them or
    /// marks them as the export preferences ask.
    static func importExportedFiles(_ paths: [String]) {
        guard !paths.isEmpty, let browser = BrowserController.currentBrowser() else { return }
        var objects = browser.database?.addFiles(atPaths: paths, postNotifications: true, dicomOnly: true,
                                                 rereadExistingItems: true, generatedByOsiriX: true)
        objects = browser.database?.objects(withIDs: objects)
        if UserDefaults.standard.bool(forKey: "afterExportSendToDICOMNode") {
            browser.selectServer(objects)
        }
        if UserDefaults.standard.bool(forKey: "afterExportMarkThemAsKeyImages") {
            for case let image as NSManagedObject in (objects as NSArray?) ?? NSArray() {
                image.setValue(NSNumber(value: true), forKey: "isKeyImage")
            }
        }
    }

    /// Redraws the overlay after each render.
    @objc func horosDrawOverlay() {
        // The original took the cube away in stereo.
        let cube = horosOrientationCubeShown && horosStereoMode() == StereoMode.off.rawValue
        let frame = try? scene.overlayFrame(cube: cube, picked: pickedActor)
        HorosSceneOverlay.draw(frame, on: self)
    }
}
