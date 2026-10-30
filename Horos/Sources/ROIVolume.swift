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
import IsiXROI
import IsiXVolumeRendering

/// A volume made from the stack of ROIs of one name, and the 3D object that
/// shows it in the volume rendering and surface views.
///
/// Implemented in Swift: the Objective-C name and the selectors are those of
/// the former class. The object is a VTK actor of the adapter
/// (IsiXVTKActor); -roiVolumeActor hands its vtkActor * to the volume
/// rendering view, as before.
@objc(ROIVolume) @MainActor
final class ROIVolume: NSObject {
    private let roiList = NSMutableArray()
    private var actor: IsiXVTKActor?
    private var textureImage: IsiXVTKTexture?
    private var volumeValue: Float = 0
    private var redValue: Float = 0, greenValue: Float = 1, blueValue: Float = 1, opacityValue: Float = 1
    private var colorValue: NSColor
    private var visibleValue = false, textured = true
    private var nameValue: NSString = ""
    private let viewer: ViewerController?
    private let propertiesValue: NSMutableDictionary

    /// The scale of the object: patient millimetres to the view's units.
    @objc var factor: Float = 1

    @objc(initWithViewer:)
    init(viewer v: ViewerController?) {
        viewer = v
        colorValue = NSColor(calibratedRed: CGFloat(redValue), green: CGFloat(greenValue), blue: CGFloat(blueValue), alpha: CGFloat(opacityValue))
        propertiesValue = NSMutableDictionary(objects: [nameValue, NSNumber(value: volumeValue), NSNumber(value: redValue),
                                                        NSNumber(value: greenValue), NSNumber(value: blueValue),
                                                        NSNumber(value: opacityValue), colorValue, NSNumber(value: visibleValue),
                                                        NSNumber(value: textured)],
                                              forKeys: ["name", "volume", "red", "green", "blue", "opacity", "color", "visible", "texture"] as [NSString])
        super.init()
    }

    /// Keeps the pencil, closed polygon and brush ROIs of `newRoiList` and
    /// measures their volume.
    @objc(setROIList:)
    func setROIList(_ newRoiList: [ROI]?) {
        var volumeSlices: [ROIVolumeSlice] = []
        volumeValue = 0

        let seriesOrigins = (viewer?.pixList() as? [DCMPix] ?? []).map {
            ROIPatientPoint(x: $0.originX, y: $0.originY, z: $0.originZ)
        }

        for roi in newRoiList ?? [] where roi.type == .tPencil || roi.type == .tCPolygon || roi.type == .tPlain {
            roiList.add(roi)
            guard let pic = roi.pix else { continue }
            var orientation = [Float](repeating: 0, count: 9)
            pic.orientation(&orientation)
            volumeSlices.append(ROIVolumeSlice(areaCm2: Double(roi.roiArea()), originX: pic.originX, originY: pic.originY,
                                               originZ: pic.originZ, normalX: Double(orientation[6]),
                                               normalY: Double(orientation[7]), normalZ: Double(orientation[8]),
                                               componentCount: 1, maskPixelCount: 0, pixelAreaMm2: 0,
                                               spacingBetweenSlicesMm: pic.spacingBetweenSlices))
        }
        if let measured = ROIVolumeGeometry.volume(from: volumeSlices, seriesOrigins: seriesOrigins,
                                                   interpolateMissing: false, meshPointCount: 0) {
            volumeValue = Float(measured.volumeCm3)
        }

        if let first = roiList.firstObject as? ROI {
            nameValue = (first.name ?? "") as NSString
            propertiesValue.setValue(nameValue, forKey: "name")
            propertiesValue.setValue(NSNumber(value: volumeValue), forKey: "volume")
        }
    }

    /// Builds the 3D object of the last ROI, as the ROI volume view builds its own.
    @objc func prepareVTKActor() {
        let splash = WaitRendering(NSLocalizedString("Preparing 3D Object...", comment: ""))
        splash?.showWindow(self)
        defer { splash?.close() }

        let made = ROIVolumeView.generateActor(for: roiList.lastObject as? ROI, viewerController: viewer,
                                               factor: factor, statistics: nil)
        // Without a surface the object stays empty, as before: the views add it all the same.
        actor = made ?? (try? IsiXVTKActor.empty())
        guard let made else { return }
        made.setCulling(front: true, back: true)

        if UserDefaults.standard.integer(forKey: "UseDelaunayFor3DRoi") == 0, let o = viewer?.pixList()?.firstObject as? DCMPix {
            var cosines = [Float](repeating: 0, count: 9)
            o.orientation(&cosines)
            let matrix = SurfacePlacement.userMatrix(cosines: cosines)
            let position = SurfacePlacement.position(origin: SIMD3(o.originX, o.originY, o.originZ), factor: factor, userMatrix: matrix)
            made.position = IsiXVTKPoint(x: position.x, y: position.y, z: position.z)
            matrix.withUnsafeBufferPointer { made.setUserMatrix($0.baseAddress) }
        }

        // The texture.
        var location = UserDefaults.standard.string(forKey: "textureLocation") ?? ""
        if location.isEmpty {
            location = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("texture.tif")
        }
        textureImage = try? IsiXVTKTexture.texture(tiffAt: location, connected: true)
        made.setTexture(textureImage)

        made.setColor(red: Double(redValue), green: Double(greenValue), blue: Double(blueValue))
        made.setSpecular(0.3, power: 20)
        made.setAmbient(0.2, diffuse: 0.8)
        made.opacity = Double(opacityValue)
    }

