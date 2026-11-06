//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
@testable import IsiXImaging

// The annotations of the image views, against the code the views ran before
// these types: each `former…` function below is that code, copied from
// DCMView's -drawTextualData:annotationsLevel:fullText:onlyOrientation:,
// -drawOrientation:, -getOrientationText:::, -computeDescriptionInLarge and
// -computeColor, with the view's state turned into a value and each drawing
// call recorded as the command it is now. The annotation levels are the
// former rules of HorosAnnotationLevel (which element a token belongs to, and
// which elements a level shows).

// MARK: - The view's state

private let prefix = "\u{1E}PatientName\u{1E}"

private enum Level: Int { case none = 0, graphic, basic, full, pluginOnly, custom }

/// The element of a token, as +[HorosAnnotationLevel elementForAnnotationItem:] gives it.
private func element(_ token: String) -> String {
    if token.hasPrefix(prefix) { return "patientName" }
    switch token {
    case "Orientation": return "orientation"
    case "PatientName": return "patientName"
    case "Window Level / Window Width": return "windowLevel"
    case "Mouse Position (px)", "Mouse Position (mm)": return "mousePosition"
    case "Image Size", "View Size", "Zoom", "Rotation Angle", "Image Position", "Thickness / Location / Position": return "imageInfo"
    default: return "otherFields"
    }
}

/// Whether `level` shows a text element, `hidden` being what the Custom sheet unchecks.
private func shows(_ element: String, level: Level, hidden: Set<String>) -> Bool {
    switch level {
    case .none, .graphic, .pluginOnly: return false
    case .basic: return element != "patientName"
    case .custom: return !hidden.contains(element)
    case .full: return true
    }
}

private struct View: AnnotationValueSource {
    var level = Level.full
    var ownLevel = Level.full
    var hidden: Set<String> = []
    var pwidth = 512, pheight = 400
    var named = false, previewDatabase = false
    var mouseX: Float = 120.7, mouseY: Float = -3.2
    var rgb = false, value: Float = 41.256, r = 10, g = 200, b = 33
    var suvConverted = false, displaySUV = false, hasSUV = false, suv: Float = 3.456
    var fused: FusedState?
    var scale: Float = 2.5, angle: Float = 725.4
    var current = 3, count = 10, stack = 1, flipped = false
    var step: (x: Double, y: Double, z: Double)? = nil
    var location: (Float, Float, Float) = (12.345, -60.5, 7)
    var isPlane = true, spacingX = 0.7
    var wl: Float = 40, ww: Float = 400, modality = "CT", maxOfSeries: Float = 0
    var thickness = 2.5, sliceLocation = -33.25, slab: (Float, Float) = (7.5, -30)
    var viewPosition: String? = nil, patientPosition: String? = nil
    var patient: String? = "DOE^JANE"

    struct FusedState {
        var x: Float = 11.4, y: Float = 12.6, rgb = false, value: Float = 5.5, r = 1, g = 2, b = 3
        var suvConverted = false, displaySUV = false, hasSUV = false, suv: Float = 1.25
    }

    func shows(_ token: String) -> Bool { IsiXImagingTests_shows(token, self) }
    func showsPatientName() -> Bool { IsiXImagingTests_showsElement("patientName", ownLevel, hidden) }
    func imageSize() -> (width: Int, height: Int) { (pwidth, pheight) }
    func pixelProbe() -> AnnotationPixelProbe? {
        guard !named || previewDatabase else { return nil }
        let image = AnnotationPixelProbe.Reading(x: mouseX, y: mouseY, value: rgb ? .colour(red: r, green: g, blue: b) : .grey(value),
                                                 suvConverted: suvConverted, suv: displaySUV && hasSUV && !suvConverted ? suv : nil)
        let fusedReading = fused.map {
            AnnotationPixelProbe.Reading(x: $0.x, y: $0.y, value: $0.rgb ? .colour(red: $0.r, green: $0.g, blue: $0.b) : .grey($0.value),
                                         suvConverted: $0.suvConverted, suv: $0.displaySUV && $0.hasSUV && !$0.suvConverted ? $0.suv : nil)
        }
        return AnnotationPixelProbe(image: image, fused: fusedReading)
    }
    func zoom() -> Float { scale }
    func rotation() -> Float { angle }
    func imagePosition() -> AnnotationImagePosition {
        AnnotationImagePosition(current: current, count: count, stack: stack, flipped: flipped, step: step)
    }
    func millimetrePosition() -> AnnotationMillimetrePosition? {
        named ? nil : AnnotationMillimetrePosition(x: location.0, y: location.1, z: location.2, isPlane: isPlane, pixelSpacingX: spacingX)
    }
    func windowLevel() -> AnnotationWindowLevel {
        AnnotationWindowLevel(level: wl, width: ww, windowsAsPET: modality == "PT", maximumOfSeries: maxOfSeries)
    }
    func slice() -> AnnotationSlice {
        AnnotationSlice(thickness: thickness, location: sliceLocation, stack: stack, viewPosition: viewPosition, patientPosition: patientPosition)
    }
    func thickSlab() -> (thickness: Float, location: Float) { slab }
    func patientName() -> String? { patient }
}

private func IsiXImagingTests_showsElement(_ element: String, _ level: Level, _ hidden: Set<String>) -> Bool {
    shows(element, level: level, hidden: hidden)
}

