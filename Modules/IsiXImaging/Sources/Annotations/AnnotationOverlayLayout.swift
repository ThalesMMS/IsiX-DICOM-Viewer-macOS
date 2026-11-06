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

/// Where the annotations of an image view go, and what they say: the lines of
/// each position (the corners and the middles of the sides), the orientation
/// letters and the notices under the top letter, the study number box and the
/// signature. It works in the view's backing pixels from its top left corner,
/// on the frame the text is drawn in; the view draws each `Command`.
///
/// The arithmetic is the C's: the positions were C ints and longs converted
/// from CGFloat, toward zero and saturated, and the scale a float.
public struct AnnotationOverlayLayout: Sendable, Equatable {
    public typealias TextAlignment = DrawingGeometry.TextAlignment

    /// What the view draws, in order.
    public enum Command: Sendable, Equatable {
        /// A line of text whose aligned edge is at `x`, its baseline at `y`.
        case text(String, x: Int, y: Int, alignment: TextAlignment)
        /// A plugin's line (the OsirixDrawTextInfo notification), at that raster.
        case plugin(x: Int, y: Int, alignment: TextAlignment)
        /// The orientation letters, drawn once a frame.
        case orientation
    }

    /// The positions whose lines start a line further when the orientation
    /// letters are drawn, in the order they are looked through for them.
    public static let orientationPositions = ["TopMiddle", "MiddleLeft", "MiddleRight", "LowerMiddle"]
    /// The token of a field that draws the orientation letters.
    public static let orientationToken = "Orientation"

    public let originX: Double, originY: Double, width: Double, height: Double
    /// The backing scale factor of the window.
    public let scale: Float
    /// The size of a "B" of the annotations' font, in backing pixels.
    public let characterWidth: Double, lineHeight: Double
    /// How far the scroll position preview pushes the top left lines right, in points.
    public let topLeftInset: Double
    /// The width the study number box takes from the first top left lines; 0 without a box.
    public let colourBoxSize: Int32
    /// Whether the orientation letters were drawn, which moves the positions
    /// beside them a line further.
    public private(set) var orientationDrawn = false

    public init(originX: Double, originY: Double, width: Double, height: Double, scale: Float,
                characterWidth: Double, lineHeight: Double, topLeftInset: Double = 0, colourBoxSize: Int32 = 0) {
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
        self.scale = scale
        self.characterWidth = characterWidth
        self.lineHeight = lineHeight
        self.topLeftInset = topLeftInset
        self.colourBoxSize = colourBoxSize
    }

    /// The layout once the orientation letters are drawn.
    public func withOrientationDrawn() -> AnnotationOverlayLayout {
        var layout = self
        layout.orientationDrawn = true
        return layout
    }

    // MARK: - Positions

    /// Where the first line of `position` goes; 0, 0 for a name that is not a position.
    public func start(of position: String) -> (x: Int32, y: Int32) {
        let sf = Double(scale), six = Double(6 * scale), two = Double(2 * scale)
        let left = cInt32(originX + six), right = cInt32(originX + width - two), middle = cInt32(originX + width / 2)
        let top = cInt32(originY + lineHeight + two), centre = cInt32(originY + height / 2), bottom = cInt32(originY + height - two)
        var start: (x: Int32, y: Int32)
        switch position {
        case "TopLeft": start = (cInt32(originX + (6 + topLeftInset) * sf), top)
        case "MiddleLeft": start = (left, centre)
        case "LowerLeft": start = (left, bottom)
        case "TopRight": start = (right, top)
        case "MiddleRight": start = (right, centre)
        case "LowerRight": start = (right, cInt32(originY + height - two - lineHeight))
        case "TopMiddle": start = (middle, cInt32(originY + lineHeight))
        case "LowerMiddle": start = (middle, bottom)
        default: return (0, 0)
        }
        if orientationDrawn && Self.orientationPositions.contains(position) {
            start.y = start.y &+ increment(of: position)
        }
        return start
    }

    /// How far each line of `position` moves from the previous one: down from
    /// the top and the middles, up from the bottom; 0 for a name that is not a position.
    public func increment(of position: String) -> Int32 {
        switch position {
        case "TopLeft", "TopMiddle", "TopRight", "MiddleLeft", "MiddleRight": return cInt32(lineHeight)
        case "LowerLeft", "LowerRight", "LowerMiddle": return cInt32(-lineHeight)
        default: return 0
        }
    }