    @objc func isVolume() -> Bool { roiList.count > 0 }

    @objc func isRoiVolumeActorComputed() -> Bool { actor != nil }

    /// The vtkActor * of the 3D object, built on the first request.
    @objc func roiVolumeActor() -> NSValue {
        if actor == nil { prepareVTKActor() }
        return NSValue(pointer: actor?.vtkActor)
    }

    /// The 3D object itself, for the views that show it.
    var surfaceActor: IsiXVTKActor? {
        if actor == nil { prepareVTKActor() }
        return actor
    }

    @objc func volume() -> Float { volumeValue }

    @objc func color() -> NSColor { colorValue }

    @objc(setColor:)
    func setColor(_ c: NSColor?) {
        guard let c else { return }
        colorValue = c
        redValue = Float(c.redComponent)
        greenValue = Float(c.greenComponent)
        blueValue = Float(c.blueComponent)
        opacityValue = Float(c.alphaComponent)
        propertiesValue.setValue(colorValue, forKey: "color")
        changed("color")
    }

    @objc func red() -> Float { redValue }

    @objc(setRed:)
    func setRed(_ r: Float) {
        redValue = r
        recolour()
        propertiesValue.setValue(NSNumber(value: redValue), forKey: "red")
        changed("red")
    }

    @objc func green() -> Float { greenValue }

    @objc(setGreen:)
    func setGreen(_ g: Float) {
        greenValue = g
        recolour()
        propertiesValue.setValue(NSNumber(value: greenValue), forKey: "green")
        changed("green")
    }

    @objc func blue() -> Float { blueValue }

    @objc(setBlue:)
    func setBlue(_ b: Float) {
        blueValue = b
        recolour()
        propertiesValue.setValue(NSNumber(value: blueValue), forKey: "blue")
        changed("blue")
    }

    @objc func opacity() -> Float { opacityValue }

    @objc(setOpacity:)
    func setOpacity(_ o: Float) {
        opacityValue = o
        colorValue = currentColour()
        actor?.opacity = Double(opacityValue)
        propertiesValue.setValue(NSNumber(value: opacityValue), forKey: "opacity")
        changed("opacity")
    }

    @objc func texture() -> Bool { textured }

    @objc(setTexture:)
    func setTexture(_ o: Bool) {
        textured = o
        if let actor { actor.setTexture(o ? textureImage : nil) }
        propertiesValue.setValue(NSNumber(value: textured), forKey: "texture")
        changed("texture")
    }

    @objc func visible() -> Bool { visibleValue }

    @objc(setVisible:)
    func setVisible(_ d: Bool) {
        visibleValue = d
        propertiesValue.setValue(NSNumber(value: visibleValue), forKey: "visible")
        changed("visible")
    }

    @objc func name() -> NSString { nameValue }

    /// The volume's own dictionary, not a copy.
    @objc func properties() -> NSMutableDictionary { propertiesValue }

    @objc func displayProperties() -> NSMutableDictionary {
        let display = NSMutableDictionary()
        for key in ["color", "red", "green", "blue", "opacity", "texture", "visible"] {
            display.setValue(propertiesValue.value(forKey: key), forKey: key)
        }
        return display
    }

    @objc(setDisplayProperties:)
    func setDisplayProperties(_ newProperties: NSDictionary?) {
        setColor(newProperties?.value(forKey: "color") as? NSColor)
        setRed((newProperties?.value(forKey: "red") as AnyObject?)?.floatValue ?? 0)
        setGreen((newProperties?.value(forKey: "green") as AnyObject?)?.floatValue ?? 0)
        setBlue((newProperties?.value(forKey: "blue") as AnyObject?)?.floatValue ?? 0)
        setOpacity((newProperties?.value(forKey: "opacity") as AnyObject?)?.floatValue ?? 0)
        setTexture((newProperties?.value(forKey: "texture") as AnyObject?)?.boolValue ?? false)
        setVisible((newProperties?.value(forKey: "visible") as AnyObject?)?.boolValue ?? false)
    }

    private func currentColour() -> NSColor {
        NSColor(calibratedRed: CGFloat(redValue), green: CGFloat(greenValue), blue: CGFloat(blueValue), alpha: CGFloat(opacityValue))
    }

    /// The colour of a component changed: the object's colour follows.
    private func recolour() {
        colorValue = currentColour()
        actor?.setColor(red: Double(redValue), green: Double(greenValue), blue: Double(blueValue))
    }

    private func changed(_ key: String) {
        NotificationCenter.default.post(name: .OsirixROIVolumePropertiesChanged, object: self, userInfo: ["key": key])
    }
}
