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

/// Region of Interest on a 2D image: a length (tMesure), a rectangle (tROI),
/// an oval, an open or closed polygon, an angle, a text, an arrow, a pencil
/// stroke, a 2D point, a brush (tPlain), a layer, an axis, a dynamic angle and
/// TAGT (two parallel lines and one perpendicular line).
///
/// The class keeps the Objective-C name, selectors and archived form it had:
/// ROI files, ROI SRs, the pasteboard and plugins hold ROIs by that name. Its
/// work is in extensions by responsibility: geometry and exported values
/// (ROI+Geometry), mouse interaction (ROI+Interaction), the brush mask
/// (ROI+Brush), the layer image (ROI+Layer), drawing (ROI+Drawing) and labels
/// (ROI+Label). The measurements, statistics, archive format, outline spline,
/// brush mask arithmetic and drag constraints are in the internal module
/// IsiXROI.
///
/// Instance variables became stored properties of the same names, so that
/// key-value coding reaches them as it did (DCMView sorts the labels by
/// `uniqueID`). The public properties keep their accessors, including those
/// that do more than set a value.
@objc(ROI)
public class ROI: NSObject, NSCoding {

    // MARK: Settings

    /// The ROI preferences, read once by +loadDefaultSettings and written back
    /// by +saveDefaultSettings: the thickness, opacity and colour a new ROI
    /// gets, set again from the last ROI changed "globally".
    struct Settings {
        var regionOpacity: Float = 0, textThickness: Float = 0, thickness: Float = 0, opacity: Float = 0
        var colorR: Float = 0, colorG: Float = 0, colorB: Float = 0
        var textColorR: Float = 0, textColorG: Float = 0, textColorB: Float = 0
        var regionThickness: Float = 0, regionColorR: Float = 0, regionColorG: Float = 0, regionColorB: Float = 0
        var arrowThickness: Float = 0
        var textIfSelected = false, textNameOnly = false, textIfMouseIsOver = false, drawPlainEdge = false
        var loaded = false
        var spline = false
        var displayCobbAngle = false
    }
    // nonisolated(unsafe): the ROI code ran on any thread with these as C
    // statics, written on the main thread from the preferences.
    nonisolated(unsafe) static var settings = Settings()
    /// The height of a label line, in points, set by the views from their label font.
    nonisolated(unsafe) static var fontHeight: Float = 0
    nonisolated(unsafe) static var defaultNameValue: String?
    /// The identifiers of ROIs, which order their labels.
    nonisolated(unsafe) static var nextUniqueID: Int32 = 0
    /// The next colour of the rotation, when the preferences ask for one.
    nonisolated(unsafe) static var colorRotationState = 0
    static let colorRotationTable: [RGBColor] = [
        RGBColor(red: 49087, green: 32639, blue: 65535),   // pastel purple bf7fff
        RGBColor(red: 0, green: 65535, blue: 0),           // default green
        RGBColor(red: 63993, green: 48830, blue: 0),       // topaz
        RGBColor(red: 60138, green: 28270, blue: 13621),   // carrot orange
        RGBColor(red: 0, green: 24672, blue: 36494),       // madonna blue
        RGBColor(red: 22102, green: 9509, blue: 22102),    // grape
        RGBColor(red: 32639, green: 65535, blue: 32639),   // pastel green 7fff7f
        RGBColor(red: 65535, green: 65534, blue: 32639),   // pastel yellow ffff7f
        RGBColor(red: 65535, green: 32639, blue: 32639),   // pastel orange ff7f7f
        RGBColor(red: 32639, green: 49087, blue: 65535),   // pastel blue 7fbfff
    ]
    /// `M_PI / 180.0f`, kept in a float.
    static let deg2rad = Float(Double.pi / 180.0)
    /// The points of an oval's outline.
    static let circleResolution = 200

    // MARK: Stored state (the former instance variables)

    final var roiLock: NSRecursiveLock?
    /// The brush's mask and where it lies; the bytes are this ROI's.
    final var mask = ROIBrushMask()
    /// The mask's outline, drawn around a selected brush; derived from the mask.
    final var textureBufferSelected: UnsafeMutablePointer<UInt8>?
    /// A marker that the layer's pixels in `mask.buffer` are current.
    @objc final var ctxArray: NSMutableArray? = NSMutableArray()
    @objc final var textArray: NSMutableArray? = NSMutableArray()
    final var textureFirstPoint: Int32 = 0

    final var _points = NSMutableArray()
    final var _zPositions = NSMutableArray()
    final var _rect = NSRect.zero
    @objc final var _hasIsSpline = false
    @objc final var _isSpline = false

    final var _type: ToolMode = .tWL
    @objc final var mode = ROI_sleep
    @objc final var previousMode = ROI_sleep
    final var _needQuartz = false

    final var _thickness: Float = 0
    @objc final var fill = false
    final var _opacity: Float = 0
    final var color = RGBColor(red: 0, green: 0, blue: 0)

    @objc final var closed = false
    final var _clickInTextBox = false

    final var _name: NSString?
    final var _comments: NSString?

    final var _pixelSpacingX: Double = 0
    final var _pixelSpacingY: Double = 0
    final var _imageOrigin = NSPoint.zero

    // Tracking
    final var _mouseOverROI = false
    @objc final var PointUnderMouse: Int32 = -1
    @objc final var selectedModifyPoint = -1
    final var _clickPoint = NSPoint.zero
    @objc final var previousPoint = NSPoint.zero
    @objc final var originAnchor = NSPoint.zero

    final unowned(unsafe) var _curView: DCMView?
    final var _pix: DCMPix?

    final var rmean: Float = 0, rmax: Float = 0, rmin: Float = 0, rdev: Float = 0, rtotal: Float = 0, rskewness: Float = 0, rkurtosis: Float = 0
    final var Brmean: Float = 0, Brmax: Float = 0, Brmin: Float = 0, Brdev: Float = 0, Brtotal: Float = 0, Brskewness: Float = 0, Brkurtosis: Float = 0
    final var Brmedian: Double = 0

    final var _mousePosMeasure: Float = 0

    /// A text ROI's string.
    final var stringTex: NSString?
    final var stanStringAttrib: NSMutableDictionary?
    final var stringTextureCache: NSCache<NSArray, AnnotationText>?

