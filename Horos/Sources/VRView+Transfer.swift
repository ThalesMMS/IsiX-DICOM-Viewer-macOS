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

// The transfer functions of VRView: the window and level, the colour table and
// the opacity curve of the volume, and those of the fused series with its share
// of the picture; the notifications of the colour and opacity editors. A Swift
// extension of the class, with the same selectors; the colour and opacity
// tables are the view's C arrays, through pointers.
//
// The arithmetic keeps the Objective-C's types: a window bound is a float
// expression, widened when VTK takes it as a double, and an opacity point's
// abscissa, `start + (x / 256.0) * (end - start)`, is one fused multiply-add,
// as clang compiled it (addingProduct).

/// Whether the screen shows inverted colours (the Accessibility setting), which
/// the colour tables follow.
@MainActor func vrDisplayUsesInvertedPolarity() -> Bool {
    let value = UserDefaults.standard.persistentDomain(forName: "com.apple.CoreGraphics")?["DisplayUseInvertedPolarity"]
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// 32767 opacities, each its own index.
nonisolated(unsafe) private var linearOpacityTable: UnsafeMutablePointer<UInt16>? = nil

extension VRView {

    @objc(linearOpacity)
    static func linearOpacity() -> UnsafeMutablePointer<UInt16>! {
        if linearOpacityTable == nil {
            let table = malloc(32767 * MemoryLayout<UInt16>.size)!.assumingMemoryBound(to: UInt16.self)

            for i in 0..<32767 {
                table[i] = UInt16(i)
            }
            linearOpacityTable = table
        }

        return linearOpacityTable
    }

    // MARK: - The editors' notifications

    @objc(CLUTChanged:)
    func clutChanged(_ note: Notification) {
        var r = [UInt8](repeating: 0, count: 256), g = [UInt8](repeating: 0, count: 256), b = [UInt8](repeating: 0, count: 256)

        (note.object as AnyObject).convertCLUT(&r, &g, &b)

        setCLUT(&r, &g, &b)
    }

    @objc(OpacityChanged:)
    func opacityChanged(_ note: Notification) {
        let points = (note.object as AnyObject?)?.perform(NSSelectorFromString("getPoints"))?.takeUnretainedValue() as? [Any]
        setOpacity(points)
    }

    // MARK: - Window and level

    @objc(getWLWW::)
    func getWLWW(_ iwl: UnsafeMutablePointer<Float>!, _ iww: UnsafeMutablePointer<Float>!) {
        iwl.pointee = horos_wl
        iww.pointee = horos_ww
    }

    @objc(getBlendingWLWW::)
    func getBlendingWLWW(_ iwl: UnsafeMutablePointer<Float>!, _ iww: UnsafeMutablePointer<Float>!) {
        iwl.pointee = horos_blendingWl
        iww.pointee = horos_blendingWw
    }

    /// The fused series' window bounds, in its 16-bit units.
    private var blendingWindowBounds: (start: Double, end: Double) {
        let factor = horos_blendingValueFactor, offset = horos_blendingOFFSET16
        let wl = horos_blendingWl, ww = horos_blendingWw
        return (Double(factor * (offset + wl - ww / 2)), Double(factor * (offset + wl + ww / 2)))
    }

    @objc(setBlendingWLWW::)
    func setBlendingWLWW(_ iwl: Float, _ iww: Float) {
        if horos_blendingController == nil { return }

        if horos_fullDepthMode != 0 { return }

        horos_blendingWl = iwl
        horos_blendingWw = iww

        let bounds = blendingWindowBounds
        horos_vtk.buildBlendingOpacity(fromTable: horos_alpha, start: bounds.start, end: bounds.end)
        horos_vtk.buildBlendingColour(fromTable: horos_blendingtable, start: bounds.start, end: bounds.end)

        needsDisplay = true
    }

    @objc(setBlendingFactor:)
    func setBlendingFactor(_ a: Float) {
        var a = a
        var val: Float, ii: Float

        if horos_fullDepthMode != 0 { return }

        if horos_blendingController != nil {
            horos_blendingFactor = a
            let alpha = horos_alpha

            if horos_vtk.volumeBlendModeIsMaximumIntensity {
                a *= 2

                for i in 0..<256 {
                    ii = Float(i)
                    val = Float(Double(a * ii) / 256.0)

                    if val > 255 { val = 255 }
                    if val < 0 { val = 0 }

                    alpha[i] = Double(val) / 255.0
                }
            } else {
                a /= 3

                for i in 0..<256 {
                    ii = Float(i)
                    val = Float(Double(a * ii) / 256.0)
                    val = Float(Double(val) - 8.0)

                    if val > 255 { val = 255 }
                    if val < 0 { val = 0 }

                    alpha[i] = Double(val) / 255.0
                }
            }
            let bounds = blendingWindowBounds
            horos_vtk.buildBlendingOpacity(fromTable: alpha, start: bounds.start, end: bounds.end)

            needsDisplay = true
        }
    }

    @objc(setBlendingCLUT:::)
    func setBlendingCLUT(_ r: UnsafeMutablePointer<UInt8>!, _ g: UnsafeMutablePointer<UInt8>!, _ b: UnsafeMutablePointer<UInt8>!) {
        if horos_fullDepthMode != 0 { return }

        guard let r, let g, let b else { return }

        if horos_blendingController != nil {
            let blendingtable = horos_blendingtable
            for i in 0..<256 {
                blendingtable[i * 3 + 0] = Double(r[i]) / 255.0
                blendingtable[i * 3 + 1] = Double(g[i]) / 255.0
                blendingtable[i * 3 + 2] = Double(b[i]) / 255.0
            }
            let bounds = blendingWindowBounds
            horos_vtk.buildBlendingColour(fromTable: blendingtable, start: bounds.start, end: bounds.end)

            needsDisplay = true
        }
    }

    // MARK: - Opacity and colour

    @objc(setOpacity:)
    func setOpacity(_ array: [Any]!) {
        if horos_fullDepthMode != 0 { return }
        let vtk = horos_vtk
        if !vtk.hasOpacityFunction { return }

        var pt = NSPoint.zero
        let start: Float, end: Float
        var opacityAdapter: Float = 1

        if renderingMode == 0 { // VR
            opacityAdapter = horos_superSampling
        }

        let wl = horos_wl, ww = horos_ww
        if horos_isRGB {
            start = wl - ww / 2
            end = wl + ww / 2
        } else {
            let valueFactor = horos_valueFactor, offset = horos_OFFSET16
            start = valueFactor * (offset + wl - ww / 2)
            end = valueFactor * (offset + wl + ww / 2)
        }

        // Retained in place of the former one.
        horos_currentOpacityArray = array

        let points = array ?? []

        vtk.removeAllOpacityPoints()

        if points.count > 0 {
            pt = opacityPoint(points[0])
            pt.x -= 1000
            if pt.x != 0 { vtk.addOpacityPoint(at: Double(0 + start), value: 0) }
        } else {
            vtk.addOpacityPoint(at: Double(0 + start), value: 0)
        }

        for point in points {
            pt = opacityPoint(point)
            pt.x -= 1000
            vtk.addOpacityPoint(at: Double(start).addingProduct(Double(pt.x) / 256.0, Double(end - start)),
                                value: Double(pt.y) / Double(opacityAdapter))
        }

        if points.count == 0 || pt.x != 256 {
            vtk.addOpacityPoint(at: Double(end), value: 1.0 / Double(opacityAdapter))
        } else {
            vtk.addOpacityPoint(at: Double(end), value: Double(pt.y) / Double(opacityAdapter))
        }
        needsDisplay = true
    }

    /// The point of an opacity entry, read as the Objective-C read it: the entry
    /// is messaged as a string whatever its class, so a wrong entry raises the
    /// Objective-C exception it raised there, which callers such as the 3D
    /// state's loading catch, instead of stopping the app on a failed cast.
    private func opacityPoint(_ entry: Any) -> NSPoint {
        NSPointFromString(unsafeBitCast(entry as AnyObject, to: NSString.self) as String)
    }

    @objc(setCLUT:::)
    func setCLUT(_ r: UnsafeMutablePointer<UInt8>!, _ g: UnsafeMutablePointer<UInt8>!, _ b: UnsafeMutablePointer<UInt8>!) {
        if horos_fullDepthMode != 0 { return }
        let vtk = horos_vtk
        if !vtk.hasColourFunction { return }
        if !vtk.hasProperty { return }

        horos_advancedCLUT = false
        if horos_appliedCurves != nil {
            horos_appliedCurves = nil
        }

        var r = r, g = g, b = b
        let inverted = UnsafeMutablePointer<UInt8>.allocate(capacity: 3 * 256)
        defer { inverted.deallocate() }
        let rr = inverted, rg = inverted + 256, rb = inverted + 512

        if vrDisplayUsesInvertedPolarity() {
            if let red = r, let green = g, let blue = b {
                for i in 0..<256 {
                    rr[i] = 255 &- red[i]
                    rg[i] = 255 &- green[i]
                    rb[i] = 255 &- blue[i]
                }
                r = rr
                g = rg
                b = rb
            }
        }

        let table = horos_table
        let wl = horos_wl, ww = horos_ww
        let valueFactor = horos_valueFactor, offset = horos_OFFSET16

        if horos_isRGB {
            if let r, let g, let b {
                for i in 0..<256 {
                    table[i * 3 + 0] = Double(r[i]) / 255.0
                    table[i * 3 + 1] = Double(g[i]) / 255.0
                    table[i * 3 + 2] = Double(b[i]) / 255.0
                }

                vtk.buildColour(fromTable: table, start: Double(wl - ww / 2), end: Double(wl + ww / 2))

                vtk.setRGBComponentsToColourFunction(true)
            } else {
                vtk.setRGBComponentsToColourFunction(false)
            }
        } else {
            if let r, let g, let b {
                for i in 0..<256 {
                    table[i * 3 + 0] = Double(r[i]) / 255.0
                    table[i * 3 + 1] = Double(g[i]) / 255.0
                    table[i * 3 + 2] = Double(b[i]) / 255.0
                }

                vtk.buildColour(fromTable: table, start: Double(valueFactor * (offset + wl - ww / 2)),
                                end: Double(valueFactor * (offset + wl + ww / 2)))
            } else {
                if vrDisplayUsesInvertedPolarity() {
                    for i in 0..<256 {
                        table[(255 - i) * 3 + 0] = Double(i) / 255.0
                        table[(255 - i) * 3 + 1] = Double(i) / 255.0
                        table[(255 - i) * 3 + 2] = Double(i) / 255.0
                    }
                } else {
                    for i in 0..<256 {
                        table[i * 3 + 0] = Double(i) / 255.0
                        table[i * 3 + 1] = Double(i) / 255.0
                        table[i * 3 + 2] = Double(i) / 255.0
                    }
                }

                vtk.buildColour(fromTable: table, start: Double(valueFactor * (offset + wl - ww / 2)),
                                end: Double(valueFactor * (offset + wl + ww / 2)))
            }
        }

        needsDisplay = true
    }

    @objc(setWLWW::)
    dynamic func setWLWW(_ iwl: Float, _ iww: Float) {
        let vtk = horos_vtk
        if !vtk.hasColourFunction {
            return
        }

        var iwl = iwl, iww = iww
        if iwl == 0 && iww == 0 {
            let first = horos_pixList?.object(at: 0) as? DCMPix
            iwl = first?.fullwl ?? 0

            let maximum = horos_controller?.maximumValue() ?? 0
            if maximum != 0 {
                iwl = maximum / 2
                iww = maximum
            } else {
                iww = first?.fullww ?? 0
            }
        }

        horos_wl = iwl
        horos_ww = iww
        let wl = iwl, ww = iww

        if horos_fullDepthMode != 0 { return }

        if horos_advancedCLUT {
            clutOpacityView?.setWL(wl, ww: ww)
            clutOpacityView?.setCLUTtoVRView(true)
        } else {
            setOpacity(horos_currentOpacityArray)
        }

        if horos_isRGB {
            vtk.buildColour(fromTable: horos_table, start: Double(wl - ww / 2), end: Double(wl + ww / 2))
        } else if !horos_advancedCLUT {
            let valueFactor = horos_valueFactor, offset = horos_OFFSET16
            vtk.buildColour(fromTable: horos_table, start: Double(valueFactor * (offset + wl - ww / 2)),
                            end: Double(valueFactor * (offset + wl + ww / 2)))
        }

        let modality = horos_controller?.viewer2D()?.modality()
        let text: String
        if modality == "PT" || (UserDefaults.standard.bool(forKey: "mouseWindowingNM") && modality == "NM") {
            if ww < 50 {
                text = String(format: "From: %0.4f   To: %0.4f ", Double(wl - ww / 2), Double(wl + ww / 2))
            } else {
                text = String(format: "From: %0.f   To: %0.f ", Double(wl - ww / 2), Double(wl + ww / 2))
            }
        } else {
            if ww < 50 {
                text = String(format: "WL: %0.4f WW: %0.4f ", Double(wl), Double(ww))
            } else {
                text = String(format: "WL: %0.f WW: %0.f ", Double(wl), Double(ww))
            }
        }
        let windowText = horos_WLWWString
        _ = strlcpy(windowText, text, 200)
        vtk.setWindowText(windowText)

        needsDisplay = true
    }
}