private func IsiXImagingTests_shows(_ token: String, _ view: View) -> Bool {
    shows(element(token), level: view.level, hidden: view.hidden)
}

// MARK: - The former code

private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

private func cLong(_ x: Double) -> Int { DrawingGeometry.cLong(x) }

/// -getOrientationText:::, into a C buffer.
private func formerOrientationText(_ orientation: UnsafeMutablePointer<CChar>, _ vector: UnsafeMutablePointer<Float>, _ inv: Bool) {
    orientation[0] = 0
    let orientationX: String, orientationY: String, orientationZ: String
    let optr = NSMutableString()
    if inv {
        orientationX = -vector[0] < 0 ? "R" : "L"
        orientationY = -vector[1] < 0 ? "A" : "P"
        orientationZ = -vector[2] < 0 ? "I" : "S"
    } else {
        orientationX = vector[0] < 0 ? "R" : "L"
        orientationY = vector[1] < 0 ? "A" : "P"
        orientationZ = vector[2] < 0 ? "I" : "S"
    }
    var absX = Float(fabs(Double(vector[0])))
    var absY = Float(fabs(Double(vector[1])))
    var absZ = Float(fabs(Double(vector[2])))
    for _ in 0 ..< 3 {
        if Double(absX) > 0.2 && absX >= absY && absX >= absZ {
            optr.append(orientationX); absX = 0
        } else if Double(absY) > 0.2 && absY >= absX && absY >= absZ {
            optr.append(orientationY); absY = 0
        } else if Double(absZ) > 0.2 && absZ >= absX && absZ >= absY {
            optr.append(orientationZ); absZ = 0
        } else {
            break
        }
    }
    strcpy(orientation, optr.utf8String!)
}