    /// The edge the lines of `position` are aligned on; left for a name that is not a position.
    public static func alignment(of position: String) -> TextAlignment {
        switch position {
        case "TopRight", "MiddleRight", "LowerRight": return .right
        case "TopMiddle", "LowerMiddle": return .center
        default: return .left
        }
    }

    /// Whether the fields of the positions beside the letters ask for the
    /// orientation letters, which are then drawn before any line.
    public static func asksForOrientation(_ annotations: [String: [[String]]]) -> Bool {
        orientationPositions.contains { position in
            annotations[position]?.contains { $0.contains(orientationToken) } ?? false
        }
    }

    // MARK: - Lines

    /// What the fields of `position` draw: its lines in order (from the bottom
    /// up for the lower positions), each with the plugin lines and the
    /// orientation letters its fields ask for before its own text, and the
    /// raster after the last line. `patientNamePrefix` marks a field holding
    /// the patient's name; `fullText` is false where only the essential lines
    /// are shown.
    public func commands(for position: String, lines: [[String]], fullText: Bool, patientNamePrefix: String,
                         phrases: AnnotationPhrases, values: some AnnotationValueSource) -> (commands: [Command], endY: Int) {
        let start = start(of: position), increment = Int(increment(of: position)), alignment = Self.alignment(of: position)
        let x = Int(start.x)
        var y = Int(start.y)
        var commands: [Command] = []
        let ordered = (position as NSString).hasPrefix("Lower") ? Array(lines.reversed()) : lines
        for fields in ordered {
            var texts = AnnotationLineTexts()
            for token in fields {
                // A level shows a field only with its element: Basic leaves out
                // the patient's name, Custom whatever its sheet unchecks.
                guard values.shows(token) else { continue }
                switch AnnotationField(token, patientNamePrefix: patientNamePrefix) {
                case .plugin:
                    commands.append(.plugin(x: x, y: y, alignment: alignment))
                    y += increment
                case .orientation:
                    commands.append(.orientation)
                case let field:
                    texts.append(field, fullText: fullText, viewWidth: width, viewHeight: height, phrases: phrases, values: values)
                }
            }
            for text in texts.trimmed where !text.isEmpty {
                // The first top left lines leave the study number box room.
                let room = position == "TopLeft" && Float(y &- increment) < Float(colourBoxSize) + 2 * scale ? Int(colourBoxSize) : 0
                commands.append(.text(text, x: x &+ room, y: y, alignment: alignment))
                y += increment
            }
        }
        return (commands, y)
    }

    // MARK: - Orientation letters

    /// The orientation letters and the notices under the top one: the left
    /// and right letters at mid-height, the top letter centred under the top
    /// edge, the notices centred under it a line apart, and the bottom letter
    /// starting at the middle of the bottom edge. A top letter that is empty
    /// takes no line.
    public func orientationCommands(left: String, right: String, top: String, bottom: String, notices: [String]) -> [Command] {
        let midHeight = DrawingGeometry.cLong(originY + 2 + height / 2)
        var commands: [Command] = [
            .text(left, x: DrawingGeometry.cLong(originX + 6), y: midHeight, alignment: .left),
            .text(right, x: DrawingGeometry.cLong(originX + width - (2 + characterWidth * Double(right.utf8.count))), y: midHeight, alignment: .left),
        ]
        var y = Float(originY + lineHeight + 3)
        if !top.utf8.isEmpty {
            commands.append(.text(top, x: DrawingGeometry.cLong(originX + width / 2 - (characterWidth * Double(top.utf8.count) / 2)),
                                  y: DrawingGeometry.cLong(Double(y)), alignment: .left))
            y = Float(Double(y) + (lineHeight + 3))
        }
        for notice in notices {
            commands.append(.text(notice, x: DrawingGeometry.cLong(originX + width / 2), y: DrawingGeometry.cLong(Double(y)), alignment: .center))
            y = Float(Double(y) + (lineHeight + 3))
        }
        commands.append(.text(bottom, x: DrawingGeometry.cLong(originX + width / 2), y: DrawingGeometry.cLong(originY + 2 + height - 6), alignment: .left))
        return commands
    }

    // MARK: - Study number box and signature

    /// The width the study number box takes, for a view that draws one (a 2D
    /// viewer's own view, whose study has a colour); 0 otherwise.
    public static func colourBoxSize(scale: Float, drawsBox: Bool) -> Int32 {
        drawsBox ? cInt32(Double(30 * scale)) : 0
    }

