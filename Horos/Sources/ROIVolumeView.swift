/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:  OsiriX
 Copyright (c) OsiriX Team
 All rights reserved.
 Distributed under GNU - LGPL
 
 See http://www.osirix-viewer.com/copyright.html for details.
   This software is distributed WITHOUT ANY WARRANTY; without even
   the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
   PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import UniformTypeIdentifiers
import IsiXROI

/// The 3D object of an ROI volume, presented by Metal (HorosSceneView): the
/// surface built from the ROIs of one name, textured, with the orientation
/// cube; the view of ROIVolume.xib and of the SEG surfaces panel.
///
/// Implemented in Swift: the Objective-C name and the selectors are those of
/// the former class. The surface is built by the VTK adapter (IsiXVTKActor).
@objc(ROIVolumeView)
final class ROIVolumeView: HorosSceneView {
    private var roiVolumeActor: IsiXVTKActor?
    private var texture: IsiXVTKTexture?
    private var roi: ROI?

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        NSLog("init ROIVolumeView")
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(closeViewerNotification(_:)), name: .OsirixCloseViewer, object: nil)
        nc.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
    }

    isolated deinit {
        NSLog("Dealloc ROIVolumeView")
        NotificationCenter.default.removeObserver(self)
        if let roiVolumeActor { scene.removeActor(roiVolumeActor) }
    }

    @objc(CloseViewerNotification:)
    func closeViewerNotification(_ note: Notification?) {}

    @objc(windowWillClose:)
    func windowWillClose(_ notification: Notification) {
        if let window, window === notification.object as AnyObject? {
            NotificationCenter.default.removeObserver(self)
            prepareForRelease()
        }
    }

    // MARK: Camera

    /// The coronal view at the same zoom.
    @objc(coView:)
    func coView(_ sender: Any?) {
        let camera = scene.camera
        let distance = Double(Float(camera.distance)), parallel = Double(Float(camera.parallelScale))

        camera.focalPoint = IsiXVTKPoint(x: 0, y: 0, z: 0)
        camera.position = IsiXVTKPoint(x: 0, y: -1, z: 0)
        camera.computeViewPlaneNormal()
        camera.viewUp = IsiXVTKPoint(x: 0, y: 0, z: 1)
        camera.orthogonalizeViewUp()
        scene.resetCamera()

        // The same zoom.
        let centre = camera.focalPoint, normal = camera.viewPlaneNormal
        camera.position = IsiXVTKPoint(x: centre.x + distance * normal.x, y: centre.y + distance * normal.y, z: centre.z + distance * normal.z)
        camera.parallelScale = parallel
        scene.resetCameraClippingRange()

        needsDisplay = true
    }

    // MARK: Capture and export

    /// The view's last frame, tightly packed top-down RGB with the overlay and
    /// the logo, malloc'd for the caller to free.
    @objc(getRawPixels::::::)
    func getRawPixels(_ width: UnsafeMutablePointer<Int>, _ height: UnsafeMutablePointer<Int>, _ spp: UnsafeMutablePointer<Int>,
                      _ bpp: UnsafeMutablePointer<Int>, _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>? {
        // The drawable is measured in pixels: the VTK window knows its size,
        // and the readback returns tightly packed, top-down RGB.
        spp.pointee = 3
        bpp.pointee = 8
        guard let buffer = scene.copyFrameRGB(width: width, height: height, stereo: false) else { return nil }
        // The orientation cube is over the surface, not in it.
        for case let overlay as AnnotationOverlay in subviews {
            overlay.composite(onto: buffer, width: width.pointee, height: height.pointee, originX: 0, originY: 0)
        }
        HorosSceneView.stampLogo(on: buffer, width: width.pointee, height: height.pointee, rowBytes: width.pointee * 3)
        return buffer
    }

    @objc(nsimage:)
    func nsimage(_ originalSize: Bool) -> NSImage {
        var width = 0, height = 0, spp = 0, bpp = 0
        let data = getRawPixels(&width, &height, &spp, &bpp, !originalSize, true)
        defer { free(data) }
        return HorosSceneView.image(rgb: data, width: width, height: height, spp: spp, bpp: bpp)
    }

    @objc(exportJPEG:)
    func exportJPEG(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]
        panel.nameFieldStringValue = "Volume Image"
        if !["jpg", "jpeg"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".jpg"
        }
        panel.begin { [weak self] result in
            guard result == .OK, let self, let url = panel.url else { return }
            let image = self.nsimage(false)
            let data = NSBitmapImageRep.representationOfImageReps(in: image.representations, using: .jpeg,
                                                                   properties: [.compressionFactor: NSDecimalNumber(value: 0.9)])
            try? data?.write(to: URL(fileURLWithPath: url.path), options: .atomic)
            if UserDefaults.standard.bool(forKey: "OPENVIEWER") { NSWorkspace.shared.open(url) }
        }
    }

    @IBAction @objc(copy:)
    func copy(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.tiff], owner: self)
        pasteboard.setData(nsimage(false).tiffRepresentation, forType: .tiff)
    }

    @IBAction @objc(exportDICOMFile:)
    func exportDICOMFile(_ sender: Any?) {
        var width = 0, height = 0, spp = 0, bpp = 0
        let exporter = DICOMExport()
        var produced: [String] = []

        if let data = getRawPixels(&width, &height, &spp, &bpp, true, true) {
            let controller = window?.windowController as? ROIVolumeController
            let pixList = controller?.viewer()?.pixList() as? [DCMPix]
            exporter.setSourceFile(pixList?.first?.srcFile)
            exporter.setSeriesDescription(controller?.seriesName?.stringValue)
            exporter.setSeriesNumber(8856)
            exporter.setPixelData(data, samplesPerPixel: Int32(spp), bitsPerSample: Int32(bpp), width: width, height: height)

            if let file = exporter.writeDCMFile(nil) {
                produced.append(file)
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                            message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
            free(data)
        }
        HorosSceneView.importExportedFiles(produced)
    }

    // MARK: The surface

    @objc(setPixSource:)
    func setPixSource(_ r: ROI?) -> NSDictionary? {
        roi = r
        return renderVolume()
    }

    /// The surface of the ROIs named like `roi` in `vc`, by the algorithm of
    /// the preferences (UseDelaunayFor3DRoi): Iso Contour (0), the voxels
    /// the ROIs fill, or Delaunay (1), the hull of their contour points, in
    /// patient millimetres times `factor`. Nil, after an alert, when no
    /// volume can be computed. `statistics` receives the volume's.
    static func generateActor(for roi: ROI?, viewerController vc: ViewerController?, factor: Float,
                              statistics: NSMutableDictionary?) -> IsiXVTKActor? {
        guard let vc else { return nil }
        let generatedROIs = NSMutableArray()
        var points: NSMutableArray?
        var error: NSString?

        let choice = ROISurfaceAlgorithm.resolvePreference(UserDefaults.standard.integer(forKey: "UseDelaunayFor3DRoi"))
        if !choice.available {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs", comment: ""), message: choice.diagnosis,
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }
        let algorithm = choice.preference

        let volume: Float
        if algorithm == 1 {
            volume = vc.computeVolume(roi, points: &points, generateMissingROIs: true, generatedROIs: generatedROIs,
                                      computeData: statistics, error: &error)
        } else {
            volume = vc.computeVolume(roi, points: nil, generateMissingROIs: true, generatedROIs: generatedROIs,
                                      computeData: statistics, error: &error)
        }

        if error != nil || volume == 0 {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs", comment: ""),
                                        message: (error as String?) ?? NSLocalizedString("Not possible to compute a volume!", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return nil
        }

        var actor: IsiXVTKActor?
        switch algorithm {
        case 0:
            // Iso Contour: every rasterized voxel, the image border included.
            // The shared SEG extractor caps the mask at half-voxel boundaries.
            actor = isoContourActor(for: roi, viewerController: vc, factor: factor, statistics: statistics)
        case 1:
            // Delaunay: the hull of the contour points, in single precision
            // as the points were inserted.
            var xyz: [Double] = []
            for case let point as NSArray in points ?? [] {
                for axis in 0..<3 {
                    xyz.append(Double(((point.object(at: axis) as AnyObject).floatValue ?? 0) * factor))
                }
            }
            actor = try? IsiXVTKActor.delaunayHull(points: xyz.withUnsafeBufferPointer { Data(buffer: $0) })
        default:
            actor = nil
        }

        // The ROIs generated for the computation go again.
        for case let generated as ROI in generatedROIs {
            let index = Int(vc.imageIndexOfROI(generated))
            if index >= 0 {
                NotificationCenter.default.post(name: .OsirixRemoveROI, object: generated, userInfo: nil)
                (vc.roiList()?.object(at: index) as? NSMutableArray)?.remove(generated)
            }
        }
        return actor
    }

    /// The voxel-face surface of the mask the ROIs named like `roi` fill.
    private static func isoContourActor(for roi: ROI?, viewerController vc: ViewerController, factor: Float,
                                        statistics: NSMutableDictionary?) -> IsiXVTKActor? {
        var volumeData: NSData?
        var copied: NSMutableArray?
        vc.copyVolumeData(&volumeData, andDCMPix: &copied, forMovieIndex: Int32(vc.curMovieIndex()))
        guard let copyPixList = copied as? [DCMPix], let first = copyPixList.first else { return nil }

        var orientation = [Float](repeating: 0, count: 9)
        first.orientation(&orientation)
        var frames: [Data] = []
        var offsets: [NSNumber] = []
        let roiList = vc.roiList()
        for (z, p) in copyPixList.enumerated() {
            let count = p.pheight * p.pwidth
            memset(p.fImage, 0, count * MemoryLayout<Float>.size)
            for case let current as ROI in (roiList?.object(at: z) as? NSArray) ?? [] where current.name == roi?.name {
                p.fillROI(current, newVal: 1000, minValue: -Float.greatestFiniteMagnitude, maxValue: Float.greatestFiniteMagnitude,
                          outside: false, orientationStack: 2, stackNo: 0, restore: false, addition: false,
                          spline: current.isSpline, clipMin: NSPoint(x: 0, y: 0), clipMax: NSPoint(x: p.pwidth, y: p.pheight))
            }
            frames.append(ROIVolumeSurface.binaryMask(UnsafeBufferPointer(start: p.fImage, count: count)))
            offsets.append(NSNumber(value: ROIVolumeSurface.frameOffset(origin: SIMD3(p.originX, p.originY, p.originZ),
                                                                         firstOrigin: SIMD3(first.originX, first.originY, first.originZ),
                                                                         normal: (orientation[6], orientation[7], orientation[8]),
                                                                         factor: factor)))
        }
        guard let surface = HorosSEGSurface.mesh(binaryFrames: frames, rows: first.pheight, columns: first.pwidth,
                                           spacingX: Double(factor) * first.pixelSpacingX, spacingY: Double(factor) * first.pixelSpacingY,
                                           frameOffsets: offsets,
                                           singleFrameThickness: ROIVolumeSurface.singleFrameThickness(factor: factor,
                                                                                                        thickness: first.sliceThickness,
                                                                                                        interval: first.sliceInterval)) else { return nil }
        // Voxel faces may meet at an edge in a valid mask. That is not a
        // manifold mesh, but VTK can still display it; the reported ROI
        // volume was computed from the contours, not from this mesh.
        guard !surface.vertices.isEmpty, !surface.triangles.isEmpty else { return nil }
        // With texture coordinates mapped onto a sphere: the view's texture shows only through them.
        let actor = try? IsiXVTKActor.sphereMappedMesh(vertices: surface.vertices, triangles: surface.triangles)
        // The planimetric statistic stays apart from the voxel volume.
        statistics?.setObject(NSNumber(value: ROIVolumeSurface.perUnitFactor(surface.maskVolumeCm3, factor: factor)),
                              forKey: "surfaceMaskVolumeCm3" as NSString)
        if surface.closed {
            statistics?.setObject(NSNumber(value: ROIVolumeSurface.perUnitFactor(surface.meshVolumeCm3, factor: factor)),
                                  forKey: "surfaceMeshVolumeCm3" as NSString)
        }
        return actor
    }

    @objc func renderVolume() -> NSDictionary? {
        let splash = WaitRendering(NSLocalizedString("Rendering 3D Object...", comment: ""))
        splash?.showWindow(self)
        defer { splash?.close() }

        let statistics = NSMutableDictionary()
        var rendered = true
        do {
            try HorosObjCException.perform {
                rendered = self.buildVolume(statistics: statistics)
            }
        } catch {
            NSLog("%@", String(describing: error))
            if ROISurfaceAlgorithm.shouldRewritePreference(afterFailure: UserDefaults.standard.integer(forKey: "UseDelaunayFor3DRoi")) {
                NSLog("ROI surface reconstruction failed; keeping UseDelaunayFor3DRoi")
            }
        }
        return rendered ? statistics : nil
    }

    /// Puts the surface of the view's ROI in the scene. NO when there is none to show.
    private func buildVolume(statistics: NSMutableDictionary) -> Bool {
        let controller = window?.windowController as? ROIVolumeController
        guard let actor = ROIVolumeView.generateActor(for: roi, viewerController: controller?.viewer(), factor: 1, statistics: statistics) else {
            return false
        }

        if let roiVolumeActor { scene.removeActor(roiVolumeActor) }
        roiVolumeActor = actor
        actor.setCulling(front: true, back: true)

        if UserDefaults.standard.integer(forKey: "UseDelaunayFor3DRoi") == 0, let o = controller?.viewer()?.pixList()?.firstObject as? DCMPix {
            actor.setOrigin(IsiXVTKPoint(x: o.originX, y: o.originY, z: o.originZ))
            actor.position = IsiXVTKPoint(x: o.originX, y: o.originY, z: o.originZ)
        }

        // The texture.
        var location = UserDefaults.standard.string(forKey: "textureLocation") ?? ""
        if location.isEmpty {
            location = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("texture.tif")
        }
        if let made = try? IsiXVTKTexture.texture(tiffAt: location, connected: false) { texture = made }
        actor.setTexture(texture)

        actor.setCulling(front: true, back: true)
        scene.addActor(actor)

        // The orientation cube, drawn on the overlay.
        horosOrientationCubeShown = true

        // The camera.
        let camera = scene.camera
        camera.zoom(1.5)
        camera.focalPoint = IsiXVTKPoint(x: 0, y: 0, z: 0)
        camera.position = IsiXVTKPoint(x: 0, y: 0, z: -1)
        camera.computeViewPlaneNormal()
        camera.viewUp = IsiXVTKPoint(x: 0, y: -1, z: 0)
        camera.orthogonalizeViewUp()
        camera.parallelProjection = false
        camera.viewAngle = 60
        scene.resetCamera()

        coView(self)
        return true
    }

    /// Shows the actor of `roiActorPointer`, a vtkActor *, with a camera of its own.
    @objc(setROIActorVolume:)
    func setROIActorVolume(_ roiActorPointer: NSValue?) {
        guard let pointer = roiActorPointer?.pointerValue else { return }
        scene.addActor(pointer: pointer)
        scene.useNewCamera()
        let camera = scene.camera
        camera.zoom(1.5)
        camera.focalPoint = IsiXVTKPoint(x: 0, y: 0, z: 0)
        camera.position = IsiXVTKPoint(x: 0, y: 0, z: -1)
        camera.computeViewPlaneNormal()
        camera.viewUp = IsiXVTKPoint(x: 0, y: -1, z: 0)
        camera.orthogonalizeViewUp()
        scene.resetCamera()
    }

    @objc(setOpacity:showPoints:showSurface:showWireframe:texture:useColor:color:)
    func setOpacity(_ opacity: Float, showPoints: Bool, showSurface: Bool, showWireframe: Bool, texture textured: Bool,
                    useColor: Bool, color: NSColor?) {
        if let actor = roiVolumeActor {
            // The surface is always shown.
            scene.addActor(actor)
            actor.setWireframe(showWireframe)
            actor.opacity = Double(opacity)
            let rgb = color?.usingColorSpace(.genericRGB)
            if useColor {
                actor.setColor(red: Double(rgb?.redComponent ?? 0), green: Double(rgb?.greenComponent ?? 0), blue: Double(rgb?.blueComponent ?? 0))
            } else {
                actor.setColor(red: 1, green: 1, blue: 1)
            }
            actor.setTexture(textured ? texture : nil)
        }
        needsDisplay = true
    }

    /// The scene, for the SEG surfaces panel that shows its meshes here.
    var surfaceScene: IsiXVTKScene { scene }
}