private func formerOrientationText(_ v: (Float, Float, Float), _ inv: Bool) -> String {
    var vector = [v.0, v.1, v.2]
    var buffer = [CChar](repeating: 0, count: 10)
    formerOrientationText(&buffer, &vector, inv)
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private typealias Command = AnnotationOverlayLayout.Command

/// The positions' rasters, alignment and lines of
/// -drawTextualData:annotationsLevel:fullText:onlyOrientation:, from the
/// annotations of the image, in the order of `keys`.
private func formerTextualData(_ view: View, keys: [String], annotations: [String: [[String]]], x originX: Double, y originY: Double,
                               width: Double, height: Double, sf: Float, stringSize: (width: Double, height: Double),
                               inset: Double, colorBoxSize: Int32, fullText: Bool) -> (commands: [Command], lowerLeftTop: Int) {
    var commands: [Command] = []
    var xRasterInit: [String: Int32] = [:], yRasterInit: [String: Int32] = [:], yRasterIncrement: [String: Int32] = [:]
    var align: [String: AnnotationOverlayLayout.TextAlignment] = [:]
    xRasterInit["TopLeft"] = cInt32(originX + (6 + inset) * Double(sf))
    xRasterInit["MiddleLeft"] = cInt32(originX + Double(6 * sf))
    xRasterInit["LowerLeft"] = cInt32(originX + Double(6 * sf))
    xRasterInit["TopRight"] = cInt32(originX + width - Double(2 * sf))
    xRasterInit["MiddleRight"] = cInt32(originX + width - Double(2 * sf))
    xRasterInit["LowerRight"] = cInt32(originX + width - Double(2 * sf))
    xRasterInit["TopMiddle"] = cInt32(originX + width / 2)
    xRasterInit["LowerMiddle"] = cInt32(originX + width / 2)
    for key in ["TopLeft", "MiddleLeft", "LowerLeft"] { align[key] = .left }
    for key in ["TopRight", "MiddleRight", "LowerRight"] { align[key] = .right }
    for key in ["TopMiddle", "LowerMiddle"] { align[key] = .center }
    yRasterInit["TopLeft"] = cInt32(originY + stringSize.height + Double(2 * sf))
    yRasterInit["TopMiddle"] = cInt32(originY + stringSize.height)
    yRasterInit["TopRight"] = cInt32(originY + stringSize.height + Double(2 * sf))
    yRasterInit["MiddleLeft"] = cInt32(originY + height / 2)
    yRasterInit["MiddleRight"] = cInt32(originY + height / 2)
    yRasterInit["LowerLeft"] = cInt32(originY + height - Double(2 * sf))
    yRasterInit["LowerRight"] = cInt32(originY + height - Double(2 * sf) - stringSize.height)
    yRasterInit["LowerMiddle"] = cInt32(originY + height - Double(2 * sf))
    for key in ["TopLeft", "TopMiddle", "TopRight", "MiddleLeft", "MiddleRight"] { yRasterIncrement[key] = cInt32(stringSize.height) }
    for key in ["LowerLeft", "LowerRight", "LowerMiddle"] { yRasterIncrement[key] = cInt32(-stringSize.height) }

    var orientationDrawn = false
    if shows("orientation", level: view.level, hidden: view.hidden) {
        for positionKey in ["TopMiddle", "MiddleLeft", "MiddleRight", "LowerMiddle"] {
            let blocks = annotations[positionKey] ?? []
            let ordered = positionKey.hasPrefix("Lower") ? Array(blocks.reversed()) : blocks
            for annot in ordered {
                for item in annot where item == "Orientation" {
                    if !orientationDrawn { commands.append(.orientation) }
                    orientationDrawn = true
                }
            }
        }
    }
    if orientationDrawn {
        for key in ["TopMiddle", "MiddleLeft", "MiddleRight", "LowerMiddle"] {
            yRasterInit[key] = (yRasterInit[key] ?? 0) &+ (yRasterIncrement[key] ?? 0)
        }
    }

    var lowerLeftTop = Int(yRasterInit["LowerLeft"] ?? 0)
    for key in keys {
        let xRaster = Int(xRasterInit[key] ?? 0)
        var yRaster = Int(yRasterInit[key] ?? 0)
        let increment = yRasterIncrement[key] ?? 0
        let blocks = annotations[key] ?? []
        let ordered = key.hasPrefix("Lower") ? Array(blocks.reversed()) : blocks
        for annotArray in ordered {
            let tempString = NSMutableString(string: ""), tempString2 = NSMutableString(string: "")
            let tempString3 = NSMutableString(string: ""), tempString4 = NSMutableString(string: "")
            for itemString in annotArray {
                let item = itemString as NSString
                if !shows(element(itemString), level: view.level, hidden: view.hidden) { continue }
                if item.isEqual(to: "Image Size") && fullText {
                    tempString.appendFormat("Image size: %ld x %ld" as NSString, view.pwidth, view.pheight)
                } else if item.isEqual(to: "View Size") && fullText {
                    tempString.appendFormat("View size: %ld x %ld" as NSString, cLong(width), cLong(height))
                } else if item.isEqual(to: "Mouse Position (px)") {
                    if !view.named || view.previewDatabase {
                        var pixelUnit: NSString = ""
                        if view.suvConverted { pixelUnit = "SUV" }
                        if view.rgb {
                            tempString.appendFormat("X: %d px Y: %d px Value: R:%ld G:%ld B:%ld" as NSString, cInt32(Double(view.mouseX)), cInt32(Double(view.mouseY)), view.r, view.g, view.b)
                        } else {
                            tempString.appendFormat("X: %d px Y: %d px Value: %2.2f %@" as NSString, cInt32(Double(view.mouseX)), cInt32(Double(view.mouseY)), Double(view.value), pixelUnit)
                        }
                        if let blending = view.fused {
                            if blending.suvConverted { pixelUnit = "SUV" }
                            if blending.rgb {
                                tempString2.appendFormat("Fused Image : X: %d px Y: %d px Value: R:%ld G:%ld B:%ld" as NSString, cInt32(Double(blending.x)), cInt32(Double(blending.y)), blending.r, blending.g, blending.b)
                            } else {
                                tempString2.appendFormat("Fused Image : X: %d px Y: %d px Value: %2.2f %@" as NSString, cInt32(Double(blending.x)), cInt32(Double(blending.y)), Double(blending.value), pixelUnit)
                            }
                        }
                        if view.displaySUV && view.hasSUV && !view.suvConverted {
                            tempString3.appendFormat("SUV: %.2f" as NSString, Double(view.suv))
                        }
                        if let blending = view.fused, blending.displaySUV && blending.hasSUV && !blending.suvConverted {
                            tempString4.appendFormat("SUV (fused image): %.2f" as NSString, Double(blending.suv))
                        }
                    }
                } else if item.isEqual(to: "Zoom") && fullText {
                    tempString.appendFormat("Zoom: %0.0f%%" as NSString, Double(view.scale) * 100.0)
                } else if item.isEqual(to: "Rotation Angle") && fullText {
                    tempString.appendFormat(" Angle: %0.0f" as NSString, Double(Float(cLong(Double(view.angle)) % 360)))
                } else if item.isEqual(to: "Image Position") && fullText {
                    var orientationStack: NSString = ""
                    if let step = view.step {
                        var xd = step.x, yd = step.y, zd = step.z
                        let interval3d = sqrt(xd * xd + yd * yd + zd * zd)
                        xd /= interval3d; yd /= interval3d; zd /= interval3d
                        var v: [Float] = [Float(xd), Float(yd), Float(zd)]
                        var text = [CChar](repeating: 0, count: 20)
                        text.withUnsafeMutableBufferPointer { buffer in
                            let start = buffer.baseAddress!, end = start + 10
                            if !view.flipped {
                                formerOrientationText(start, &v, true); formerOrientationText(end, &v, false)
                            } else {
                                formerOrientationText(start, &v, false); formerOrientationText(end, &v, true)
                            }
                            if start[0] != 0 && end[0] != 0 {
                                let pos: Float = view.flipped ? Float(UInt(bitPattern: view.count) &- UInt(bitPattern: view.current)) / Float(view.count)
                                                              : Float(view.current) / Float(view.count)
                                if Double(pos) < 0.4 {
                                    orientationStack = NSString(format: " %c (%c -> %c)", Int32(start[0]), Int32(start[0]), Int32(end[0]))
                                } else if Double(pos) > 0.6 {
                                    orientationStack = NSString(format: " %c (%c -> %c)", Int32(end[0]), Int32(start[0]), Int32(end[0]))
                                } else {
                                    orientationStack = NSString(format: " (%c -> %c)", Int32(start[0]), Int32(end[0]))
                                }
                            }
                        }
                    }
                    let curImage = view.current, pixCount = view.count
                    if view.stack > 1 {
                        var maxVal = view.flipped ? curImage - view.stack + 1 : curImage + view.stack
                        if maxVal < 0 { maxVal = 0 }
                        if maxVal > pixCount { maxVal = pixCount }
                        if view.flipped {
                            tempString.appendFormat("Im: %ld-%ld/%ld %@" as NSString, pixCount - curImage, pixCount &- maxVal, pixCount, orientationStack)
                        } else {
                            tempString.appendFormat("Im: %ld-%ld/%ld %@" as NSString, curImage + 1, maxVal, pixCount, orientationStack)
                        }
                    } else if fullText {
                        if view.flipped {
                            tempString.appendFormat("Im: %ld/%ld %@" as NSString, pixCount - curImage, pixCount, orientationStack)
                        } else {
                            tempString.appendFormat("Im: %ld/%ld %@" as NSString, curImage + 1, pixCount, orientationStack)
                        }
                    }
                } else if item.isEqual(to: "Mouse Position (mm)") {
                    if !view.named {
                        let location = view.location
                        if view.isPlane {
                            if fabs(Double(location.0)) < 1.0 && location.0 != 0.0 && view.spacingX < 0.2 {
                                tempString.appendFormat("X: %2.2f %cm Y: %2.2f %cm Z: %2.2f %cm" as NSString, Double(location.0) * 1000.0, Int32(0xB5), Double(location.1) * 1000.0, Int32(0xB5), Double(location.2) * 1000.0, Int32(0xB5))
                            } else {
                                tempString.appendFormat("X: %2.2f mm Y: %2.2f mm Z: %2.2f mm" as NSString, Double(location.0), Double(location.1), Double(location.2))
                            }
                        } else {
                            if fabs(Double(location.0)) < 1.0 && location.0 != 0.0 && view.spacingX < 0.2 {
                                tempString.appendFormat("X: %2.2f %cm Y: %2.2f %cm" as NSString, Double(location.0) * 1000.0, Int32(0xB5), Double(location.1) * 1000.0, Int32(0xB5))
                            } else {
                                tempString.appendFormat("X: %2.2f mm Y: %2.2f mm" as NSString, Double(location.0), Double(location.1))
                            }
                        }
                    }
                } else if item.isEqual(to: "Window Level / Window Width") {
                    let lwl = view.wl, lww = view.ww
                    let iwl = cInt32(Double(lwl)), iww = cInt32(Double(lww))
                    if lww < 50 && (lwl != Float(iwl) || lww != Float(iww)) {
                        tempString.appendFormat("WL: %0.4f WW: %0.4f" as NSString, Double(lwl), Double(lww))
                    } else {
                        tempString.appendFormat("WL: %d WW: %d" as NSString, cInt32(Double(lwl)), cInt32(Double(lww)))
                    }
                    if view.modality == "PT" && view.maxOfSeries != 0 {
                        let min = lwl - lww / 2, max = lwl + lww / 2
                        tempString2.appendFormat("From: %d %% (%0.2f) to: %d %% (%0.2f)" as NSString, cLong(Double(min) * 100.0 / Double(view.maxOfSeries)), Double(lwl - lww / 2), cLong(Double(max) * 100.0 / Double(view.maxOfSeries)), Double(lwl + lww / 2))
                    }
                } else if item.isEqual(to: "Plugin") {
                    commands.append(.plugin(x: xRaster, y: yRaster, alignment: align[key] ?? .left))
                    yRaster += Int(increment)
                } else if item.isEqual(to: "Orientation") {
                    if !orientationDrawn { commands.append(.orientation) }
                    orientationDrawn = true
                } else if item.isEqual(to: "Thickness / Location / Position") {
                    if view.thickness != 0 && view.sliceLocation != 0 {
                        if view.stack > 1 {
                            let vv = view.slab.0, pp = view.slab.1
                            if vv < 1.0 && vv != 0.0 {
                                if fabs(Double(pp)) < 1.0 && pp != 0.0 {
                                    tempString.appendFormat("Thickness: %0.2f %cm Location: %0.2f %cm" as NSString, fabs(Double(vv) * 1000.0), Int32(0xB5), Double(pp) * 1000.0, Int32(0xB5))
                                } else {
                                    tempString.appendFormat("Thickness: %0.2f %cm Location: %0.2f mm" as NSString, fabs(Double(vv) * 1000.0), Int32(0xB5), Double(pp))
                                }
                            } else {
                                tempString.appendFormat("Thickness: %0.2f mm Location: %0.2f mm" as NSString, fabs(Double(vv)), Double(pp))
                            }
                        } else if fullText {
                            if view.thickness < 1.0 && view.thickness != 0.0 {
                                if fabs(view.sliceLocation) < 1.0 && view.sliceLocation != 0.0 {
                                    tempString.appendFormat("Thickness: %0.2f %cm Location: %0.2f %cm" as NSString, view.thickness * 1000.0, Int32(0xB5), view.sliceLocation * 1000.0, Int32(0xB5))
                                } else {
                                    tempString.appendFormat("Thickness: %0.2f %cm Location: %0.2f mm" as NSString, view.thickness * 1000.0, Int32(0xB5), view.sliceLocation)
                                }
                            } else {
                                tempString.appendFormat("Thickness: %0.2f mm Location: %0.2f mm" as NSString, view.thickness, view.sliceLocation)
                            }
                        }
                    } else if view.viewPosition != nil || view.patientPosition != nil {
                        if let viewPosition = view.viewPosition {
                            tempString.appendFormat("Position: %@ " as NSString, viewPosition as NSString)
                        }
                        if let patientPosition = view.patientPosition {
                            if view.viewPosition != nil {
                                tempString.append(patientPosition)
                            } else {
                                tempString.appendFormat("Position: %@ " as NSString, patientPosition as NSString)
                            }
                        }
                    }
                } else if item.isEqual(to: "PatientName") {
                    if shows("patientName", level: view.ownLevel, hidden: view.hidden), let name = view.patient, (name as NSString).length != 0 {
                        tempString.append(name)
                    }
                } else if item.hasPrefix(prefix) {
                    if shows("patientName", level: view.ownLevel, hidden: view.hidden) {
                        tempString.appendFormat(" %@" as NSString, item.substring(from: (prefix as NSString).length) as NSString)
                    }
                } else if fullText {
                    tempString.appendFormat(" %@" as NSString, item)
                }
            }
            for line in [tempString, tempString2, tempString3, tempString4] {
                line.setString(line.trimmingCharacters(in: .whitespaces))
                if !line.isEqual(to: "") {
                    var xAdd = 0
                    if key == "TopLeft" && Float(yRaster &- Int(increment)) < Float(colorBoxSize) + 2 * sf {
                        xAdd = Int(colorBoxSize)
                    }
                    commands.append(.text(line as String, x: xRaster &+ xAdd, y: yRaster, alignment: align[key] ?? .left))
                    yRaster += Int(increment)
                }
            }
        }
        if key == "LowerLeft" { lowerLeftTop = yRaster }
    }
    return (commands, lowerLeftTop)
}

/// The same frame through AnnotationOverlayLayout, as the view runs it now.
private func textualData(_ view: View, keys: [String], annotations: [String: [[String]]], x: Double, y: Double, width: Double, height: Double,
                         sf: Float, stringSize: (width: Double, height: Double), inset: Double, colorBoxSize: Int32,
                         fullText: Bool) -> (commands: [Command], lowerLeftTop: Int) {
    var layout = AnnotationOverlayLayout(originX: x, originY: y, width: width, height: height, scale: sf, characterWidth: stringSize.width,
                                         lineHeight: stringSize.height, topLeftInset: inset, colourBoxSize: colorBoxSize)
    var commands: [Command] = []
    var orientationDrawn = false
    if shows("orientation", level: view.level, hidden: view.hidden) && AnnotationOverlayLayout.asksForOrientation(annotations) {
        commands.append(.orientation)
        orientationDrawn = true
        layout = layout.withOrientationDrawn()
    }
    var lowerLeftTop = Int(layout.start(of: "LowerLeft").y)
    for key in keys {
        let drawn = layout.commands(for: key, lines: annotations[key] ?? [], fullText: fullText, patientNamePrefix: prefix,
                                    phrases: .english, values: view)
        for command in drawn.commands {
            if command == .orientation {
                if !orientationDrawn { commands.append(.orientation) }
                orientationDrawn = true
            } else {
                commands.append(command)
            }
        }
        if key == "LowerLeft" { lowerLeftTop = drawn.endY }
    }
    return (commands, lowerLeftTop)
}

// MARK: - Tests

struct AnnotationOverlayLayoutTests {
    private let annotations: [String: [[String]]] = [
        "TopLeft": [["Image Size"], ["View Size"], ["PatientName", "\u{1E}PatientName\u{1E}DOE^JOHN"], ["Plugin"], ["Study Description", "Head"]],
        "TopRight": [["Window Level / Window Width"], ["Zoom", "Rotation Angle"], ["Mouse Position (px)"]],
        "LowerLeft": [["Image Position"], ["Thickness / Location / Position"], ["Mouse Position (mm)"]],
        "LowerRight": [["Window Level / Window Width", "Zoom"], ["Orientation"], ["Manufacturer"]],
        "TopMiddle": [["Orientation"]],
        "MiddleLeft": [["Series Number"]],
        "LowerMiddle": [["Plugin", "Image Size"]],
        "Unknown": [["Image Size"]],
    ]

    private func keyOrders() -> [[String]] {
        let keys = Array(annotations.keys).sorted()
        return [keys, keys.reversed(), ["LowerLeft", "TopLeft", "Unknown", "TopRight", "LowerRight", "LowerMiddle", "TopMiddle", "MiddleLeft"]]
    }

    private func compare(_ view: View, annotations: [String: [[String]]]? = nil, x: Double = 0, y: Double = 0, width: Double = 1024,
                         height: Double = 768, sf: Float = 2, stringSize: (Double, Double) = (9.5, 17.2), inset: Double = 0,
                         colorBoxSize: Int32 = 0, fullText: Bool = true, _ comment: Comment) {
        let annotations = annotations ?? self.annotations
        for keys in keyOrders() {
            let former = formerTextualData(view, keys: keys, annotations: annotations, x: x, y: y, width: width, height: height, sf: sf,
                                           stringSize: stringSize, inset: inset, colorBoxSize: colorBoxSize, fullText: fullText)
            let now = textualData(view, keys: keys, annotations: annotations, x: x, y: y, width: width, height: height, sf: sf,
                                  stringSize: stringSize, inset: inset, colorBoxSize: colorBoxSize, fullText: fullText)
            #expect(now.commands == former.commands, comment)
            #expect(now.lowerLeftTop == former.lowerLeftTop, comment)
        }
    }

    @Test func theFourCornersAndTheMiddlesAtEachLevel() {
        for level in [Level.none, .graphic, .basic, .full, .pluginOnly, .custom] {
            for ownLevel in [Level.basic, .full] {
                for fullText in [true, false] {
                    var view = View()
                    view.level = level
                    view.ownLevel = ownLevel
                    compare(view, fullText: fullText, "level \(level) own \(ownLevel) fullText \(fullText)")
                }
            }
        }
        // Custom hides what its sheet unchecks.
        for hidden: Set<String> in [["windowLevel"], ["orientation", "imageInfo"], ["mousePosition", "patientName", "otherFields"]] {
            var view = View()
            view.level = .custom
            view.ownLevel = .custom
            view.hidden = hidden
            compare(view, "custom without \(hidden)")
        }
    }

    @Test func theLinesReadTheValuesOfTheImage() {
        var view = View()
        // Colour images, a fused image with SUV, a named view.
        view.rgb = true
        view.fused = View.FusedState()
        compare(view, "colour image with a fused grey image")
        view.rgb = false
        view.suvConverted = true
        view.fused?.rgb = true
        view.fused?.suvConverted = true
        compare(view, "SUV image with a fused colour image")
        view.suvConverted = false
        view.displaySUV = true
        view.hasSUV = true
        view.fused = View.FusedState(suvConverted: false, displaySUV: true, hasSUV: true)
        compare(view, "SUV lines")
        view.named = true
        compare(view, "a named view")
        view.previewDatabase = true
        compare(view, "the database preview")

        // Window: decimals of a narrow window, PET percents.
        view = View()
        for (wl, ww) in [(Float(40), Float(400)), (0.5, 1.25), (12, 30), (-1000.5, 40.5), (Float.nan, 3)] {
            view.wl = wl
            view.ww = ww
            for modality in ["CT", "PT"] {
                view.modality = modality
                view.maxOfSeries = modality == "PT" ? 1234.5 : 0
                compare(view, "window \(wl) \(ww) \(modality)")
            }
        }

        // Positions in micrometres and millimetres, in plane and in space.
        view = View()
        for (location, spacing) in [((Float(0.25), Float(0.5), Float(-0.75)), 0.1), ((0.25, 0.5, -0.75), 0.3), ((12.5, -3, 0), 0.1)] {
            for isPlane in [true, false] {
                view.location = location
                view.spacingX = spacing
                view.isPlane = isPlane
                compare(view, "position \(location) \(spacing) \(isPlane)")
            }
        }

        // Thickness, slab and positions.
        view = View()
        for (thickness, location) in [(2.5, -33.25), (0.6, 0.3), (0.6, 12), (0, 5), (3, 0)] {
            for stack in [1, 4] {
                for slab in [(Float(7.5), Float(-30)), (0.4, 0.2), (0.4, 15)] {
                    for positions in [(nil, nil), ("AP", nil), (nil, "HFS"), ("PA", "FFS")] as [(String?, String?)] {
                        view.thickness = thickness
                        view.sliceLocation = location
                        view.stack = stack
                        view.slab = slab
                        view.viewPosition = positions.0
                        view.patientPosition = positions.1
                        compare(view, "slice \(thickness) \(location) stack \(stack)")
                        compare(view, fullText: false, "slice \(thickness) \(location) stack \(stack), short")
                    }
                }
            }
        }

        // The patient's name, empty or absent.
        view = View()
        for patient in ["DOE^JANE", "", nil] as [String?] {
            view.patient = patient
            compare(view, "patient \(String(describing: patient))")
        }
    }

    @Test func theImagePositionNamesTheWayTheImagesGo() {
        var view = View()
        let steps: [(Double, Double, Double)?] = [nil, (0, 0, 2.5), (0, 0, -2.5), (1.2, -3, 0.1), (0.1, 0.1, 0.1), (0, 0, 0)]
        for step in steps {
            for flipped in [false, true] {
                for current in [0, 3, 5, 9] {
                    for stack in [1, 3, 20] {
                        view.step = step.map { (x: $0.0, y: $0.1, z: $0.2) }
                        view.flipped = flipped
                        view.current = current
                        view.stack = stack
                        compare(view, "step \(String(describing: step)) flipped \(flipped) image \(current) stack \(stack)")
                    }
                }
            }
        }
    }

    @Test func theRastersFollowTheFrameTheScaleAndTheBox() {
        for (x, y, width, height) in [(0.0, 0.0, 1024.0, 768.0), (13.5, 7.25, 333.3, 251.9), (0, 0, 0, 0)] {
            for sf: Float in [1, 2, 3] {
                for inset in [0.0, 24.5] {
                    for box: Int32 in [0, 30, 60] {
                        compare(View(), x: x, y: y, width: width, height: height, sf: sf, stringSize: (8, 14.6), inset: inset,
                                colorBoxSize: box, "frame \(x) \(y) \(width) \(height) scale \(sf) inset \(inset) box \(box)")
                    }
                }
            }
        }
        // The orientation letters asked for beside them, or only in a corner.
        var only = annotations
        only["TopMiddle"] = nil
        only["LowerRight"] = [["Orientation"]]
        compare(View(), annotations: only, "orientation asked for only in a corner")
        compare(View(), annotations: [:], "no annotations")
    }

    @Test func theStudyNumberBoxAndTheSignature() {
        #expect(AnnotationOverlayLayout.studyNumber(dateIndex: 0) == " 1 ")
        #expect(AnnotationOverlayLayout.studyNumber(dateIndex: 8) == " 9 ")
        #expect(AnnotationOverlayLayout.studyNumber(dateIndex: 9) == "10")
        #expect(AnnotationOverlayLayout.colourBoxSize(scale: 2, drawsBox: true) == 60)
        #expect(AnnotationOverlayLayout.colourBoxSize(scale: 1.5, drawsBox: true) == 45)
        #expect(AnnotationOverlayLayout.colourBoxSize(scale: 2, drawsBox: false) == 0)
        let layout = AnnotationOverlayLayout(originX: 10, originY: 20, width: 500.7, height: 300.2, scale: 2, characterWidth: 8, lineHeight: 14)
        #expect(layout.studyNumberOrigin == (20, 28))
        #expect(layout.signature == (508, 318))
    }

    // MARK: Orientation letters

    @Test func aLabelAtTheBottomKeepsClearOfTheLowerCorners() {
        var corners = LowerCornerText()
        // Nothing noted: the label stands where it is asked to.
        #expect(corners.labelTop(preferred: 700, minX: 300, maxX: 500, height: 30, gap: 6) == 700)
        // Twenty characters of 8 from x 10 in the lower left corner, ending at
        // raster 660; the middles and the upper corners do not count.
        corners.note(position: "LowerLeft", commands: [.text("Zoom: 526% Angle: 0", x: 10, y: 730, alignment: .left),
                                                       .text("12345678901234567890", x: 10, y: 700, alignment: .left)],
                     endY: 660, characterWidth: 8)
        corners.note(position: "TopLeft", commands: [.text(String(repeating: "x", count: 90), x: 10, y: 20, alignment: .left)], endY: 60, characterWidth: 8)
        corners.note(position: "LowerMiddle", commands: [.text(String(repeating: "x", count: 90), x: 400, y: 730, alignment: .center)], endY: 700, characterWidth: 8)
        #expect(corners.left?.maxX == 170 && corners.left?.top == 660 && corners.right == nil)
        // A wide view: the label is clear of the lines, and stays.
        #expect(corners.labelTop(preferred: 700, minX: 300, maxX: 500, height: 30, gap: 6) == 700)
        // A narrow one: it would cover them, and goes above them.
        #expect(corners.labelTop(preferred: 700, minX: 150, maxX: 350, height: 30, gap: 6) == 624)
        // The lower right lines end to the left of their raster.
        corners.note(position: "LowerRight", commands: [.text("Made In IsiX DICOM Viewer", x: 600, y: 730, alignment: .right)], endY: 640, characterWidth: 8)
        #expect(corners.right?.minX == 400 && corners.right?.top == 640)
        #expect(corners.labelTop(preferred: 700, minX: 300, maxX: 500, height: 30, gap: 6) == 604)
        #expect(corners.labelTop(preferred: 700, minX: 200, maxX: 380, height: 30, gap: 6) == 700)
        // A corner without text notes nothing.
        var empty = LowerCornerText()
        empty.note(position: "LowerLeft", commands: [.orientation], endY: 700, characterWidth: 8)
        #expect(empty == LowerCornerText())
    }

    @Test func theOrientationLettersAreTheFormerCStrings() {
        let components: [Float] = [0, 0.2, 0.2000001, -0.2000001, 0.5, -0.5, 0.7071, -0.7071, 1, -1, .nan, -0.0]
        for x in components {
            for y in components {
                for z in components {
                    for inverted in [false, true] {
                        let vector = (x, y, z)
                        #expect(OrientationLetters.english.text(vector, inverted: inverted) == formerOrientationText(vector, inverted),
                                "\(vector) inverted \(inverted)")
                    }
                }
            }
        }
        let french = OrientationLetters(right: "D", left: "G", anterior: "A", posterior: "P", inferior: "I", superior: "S")
        #expect(french.text((-1, 0.5, 0.3), inverted: false) == "DPS")
    }

    @Test func theLettersAndTheNoticesAroundTheImage() {
        for (x, y, width, height) in [(0.0, 0.0, 1024.0, 768.0), (13.5, 7.25, 333.3, 251.9)] {
            for (left, right, top, bottom) in [("R", "L", "A", "P"), ("RA", "LP", "", "IS"), ("", "", "", "")] {
                for notices in [[], ["L"], ["", "Horizontally Flipped", "VOI LUT Applied"]] as [[String]] {
                    let stringSize = (width: 9.0, height: 17.0)
                    var former: [Command] = []
                    former.append(.text(left, x: cLong(x + 6), y: cLong(y + 2 + height / 2), alignment: .left))
                    former.append(.text(right, x: cLong(x + width - (2 + stringSize.width * Double(strlen(right)))),
                                        y: cLong(y + 2 + height / 2), alignment: .left))
                    var yPosition = Float(y + stringSize.height + 3)
                    if strlen(top) != 0 {
                        former.append(.text(top, x: cLong(x + width / 2 - (stringSize.width * Double(strlen(top)) / 2)),
                                            y: cLong(Double(yPosition)), alignment: .left))
                        yPosition = Float(Double(yPosition) + (stringSize.height + 3))
                    }
                    for notice in notices {
                        former.append(.text(notice, x: cLong(x + width / 2), y: cLong(Double(yPosition)), alignment: .center))
                        yPosition = Float(Double(yPosition) + (stringSize.height + 3))
                    }
                    former.append(.text(bottom, x: cLong(x + width / 2), y: cLong(y + 2 + height - 6), alignment: .left))
                    let layout = AnnotationOverlayLayout(originX: x, originY: y, width: width, height: height, scale: 2,
                                                         characterWidth: stringSize.width, lineHeight: stringSize.height)
                    #expect(layout.orientationCommands(left: left, right: right, top: top, bottom: bottom, notices: notices) == former)
                }
            }
        }
    }

    // MARK: Description in large

    /// -allIdenticalValues:inArray: on the values of the open studies.
    private func formerAllIdentical(_ values: [String?]) -> Bool {
        if values.count > 0 {
            guard let s = values[0].map({ $0 as NSString }) else { return false }
            for value in values {
                guard let value, s.isEqual(to: value) else { return false }
            }
            return true
        }
        return false
    }

    /// The text of -computeDescriptionInLarge.
    private func formerDescription(name: String?, studyName: String?, seriesName: String?, date: String?,
                                   names: [String?], studyNames: [String?]) -> String {
        let description = NSMutableString(string: "")
        if !formerAllIdentical(names) {
            if let name {
                if description.length > 0 { description.append("\r") }
                description.append(name)
            }
        }
        if description.length > 0 { description.append("\r") }
        if let date { description.append(date) }
        if !formerAllIdentical(studyNames) {
            if let studyName {
                if description.length > 0 { description.append("\r") }
                description.append(studyName)
            }
        }
        if let seriesName {
            if description.length > 0 { description.append("\r") }
            description.append(seriesName)
        }
        return description as String
    }

    @Test func theDescriptionInLargeTellsTheSeriesApart() {
        let lists: [[String?]] = [[], ["A"], ["A", "A"], ["A", "B"], [nil, "A"], ["A", nil], ["É", "E\u{301}"]]
        for name in ["DOE^JANE", nil] as [String?] {
            for studyName in ["CT HEAD", nil] as [String?] {
                for seriesName in ["AXIAL 5mm", nil] as [String?] {
                    for date in ["03/11/2026 10:21", nil] as [String?] {
                        for names in lists {
                            for studyNames in lists {
                                #expect(DescriptionInLarge.text(patientName: name, studyName: studyName, seriesName: seriesName, date: date,
                                                                openPatientNames: names, openStudyNames: studyNames)
                                        == formerDescription(name: name, studyName: studyName, seriesName: seriesName, date: date,
                                                             names: names, studyNames: studyNames))
                            }
                        }
                    }
                }
            }
        }
        for list in lists {
            #expect(DescriptionInLarge.allIdentical(list) == formerAllIdentical(list), "\(list)")
        }
    }

    // MARK: Study colours

    /// The colour index and date index -computeColor gave each viewer's views (nil: no marks at all).
    private func formerMarks(viewers: [String?], coloured: [String?], studyUIDs: [String?], colours: Int) -> [StudyColour.Mark]? {
        var colorsStudy: [String: Int] = [:]
        for study in coloured {
            guard let uid = study, colorsStudy[uid] == nil else { continue }
            if var color = studyUIDs.firstIndex(where: { $0 == uid }) {
                if color >= colours { color = colours - 1 }
                colorsStudy[uid] = color
            }
        }
        guard studyUIDs.count > 1 else { return nil }
        return viewers.map { uid in
            StudyColour.Mark(colourIndex: uid.flatMap { colorsStudy[$0] }, dateIndex: uid.flatMap { u in studyUIDs.firstIndex { $0 == u } })
        }
    }

    @Test func eachStudyOfThePatientTakesItsColourAndNumber() {
        let patients: [[String?]] = [[], ["1.1"], ["1.3", "1.2", "1.1"], ["1.3", nil, "1.1"], (0 ..< 15).map { "2.\($0)" }]
        let viewerSets: [[String?]] = [[], ["1.1"], ["1.1", "1.3", nil, "9.9"], ["2.14", "2.0", "2.13", "1.2"]]
        for patient in patients {
            for viewers in viewerSets {
                for coloured in [viewers, Array(viewers.dropFirst()), viewers + viewers] {
                    for colours in [12, 1] {
                        #expect(StudyColour.marks(viewerStudies: viewers, colouredStudies: coloured, patientStudies: patient, colourCount: colours)
                                == formerMarks(viewers: viewers, coloured: coloured, studyUIDs: patient, colours: colours))
                    }
                }
            }
        }
    }
}