    /// The number of the study among the patient's, newest first, as its box shows it.
    public static func studyNumber(dateIndex: UInt) -> String {
        let number = Int32(truncatingIfNeeded: dateIndex) &+ 1
        return dateIndex &+ 1 < 10 ? String(format: " %d ", number) : String(format: "%d", number)
    }

    /// Where the study number box's top left corner goes.
    public var studyNumberOrigin: (x: Double, y: Double) {
        (originX + Double(5 * scale), originY + Double(4 * scale))
    }

    /// Where the signature of the full text ends: the bottom right corner.
    public var signature: (x: Int, y: Int) {
        (DrawingGeometry.cLong(originX + width - 2), DrawingGeometry.cLong(originY + height - 2))
    }
}

/// A double converted to int as the arm64 code of the C did (fcvtzs): toward
/// zero, saturated, NaN to 0.
func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// What a field of the annotations' template is drawn as.
enum AnnotationField: Equatable {
    case imageSize, viewSize, mousePixels, zoom, rotationAngle, imagePosition, mouseMillimetres, windowLevel
    case plugin, orientation, slice, patientName
    /// A field holding the patient's name, marked by the prefix; its text without it.
    case patientNameField(String)
    /// Any other text of the template.
    case other(String)

    init(_ token: String, patientNamePrefix: String) {
        switch token {
        case "Image Size": self = .imageSize
        case "View Size": self = .viewSize
        case "Mouse Position (px)": self = .mousePixels
        case "Zoom": self = .zoom
        case "Rotation Angle": self = .rotationAngle
        case "Image Position": self = .imagePosition
        case "Mouse Position (mm)": self = .mouseMillimetres
        case "Window Level / Window Width": self = .windowLevel
        case "Plugin": self = .plugin
        case AnnotationOverlayLayout.orientationToken: self = .orientation
        case "Thickness / Location / Position": self = .slice
        case "PatientName": self = .patientName
        default:
            let text = token as NSString
            if text.hasPrefix(patientNamePrefix) {
                self = .patientNameField(text.substring(from: (patientNamePrefix as NSString).length))
            } else {
                self = .other(token)
            }
        }
    }
}

/// The four texts a line of fields builds: the field's own, and the second,
/// third and fourth lines the mouse value and the window add (the fused
/// image, the SUV, the fused image's SUV).
struct AnnotationLineTexts {
    var texts = ["", "", "", ""]

    /// The texts without the white space at their ends.
    var trimmed: [String] { texts.map { $0.trimmingCharacters(in: .whitespaces) } }

    mutating func append(_ field: AnnotationField, fullText: Bool, viewWidth: Double, viewHeight: Double,
                         phrases: AnnotationPhrases, values: some AnnotationValueSource) {
        switch field {
        case .imageSize:
            guard fullText else { return }
            let size = values.imageSize()
            texts[0] += String(format: phrases.imageSize, size.width, size.height)
        case .viewSize:
            guard fullText else { return }
            texts[0] += String(format: phrases.viewSize, DrawingGeometry.cLong(viewWidth), DrawingGeometry.cLong(viewHeight))
        case .mousePixels:
            guard let probe = values.pixelProbe() else { return }
            appendMouse(probe, phrases: phrases)
        case .zoom:
            guard fullText else { return }
            texts[0] += String(format: phrases.zoom, Double(values.zoom()) * 100.0)
        case .rotationAngle:
            guard fullText else { return }
            texts[0] += String(format: phrases.angle, Double(Float(DrawingGeometry.cLong(Double(values.rotation())) % 360)))
        case .imagePosition:
            guard fullText else { return }
            appendImagePosition(values.imagePosition(), phrases: phrases)
        case .mouseMillimetres:
            guard let position = values.millimetrePosition() else { return }
            appendMillimetres(position)
        case .windowLevel:
            appendWindow(values.windowLevel(), phrases: phrases)
        case .slice:
            appendSlice(values.slice(), fullText: fullText, phrases: phrases, values: values)
        case .patientName:
            if values.showsPatientName(), let name = values.patientName(), !name.isEmpty {
                texts[0] += name
            }
        case .patientNameField(let name):
            // Basic is the level without it; Full shows it, and Custom when its sheet says so.
            if values.showsPatientName() {
                texts[0] += String(format: " %@", name)
            }
        case .other(let text):
            if fullText {
                texts[0] += String(format: " %@", text)
            }
        case .plugin, .orientation:
            break
        }
    }