    final var _parentROI: ROI?

    /// Where the label is, in the view's backing pixels from its centre.
    @objc final var drawRect = NSRect.zero

    @objc final var offsetTextBox_x: Float = 0
    @objc final var offsetTextBox_y: Float = 0

    final var _textualBoxLine1: NSString?, _textualBoxLine2: NSString?, _textualBoxLine3: NSString?
    final var _textualBoxLine4: NSString?, _textualBoxLine5: NSString?, _textualBoxLine6: NSString?

    final var _displayCalciumScoring = false
    final var _calciumThreshold: Int32 = 0
    final var _sliceThickness: Double = 0
    final var _calciumCofactor: Int32 = 0

    final var _layerReferenceFilePath: NSString?
    final var _layerImage: NSImage?
    @objc final var layerImageJPEG: NSData?
    final var _layerPixelSpacingX: Float = 0, _layerPixelSpacingY: Float = 0
    final var _isLayerOpacityConstant = false
    final var _canColorizeLayer = false
    /// Its setter is -setCanResizeLayer:, which the viewer sends to a new layer.
    @objc final var canResizeLayer = false
    @objc final var layerColor: NSColor?

    /// Not archived: valid during the life of the ROI only.
    @objc final var uniqueID: NSNumber?
    final var _groupID: TimeInterval = 0

    final var _displayTextualData = false
    final var _displayCMOrPixels = false

    final var _locked = false
    final var _selectable = false
    final var _isAliased = false
    final var _originalIndexForAlias: Int32 = 0

    final var _hidden = false
    final var _textNameOnly = false
    final var hasTextureLabelPoint = false
    final var textureLabelPointBuffer: UnsafeMutablePointer<UInt8>?
    final var textureLabelPointValue = NSPoint.zero

    final var _median: Double = 0

    /// The layer image's ARGB pixels in `mask.buffer`.
    final var layerPixelsWidth: Int32 = 0, layerPixelsHeight: Int32 = 0, layerPixelsRowBytes: Int32 = 0
    /// The segments of the textual box lines written by setTextualBoxLine(_:segments:), by line number.
    final var textualBoxSegments: NSDictionary?

    // MARK: Notifications

