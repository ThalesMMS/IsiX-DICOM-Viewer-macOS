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

/// The surface view's 3D points: spheres the 2D viewer's points and the
/// clicks on a surface put in the scene, their colours, radii and
/// annotations (3D text that faces the camera), and their selection.
extension SRView {
    // MARK: Adding

    @objc(add3DPoint:::::::)
    func add3DPoint(_ x: Double, _ y: Double, _ z: Double, _ radius: Float, _ r: Float, _ g: Float, _ b: Float) {
        guard let sphere = try? IsiXVTKActor.sphere(at: IsiXVTKPoint(x: x, y: y, z: z), radius: Double(radius)) else { return }
        sphere.setColor(red: Double(r), green: Double(g), blue: Double(b))
        sphere.dragable = true
        sphere.pickable = true

        point3DPositions.append(IsiXVTKPoint(x: x, y: y, z: z))
        point3DRadius.append(radius)
        point3DColors.append(NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1))
        point3DDisplayPosition.append(0)
        point3DPositionsStrings.append(String(format: "x: %0.3f mm\ny: %0.3f mm\nz: %0.3f mm", x, y, z))
        point3DTextColors.append(NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1))
        point3DTextSizes.append(4)

        add3DPointActor(sphere)
        setAnnotation("", for3DPointAt: point3DPositions.count - 1)
    }

    @objc(add3DPoint:::)
    func add3DPoint(_ x: Double, _ y: Double, _ z: Double) {
        add3DPoint(x, y, z, point3DDefaultRadius, point3DDefaultColorRed, point3DDefaultColorGreen, point3DDefaultColorBlue)
    }

    func add3DPointActor(_ actor: IsiXVTKActor) {
        point3DActors.append(actor)
        scene.addActor(actor)
    }

    @objc(addRandomPoints::)
    func addRandomPoints(_ n: Int32, _ r: Int32) {
        for _ in 0..<max(0, Int(n)) {
            func coordinate() -> Double { (Double(Int.random(in: 0...Int(Int32.max))) / (pow(2.0, 31.0) - 1) * 2.0 - 1.0) * Double(r) }
            add3DPoint(coordinate(), coordinate(), coordinate(), 2.0, 1.0, 0.0, 0.0)
        }
    }

    /// The point of a surface under the display position (x, y), in pixels
    /// from the bottom left, the surfaces made pickable for the pick.
    func pickSurface(atDisplayX x: Double, y: Double, world: inout IsiXVTKPoint) -> Bool {
        scene.pick(surfaces, x: x, y: y, tolerance: 0.005, world: &world)
    }

    @objc(pickSurfaceAtDisplayX:y:world:)
    func pickSurface(atDisplayX x: Double, y: Double, world wXYZ: UnsafeMutablePointer<Double>?) -> Bool {
        guard let wXYZ else { return false }
        var world = IsiXVTKPoint(x: 0, y: 0, z: 0)
        let hit = pickSurface(atDisplayX: x, y: y, world: &world)
        wXYZ[0] = world.x
        wXYZ[1] = world.y
        wXYZ[2] = world.z
        return hit
    }

    /// A 3D point where a surface is under (x, y), and its 2D point in the viewer.
    @objc(throw3DPointOnSurface::)
    func throw3DPointOnSurface(_ x: Double, _ y: Double) {
        var world = IsiXVTKPoint(x: 0, y: 0, z: 0)
        guard pickSurface(atDisplayX: x, y: y, world: &world) else { return }
        add3DPoint(world.x, world.y, world.z)
        controller?.add2DPoint(Float(world.x), Float(world.y), Float(world.z))
    }

    /// The voxel of the series at the world point `pt3D`.
    @objc(convert3Dto2Dpoint::)
    func convert3Dto2Dpoint(_ pt3D: UnsafeMutablePointer<Double>?, _ pt2D: UnsafeMutablePointer<Double>?) {
        guard let pt3D, let pt2D else { return }
        var position = (0.0, 0.0, 0.0)
        var spacing = (0.0, 0.0, 0.0)
        if let surface = iso[0], let first = firstObject {
            let p = surface.position
            position = (p.x, p.y, p.z)
            spacing = (first.pixelSpacingX, first.pixelSpacingY, first.sliceInterval)
        }
        if let voxel = SRSurfacePointGeometry.voxel(fromWorldX: pt3D[0], y: pt3D[1], z: pt3D[2],
                                                         rowMajorMatrix: matrix.map { NSNumber(value: $0) },
                                                         actorPositionX: position.0, actorPositionY: position.1, actorPositionZ: position.2,
                                                         spacingX: spacing.0, spacingY: spacing.1, spacingZ: spacing.2) {
            pt2D[0] = voxel.x
            pt2D[1] = voxel.y
            pt2D[2] = voxel.z
        }
    }

    // MARK: Display

    @objc(setDisplay3DPoints:)
    func setDisplay3DPoints(_ on: Bool) {
        display3DPoints = on
        for (index, actor) in point3DActors.enumerated() {
            let text = index < point3DTexts.count ? point3DTexts[index] : nil
            if on {
                scene.addActor(actor)
                if let text { scene.addActor(text) }
            } else {
                scene.removeActor(actor)
                if let text { scene.removeActor(text) }
            }
        }
        unselectAllActors()
        needsDisplay = true
    }

    @objc func toggleDisplay3DPoints() { setDisplay3DPoints(!display3DPoints) }

    // MARK: Selection

    @objc func isAny3DPointSelected() -> Bool {
        pickedActor != nil && Int(selected3DPointIndex()) < point3DActors.count
    }

    /// The index of the picked point, or the number of points when none is.
    @objc func selected3DPointIndex() -> UInt32 {
        guard let picked = pickedActor, let index = point3DActors.firstIndex(where: { $0 === picked }) else {
            return UInt32(point3DActors.count)
        }
        return UInt32(index)
    }

    @objc func unselectAllActors() { horosClearPick() }

    /// What 'p' picks, as vtkPropPicker gave it the 3D points.
    override func horosPickableActors() -> [IsiXVTKActor] { display3DPoints ? point3DActors : [] }

    /// The point's settings in the info panel, which a double click shows under the mouse.
    func showSelected3DPointInfo(_ event: NSEvent) {
        let index = Int(selected3DPointIndex())
        point3DRadiusSlider?.floatValue = point3DRadius[index]
        point3DColorWell?.color = point3DColors[index]
        point3DPositionTextField?.stringValue = point3DPositionsStrings[index]
        point3DDisplayPositionButton?.state = NSControl.StateValue(rawValue: point3DDisplayPosition[index])
        point3DTextSizeSlider?.floatValue = point3DTextSizes[index]
        point3DTextColorWell?.color = point3DTextColors[index]

        if event.clickCount == 2, let panel = point3DInfoPanel {
            let screen = controller?.window?.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin ?? .zero
            panel.setFrame(NSRect(x: screen.x - panel.frame.size.width / 2.0, y: screen.y - panel.frame.size.height - 20.0,
                                  width: panel.frame.size.width, height: panel.frame.size.height),
                           display: true, animate: false)
            panel.orderFront(self)
        }
    }

    // MARK: Removing

    @objc(remove3DPointAtIndex:)
    func remove3DPoint(at index: UInt32) {
        let i = Int(index)
        guard i < point3DActors.count else { return }
        scene.removeActor(point3DActors[i])
        unselectAllActors()
        point3DActors.remove(at: i)
        point3DPositions.remove(at: i)
        point3DRadius.remove(at: i)
        point3DColors.remove(at: i)
        if i < point3DTexts.count {
            scene.removeActor(point3DTexts[i])
            point3DTexts.remove(at: i)
        }
        point3DPositionsStrings.remove(at: i)
        point3DTextColors.remove(at: i)
        point3DTextSizes.remove(at: i)
        needsDisplay = true
    }

    /// Removes the picked point's 2D point; the 3D point goes with the
    /// notification its removal posts.
    @objc func removeSelected3DPoint() {
        guard isAny3DPointSelected() else { return }
        NSLog("[point3DPositionsArray count]: %d", Int32(point3DPositions.count))
        let position = point3DPositions[Int(selected3DPointIndex())]
        controller?.remove2DPoint(Float(position.x), Float(position.y), Float(position.z))
    }

    // MARK: Colours and radii

    /// Whether a change goes to every point, as the panel's checkbox says.
    private var propagatesToAll: Bool { (point3DPropagateToAll?.state ?? .off) != .off }

    @IBAction @objc(IBSetSelected3DPointColor:)
    func ibSetSelected3DPointColor(_ sender: Any?) {
        let color = (sender as? NSColorWell)?.color ?? .white
        if propagatesToAll {
            setAll3DPointsColor(color)
            setAll3DPointsRadius(point3DRadiusSlider?.floatValue ?? 0)
        } else {
            setSelected3DPointColor(color)
        }
        needsDisplay = true
    }

    @IBAction @objc(IBSetSelected3DPointRadius:)
    func ibSetSelected3DPointRadius(_ sender: Any?) {
        let radius = (sender as? NSControl)?.floatValue ?? 0
        if propagatesToAll {
            setAll3DPointsRadius(radius)
            if let color = point3DColorWell?.color.usingColorSpace(.genericRGB) { setAll3DPointsColor(color) }
        } else {
            setSelected3DPointRadius(radius)
        }
        needsDisplay = true
    }

    @IBAction @objc(IBPropagate3DPointsSettings:)
    func ibPropagate3DPointsSettings(_ sender: Any?) {
        guard (sender as? NSButton)?.state == .on else { return }
        setAll3DPointsRadius(point3DRadiusSlider?.floatValue ?? 0)
        if let color = point3DColorWell?.color.usingColorSpace(.genericRGB) { setAll3DPointsColor(color) }
        ibSetSelected3DPointAnnotation(point3DDisplayPositionButton)
        ibSetSelected3DPointAnnotationColor(point3DTextColorWell)
        ibSetSelected3DPointAnnotationSize(point3DTextSizeSlider)
        needsDisplay = true
    }

    @objc(setSelected3DPointColor:)
    func setSelected3DPointColor(_ color: NSColor) {
        if isAny3DPointSelected() { set3DPoint(at: selected3DPointIndex(), color: color) }
    }

    @objc(setAll3DPointsColor:)
    func setAll3DPointsColor(_ color: NSColor) {
        for index in point3DColors.indices { set3DPoint(at: UInt32(index), color: color) }
    }

    @objc(set3DPointAtIndex:Color:)
    func set3DPoint(at index: UInt32, color: NSColor) {
        let i = Int(index)
        let rgb = SRController.surfaceRGB(color)
        point3DActors[i].setColor(red: Double(rgb.red), green: Double(rgb.green), blue: Double(rgb.blue))
        point3DColors[i] = color
    }

    @objc(setSelected3DPointRadius:)
    func setSelected3DPointRadius(_ radius: Float) {
        if isAny3DPointSelected() { set3DPoint(at: selected3DPointIndex(), radius: radius) }
    }

    @objc(setAll3DPointsRadius:)
    func setAll3DPointsRadius(_ radius: Float) {
        for index in point3DRadius.indices { set3DPoint(at: UInt32(index), radius: radius) }
    }

    @objc(set3DPointAtIndex:Radius:)
    func set3DPoint(at index: UInt32, radius: Float) {
        let i = Int(index)
        _ = try? point3DActors[i].setSphere(centre: point3DPositions[i], radius: Double(radius))
        point3DRadius[i] = radius
    }

    @IBAction @objc(save3DPointsDefaultProperties:)
    func save3DPointsDefaultProperties(_ sender: Any?) {
        let defaults = UserDefaults.standard
        if let color = point3DColorWell?.color.usingColorSpace(.genericRGB) {
            point3DDefaultColorRed = Float(color.redComponent)
            point3DDefaultColorGreen = Float(color.greenComponent)
            point3DDefaultColorBlue = Float(color.blueComponent)
            point3DDefaultColorAlpha = Float(color.alphaComponent)
        }
        defaults.set(point3DDefaultColorRed, forKey: "points3DcolorRed")
        defaults.set(point3DDefaultColorGreen, forKey: "points3DcolorGreen")
        defaults.set(point3DDefaultColorBlue, forKey: "points3DcolorBlue")
        defaults.set(point3DDefaultColorAlpha, forKey: "points3DcolorAlpha")
        point3DDefaultRadius = point3DRadiusSlider?.floatValue ?? 0
        defaults.set(point3DDefaultRadius, forKey: "points3Dradius")
    }

    @objc func load3DPointsDefaultProperties() {
        let defaults = UserDefaults.standard
        point3DDefaultColorRed = defaults.float(forKey: "points3DcolorRed")
        point3DDefaultColorGreen = defaults.float(forKey: "points3DcolorGreen")
        point3DDefaultColorBlue = defaults.float(forKey: "points3DcolorBlue")
        point3DDefaultColorAlpha = defaults.float(forKey: "points3DcolorAlpha")
        if point3DDefaultColorAlpha == 0.0 {
            point3DDefaultColorRed = 1.0
            point3DDefaultColorGreen = 0.0
            point3DDefaultColorBlue = 0.0
            point3DDefaultColorAlpha = 1.0
        }
        point3DDefaultRadius = defaults.float(forKey: "points3Dradius")
        if point3DDefaultRadius == 0 { point3DDefaultRadius = 1.0 }
    }

    // MARK: Annotations

    @IBAction @objc(IBSetSelected3DPointAnnotation:)
    func ibSetSelected3DPointAnnotation(_ sender: Any?) {
        let displayPosition = (sender as? NSButton)?.state.rawValue ?? 0
        if propagatesToAll {
            for index in point3DActors.indices { setAnnotation(withPosition: displayPosition, for3DPointAt: UInt32(index)) }
        } else {
            setAnnotation(withPosition: displayPosition, for3DPointAt: selected3DPointIndex())
        }
        needsDisplay = true
    }

    @objc(setAnnotationWithPosition:for3DPointAtIndex:)
    func setAnnotation(withPosition displayPosition: Int, for3DPointAt index: UInt32) {
        let i = Int(index)
        guard i < point3DPositionsStrings.count else { return }
        let position = displayPosition != 0 ? point3DPositionsStrings[i] : ""
        setAnnotation(position, for3DPointAt: i)
        if !position.isEmpty { displayAnnotation(for3DPointAt: index) } else { hideAnnotation(for3DPointAt: index) }
        point3DDisplayPosition[i] = displayPosition
    }

    /// The 3D text of point `index`, beside its sphere, replacing the one it had.
    func setAnnotation(_ annotation: String, for3DPointAt index: Int) {
        guard let text = try? IsiXVTKActor.follower(text: annotation) else { return }
        let radius = Double(point3DRadius[index]), position = point3DPositions[index]
        let size = Double(point3DTextSizes[index])
        text.setUniformScale(size)
        text.position = IsiXVTKPoint(x: position.x + radius, y: position.y + radius, z: position.z + radius)
        let colour = SRController.surfaceRGB(point3DTextColors[index])
        text.setColor(red: Double(colour.red), green: Double(colour.green), blue: Double(colour.blue))
        if index < point3DTexts.count {
            scene.removeActor(point3DTexts[index])
            point3DTexts[index] = text
        } else {
            point3DTexts.append(text)
        }
    }

    @objc(displayAnnotationFor3DPointAtIndex:)
    func displayAnnotation(for3DPointAt index: UInt32) {
        let text = point3DTexts[Int(index)]
        scene.addActor(text)
        text.followCamera(of: scene)
        needsDisplay = true
    }

    @objc(hideAnnotationFor3DPointAtIndex:)
    func hideAnnotation(for3DPointAt index: UInt32) {
        scene.removeActor(point3DTexts[Int(index)])
        needsDisplay = true
    }

    @IBAction @objc(IBSetSelected3DPointAnnotationColor:)
    func ibSetSelected3DPointAnnotationColor(_ sender: Any?) {
        guard Int(selected3DPointIndex()) < point3DTexts.count, let c = (sender as? NSColorWell)?.color else { return }
        let rgb = SRController.surfaceRGB(c)
        let r = Double(rgb.red), g = Double(rgb.green), b = Double(rgb.blue)
        if propagatesToAll {
            for i in point3DActors.indices {
                point3DTexts[i].setColor(red: r, green: g, blue: b)
                point3DTextColors[i] = c
            }
        } else {
            let i = Int(selected3DPointIndex())
            point3DTexts[i].setColor(red: r, green: g, blue: b)
            point3DTextColors[i] = c
        }
        needsDisplay = true
    }

    @IBAction @objc(IBSetSelected3DPointAnnotationSize:)
    func ibSetSelected3DPointAnnotationSize(_ sender: Any?) {
        guard Int(selected3DPointIndex()) < point3DTexts.count else { return }
        let s = (sender as? NSControl)?.floatValue ?? 0
        if propagatesToAll {
            for i in point3DActors.indices {
                point3DTexts[i].setUniformScale(Double(s))
                point3DTextSizes[i] = s
            }
        } else {
            let i = Int(selected3DPointIndex())
            point3DTexts[i].setUniformScale(Double(s))
            point3DTextSizes[i] = s
        }
        needsDisplay = true
    }
}