    private mutating func appendMouse(_ probe: AnnotationPixelProbe, phrases: AnnotationPhrases) {
        var unit = probe.image.suvConverted ? "SUV" : ""
        let image = probe.image
        switch image.value {
        case let .colour(red, green, blue):
            texts[0] += String(format: phrases.mouseColour, cInt32(Double(image.x)), cInt32(Double(image.y)), red, green, blue)
        case let .grey(value):
            texts[0] += String(format: phrases.mouseGrey, cInt32(Double(image.x)), cInt32(Double(image.y)), Double(value), unit)
        }
        if let fused = probe.fused {
            if fused.suvConverted { unit = "SUV" }
            switch fused.value {
            case let .colour(red, green, blue):
                texts[1] += String(format: phrases.fusedColour, cInt32(Double(fused.x)), cInt32(Double(fused.y)), red, green, blue)
            case let .grey(value):
                texts[1] += String(format: phrases.fusedGrey, cInt32(Double(fused.x)), cInt32(Double(fused.y)), Double(value), unit)
            }
        }
        if let suv = image.suv {
            texts[2] += String(format: phrases.suv, Double(suv))
        }
        if let suv = probe.fused?.suv {
            texts[3] += String(format: phrases.fusedSUV, Double(suv))
        }
    }

    private mutating func appendImagePosition(_ position: AnnotationImagePosition, phrases: AnnotationPhrases) {
        let current = position.current, count = position.count, flipped = position.flipped
        var direction = ""
        if let step = position.step {
            let interval = sqrt(step.x * step.x + step.y * step.y + step.z * step.z)
            let vector = (Float(step.x / interval), Float(step.y / interval), Float(step.z / interval))
            let first = phrases.letters.text(vector, inverted: !flipped)
            let last = phrases.letters.text(vector, inverted: flipped)
            // The letters were C strings, shown by their first byte with %c.
            if let a = first.utf8.first, let b = last.utf8.first, a != 0, b != 0 {
                let start = Int32(Int8(bitPattern: a)), end = Int32(Int8(bitPattern: b))
                let place = flipped ? Float(UInt(bitPattern: count) &- UInt(bitPattern: current)) / Float(count)
                                    : Float(current) / Float(count)
                // The float compared with the doubles 0.4 and 0.6, as in C.
                if Double(place) < 0.4 {
                    direction = String(format: " %c (%c -> %c)", start, start, end)
                } else if Double(place) > 0.6 {
                    direction = String(format: " %c (%c -> %c)", end, start, end)
                } else {
                    direction = String(format: " (%c -> %c)", start, end)
                }
            }
        }

        if position.stack > 1 {
            var last = flipped ? current - position.stack + 1 : current + position.stack
            if last < 0 { last = 0 }
            if last > count { last = count }
            texts[0] += flipped ? String(format: phrases.imageRange, count - current, count &- last, count, direction)
                                : String(format: phrases.imageRange, current + 1, last, count, direction)
        } else {
            texts[0] += flipped ? String(format: phrases.image, count - current, count, direction)
                                : String(format: phrases.image, current + 1, count, direction)
        }
    }

    private mutating func appendMillimetres(_ p: AnnotationMillimetrePosition) {
        // Under 1 mm on a fine image, in micrometres (µ, 0xB5).
        let microns = abs(Double(p.x)) < 1.0 && p.x != 0.0 && p.pixelSpacingX < 0.2
        let mu = Int32(0xB5)
        if p.isPlane {
            texts[0] += microns
                ? String(format: "X: %2.2f %cm Y: %2.2f %cm Z: %2.2f %cm", Double(p.x) * 1000.0, mu, Double(p.y) * 1000.0, mu, Double(p.z) * 1000.0, mu)
                : String(format: "X: %2.2f mm Y: %2.2f mm Z: %2.2f mm", Double(p.x), Double(p.y), Double(p.z))
        } else {
            texts[0] += microns
                ? String(format: "X: %2.2f %cm Y: %2.2f %cm", Double(p.x) * 1000.0, mu, Double(p.y) * 1000.0, mu)
                : String(format: "X: %2.2f mm Y: %2.2f mm", Double(p.x), Double(p.y))
        }
    }

