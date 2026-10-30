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
import IsiXVolumeRendering
import ObjectiveC

/// The MPR's switch for drawing the hidden view's next render with Metal, and
/// whether that render drew it; on the view.
private enum MPRVolumeMetalSlots {
    nonisolated(unsafe) static var on: UInt8 = 0
    nonisolated(unsafe) static var drawn: UInt8 = 0
}

/// The 3D view's state as the Metal volume renderer takes it. VTK's objects
/// are read through the VTK adapter (IsiXVTKVolumeScene) as numbers and
/// tables, in the volume's own millimetre frame (the VTK world divided by the
/// view's factor); the rules that turn them into the renderer's inputs are
/// IsiXVolumeRendering's. The picture Metal makes goes back into the mapper's
/// ray-cast image, where VTK composes it with the surfaces and a fused series.
///
/// VRView adopts HorosMPRVRViewMessages (MPRHostMessages.h), the messages the
/// Swift MPR sends the VRView of its hidden VRController, in VRView+CAPI.m:
/// its own methods and the MPR's ones here.
extension VRView {

    // MARK: The render hook

    /// Fills the image of the mapper being rendered (`scene`) - the volume's or
    /// a fused series' (`fused`) - with Metal RGBA pixels. Called by the mapper
    /// during VTK's render, after the view checked that the mapper is one of its
    /// own and that Metal is asked for (`mprPlane`: by the MPR, plane by plane).
    /// Returns NO for the CPU fallback.
    @objc(horosRenderMetalImageInScene:fused:mprPlane:)
    func horosRenderMetalImage(in scene: IsiXVTKVolumeScene, fused: Bool, mprPlane: Bool) -> Bool {
        if mprPlane { objc_setAssociatedObject(self, &MPRVolumeMetalSlots.drawn, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
        return autoreleasepool { renderMetalImage(in: scene, fused: fused) }
    }

    private func renderMetalImage(in scene: IsiXVTKVolumeScene, fused: Bool) -> Bool {
        // A fused series has its own mapper and volume, drawn after the image's:
        // each fills its own ray-cast image, and VTK composes the two, the fused
        // one over the image, premultiplied.
        let controller: VRController = self.controller()
        // A series fused and then closed leaves its volume on the GPU until
        // the image's next frame.
        if !fused && !horosHasBlendingVolume { controller.horosFusedVolumeMetalRelease() }
        var reason: String?
        var snapshot: NSDictionary?
        // MIP, MinIP and mean draw in Metal, sampled and painted as VTK's ray
        // caster does; the snapshot carries its step and planes. A crop
        // is clipped in Metal against the mapper's own planes, and the clipping
        // range is the camera's own. VTK's cropping regions, which the
        // host never turns on, are planes too when they are one box.
        if !fused && (isRGB() || advancedCLUT()) { reason = horosVolumeSnapshot()["error"] as? String }
        if reason == nil {
            do {
                let refusal = try scene.prepareGeometry(acceptingClippingPlanes: true)
                if refusal != .accepted { reason = Self.geometryRefusalReason(refusal) }
            } catch {
                reason = error.localizedDescription
            }
        }
        // The fused snapshot reads the planes the preparation just set up.
        if reason == nil && fused {
            let fusedSnapshot = horosFusedVolumeSnapshot()
            snapshot = fusedSnapshot
            reason = fusedSnapshot["error"] as? String
        }

        var pixels: NSData?, picture: NSData?
        let opacity = NSMutableData()
        var image = IsiXVTKRayCastImageInfo()
        if (try? scene.readRayCastImage(&image)) == nil, reason == nil { reason = "The 3D view has no volume yet." }
        let width = image.usedWidth, height = image.usedHeight
        if reason == nil {
            let region = Array(RayCastPicture.region(viewportWidth: image.viewportWidth, viewportHeight: image.viewportHeight,
                                                     originX: image.originX, originY: image.originY,
                                                     usedWidth: width, usedHeight: height).prefix(4)).map { NSNumber(value: $0) }
            // As in VTK's CPU pass, stop each ray at already drawn geometry.
            // Without this, ribs behind an ROI are painted over it too.
            let depth = (try? scene.geometryDepth(withWorldUnitsPerMillimetre: Double(factor()))).flatMap { $0.isEmpty ? nil : $0 }
            // The view's own state: a preset preview shares its controller's
            // renderer and volume, not its camera and tables.
            if !fused {
                let snapshotFrom = MetalPerformanceTrace.hostTime()
                snapshot = horosVolumeSnapshot()
                MetalPerformanceTrace.recordHost("vr.host_snapshot", startedAt: snapshotFrom)
            }
            do {
                pixels = try controller.horosVolumeMetalRender(snapshot ?? [:], fused: fused, width: width, height: height,
                                                               imageRegion: region, geometryDepth: depth, scalarOut: opacity, forVTK: true)
            } catch {
                reason = error.localizedDescription
            }
        }
        let count = width * height
        // An RGB volume's projection hands back three values a pixel.
        let colourProjection = (fused ? horosIsBlendingRGB : isRGB()) && renderingMode != 0
        let ready = pixels?.length == count * 4 && opacity.length == count * MemoryLayout<Float>.size * (colourProjection ? 3 : 1) && count > 0
        if reason == nil && !ready { reason = "Metal returned an incomplete image." }
        let convertedFrom = MetalPerformanceTrace.hostTime()
        if reason == nil, let pixels {
            picture = Self.volumePicture(bgra: pixels, scalar: opacity, projection: renderingMode == 0 ? nil : snapshot)
            if picture?.length != count * 4 * MemoryLayout<UInt16>.size { reason = "Metal returned an incomplete image." }
        }
        if let reason { MetalPerformanceTrace.recordRefusal(fused ? "vr.fusion.refusal" : "vr.refusal", reason: reason) }
        objc_setAssociatedObject(controller, VolumeMetalSlots.reasonKey(fused: fused), reason, .OBJC_ASSOCIATION_COPY_NONATOMIC)
        if horosShowsWindowText {
            let imageReason = objc_getAssociatedObject(controller, VolumeMetalSlots.reasonKey(fused: false)) as? String
            let fusedReason = horosHasBlendingVolume ? objc_getAssociatedObject(controller, VolumeMetalSlots.reasonKey(fused: true)) as? String : nil
            var status = imageReason.map { "CPU fallback: " + $0 } ?? "Metal"
            if let fusedReason { status += "\nFused series, CPU fallback: " + fusedReason }
            var wl: Float = 0, ww: Float = 0
            getWLWW(&wl, &ww)
            horosSetWindowText(String(format: "WL: %.4g WW: %.4g\n%@", Double(wl), Double(ww), status))
        }
        guard reason == nil, let picture else { return false }

        // A projection captured in full depth (-prepareFullDepthCapture): the
        // fourth word is the projected value as the volume stores it, which
        // -imageInFullDepthWidth: reads back. VTK's caster wrote it through
        // the linear opacity table the capture installs; Metal paints the
        // opacity curve there, and the 16-bit export held the curve.
        let fullDepth = horosFullDepthMode && renderingMode != 0 && !colourProjection
        let offset = fused ? horosBlendingOffset : self.offset(), valueFactor = fused ? horosBlendingValueFactor : self.valueFactor()
        var written = false
        try? scene.accessRayCastImage { rgba, info in
            guard let rgba else { return }
            RayCastPicture.replace(rgba, memoryWidth: info.memoryWidth, memoryHeight: info.memoryHeight,
                                   with: picture.bytes.assumingMemoryBound(to: UInt16.self), usedWidth: width, usedHeight: height)
            if fullDepth {
                RayCastPicture.writeFullDepthProjection(rgba, stride: info.memoryWidth * 4, width: width, height: height,
                                                        values: opacity.bytes.assumingMemoryBound(to: Float.self),
                                                        offset: offset, factor: valueFactor)
            }
            written = true
        }
        MetalPerformanceTrace.recordHost(fused ? "vr.fusion.host_convert" : "vr.host_convert", startedAt: convertedFrom)
        return written
    }

    /// Why the mapper refused the ray-cast geometry, one text per cause so that
    /// a trace can count them.
    private static func geometryRefusalReason(_ refusal: IsiXVTKGeometryRefusal) -> String {
        switch refusal {
        case .clippingPlane: return "The crop uses the original renderer."
        case .noRows: return "The ray caster has no rows to cast."
        case .noViewport: return "The view has no size yet."
        default: return "The 3D view has no volume yet."
        }
    }

    /// A volume's ray-cast image as VTK displays it: premultiplied RGBA in its
    /// 15-bit fixed-point range, row 0 at the top. Composite rendering converts
    /// Metal's premultiplied colour and accumulated opacity. A projection's
    /// scalar is a value, not an opacity: VTK paints it with the colour and the
    /// unscaled opacity curve at that value, so `projection` is the snapshot to
    /// paint it with, or nil for composite rendering.
    private static func volumePicture(bgra: NSData, scalar: NSData, projection: NSDictionary?) -> NSData? {
        func number(_ key: String) -> Double { (projection?[key] as? NSNumber)?.doubleValue ?? 0 }
        // An RGB volume's projection: three values a pixel, painted with the
        // mapper's own tables.
        if (projection?["colourVolume"] as? NSNumber)?.boolValue == true {
            return MPRColourPlane.picture(components: scalar, count: bgra.length / 4,
                                          tables: projection?["componentTables"] as? [NSDictionary] ?? [])
        }
        if let projection, let opacityTable = projection["projectionOpacityTable"] as? NSData {
            return VolumeRendererBridge.projectionPicture(scalar: scalar, level: number("level"), width: number("width"),
                                                          colourTable: projection["clut"] as? NSData ?? NSData(), opacityTable: opacityTable,
                                                          background: number("scalarBackground"))
        }
        if let projection {
            return VolumeRendererBridge.projectionPicture(scalar: scalar, level: number("level"), width: number("width"),
                                                          clut: projection["clut"] as? NSData ?? NSData(),
                                                          opacityPoints: projection["projectionOpacity"] as? [NSNumber] ?? [],
                                                          background: number("scalarBackground"))
        }
        return RayCastPicture.composite(bgra: bgra as Data, opacity: scalar as Data) as NSData?
    }

    // MARK: The ray-cast images

    private func rayCastImageRegion(_ scene: IsiXVTKVolumeScene) -> [NSNumber]? {
        guard scene.hasMapper else { return nil }
        var image = IsiXVTKRayCastImageInfo()
        guard (try? scene.readRayCastImage(&image)) != nil else { return nil }
        return RayCastPicture.region(viewportWidth: image.viewportWidth, viewportHeight: image.viewportHeight,
                                     originX: image.originX, originY: image.originY,
                                     usedWidth: image.usedWidth, usedHeight: image.usedHeight).map { NSNumber(value: $0) }
    }

    private func rayCastImagePixels(_ scene: IsiXVTKVolumeScene) -> NSData? {
        guard scene.hasMapper else { return nil }
        var words: Data?
        try? scene.accessRayCastImage { pixels, info in
            words = RayCastPicture.inUseWords(pixels.map { UnsafePointer($0) }, memoryWidth: info.memoryWidth,
                                              usedWidth: info.usedWidth, usedHeight: info.usedHeight)
        }
        return words as NSData?
    }

    /// VTK's ray-cast image as the hook renders into it: the viewport in ray
    /// pixels, the in-use rectangle's top-left origin, and its size. The native
    /// comparison renders Metal on this same grid.
    @objc func horosRayCastImageRegion() -> [NSNumber]? { rayCastImageRegion(horosVTKScene(fused: false)) }

    /// What the view shows: the in-use rectangle of VTK's ray-cast image,
    /// premultiplied RGBA in 15 bits, rows as VTK keeps them (bottom row first),
    /// whichever engine filled it. The native comparison reads it.
    @objc func horosRayCastImagePixels() -> NSData? { rayCastImagePixels(horosVTKScene(fused: false)) }

    /// Whether a series is fused over the volume.
    @objc func horosHasFusedVolume() -> Bool { horosHasBlendingVolume }

    /// The same two for the fused series' mapper, whose image VTK draws over the
    /// volume's; nil without a fused series.
    @objc func horosFusedRayCastImageRegion() -> [NSNumber]? {
        horosHasBlendingVolume ? rayCastImageRegion(horosVTKScene(fused: true)) : nil
    }

    @objc func horosFusedRayCastImagePixels() -> NSData? {
        horosHasBlendingVolume ? rayCastImagePixels(horosVTKScene(fused: true)) : nil
    }

    // MARK: The MPR's planes

    /// An RGB volume's tables as the ray caster looks them up, brought up to date
    /// for the view's current window, colour and opacity: for each component VTK
    /// weighs, its `component` (1 red, 2 green, 3 blue), `weight`, `shift`,
    /// `scale`, table `size`, `opacity` and `colour` tables in 15 bits; or an
    /// `error`.
    @objc public func horosMPRColourTables() -> [AnyHashable: Any] { horosColourTables(fused: false, refresh: true) as? [AnyHashable: Any] ?? [:] }

    /// The image's or the fused series' mapper tables; inside VTK's own render,
    /// which has just brought them up to date, without initialising the volume
    /// again.
    @objc(horosColourTablesFused:refresh:)
    func horosColourTables(fused: Bool, refresh: Bool) -> NSDictionary {
        let scene = horosVTKScene(fused: fused)
        guard scene.hasMapper, scene.hasVolume, scene.hasProperty, scene.hasRenderer else {
            return ["error": "The 3D view has no volume yet."]
        }
        guard fused ? horosIsBlendingRGB : isRGB() else { return ["error": "The volume is not RGB."] }
        do {
            if refresh { try scene.initializeVolumeTables() }
            var tables: [NSDictionary] = []
            for table in try scene.componentTables() where table.weight != 0 {
                // The alpha component carries no colour; it is weighted 0 (setup of the view).
                if table.component == 0 { return ["error": "An RGB volume that weighs its alpha keeps the original renderer."] }
                guard let opacity = table.opacity, let colour = table.colour else { return ["error": "The colour tables are not ready."] }
                let entry: [String: Any] = [
                    "component": NSNumber(value: Int32(table.component)), "weight": NSNumber(value: table.weight),
                    "shift": NSNumber(value: table.shift), "scale": NSNumber(value: table.scale),
                    "size": NSNumber(value: Int32(table.size)), "opacity": opacity, "colour": colour]
                tables.append(entry as NSDictionary)
            }
            return ["tables": tables]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Whether the MPR's hidden view draws its next render with the Metal ray
    /// cast instead of VTK's CPU one. The MPR sets it before each plane in volume
    /// rendering mode and clears it after; the 3D window's own engine setting is
    /// not involved.
    @objc public func horosMPRVolumeMetal() -> Bool {
        (objc_getAssociatedObject(self, &MPRVolumeMetalSlots.on) as? NSNumber)?.boolValue ?? false
    }

    @objc public func horosSetMPRVolumeMetal(_ on: Bool) {
        objc_setAssociatedObject(self, &MPRVolumeMetalSlots.on, on ? true : nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(self, &MPRVolumeMetalSlots.drawn, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// After a render the MPR asked Metal for: nil when Metal drew it, otherwise
    /// the reason, the fused series' included; NO in `drawn` when no ray cast ran.
    @objc public func horosMPRVolumeMetalReasonDrawn(_ drawn: UnsafeMutablePointer<ObjCBool>!) -> String? {
        drawn.pointee = ObjCBool((objc_getAssociatedObject(self, &MPRVolumeMetalSlots.drawn) as? NSNumber)?.boolValue ?? false)
        let controller: VRController = self.controller()
        let image = controller.horosVolumeMetalFallbackReason()
        if horosHasBlendingVolume, let fusedReason = controller.horosFusedVolumeMetalFallbackReason() {
            return image.map { $0 + " Fused series: " + fusedReason } ?? "Fused series: " + fusedReason
        }
        return image
    }

    /// Whether the MPR reslice can stand in for this plane's ray cast: nil when it
    /// can, with the plane's size in ray pixels, otherwise the reason, one text per
    /// cause so that the trace can count them.
    @objc public func horosMPRGeometryRefusalWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!) -> String? {
        let scene = horosVTKScene(fused: false)
        guard scene.hasMapper, scene.hasCamera else { return "The 3D view has no volume yet." }
        var camera = IsiXVTKCameraState(), sampling = IsiXVTKVolumeSampling()
        do {
            try scene.readCamera(&camera)
            try scene.readSampling(&sampling)
        } catch {
            return error.localizedDescription
        }
        if !camera.parallelProjection.boolValue { return "A perspective plane keeps the original renderer." }
        if !clipRangeActivated { return "A plane without a clipping range keeps the original renderer." }
        if sampling.cropping.boolValue { return "VTK cropping regions keep the original renderer." }
        if !prepareRenderWindow() { return "The plane has no window yet." }
        return preparedPlane(scene, width: width, height: height)
    }

    /// The same for the series fused over the MPR: the blending mapper's
    /// ray-cast geometry, prepared for its own volume without a render.
    @objc public func horosMPRFusedGeometryRefusalWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!) -> String? {
        let scene = horosVTKScene(fused: true)
        guard scene.hasMapper, scene.hasVolume else { return "The fused series has no volume yet." }
        var sampling = IsiXVTKVolumeSampling()
        do { try scene.readSampling(&sampling) } catch { return error.localizedDescription }
        if sampling.cropping.boolValue { return "VTK cropping regions keep the original renderer." }
        return preparedPlane(scene, width: width, height: height)
    }

    private func preparedPlane(_ scene: IsiXVTKVolumeScene, width: UnsafeMutablePointer<Int>, height: UnsafeMutablePointer<Int>) -> String? {
        var image = IsiXVTKRayCastImageInfo()
        do {
            let refusal = try scene.prepareGeometry(acceptingClippingPlanes: false)
            if refusal != .accepted { return Self.geometryRefusalReason(refusal) }
            try scene.readRayCastImage(&image)
        } catch {
            return error.localizedDescription
        }
        width.pointee = image.usedWidth
        height.pointee = image.usedHeight
        return image.usedWidth > 0 && image.usedHeight > 0 ? nil : "The view has no size yet."
    }

    /// The fused series as VTK reslices it: its float voxels (`volume`, the
    /// buffer VTK converts to 16 bits from), `width`, `height`, `depth`, the
    /// column-major voxel-to-world `transform` in millimetres, the `background` a
    /// ray that misses it reads back as, and a `sampleStep`; or an `error`.
    @objc public func horosMPRFusedVolume() -> [AnyHashable: Any] {
        let scene = horosVTKScene(fused: true)
        guard let blendingController = horosBlendingController, horosHasBlendingVolume, scene.hasImporter,
              let first = horosBlendingFirstPix, let blendingData = horosBlendingData,
              let blendingPixList = horosBlendingPixList, !blendingPixList.isEmpty else {
            return ["error": "The fused series has no volume yet."]
        }
        // A reversed stack: the blending reader takes the signed interval
        // and the transform below places the slices by it, as the image's does.
        var dz = fabs(first.sliceInterval)
        if dz == 0 { dz = fabs(first.sliceThickness) }
        var sx = first.pixelSpacingX, sy = first.pixelSpacingY
        if sx <= 0 || sy <= 0 { sx = 1; sy = 1 }
        if dz <= 0 || !dz.isFinite || !sx.isFinite || !sy.isFinite { return ["error": "The fused volume spacing is not usable."] }
        // The float buffer VTK converts to 16 bits from, found among the fused
        // viewer's volumes: the phase setBlendingPixSource: or
        // movieBlendingChangeSource: gave the reader.
        let expected = VolumeAllocation.byteCount(width: first.pwidth, height: first.pheight, slices: blendingPixList.count, bytesPerVoxel: 4)
        var voxels: NSData?
        var i = 0
        while i < max(1, Int(blendingController.maxMovieIndex())) && voxels == nil {
            if let candidate = blendingController.volumeData(i), candidate.bytes == UnsafeRawPointer(blendingData) { voxels = candidate }
            i += 1
        }
        guard let voxels, expected != 0, voxels.length >= expected else { return ["error": "The fused volume bytes do not match its slices."] }
        // As -mprVoxelToWorldTransform places the volume, for the blending reader
        // and volume: the reader's origin and spacing through the volume's matrix,
        // out of VTK's frame scaled by `factor`, column by column.
        var placement = IsiXVTKVolumePlacement()
        let factor = Double(self.factor())
        guard (try? scene.readPlacement(&placement)) != nil, placement.hasImporterOutput.boolValue, factor.isFinite, factor > 0 else {
            return ["error": "The fused volume transform is unavailable."]
        }
        let transform = VolumePlacement.voxelToWorldColumns(matrix: Self.array(placement.matrix), origin: Self.array(placement.origin),
                                                            spacing: Self.array(placement.spacing), factor: factor)
        // A ray that misses the volume leaves 0 in VTK's 16-bit image, which
        // -imageInFullDepthWidth:... reads back as -blendingOFFSET16.
        // An RGB fused series is its ARGB bytes, which only the 3D view's
        // renderer draws.
        return ["volume": voxels, "width": NSNumber(value: first.pwidth), "height": NSNumber(value: first.pheight),
                "depth": NSNumber(value: blendingPixList.count), "transform": Self.numbers(transform),
                "background": NSNumber(value: -horosBlendingOffset), "sampleStep": NSNumber(value: min(sx, min(sy, dz))),
                "colour": NSNumber(value: horosIsBlendingRGB)]
    }

    // MARK: Snapshots

    /// The view's camera in the volume's own millimetre frame and the rays' near
    /// and far distances: the same for every volume the view draws.
    func horosVolumeCameraSnapshot() throws -> VolumeCameraSnapshot {
        var state = IsiXVTKCameraState()
        try horosVTKScene(fused: false).readCamera(&state)
        let camera = VolumeCameraSnapshot.Camera(
            position: Self.array(state.position), focalPoint: Self.array(state.focalPoint), viewUp: Self.array(state.viewUp),
            parallelProjection: state.parallelProjection.boolValue, parallelScale: state.parallelScale, viewAngle: state.viewAngle,
            eyeAngle: state.eyeAngle, leftEye: state.leftEye.boolValue, windowCenter: Self.array(state.windowCenter),
            clippingRange: Self.array(state.clippingRange), stereo: state.stereoRender.boolValue)
        return VolumeCameraSnapshot(camera: camera, factor: Double(factor()),
                                    clipThickness: clipRangeActivated ? clippingRangeThickness : nil, projection: renderingMode != 0)
    }

    /// Reads camera, window, CLUT, opacity, mode, clipping, shading and crop from
    /// the VTK state, in the volume's own millimetre frame (the VTK world divided
    /// by the view's factor).
    @objc func horosVolumeSnapshot() -> NSDictionary {
        let scene = horosVTKScene(fused: false)
        let controller: VRController = self.controller()
        guard scene.hasCamera, scene.hasProperty, horosFirstPix != nil, factor() > 0 else { return ["error": "The 3D view has no volume yet."] }
        guard let pix = controller.horosVolumePixList(), pix.count > 0, let first = pix.firstObject as? DCMPix,
              let volume = controller.horosVolumeData() as? NSData else { return ["error": "The 3D view has no volume yet."] }
        let dz = first.sliceInterval != 0 ? fabs(first.sliceInterval) : fabs(first.sliceThickness)
        let sx = first.pixelSpacingX > 0 ? first.pixelSpacingX : 1, sy = first.pixelSpacingY > 0 ? first.pixelSpacingY : 1
        if dz <= 0 || !dz.isFinite { return ["error": "The volume spacing is not usable."] }
        do {
            let view = try horosVolumeCameraSnapshot()
            let projection = renderingMode != 0
            let superSampling = Double(horosSuperSampling)

            // The host divides its opacity curve by superSampling and VTK applies it
            // per unit of the scaled frame; the renderer wants opacity per
            // millimetre. A projection paints with the curve itself.
            let samplesPerMillimetre = Self.samplesPerMillimetre(superSampling: superSampling, spacingX: sx)
            let points = Self.points(currentOpacityArray as NSArray?)
            let curve = VolumeOpacityCurve.curvePoints(points, composite: renderingMode == 0, superSampling: superSampling,
                                                       samplesPerMillimetre: samplesPerMillimetre)
            var opacity = curve.opacity, projectionOpacity = curve.projection
            var wl: Float = 0, ww: Float = 0
            getWLWW(&wl, &ww)
            var level = Double(wl), windowWidth = ww > 0 ? Double(ww) : 1
            var clut = Data(VolumeColourTable.rgba(colours: horosColourTable, count: 256))
            var opacityTable: Data?, projectionOpacityTable: Data?
            // The 16-bit CLUT: colour and opacity functions over the whole
            // value range, not over the window, which VTK evaluates into its own
            // tables. The renderer takes 4096 entries of the same functions over the
            // volume's range; the opacity, which the host has already divided by
            // superSampling in volume rendering, goes to millimetres as the curve does.
            if advancedCLUT() {
                let entries = 4096
                let lowest = Double(controller.minimumValue()), highest = Double(controller.maximumValue())
                if !(highest > lowest) || !scene.hasColourFunction || !scene.hasOpacityFunction {
                    return ["error": "The 16-bit CLUT has no value range."]
                }
                let from = (Double(offset()) + lowest) * Double(valueFactor()), to = (Double(offset()) + highest) * Double(valueFactor())
                let colours = Self.doubles(try scene.colourTable(from: from, to: to, count: entries))
                let alphas = Self.doubles(try scene.opacityTable(from: from, to: to, count: entries))
                clut = Data(colours.withUnsafeBufferPointer { VolumeColourTable.rgba(colours: $0.baseAddress!, count: entries) })
                let converted = alphas.withUnsafeBufferPointer {
                    VolumeOpacityCurve.tables(alphas: $0, samplesPerMillimetre: samplesPerMillimetre)
                }
                opacityTable = Self.data(converted.composite)
                projectionOpacityTable = Self.data(converted.painted)
                level = (lowest + highest) / 2
                windowWidth = highest - lowest
                opacity = []
                projectionOpacity = []
            }
            // An RGB volume: VTK holds the ARGB bytes as independent
            // components, alpha weighted 0, and red, green and blue each with its
            // colour function - its own ramp, or the CLUT over the window for all three
            // - and one opacity function, both over the byte's 0...255. The renderer
            // takes the three colour tables one after the other and the opacity table
            // at those 256 values; the window maps a byte to its own entry.
            if isRGB() {
                switch try Self.colourTables(scene, samplesPerMillimetre: samplesPerMillimetre) {
                case .failure(let refusal): return ["error": refusal.reason]
                case .success(let tables):
                    clut = tables.clut
                    opacityTable = tables.opacity
                    projectionOpacityTable = tables.projection
                }
                level = 127.5
                windowWidth = 255
                opacity = []
                projectionOpacity = []
            }
            // VTK places the volume in the patient frame: user matrix of the DICOM
            // cosines and a position that resolves to the first slice's origin.
            guard let columns = mprVoxelToWorldTransform() as? [NSNumber], columns.count == 16 else {
                return ["error": "The volume transform is unavailable."]
            }
            let transform = Self.rows(fromColumns: columns)
            var sampling = IsiXVTKVolumeSampling()
            try scene.readSampling(&sampling)
            let clippingPlanes: [Float]
            switch try Self.cuttingPlanes(scene, sampling: sampling, width: first.pwidth, height: first.pheight, depth: pix.count) {
            case .failure(let refusal): return ["error": refusal.reason]
            case .success(let planes): clippingPlanes = planes
            }
            if clippingPlanes.count > 4 * VolumeRendererBridge.maximumClippingPlanes {
                return ["error": "More than 32 crop planes use the original renderer."]
            }
            let shading = try Self.shading(scene, sampling: sampling)
            let sampleStep: Double = projection && scene.hasMapper
                ? Double(Float(sampling.sampleDistance) / factor())
                : VolumeSamplingStep.composite(spacingX: sx, superSampling: superSampling)
                    * VolumeSamplingStep.interactionScale(minimumImageSampleDistance: scene.hasMapper ? sampling.minimumImageSampleDistance : 0,
                                                          lod: Double(lod()))
            let snapshot = NSMutableDictionary(dictionary: [
                "camera": Self.numbers(view.camera), "near": NSNumber(value: view.near), "far": NSNumber(value: view.far),
                "level": NSNumber(value: level), "width": NSNumber(value: windowWidth),
                "clut": clut, "opacity": Self.numbers(opacity), "mode": NSNumber(value: renderingMode),
                "shading": shading, "clippingPlanes": Self.numbers(clippingPlanes),
                "movieIndex": NSNumber(value: controller.curMovieIndex()),
                "volume": volume, "volumeWidth": NSNumber(value: first.pwidth), "volumeHeight": NSNumber(value: first.pheight),
                "volumeDepth": NSNumber(value: UInt(pix.count)),
                "spacing": [NSNumber(value: sx), NSNumber(value: sy), NSNumber(value: dz)], "transform": transform,
                "superSampling": NSNumber(value: horosSuperSampling), "sampleStep": NSNumber(value: sampleStep),
                "anchoredProjection": NSNumber(value: projection), "projectionOpacity": Self.numbers(projectionOpacity),
                "scalarBackground": NSNumber(value: isRGB() ? Float(-1) : controller.minimumValue())])
            if isRGB() {
                snapshot["colourVolume"] = true
                snapshot["componentTables"] = horosColourTables(fused: false, refresh: false)["tables"] ?? [NSDictionary]()
            }
            if let opacityTable {
                snapshot["opacityTable"] = opacityTable
                snapshot["projectionOpacityTable"] = projectionOpacityTable
            }
            return snapshot
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// The fused series as the renderer takes it, with the same keys: its
    /// voxels and placement, its window, CLUT, opacity table, shading, crop planes
    /// and step, under the view's camera and mode; or an `error`.
    @objc func horosFusedVolumeSnapshot() -> NSDictionary {
        let scene = horosVTKScene(fused: true)
        guard horosHasBlendingVolume, scene.hasMapper, scene.hasProperty else { return ["error": "The fused series has no volume yet."] }
        guard scene.hasCamera, let viewFirst = horosFirstPix, factor() > 0 else { return ["error": "The 3D view has no volume yet."] }
        // The fused voxels, their size and their placement are the MPR's.
        let fused = horosMPRFusedVolume()
        if fused["error"] != nil { return fused as NSDictionary }
        let controller: VRController = self.controller()
        let first = controller.horosVolumePixList()?.firstObject as? DCMPix ?? viewFirst
        let dz = first.sliceInterval != 0 ? fabs(first.sliceInterval) : fabs(first.sliceThickness)
        let sx = first.pixelSpacingX > 0 ? first.pixelSpacingX : 1
        if dz <= 0 || !dz.isFinite { return ["error": "The volume spacing is not usable."] }
        do {
            let view = try horosVolumeCameraSnapshot()
            let projection = renderingMode != 0
            let superSampling = Double(horosSuperSampling)
            let samplesPerMillimetre = Self.samplesPerMillimetre(superSampling: superSampling, spacingX: sx)

            // setBlendingCLUT: and setBlendingWLWW:: build the fused colour function
            // from blendingtable over the fused window, as the image's is built.
            var clut = Data(VolumeColourTable.rgba(colours: horosBlendingColourTable, count: 256))
            // The fused table is not divided by superSampling: VTK applies it per
            // sample as it is.
            let points = VolumeOpacityCurve.fusedPoints(table: horosBlendingOpacityTable, samplesPerMillimetre: samplesPerMillimetre)
            var opacity = points.opacity, projectionOpacity = points.projection
            var opacityTable: Data?, projectionOpacityTable: Data?
            var blendingWl: Float = 0, blendingWw: Float = 0
            getBlendingWLWW(&blendingWl, &blendingWw)
            var level = Double(blendingWl), windowWidth = blendingWw > 0 ? Double(blendingWw) : 1
            // An RGB fused series: its components' tables, as the image's.
            if horosIsBlendingRGB {
                switch try Self.colourTables(scene, samplesPerMillimetre: samplesPerMillimetre) {
                case .failure(let refusal): return ["error": refusal.reason]
                case .success(let tables):
                    clut = tables.clut
                    opacityTable = tables.opacity
                    projectionOpacityTable = tables.projection
                }
                level = 127.5
                windowWidth = 255
                opacity = []
                projectionOpacity = []
            }
            // The renderer takes the transform row by row; the MPR's is column by column.
            let columns = fused["transform"] as? [NSNumber] ?? []
            let transform = Self.rows(fromColumns: columns)
            let width = (fused["width"] as? NSNumber)?.intValue ?? 0, height = (fused["height"] as? NSNumber)?.intValue ?? 0
            let depth = (fused["depth"] as? NSNumber)?.intValue ?? 0
            var sampling = IsiXVTKVolumeSampling()
            try scene.readSampling(&sampling)
            let clippingPlanes: [Float]
            switch try Self.cuttingPlanes(scene, sampling: sampling, width: width, height: height, depth: depth) {
            case .failure(let refusal): return ["error": refusal.reason]
            case .success(let planes): clippingPlanes = planes
            }
            if clippingPlanes.count > 4 * VolumeRendererBridge.maximumClippingPlanes {
                return ["error": "More than 32 crop planes use the original renderer."]
            }
            // The fused property is shaded only if something turns it on; nothing in
            // the host does.
            let shading = try Self.shading(scene, sampling: sampling)
            // The fused mapper samples in the same world frame and at the same
            // SampleDistance as the image's.
            let sampleStep: Double = projection
                ? Double(Float(sampling.sampleDistance) / factor())
                : VolumeSamplingStep.composite(spacingX: sx, superSampling: superSampling)
                    * VolumeSamplingStep.interactionScale(minimumImageSampleDistance: sampling.minimumImageSampleDistance, lod: Double(lod()))
            let snapshot = NSMutableDictionary(dictionary: [
                "camera": Self.numbers(view.camera), "near": NSNumber(value: view.near), "far": NSNumber(value: view.far),
                "level": NSNumber(value: level), "width": NSNumber(value: windowWidth),
                "clut": clut, "opacity": Self.numbers(opacity), "mode": NSNumber(value: renderingMode),
                "shading": shading, "clippingPlanes": Self.numbers(clippingPlanes),
                "volume": fused["volume"] ?? NSData(), "volumeWidth": NSNumber(value: width), "volumeHeight": NSNumber(value: height),
                "volumeDepth": NSNumber(value: UInt(depth)),
                "transform": transform, "superSampling": NSNumber(value: horosSuperSampling), "sampleStep": NSNumber(value: sampleStep),
                "anchoredProjection": NSNumber(value: projection), "projectionOpacity": Self.numbers(projectionOpacity),
                // A ray that misses the fused volume leaves 0 in VTK's 16-bit image.
                "scalarBackground": horosIsBlendingRGB ? NSNumber(value: Int32(-1)) : fused["background"] ?? NSNumber(value: 0)])
            if horosIsBlendingRGB {
                snapshot["colourVolume"] = true
                snapshot["opacityTable"] = opacityTable
                snapshot["projectionOpacityTable"] = projectionOpacityTable
                snapshot["componentTables"] = horosColourTables(fused: true, refresh: false)["tables"] ?? [NSDictionary]()
            }
            return snapshot
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    // MARK: Reading VTK's tables

    private static func samplesPerMillimetre(superSampling: Double, spacingX: Double) -> Double {
        let defaults = UserDefaults.standard
        return VolumeOpacityCurve.samplesPerMillimetre(superSampling: superSampling, spacingX: spacingX,
                                                       rayStep: Double(defaults.float(forKey: "BESTRENDERING")),
                                                       override: defaults.double(forKey: "HorosVolumeMetalOpacityExponent"))
    }

    private struct ColourTables {
        var clut: Data, opacity: Data, projection: Data
    }

    /// Why a volume keeps the original renderer, as the view shows it.
    private struct Refusal: Error {
        let reason: String
    }

    /// An RGB volume's transfer tables as the renderer takes them: VTK's
    /// component colour functions for red, green and blue over the byte's
    /// 0...255, one table after the other, and the components' shared opacity
    /// function at those 256 values, per millimetre of ray for composite
    /// rendering and as it is for a projection's painting. The reason, when a
    /// component is weighted as the renderer does not weigh it.
    private static func colourTables(_ scene: IsiXVTKVolumeScene, samplesPerMillimetre: Double) throws -> Result<ColourTables, Refusal> {
        var sampling = IsiXVTKVolumeSampling()
        try scene.readSampling(&sampling)
        let weights = array(sampling.componentWeight)
        if weights[0] != 0 { return .failure(Refusal(reason: "An RGB volume that weighs its alpha keeps the original renderer.")) }
        var colours: [[Double]] = []
        for component in 1...3 {
            if weights[component] != 1 { return .failure(Refusal(reason: "A weighted RGB component keeps the original renderer.")) }
            colours.append(doubles(try scene.componentColourTable(component, from: 0, to: 255, count: 256)))
        }
        let alphas = doubles(try scene.componentOpacityTable(1, from: 0, to: 255, count: 256))
        let tables = alphas.withUnsafeBufferPointer { VolumeOpacityCurve.tables(alphas: $0, samplesPerMillimetre: samplesPerMillimetre) }
        return .success(ColourTables(clut: Data(VolumeColourTable.componentTables(colours)), opacity: data(tables.composite),
                                     projection: data(tables.painted)))
    }

    /// The crop planes the renderer clips each ray against, in voxel index
    /// space, as VTK's ray caster clips it: the mapper's, and VTK's cropping
    /// regions when they are one box.
    nonisolated private static func cuttingPlanes(_ scene: IsiXVTKVolumeScene, sampling: IsiXVTKVolumeSampling, width: Int, height: Int,
                                      depth: Int) throws -> Result<[Float], VolumeCropPlanes.Refusal> {
        let planes = try scene.voxelClippingPlanes().withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let cropping = scene.hasMapper && sampling.cropping.boolValue
            ? VolumeCropPlanes.Cropping(subvolume: sampling.croppingSubvolume.boolValue, planes: array(sampling.croppingRegionPlanes),
                                        origin: sampling.hasInput.boolValue ? array(sampling.inputOrigin) : nil,
                                        spacing: sampling.hasInput.boolValue ? array(sampling.inputSpacing) : nil)
            : nil
        do {
            return .success(try VolumeCropPlanes.cuttingPlanes(voxelPlanes: planes, cropping: cropping, width: width, height: height,
                                                               depth: depth))
        } catch {
            return .failure(error)
        }
    }

    /// A volume property's shading and the renderer's lights, as VTK's ray
    /// caster lights a sample with them. The headlight VTK creates, the host's
    /// only light, has a black ambient colour, so the material's ambient adds
    /// nothing; with no light yet, that headlight is the one the next render
    /// makes.
    nonisolated private static func shading(_ scene: IsiXVTKVolumeScene, sampling: IsiXVTKVolumeSampling) throws -> [NSNumber] {
        var lights: [VolumeLighting.Light] = []
        try scene.enumerateLights { on, intensity, colour in
            lights.append(VolumeLighting.Light(on: on, intensity: intensity, ambientColour: [colour[0], colour[1], colour[2]]))
        }
        let terms = VolumeLighting.terms(of: lights)
        return [NSNumber(value: Int32(sampling.shade.boolValue ? 1 : 0)), NSNumber(value: sampling.ambient), NSNumber(value: sampling.diffuse),
                NSNumber(value: sampling.specular), NSNumber(value: sampling.specularPower), NSNumber(value: terms.ambient),
                NSNumber(value: terms.intensity)]
    }

    // The snapshot is made at every frame. These are nonisolated and loop by
    // hand: a closure inside the view's main-actor methods checks the executor
    // at each call, which in Debug cost more than the values it boxed.

    nonisolated private static func numbers(_ values: [Double]) -> [NSNumber] {
        var numbers: [NSNumber] = []
        numbers.reserveCapacity(values.count)
        for value in values { numbers.append(NSNumber(value: value)) }
        return numbers
    }

    nonisolated private static func numbers(_ values: [Float]) -> [NSNumber] {
        var numbers: [NSNumber] = []
        numbers.reserveCapacity(values.count)
        for value in values { numbers.append(NSNumber(value: value)) }
        return numbers
    }

    /// A column-major 4 × 4 matrix by rows.
    nonisolated private static func rows(fromColumns columns: [NSNumber]) -> [NSNumber] {
        var rows: [NSNumber] = []
        rows.reserveCapacity(16)
        for index in 0..<16 { rows.append(columns[(index % 4) * 4 + index / 4]) }
        return rows
    }

    /// The view's opacity curve, kept as point strings.
    nonisolated private static func points(_ strings: NSArray?) -> [(x: Double, y: Double)] {
        var points: [(x: Double, y: Double)] = []
        guard let strings else { return points }
        points.reserveCapacity(strings.count)
        for case let string as String in strings {
            let point = NSPointFromString(string)
            points.append((Double(point.x), Double(point.y)))
        }
        return points
    }

    nonisolated private static func data(_ values: [Float]) -> Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

    nonisolated private static func doubles(_ data: Data) -> [Double] { data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) } }

    /// A C array imported as a tuple, as an array.
    nonisolated private static func array<T>(_ tuple: T) -> [Double] {
        withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Double.self)) }
    }
}

// MARK: - What the Metal host reads of the view

// The view's state as the Metal host and the MPR's Metal planes read it: the
// VTK objects go out only as IsiXVTKVolumeScene, the VTK adapter's reading
// of them.
extension VRView {

    /// The view's volume, or the fused series' (`fused`): the view's renderer and
    /// camera with that volume's mapper, property, transfer functions and
    /// importer. A fused scene without a fused series has none of them.
    func horosVTKScene(fused: Bool) -> IsiXVTKVolumeScene { horos_vtk.volumeSceneFused(fused) }

    /// A series is fused over the volume.
    var horosHasBlendingVolume: Bool { horos_vtk.hasBlendingVolume }
    var horosIsBlendingRGB: Bool { horos_isBlendingRGB }
    /// The full-depth capture is on (prepareFullDepthCapture).
    var horosFullDepthMode: Bool { horos_fullDepthMode != 0 }
    /// The fused series' offset and factor into VTK's 16 bits, as offset and
    /// valueFactor are the volume's.
    var horosBlendingOffset: Float { horos_blendingOFFSET16 }
    var horosBlendingValueFactor: Float { horos_blendingValueFactor }
    var horosSuperSampling: Float { horos_superSampling }
    /// The first image of the volume, and of the fused series.
    var horosFirstPix: DCMPix? { horos_firstObject }
    var horosBlendingFirstPix: DCMPix? { horos_blendingFirstObject }
    var horosBlendingController: ViewerController? { horos_blendingController }
    var horosBlendingPixList: [DCMPix]? { horos_blendingPixList.map { $0 as! [DCMPix] } }
    /// The fused voxels VTK converts to 16 bits from.
    var horosBlendingData: UnsafePointer<Float>? { UnsafePointer(horos_blendingData) }
    /// The CLUT over the window, 256 entries of red, green, blue in [0, 1]; the
    /// fused series' table; and the fused opacity table, as setBlendingFactor:
    /// fills them.
    var horosColourTable: UnsafePointer<Double> { UnsafePointer(horos_table) }
    var horosBlendingColourTable: UnsafePointer<Double> { UnsafePointer(horos_blendingtable) }
    var horosBlendingOpacityTable: UnsafePointer<Double> { UnsafePointer(horos_alpha) }
    /// The window and level text the view shows, when it shows one.
    var horosShowsWindowText: Bool { horos_vtk.hasWindowText }
    func horosSetWindowText(_ text: String) { horos_vtk.setWindowText(text) }
}