    /// The views and windows that observe ROI notifications run on the main
    /// thread, and the Swift ones check it when the notification calls them. A
    /// ROI changed on another thread - read for the web portal, or for a
    /// database repair - tells them there, keeping the ROI until they have
    /// been told.
    func postChange(_ userInfo: [AnyHashable: Any]? = nil) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .OsirixROIChange, object: self, userInfo: userInfo)
        } else {
            // The block keeps the ROI and its user info, as the Objective-C block did.
            nonisolated(unsafe) let roi = self, info = userInfo
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .OsirixROIChange, object: roi, userInfo: info)
            }
        }
    }

    /// A ROI being created or decoded is in no list yet, and one being
    /// deallocated is in none any more: off the main thread no view can be
    /// showing it, so only the main thread tells the observers.
    func postOnMainThreadOnly(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: self, userInfo: nil)
        }
    }

    // MARK: Class settings

    @objc(setFontHeight:)
    public class func setFontHeight(_ f: Float) {
        fontHeight = f
    }

    @objc public class func saveDefaultSettings() {
        let s = settings
        guard s.loaded else { return }
        let defaults = UserDefaults.standard
        defaults.set(s.regionOpacity, forKey: "ROIRegionOpacity")
        defaults.set(s.textThickness, forKey: "ROITextThickness")
        defaults.set(s.thickness, forKey: "ROIThickness")
        defaults.set(s.opacity, forKey: "ROIOpacity")
        defaults.set(s.colorR, forKey: "ROIColorR")
        defaults.set(s.colorG, forKey: "ROIColorG")
        defaults.set(s.colorB, forKey: "ROIColorB")
        defaults.set(s.textColorR, forKey: "ROITextColorR")
        defaults.set(s.textColorG, forKey: "ROITextColorG")
        defaults.set(s.textColorB, forKey: "ROITextColorB")
        defaults.set(s.regionColorR, forKey: "ROIRegionColorR")
        defaults.set(s.regionColorG, forKey: "ROIRegionColorG")
        defaults.set(s.regionColorB, forKey: "ROIRegionColorB")
        defaults.set(s.regionThickness, forKey: "ROIRegionThickness")
        defaults.set(s.arrowThickness, forKey: "ROIArrowThickness")
    }

    @objc public class func loadDefaultSettings() {
        let defaults = UserDefaults.standard
        var s = settings
        s.regionOpacity = defaults.float(forKey: "ROIRegionOpacity")
        if s.regionOpacity < 0.3 { s.regionOpacity = 0.3 }
        s.textThickness = defaults.float(forKey: "ROITextThickness")
        s.thickness = defaults.float(forKey: "ROIThickness")
        if s.thickness < 0.3 { s.thickness = 0.3 }
        s.opacity = defaults.float(forKey: "ROIOpacity")
        if s.opacity < 0.3 { s.opacity = 0.3 }
        s.colorR = defaults.float(forKey: "ROIColorR")
        s.colorG = defaults.float(forKey: "ROIColorG")
        s.colorB = defaults.float(forKey: "ROIColorB")
        s.textColorR = defaults.float(forKey: "ROITextColorR")
        s.textColorG = defaults.float(forKey: "ROITextColorG")
        s.textColorB = defaults.float(forKey: "ROITextColorB")
        s.regionColorR = defaults.float(forKey: "ROIRegionColorR")
        s.regionColorG = defaults.float(forKey: "ROIRegionColorG")
        s.regionColorB = defaults.float(forKey: "ROIRegionColorB")
        s.regionThickness = defaults.float(forKey: "ROIRegionThickness")
        s.arrowThickness = defaults.float(forKey: "ROIArrowThickness")
        s.textIfSelected = defaults.bool(forKey: "ROITEXTIFSELECTED")
        s.textIfMouseIsOver = defaults.bool(forKey: "ROITextIfMouseIsOver")
        s.textNameOnly = defaults.bool(forKey: "ROITEXTNAMEONLY")
        s.spline = defaults.bool(forKey: "splineForROI")
        s.displayCobbAngle = defaults.bool(forKey: "displayCobbAngle")
        s.drawPlainEdge = defaults.bool(forKey: "ROIDrawPlainEdge")
        s.loaded = true
        settings = s
    }

    @discardableResult
    @objc public class func splineForROI() -> Bool {
        return settings.spline
    }

    @objc(setDefaultName:)
    public class func setDefaultName(_ n: String!) {
        defaultNameValue = n
    }

    @discardableResult
    @objc public class func defaultName() -> String! {
        return defaultNameValue
    }

    @objc(setDefaultName:)
    public func setDefaultName(_ n: String!) { ROI.setDefaultName(n) }

    @discardableResult
    @objc public func defaultName() -> String! { return ROI.defaultNameValue }

    // MARK: Initialization

    /// -init of NSObject, which -copyWithZone: calls: every value zero.
    @objc public required override init() {
        super.init()
    }

    /// Creates a new ROI, with the pixel resolution of its image and the image's origin.
    @objc(initWithType:::)
    public convenience init!(type itype: ToolMode, _ ipixelSpacing: Float, _ iimageOrigin: NSPoint) {
        self.init(type: itype, ipixelSpacing, ipixelSpacing, iimageOrigin)
    }

    /// Creates a new ROI, with the pixel width and height of its image and the image's origin.
    @objc(initWithType::::)
    public init!(type itype: ToolMode, _ ipixelSpacingx: Float, _ ipixelSpacingy: Float, _ iimageOrigin: NSPoint) {
        super.init()
        let s = ROI.settings
        uniqueID = NSNumber(value: ROI.takeUniqueID())
        _groupID = 0.0
        PointUnderMouse = -1
        selectedModifyPoint = -1
        ctxArray = NSMutableArray(capacity: 10)
        textArray = NSMutableArray(capacity: 10)
        _opacity = 1.0
        _selectable = true
        _locked = false
        _type = itype
        mode = ROI_sleep
        _parentROI = nil
        previousPoint = NSPoint(x: -1000, y: -1000)

        if _type == .tText { _thickness = s.textThickness }
        else if _type == .tArrow { _thickness = s.arrowThickness }
        else if _type == .tPlain { _thickness = s.regionThickness }
        else { _thickness = s.thickness }

        _opacity = s.opacity

        if UserDefaults.standard.bool(forKey: "ROIColorRotation") {
            color = ROI.colorRotationTable[ROI.colorRotationState % 10]
            ROI.colorRotationState += 1
        } else {
            color = RGBColor(red: ROI.colorComponent(s.colorR), green: ROI.colorComponent(s.colorG), blue: ROI.colorComponent(s.colorB))
        }

        _mousePosMeasure = -1
        _pixelSpacingX = Double(ipixelSpacingx)
        _pixelSpacingY = Double(ipixelSpacingy)
        _imageOrigin = iimageOrigin
        _points = NSMutableArray()
        _zPositions = NSMutableArray()
        _comments = ROI.empty
        stringTex = nil
        resetStatistics()

        if _type == .tText {
            stanStringAttrib = ROI.labelAttributes(size: 12.0 + Double(_thickness) * 2)
            self.name = NSLocalizedString("Double-Click to edit", comment: "")   // Recompute the texture
            color = RGBColor(red: ROI.colorComponent(s.textColorR), green: ROI.colorComponent(s.textColorG), blue: ROI.colorComponent(s.textColorB))
        } else if _type == .tPlain {
            mask = ROIBrushMask()
            mask.width = 128
            mask.height = 128
            textureFirstPoint = 0
            _thickness = s.regionThickness
            color = RGBColor(red: ROI.colorComponent(s.regionColorR), green: ROI.colorComponent(s.regionColorG), blue: ROI.colorComponent(s.regionColorB))
            _opacity = s.regionOpacity
            self.name = NSLocalizedString("Region", comment: "")
        } else if _type == .tLayerROI {
            _layerReferenceFilePath = ROI.empty
            _layerImage = nil
            _layerPixelSpacingX = Float(1.0 / 72.0 * 25.4)   // 1/72 inch in millimetres
            _layerPixelSpacingY = _layerPixelSpacingX
            self.name = NSLocalizedString("Layer", comment: "")
            _textualBoxLine1 = ROI.empty
            _textualBoxLine2 = ROI.empty
            _textualBoxLine3 = ROI.empty
            _textualBoxLine4 = ROI.empty
            _textualBoxLine5 = ROI.empty
            _textualBoxLine6 = ROI.empty
            forgetLayerPixels()
        } else {
            self.name = NSLocalizedString("Unnamed", comment: "")
        }

        _displayTextualData = true

        if AnnotationLevel.revealROIs() {
            ROI.setViewDefaults()
        }
        postOnMainThreadOnly(.OsirixROIChange)
    }

    /// A brush ROI of the `tWidth` × `tHeight` bytes of `tBuff`, whose upper
    /// left corner is at (`posX`, `posY`) in the image.
    @objc(initWithTexture:textWidth:textHeight:textName:positionX:positionY:spacingX:spacingY:imageOrigin:)
    public init!(texture tBuff: UnsafeMutablePointer<UInt8>!, textWidth tWidth: Int32, textHeight tHeight: Int32, textName tName: String!,
                 positionX posX: Int32, positionY posY: Int32, spacingX ipixelSpacingx: Float, spacingY ipixelSpacingy: Float,
                 imageOrigin iimageOrigin: NSPoint) {
        super.init()
        if tWidth < 0 || tHeight < 0 { return nil }
        guard let copy = malloc(Int(tWidth) &* Int(tHeight))?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let s = ROI.settings

        // As the other ROIs are.
        uniqueID = NSNumber(value: ROI.takeUniqueID())
        _groupID = 0.0
        PointUnderMouse = -1
        selectedModifyPoint = -1
        ctxArray = NSMutableArray(capacity: 10)
        textArray = NSMutableArray(capacity: 10)
        _selectable = true
        _locked = false
        _type = .tPlain
        mode = ROI_sleep
        _parentROI = nil
        _thickness = 2.0
        _opacity = 0.5
        _mousePosMeasure = -1
        _pixelSpacingX = Double(ipixelSpacingx)
        _pixelSpacingY = Double(ipixelSpacingy)
        _imageOrigin = iimageOrigin
        _points = NSMutableArray()
        _zPositions = NSMutableArray()
        _comments = ROI.empty
        stringTex = nil
        resetStatistics()
        previousPoint = NSPoint(x: -1000, y: -1000)

        // A brush's own.
        textureFirstPoint = 1   // the texture has its first point
        mask.buffer = copy
        mask.upLeftX = posX
        mask.upLeftY = posY
        mask.downRightX = posX &+ tWidth &- 1
        mask.downRightY = posY &+ tHeight &- 1
        mask.width = tWidth
        mask.height = tHeight
        memcpy(copy, tBuff, Int(tHeight) &* Int(tWidth))
        _ = reduceTextureIfPossible()

        self.name = tName
        _displayTextualData = true

        _thickness = s.regionThickness
        color = RGBColor(red: ROI.colorComponent(s.regionColorR), green: ROI.colorComponent(s.regionColorG), blue: ROI.colorComponent(s.regionColorB))
        _opacity = s.regionOpacity

        if AnnotationLevel.revealROIs() {
            ROI.setViewDefaults()
        }
        postOnMainThreadOnly(.OsirixROIChange)
    }

    /// An archived ROI arrives from outside Horos - in an SR received by
    /// C-STORE, imported or read from media, in a .roi file, on the
    /// pasteboard. IsiXROI reads its values, in the order and of the classes
    /// encode(with:) writes them, and refuses the whole ROI when one is not;
    /// what is left here is what needs AppKit (the layer's colour and image)
    /// and the ROI's own fields.
    @objc(initWithCoder:)
    public required init?(coder: NSCoder) {
        super.init()
        uniqueID = NSNumber(value: ROI.takeUniqueID())
        _groupID = 0.0
        PointUnderMouse = -1
        selectedModifyPoint = -1
        _parentROI = nil

        var refusal = ROIArchiveRefusal.none
        let record = ROIArchiveCoder.read(from: coder, version: coder.version(forClassName: "ROI"),
                                          pointClass: MyPoint.self, colorClass: NSColor.self, refusal: &refusal)
        if refusal == .unsupportedTool { return nil }   // OsiriX 6's tBall and tOvalAngle
        guard let record else {
            NSLog("Refused an archived ROI holding a value of another class or size than a ROI archives")
            return nil
        }

        _points = record.points ?? NSMutableArray()
        _rect = record.rect
        _type = ToolMode(rawValue: record.tool) ?? .tWL
        _needQuartz = record.needQuartz != 0
        _thickness = record.thickness
        fill = record.fill != 0
        _opacity = record.opacity
        color = RGBColor(red: ROI.colorComponent(record.colorRed), green: ROI.colorComponent(record.colorGreen),
                         blue: ROI.colorComponent(record.colorBlue))
        _name = record.name
        _comments = record.comments
        _pixelSpacingX = Double(record.pixelSpacingX)
        _pixelSpacingY = Double(record.pixelSpacingY)
        _imageOrigin = record.imageOrigin

        var valid = true
        if _type == .tPlain {
            mask.width = record.textureWidth
            mask.height = record.textureHeight
            mask.upLeftX = record.textureUpLeftCornerX
            mask.upLeftY = record.textureUpLeftCornerY
            mask.downRightX = record.textureDownRightCornerX
            mask.downRightY = record.textureDownRightCornerY
            let size = Int(mask.width) &* Int(mask.height)
            mask.buffer = malloc(Swift.max(size, 1))?.assumingMemoryBound(to: UInt8.self)
            if let buffer = mask.buffer {
                record.texture?.getBytes(buffer, length: size)
            } else {
                valid = false
            }
        }

        _zPositions = record.zPositions ?? NSMutableArray()
        offsetTextBox_x = record.offsetTextBoxX
        offsetTextBox_y = record.offsetTextBoxY
        _calciumThreshold = record.calciumThreshold
        _displayCalciumScoring = record.displayCalciumScoring
        _groupID = record.groupID

        if _type == .tLayerROI, let layer = record.layerImage {
            layerImageJPEG = layer
            _layerImage = NSImage(data: layer as Data)
            forgetLayerPixels()
        }
        _textualBoxLine1 = record.textualBoxLine1
        _textualBoxLine2 = record.textualBoxLine2
        _textualBoxLine3 = record.textualBoxLine3
        _textualBoxLine4 = record.textualBoxLine4
        _textualBoxLine5 = record.textualBoxLine5

        _isLayerOpacityConstant = record.isLayerOpacityConstant
        _canColorizeLayer = record.canColorizeLayer
        // Colorizing reads its RGB components, which a catalog or pattern colour does not have.
        if let archived = record.layerColor as? NSColor {
            layerColor = archived.usingColorSpace(.genericRGB)
            if layerColor == nil { valid = false }
        }
        _displayTextualData = record.displayTextualData
        canResizeLayer = record.canResizeLayer
        _selectable = record.selectable
        _locked = record.locked
        _isAliased = record.isAliased
        _isSpline = record.isSpline
        _hasIsSpline = record.hasIsSpline
        _textNameOnly = record.textNameOnly
        _hidden = record.hidden

        if !valid {
            NSLog("Refused an archived ROI holding a value of another class or size than a ROI archives")
            return nil
        }
        mode = ROI_sleep
        previousPoint = NSPoint(x: -1000, y: -1000)
        stringTex = nil
        resetStatistics()
        _mousePosMeasure = -1
        ctxArray = NSMutableArray(capacity: 10)
        textArray = NSMutableArray(capacity: 10)
        stanStringAttrib = ROI.labelAttributes(size: 12.0 + Double(_thickness) * 2)
        _ = reduceTextureIfPossible()

        postOnMainThreadOnly(.OsirixROIChange)
    }

    @objc(encodeWithCoder:)
    public func encode(with coder: NSCoder) {
        ROI.setVersion(Int(ROIArchiveRecord.currentVersion))

        let record = ROIArchiveRecord()
        record.points = _points
        record.rect = _rect
        record.type = Float(_type.rawValue)
        record.needQuartz = _needQuartz ? 1 : 0
        record.thickness = _thickness
        record.fill = fill ? 1 : 0
        record.opacity = _opacity
        record.colorRed = Float(color.red)
        record.colorGreen = Float(color.green)
        record.colorBlue = Float(color.blue)
        record.name = _name
        record.comments = _comments
        record.pixelSpacingX = Float(_pixelSpacingX)
        record.pixelSpacingY = Float(_pixelSpacingY)
        record.imageOrigin = _imageOrigin
        if _type == .tPlain {
            record.textureWidth = mask.width
            record.textureHeight = mask.height
            record.textureUpLeftCornerX = mask.upLeftX
            record.textureUpLeftCornerY = mask.upLeftY
            record.textureDownRightCornerX = mask.downRightX
            record.textureDownRightCornerY = mask.downRightY
            record.texture = NSData(bytes: mask.buffer, length: Int(Int32(truncatingIfNeeded: Int(mask.width) &* Int(mask.height))))
        }
        record.zPositions = _zPositions
        record.offsetTextBoxX = offsetTextBox_x
        record.offsetTextBoxY = offsetTextBox_y
        record.calciumThreshold = _calciumThreshold
        record.displayCalciumScoring = _displayCalciumScoring
        record.groupID = _groupID
        if _type == .tLayerROI {
            if layerImageJPEG == nil { generateEncodedLayerImage() }
            record.layerImage = layerImageJPEG
        }
        record.textualBoxLine1 = _textualBoxLine1
        record.textualBoxLine2 = _textualBoxLine2
        record.textualBoxLine3 = _textualBoxLine3
        record.textualBoxLine4 = _textualBoxLine4
        record.textualBoxLine5 = _textualBoxLine5
        record.isLayerOpacityConstant = _isLayerOpacityConstant
        record.canColorizeLayer = _canColorizeLayer
        record.layerColor = layerColor
        record.displayTextualData = _displayTextualData
        record.canResizeLayer = canResizeLayer
        record.selectable = _selectable
        record.locked = _locked
        record.isAliased = _isAliased
        record.isSpline = _isSpline
        record.hasIsSpline = _hasIsSpline
        record.textNameOnly = _textNameOnly
        record.hidden = _hidden
        record.emptyString = ROI.empty

        ROIArchiveCoder.write(record, to: coder)
    }

    /// The archive SDK callers and persisted SR comparisons use: a typedstream
    /// written by NSArchiver, which only Objective-C still reaches.
    @objc public var data: Data! {
        let selector = NSSelectorFromString("archivedDataWithRootObject:")
        guard let writer = NSClassFromString("NSArchiver").map({ $0 as AnyObject }), writer.responds(to: selector) else {
            NSException(name: .internalInconsistencyException, reason: "The historical typedstream writer is unavailable.", userInfo: nil).raise()
            return nil
        }
        return writer.perform(selector, with: self)?.takeUnretainedValue() as? Data
    }

    /// A copy of the ROI, as a new ROI: its own identifier and no group, its
    /// points and texture copied, asleep. Answers nil when its brush texture
    /// or layer image cannot be copied, as it always did: callers check.
    @objc(copyWithZone:)
    @discardableResult
    public func copyROI(with zone: NSZone?) -> ROI? {
        // A layer whose image cannot be decoded has no copy. The Objective-C
        // ROI found it out on a copy it then leaked; this one finds it out
        // before making the copy, which would otherwise be announced removed
        // when dropped, and skips the identifier the copy took.
        var layerJPEG: NSData?, layerImage: NSImage?
        if _type == .tLayerROI {
            layerJPEG = layerImageJPEG?.copy() as? NSData
            layerImage = layerJPEG.flatMap { NSImage(data: $0 as Data) }
            if layerImage == nil {
                _ = ROI.takeUniqueID()
                return nil
            }
        }

        let c = Swift.type(of: self).init()
        c.uniqueID = NSNumber(value: ROI.takeUniqueID())
        c._groupID = 0.0
        c.PointUnderMouse = -1
        c.selectedModifyPoint = -1
        c._parentROI = nil

        let a = NSMutableArray()
        for case let p as MyPoint in _points { a.add(p.copy(with: nil)) }
        c._points = a

        c._rect = _rect
        c._type = _type
        c._needQuartz = _needQuartz
        c._thickness = _thickness
        c.fill = fill
        c._opacity = _opacity
        c.color = color
        c._name = _name?.copy() as? NSString
        c._comments = _comments?.copy() as? NSString
        c._pixelSpacingX = _pixelSpacingX
        c._imageOrigin = _imageOrigin
        c._pixelSpacingY = _pixelSpacingY

        if c._type == .tPlain {
            c.mask.width = mask.width
            c.mask.height = mask.height
            c.mask.upLeftX = mask.upLeftX
            c.mask.upLeftY = mask.upLeftY
            c.mask.downRightX = mask.downRightX
            c.mask.downRightY = mask.downRightY
            let size = Int(Int32(truncatingIfNeeded: Int(mask.width) &* Int(mask.height)))
            c.mask.buffer = malloc(size)?.assumingMemoryBound(to: UInt8.self)
            guard let buffer = c.mask.buffer else { return nil }
            if let source = mask.buffer { memcpy(buffer, source, size) }
        }

        let z = NSMutableArray()
        for case let p as NSNumber in _zPositions { z.add(p.copy()) }
        c._zPositions = z

        c.offsetTextBox_x = offsetTextBox_x
        c.offsetTextBox_y = offsetTextBox_y
        c._calciumThreshold = _calciumThreshold
        c._displayCalciumScoring = _displayCalciumScoring
        c._groupID = _groupID
        if c._type == .tLayerROI {
            c.layerImageJPEG = layerJPEG
            c._layerImage = layerImage
            forgetLayerPixels()
        }
        c._textualBoxLine1 = _textualBoxLine1?.copy() as? NSString
        c._textualBoxLine2 = _textualBoxLine2?.copy() as? NSString
        c._textualBoxLine3 = _textualBoxLine3?.copy() as? NSString
        c._textualBoxLine4 = _textualBoxLine4?.copy() as? NSString
        c._textualBoxLine5 = _textualBoxLine5?.copy() as? NSString
        c.textualBoxSegments = textualBoxSegments?.copy() as? NSDictionary

        c._isLayerOpacityConstant = _isLayerOpacityConstant
        c._canColorizeLayer = _canColorizeLayer
        c.layerColor = layerColor?.copy() as? NSColor
        c._displayTextualData = _displayTextualData
        c.canResizeLayer = canResizeLayer
        c._selectable = _selectable
        c._locked = _locked
        c._isAliased = _isAliased
        c._originalIndexForAlias = _originalIndexForAlias
        c.mode = ROI_sleep
        c.previousPoint = NSPoint(x: -1000, y: -1000)
        c.stringTex = nil
        c.resetStatistics()
        c._mousePosMeasure = -1
        c.ctxArray = NSMutableArray(capacity: 10)
        c.textArray = NSMutableArray(capacity: 10)
        c.stanStringAttrib = ROI.labelAttributes(size: 12.0 + Double(c._thickness) * 2)
        _ = c.reduceTextureIfPossible()
        c._hasIsSpline = _hasIsSpline
        c._isSpline = _isSpline
        c._textNameOnly = _textNameOnly
        return c
    }

    @objc public func prepareForRelease() {
        stringTextureCache = nil
        forgetLayerPixels()
        ctxArray = nil
        if (textArray?.count ?? 0) > 0 { NSLog("** not all texture were deleted...") }
        textArray = nil
    }

    deinit {
        _parentROI = nil
        // The notification center may keep the ROI in an autorelease pool: it
        // is drained before the ROI is gone.
        autoreleasepool {
            postOnMainThreadOnly(.OsirixRemoveROI)
        }
        prepareForRelease()
        free(mask.buffer)
        textureBufferHasChanged()
    }

    // MARK: Helpers

    /// The NSString the archive and the label lines share for "", as the
    /// Objective-C shared its one literal: the archive writes it once.
    nonisolated(unsafe) static let empty: NSString = ""

    static func takeUniqueID() -> Int32 {
        let id = nextUniqueID
        nextUniqueID &+= 1
        return id
    }

    /// `(unsigned short) value`, as a colour component was set from a float.
    static func colorComponent(_ value: Float) -> UInt16 {
        UInt16(truncatingIfNeeded: ROIBrushMask.int32(Double(value)))
    }

    static func colorComponent(_ value: Double) -> UInt16 {
        UInt16(truncatingIfNeeded: ROIBrushMask.int32(value))
    }

    /// The attributes of a text ROI's string: white Helvetica of `size` points.
    static func labelAttributes(size: Double) -> NSMutableDictionary {
        let attributes = NSMutableDictionary()
        if let font = NSFont(name: "Helvetica", size: CGFloat(size)) {
            attributes[NSAttributedString.Key.font] = font
        }
        attributes[NSAttributedString.Key.foregroundColor] = NSColor.white
        return attributes
    }

    func resetStatistics() {
        rmean = -1; rmax = -1; rmin = -1; rdev = -1; rtotal = -1
        Brmean = -1; Brmax = -1; Brmin = -1; Brdev = -1; Brtotal = -1
    }

    /// The statistics are computed again when next shown.
    func forgetStatistics() {
        rtotal = -1
        Brtotal = -1
    }

    // MARK: Properties

    @objc public dynamic var imageOrigin: NSPoint {
        get { _imageOrigin }
        set { _imageOrigin = newValue }
    }
    @objc public var textureWidth: Int32 { mask.width }
    @objc public var textureHeight: Int32 { mask.height }
    @objc public var textureDownRightCornerX: Int32 { mask.downRightX }
    @objc public var textureDownRightCornerY: Int32 { mask.downRightY }
    @objc public var textureUpLeftCornerX: Int32 { mask.upLeftX }
    @objc public var textureUpLeftCornerY: Int32 { mask.upLeftY }
    @objc public var textureBuffer: UnsafeMutablePointer<UInt8>! { mask.buffer }

    @objc public dynamic var opacity: Float {
        get { _opacity }
        set { setOpacity(newValue, globally: true) }
    }

    @objc public dynamic var originalIndexForAlias: Int32 {
        get { _originalIndexForAlias }
        set { _originalIndexForAlias = newValue }
    }

    @objc public dynamic var hidden: Bool {
        get { _hidden }
        set {
            _hidden = newValue
            view?.setNeedsDisplay(true)
        }
    }

    /// A hidden ROI is locked.
    @objc public dynamic var locked: Bool {
        get { _hidden ? true : _locked }
        set { _locked = newValue }
    }

    /// A hidden ROI cannot be selected.
    @objc public dynamic var selectable: Bool {
        get { _hidden ? false : _selectable }
        set { _selectable = newValue }
    }

    /// The label says only the name, without statistics; a brush's label then
    /// hangs from inside its largest piece. Archived.
    @objc public dynamic var textNameOnly: Bool {
        get { _textNameOnly }
        set { _textNameOnly = newValue }
    }

    @objc public dynamic var isAliased: Bool {
        get { _isAliased }
        set { _isAliased = newValue }
    }

    @objc public dynamic var displayCMOrPixels: Bool {
        get { _displayCMOrPixels }
        set { _displayCMOrPixels = newValue }
    }

    @objc public dynamic var mouseOverROI: Bool {
        get { _mouseOverROI }
        set { _mouseOverROI = newValue }
    }

    // The name and the comments: Swift reads them as String; Objective-C and
    // key-value coding, by the names they always had, get and set the very
    // strings the ROI keeps, as the Objective-C class did, without a
    // conversion at each call (observers read the name at every change).
    public var name: String! {
        get { _name as String? }
        set { nameString = newValue as NSString? }
    }

    @objc(name)
    public dynamic var nameString: NSString! {
        get { _name }
        set { setNameValue(newValue) }
    }

    public var comments: String! {
        get { _comments as String? }
        set { commentsString = newValue as NSString? }
    }

    @objc(comments)
    public dynamic var commentsString: NSString! {
        get { _comments }
        set { _comments = newValue }
    }

    @objc public dynamic var type: ToolMode {
        get { _type }
        set { _type = newValue }
    }

    @objc(ROImode)
    public dynamic var roImode: Int {
        get { mode }
        @objc(setROIMode:) set { setROIModeValue(newValue) }
    }

    /// The points of the ROI; computed for a rectangle, an oval, a 2D point
    /// and a brush. Setting them copies them in, except for those.
    @objc public dynamic var points: NSMutableArray! {
        get { pointsValue() }
        set { setPointsValue(newValue) }
    }

    @objc public var zPositions: NSMutableArray! { _zPositions }

    @objc public dynamic var clickInTextBox: Bool {
        get { _clickInTextBox }
        set { _clickInTextBox = newValue }
    }

    /// A rectangle's or an oval's frame (its centre and half sides for an
    /// oval), a 2D point's position, a text's frame.
    @objc public dynamic var rect: NSRect {
        get { _rect }
        @objc(setROIRect:) set { _rect = newValue }
    }

    /// The image of the ROI. Without one, the view's current image is taken, with a warning.
    @objc public dynamic var pix: DCMPix! {
        get {
            if let pix = _pix { return pix }
            NSLog("----- warning pix == [curView curDCM]")
            _pix = view?.curDCM
            return _pix
        }
        set { _pix = newValue }
    }

    /// The view of the ROI. Not retained.
    @objc public var curView: DCMView! {
        get { _curView }
        set { _curView = newValue }
    }

    @objc public dynamic var mousePosMeasure: Float {
        get { _mousePosMeasure }
        set { _mousePosMeasure = newValue }
    }

    @objc public dynamic var rgbcolor: RGBColor {
        get { color }
        @objc(setColor:) set { setColor(newValue, globally: true) }
    }

    @objc public dynamic var thickness: Float {
        get { _thickness }
        set { setThickness(newValue, globally: true) }
    }

    @objc(parentROI)
    public dynamic var parent: ROI! {
        get { _parentROI }
        @objc(setParentROI:) set { _parentROI = newValue }
    }

    @objc public dynamic var sliceThickness: Double {
        get { _sliceThickness }
        set { _sliceThickness = newValue }
    }

    @objc public dynamic var pixelSpacingX: Double {
        get { _pixelSpacingX }
        set { _pixelSpacingX = newValue }
    }

    @objc public dynamic var pixelSpacingY: Double {
        get { _pixelSpacingY }
        set { _pixelSpacingY = newValue }
    }

    @objc public dynamic var min: Float {
        get { rmin }
        set { rmin = newValue }
    }

    @objc public dynamic var max: Float {
        get { rmax }
        set { rmax = newValue }
    }

    @objc public dynamic var mean: Float {
        get { rmean }
        set { rmean = newValue }
    }

    @objc public dynamic var median: Double {
        get { _median }
        set { _median = newValue }
    }

    /// The colour with the opacity, calibrated.
    @objc(NSColor)
    public var nsColor: NSColor! {
        get {
            NSColor(calibratedRed: CGFloat(Double(color.red) / 65535.0), green: CGFloat(Double(color.green) / 65535.0),
                    blue: CGFloat(Double(color.blue) / 65535.0), alpha: CGFloat(_opacity))
        }
        @objc(setNSColor:) set { setNSColor(newValue, globally: true) }
    }

    /// Whether the outline is smoothed: the ROI's own choice once made, the preference otherwise.
    @objc public dynamic var isSpline: Bool {
        get { _hasIsSpline ? _isSpline : ROI.splineForROI() }
        set {
            _isSpline = newValue
            _hasIsSpline = true
        }
    }

    @objc public dynamic var displayCalciumScoring: Bool {
        get { _displayCalciumScoring }
        set { _displayCalciumScoring = newValue }
    }

    @objc public dynamic var calciumThreshold: Int32 {
        get { _calciumThreshold }
        set { _calciumThreshold = newValue }
    }

    @objc public dynamic var layerReferenceFilePath: String! {
        get { _layerReferenceFilePath as String? }
        set { _layerReferenceFilePath = newValue.map { $0 as NSString } }
    }

    @objc public dynamic var layerImage: NSImage! {
        get { _layerImage }
        set { setLayerImageValue(newValue) }
    }

    @objc public dynamic var layerPixelSpacingX: Float {
        get { _layerPixelSpacingX }
        set { _layerPixelSpacingX = newValue }
    }

    @objc public dynamic var layerPixelSpacingY: Float {
        get { _layerPixelSpacingY }
        set { _layerPixelSpacingY = newValue }
    }

    @objc public dynamic var textualBoxLine1: String! {
        get { _textualBoxLine1 as String? }
        set { _textualBoxLine1 = newValue.map { $0 as NSString } }
    }

    @objc public dynamic var textualBoxLine2: String! {
        get { _textualBoxLine2 as String? }
        set { _textualBoxLine2 = newValue.map { $0 as NSString } }
    }

    @objc public dynamic var textualBoxLine3: String! {
        get { _textualBoxLine3 as String? }
        set { _textualBoxLine3 = newValue.map { $0 as NSString } }
    }

    @objc public dynamic var textualBoxLine4: String! {
        get { _textualBoxLine4 as String? }
        set { _textualBoxLine4 = newValue.map { $0 as NSString } }
    }

    @objc public dynamic var textualBoxLine5: String! {
        get { _textualBoxLine5 as String? }
        set { _textualBoxLine5 = newValue.map { $0 as NSString } }
    }

    @objc public dynamic var textualBoxLine6: String! {
        get { _textualBoxLine6 as String? }
        set { _textualBoxLine6 = newValue.map { $0 as NSString } }
    }

    @objc public dynamic var groupID: TimeInterval {
        get { _groupID }
        set { _groupID = newValue }
    }

    @objc public dynamic var isLayerOpacityConstant: Bool {
        get { _isLayerOpacityConstant }
        set {
            _isLayerOpacityConstant = newValue
            forgetLayerPixels()
        }
    }

    @objc public dynamic var canColorizeLayer: Bool {
        get { _canColorizeLayer }
        set {
            _canColorizeLayer = newValue
            forgetLayerPixels()
        }
    }

    @objc public dynamic var displayTextualData: Bool {
        get { _displayTextualData }
        set { _displayTextualData = newValue }
    }

    @objc public var clickPoint: NSPoint { _clickPoint }

    // MARK: Setters that do more

    @objc(setOpacity:globally:)
    public func setOpacity(_ newOpacity: Float, globally g: Bool) {
        _opacity = newOpacity
        if _type == .tPlain {
            if g { ROI.settings.regionOpacity = _opacity }
        } else if _type == .tLayerROI {
            forgetLayerPixels()
        } else if g {
            ROI.settings.opacity = _opacity
        }
    }

    /// A name of more than 256 characters is cut, except a text ROI's; a text
    /// ROI's string and frame follow its name and comments.
    func setNameValue(_ value: NSString?) {
        var a: NSString = value ?? ROI.empty
        if _name !== a && !(_name?.isEqual(to: a as String) ?? false) {
            if _type != .tText && a.length > 256 {
                a = a.substring(to: 256) as NSString
            }
            _name = a.copy() as? NSString
            postChange()
        }
        if _type == .tText {
            var finalString: NSString
            if let comments = _comments, comments.length > 0 {
                finalString = (_name ?? ROI.empty).appendingFormat("\r%@", comments)
            } else {
                finalString = _name ?? ROI.empty
            }
            if finalString.length > 4096 { finalString = finalString.substring(to: 4096) as NSString }
            stringTex = finalString.copy() as? NSString
            _rect.size = textFrameSize()
            if _pixelSpacingX != 0 && _pixelSpacingY != 0 {
                _rect.size.height *= CGFloat(_pixelSpacingX / _pixelSpacingY)
            }
        }
    }

    /// A hidden ROI sleeps. Changing the mode tells the observers.
    func setROIModeValue(_ newMode: Int) {
        var m = newMode
        if _hidden { m = ROI_sleep }
        if mode != m {
            if NSEvent.pressedMouseButtons != 0 && (mode == ROI_drawing || mode == ROI_selectedModify) {
                NSLog("---- change ROI mode during modification?")
            }
            mode = m
            postChange()
        }
    }

    @objc(setColor:globally:)
    public func setColor(_ a: RGBColor, globally g: Bool) {
        color = a
        if _type == .tText {
            if g {
                ROI.settings.textColorR = Float(color.red)
                ROI.settings.textColorG = Float(color.green)
                ROI.settings.textColorB = Float(color.blue)
            }
        } else if _type == .tPlain {
            if g {
                ROI.settings.regionColorR = Float(color.red)
                ROI.settings.regionColorG = Float(color.green)
                ROI.settings.regionColorB = Float(color.blue)
            }
        } else if _type == .tLayerROI {
            guard _canColorizeLayer else { return }
            layerColor = NSColor(calibratedRed: CGFloat(Double(color.red) / 65535.0), green: CGFloat(Double(color.green) / 65535.0),
                                 blue: CGFloat(Double(color.blue) / 65535.0), alpha: 1.0)
            forgetLayerPixels()
        } else if g {
            ROI.settings.colorR = Float(color.red)
            ROI.settings.colorG = Float(color.green)
            ROI.settings.colorB = Float(color.blue)
        }
    }

    /// Between 1 and 20, rounded. A text's font follows its thickness.
    @objc(setThickness:globally:)
    public func setThickness(_ a: Float, globally g: Bool) {
        var v = a.rounded()   // roundf: fewer distinct point sizes and line widths
        if v < 1 { v = 1 }
        if v > 20 { v = 20 }
        _thickness = v

        if _type == .tPlain {
            if g { ROI.settings.regionThickness = _thickness }
        } else if _type == .tArrow {
            if g { ROI.settings.arrowThickness = _thickness }
        } else if _type == .tText || _type == .tTAGT {
            if g { ROI.settings.textThickness = _thickness }
            stanStringAttrib = ROI.labelAttributes(size: 12.0 + Double(_thickness) * 2)
            self.name = self.name
        } else {
            if g { ROI.settings.thickness = _thickness }
        }
    }

    @objc(setNSColor:globally:)
    public func setNSColor(_ nsColor: NSColor!, globally g: Bool) {
        // Normalize the input before reading RGB components or changing either property.
        guard let rgb = nsColor?.usingColorSpace(.genericRGB) else { return }   // Pattern colors and nil have no representable ROI color.
        var r: CGFloat = 0, green: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getRed(&r, green: &green, blue: &b, alpha: &a)
        guard r.isFinite, green.isFinite, b.isFinite, a.isFinite else { return }
        let rgbColor = RGBColor(red: ROI.colorComponent(Double(Swift.min(1.0, Swift.max(0.0, r)) * 65535.0)),
                                green: ROI.colorComponent(Double(Swift.min(1.0, Swift.max(0.0, green)) * 65535.0)),
                                blue: ROI.colorComponent(Double(Swift.min(1.0, Swift.max(0.0, b)) * 65535.0)))
        setOpacity(Float(Swift.min(1.0, Swift.max(0.0, a))), globally: g)
        setColor(rgbColor, globally: g)
    }

    @discardableResult
    @objc public func isValidForVolume() -> Bool {
        return _type == .tCPolygon || _type == .tOPolygon || _type == .tPlain || _type == .tPencil || _type == .tOval
    }

    /// Prints the brush's bytes.
    @objc public func displayTexture() {
        print("-*- DISPLAY ROI TEXTURE -*-")
        for j in 0..<Int(mask.height) {
            var line = ""
            for i in 0..<Int(mask.width) { line += "\(mask.buffer![i + j * Int(mask.width)]) " }
            print(line)
        }
    }

    /// The label pictures are made again, in the label font.
    @objc public func updateLabelFont() {
        stringTextureCache?.removeAllObjects()
        view?.setNeedsDisplay(true)
    }

    @available(*, deprecated, message: "use curView")
    @objc(setRoiView:)
    public func setRoiView(_ v: DCMView!) {
        self.curView = v
    }

    /// Always NO.
    @discardableResult
    @objc public func needQuartz() -> Bool {
        return false
    }

    public override var description: String {
        var mean: Float = 0, min: Float = 0, max: Float = 0, total: Float = 0, dev: Float = 0
        _pix?.computeROI(self, &mean, &total, &dev, &min, &max)
        let median = self.median.isFinite ? String(format: "%.3f", self.median) : NSLocalizedString("N/A", comment: "")
        let unit = _pix?.suvConverted == true ? "SUV" : (_pix?.rescaleType ?? "")
        return String(format: "%@\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%@\t%@", (_name ?? "(null)") as NSString, Double(mean), Double(min), Double(max),
                      Double(total), Double(dev), median as NSString, unit as NSString)
    }
}