    private mutating func appendWindow(_ window: AnnotationWindowLevel, phrases: AnnotationPhrases) {
        let level = window.level, width = window.width
        let intLevel = cInt32(Double(level)), intWidth = cInt32(Double(width))
        // A narrow window with decimals keeps them.
        if width < 50 && (level != Float(intLevel) || width != Float(intWidth)) {
            texts[0] += String(format: phrases.windowLevelDecimals, Double(level), Double(width))
        } else {
            texts[0] += String(format: phrases.windowLevel, intLevel, intWidth)
        }
        if window.windowsAsPET && window.maximumOfSeries != 0 {
            let low = level - width / 2, high = level + width / 2
            let maximum = Double(window.maximumOfSeries)
            // %d with long arguments, as the Objective-C passed them.
            texts[1] += String(format: phrases.windowPercent, DrawingGeometry.cLong(Double(low) * 100.0 / maximum), Double(low),
                               DrawingGeometry.cLong(Double(high) * 100.0 / maximum), Double(high))
        }
    }

    private mutating func appendSlice(_ slice: AnnotationSlice, fullText: Bool, phrases: AnnotationPhrases, values: some AnnotationValueSource) {
        let mu = Int32(0xB5)
        if slice.thickness != 0 && slice.location != 0 {
            if slice.stack > 1 {
                let slab = values.thickSlab()
                let thickness = slab.thickness, location = slab.location
                if thickness < 1.0 && thickness != 0.0 {
                    texts[0] += abs(Double(location)) < 1.0 && location != 0.0
                        ? String(format: phrases.thicknessMicronsLocationMicrons, abs(Double(thickness) * 1000.0), mu, Double(location) * 1000.0, mu)
                        : String(format: phrases.thicknessMicrons, abs(Double(thickness) * 1000.0), mu, Double(location))
                } else {
                    texts[0] += String(format: phrases.thickness, abs(Double(thickness)), Double(location))
                }
            } else if fullText {
                if slice.thickness < 1.0 && slice.thickness != 0.0 {
                    texts[0] += abs(slice.location) < 1.0 && slice.location != 0.0
                        ? String(format: phrases.thicknessMicronsLocationMicrons, slice.thickness * 1000.0, mu, slice.location * 1000.0, mu)
                        : String(format: phrases.thicknessMicrons, slice.thickness * 1000.0, mu, slice.location)
                } else {
                    texts[0] += String(format: phrases.thickness, slice.thickness, slice.location)
                }
            }
        } else if slice.viewPosition != nil || slice.patientPosition != nil {
            if let view = slice.viewPosition {
                texts[0] += String(format: phrases.position, view)
            }
            if let patient = slice.patientPosition {
                texts[0] += slice.viewPosition != nil ? patient : String(format: phrases.position, patient)
            }
        }
    }
}

/// Where the lines of the two lower corners end, as they are drawn, so that a
/// label centred at the bottom of the view can keep clear of them: in a
/// narrow view the zoom and the thickness lines reach the middle.
public struct LowerCornerText: Sendable, Equatable {
    /// The right end of the lower left lines and the raster above them.
    public private(set) var left: (maxX: Double, top: Double)?
    /// The left end of the lower right lines and the raster above them.
    public private(set) var right: (minX: Double, top: Double)?

    public init() {}

    public static func == (a: LowerCornerText, b: LowerCornerText) -> Bool {
        a.left?.maxX == b.left?.maxX && a.left?.top == b.left?.top && a.right?.minX == b.right?.minX && a.right?.top == b.right?.top
    }

    /// Notes the text lines of a position, of which only the two lower
    /// corners count. A line is as wide as its characters, each
    /// `characterWidth` wide; `endY` is the raster after its last line.
    public mutating func note(position: String, commands: [AnnotationOverlayLayout.Command], endY: Int, characterWidth: Double) {
        guard position == "LowerLeft" || position == "LowerRight" else { return }
        var longest = 0.0, anchor: Double?
        for case .text(let text, let x, _, _) in commands {
            longest = max(longest, Double(text.count) * characterWidth)
            anchor = Double(x)
        }
        guard let anchor, longest > 0 else { return }
        if position == "LowerLeft" {
            left = (anchor + longest, Double(endY))
        } else {
            right = (anchor - longest, Double(endY))
        }
    }

    /// The top of a label `height` tall between `minX` and `maxX`, which would
    /// stand at `preferred`: there when the corners' lines leave it room, else
    /// above the lines it would cover, `gap` away from them. The view's y
    /// grows downwards.
    public func labelTop(preferred: Double, minX: Double, maxX: Double, height: Double, gap: Double) -> Double {
        var top = preferred
        if let left, minX < left.maxX + gap { top = min(top, left.top - height - gap) }
        if let right, maxX > right.minX - gap { top = min(top, right.top - height - gap) }
        return top
    }
}
