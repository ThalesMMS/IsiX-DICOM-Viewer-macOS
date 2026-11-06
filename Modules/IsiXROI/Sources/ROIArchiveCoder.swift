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

import CoreGraphics
import Foundation

/// What a ROI archive holds, field by field, in the order and with the types
/// `-[ROI encodeWithCoder:]` writes them: the persisted form of a ROI, which
/// `.roi` and `.rois_series` files, the pasteboard and the ROI SRs carry, and
/// which ROIs written by earlier versions must still open as.
///
/// The archive is unkeyed: values follow one another, and the class version
/// of ROI in the stream says which of them are there. Numbers are kept here as
/// the archive stores them (`float` for most, `int` for the brush texture);
/// the ROI converts them to its own fields as it always did. Objects the module
/// cannot know - the points, the layer colour - are kept as they were decoded,
/// after their class has been checked against the one the caller names.
@objc(IsiXROIArchiveRecord)
@objcMembers
public final class ROIArchiveRecord: NSObject {
    /// The class version `-encodeWithCoder:` gives ROI: values 12 to 15 are
    /// OsiriX 6's placeholders, 16 this fork's own.
    public static let currentVersion = 16

    public var points: NSMutableArray?
    public var rect: CGRect = .zero
    /// The tool, as stored: a `float` holding a ToolMode.
    public var type: Float = 0
    public var needQuartz: Float = 0
    public var thickness: Float = 0
    public var fill: Float = 0
    public var opacity: Float = 0
    public var colorRed: Float = 0
    public var colorGreen: Float = 0
    public var colorBlue: Float = 0
    public var name: NSString?
    public var comments: NSString?
    public var pixelSpacingX: Float = 0
    public var pixelSpacingY: Float = 0
    public var imageOrigin: CGPoint = .zero

    /// The brush mask, only for a brush (tPlain): width x height bytes, row by
    /// row, and its corners in image pixels.
    public var textureWidth: Int32 = 0
    public var textureHeight: Int32 = 0
    public var textureUpLeftCornerX: Int32 = 0
    public var textureUpLeftCornerY: Int32 = 0
    public var textureDownRightCornerX: Int32 = 0
    public var textureDownRightCornerY: Int32 = 0
    public var texture: NSData?

    public var zPositions: NSMutableArray?
    public var offsetTextBoxX: Float = 0
    public var offsetTextBoxY: Float = 0
    public var calciumThreshold: Int32 = 0
    public var displayCalciumScoring = false
    public var groupID: Double = 0
    /// The encoded layer image, only for a layer ROI (tLayerROI).
    public var layerImage: NSData?
    public var textualBoxLine1: NSString?
    public var textualBoxLine2: NSString?
    public var textualBoxLine3: NSString?
    public var textualBoxLine4: NSString?
    public var textualBoxLine5: NSString?
    public var isLayerOpacityConstant = false
    public var canColorizeLayer = false
    public var layerColor: AnyObject?
    public var displayTextualData = true
    public var canResizeLayer = false
    public var selectable = true
    public var locked = false
    public var isAliased = false
    public var isSpline = false
    public var hasIsSpline = false
    public var textNameOnly = false
    public var hidden = false
    /// The empty string written where OsiriX 6 keeps a study UID. An archive
    /// writes an object it has already written as a reference to it, so the
    /// writer passes its own empty literal, the one its other empty strings
    /// are: the archive then stays byte for byte what it was.
    public var emptyString: NSString = ""

    /// The tool as the ROI keeps it: the stored `float` truncated to a short.
    public var tool: Int16 { Int16(truncatingIfNeeded: Int(type)) }
}

/// Why an archived ROI did not read.
@objc(IsiXROIArchiveRefusal)
public enum ROIArchiveRefusal: Int {
    case none = 0
    /// A ball or an oval angle of OsiriX 6, which this application never had:
    /// silently skipped, as it always was.
    case unsupportedTool
    /// A value of another class or size than a ROI archives.
    case invalidValue
}

/// Reads and writes `ROIArchiveRecord` through an unkeyed `NSCoder`.
///
/// An archived ROI arrives from outside - in an SR received by C-STORE,
/// imported or read from media, in a .roi file, on the pasteboard - so every
/// value read is checked against what the writer puts there before it is
/// used. A value of another class, or a brush texture that its data does not
/// hold, refuses the whole ROI. Every value is still read, so that a refused
/// ROI does not leave the stream out of step for the objects after it.
@objc(IsiXROIArchiveCoder)
public final class ROIArchiveCoder: NSObject {
    /// DICOM Rows and Columns are 16 bits, and a brush texture lies on its image.
    static let maximumTextureSide: Int64 = 65535
    /// Texture corners are image pixel coordinates; far beyond any image, and
    /// small enough that a corner plus a side stays an int.
    static let maximumTextureCorner: Int64 = 1 << 24

    static let brushTool: Int16 = 20         // tPlain
    static let layerTool: Int16 = 24         // tLayerROI
    static let ballTool: Int16 = 30          // OsiriX 6's tBall
    static let ovalAngleTool: Int16 = 31     // OsiriX 6's tOvalAngle

    /// Reads one ROI written at class `version`. Points must be of `pointClass`
    /// and the layer colour of `colorClass`. On a refusal the result is nil and
    /// `refusal` says why.
    @objc(readFromCoder:version:pointClass:colorClass:refusal:)
    public static func read(from coder: NSCoder, version: Int, pointClass: AnyClass, colorClass: AnyClass,
                            refusal: UnsafeMutablePointer<ROIArchiveRefusal>?) -> ROIArchiveRecord? {
        var reader = Reader(coder: coder)
        let record = ROIArchiveRecord()

        record.points = reader.array(of: pointClass)
        record.rect = NSRectFromString(reader.string() as String? ?? "")
        let archivedType = reader.number()?.floatValue ?? 0
        if archivedType >= 0 && archivedType <= 31 {   // tWL to OsiriX 6's tOvalAngle; not NaN
            record.type = archivedType
        } else {
            reader.valid = false
        }
        if record.tool == ovalAngleTool || record.tool == ballTool {
            refusal?.pointee = .unsupportedTool
            return nil
        }

        record.needQuartz = reader.number()?.floatValue ?? 0
        record.thickness = reader.number()?.floatValue ?? 0
        record.fill = reader.number()?.floatValue ?? 0
        record.opacity = reader.number()?.floatValue ?? 0
        record.colorRed = reader.number()?.floatValue ?? 0
        record.colorGreen = reader.number()?.floatValue ?? 0
        record.colorBlue = reader.number()?.floatValue ?? 0
        record.name = reader.string()
        record.comments = reader.string()
        record.pixelSpacingX = reader.number()?.floatValue ?? 0
        record.imageOrigin = NSPointFromString(reader.string() as String? ?? "")
        record.pixelSpacingY = version >= 2 ? reader.number()?.floatValue ?? 0 : record.pixelSpacingX

        if record.tool == brushTool {
            readTexture(into: record, from: &reader)
        }

        record.zPositions = version >= 3 ? reader.array(of: NSNumber.self) : NSMutableArray()

        if version >= 4 {
            record.offsetTextBoxX = reader.number()?.floatValue ?? 0
            record.offsetTextBoxY = reader.number()?.floatValue ?? 0
        }
        if version >= 5 {
            record.calciumThreshold = reader.number()?.int32Value ?? 0
            record.displayCalciumScoring = reader.number()?.boolValue ?? false
        }
        if version >= 6 {
            record.groupID = reader.number()?.doubleValue ?? 0
            if record.tool == layerTool {
                record.layerImage = reader.object(of: NSData.self) as? NSData
            }
            record.textualBoxLine1 = reader.string()
            record.textualBoxLine2 = reader.string()
            record.textualBoxLine3 = reader.string()
            record.textualBoxLine4 = reader.string()
            record.textualBoxLine5 = reader.string()
        }
        if version >= 7 {
            record.isLayerOpacityConstant = reader.number()?.boolValue ?? false
            record.canColorizeLayer = reader.number()?.boolValue ?? false
            record.layerColor = reader.object(of: colorClass)
            record.displayTextualData = reader.number()?.boolValue ?? false
        }
        if version >= 8 {
            record.canResizeLayer = reader.number()?.boolValue ?? false
        }
        if version >= 9 {
            record.selectable = reader.number()?.boolValue ?? false
            record.locked = reader.number()?.boolValue ?? false
        }
        if version >= 10 {
            record.isAliased = reader.number()?.boolValue ?? false
        }
        if version >= 11 {
            record.isSpline = reader.number()?.boolValue ?? false
            record.hasIsSpline = reader.number()?.boolValue ?? false
        }

        // OsiriX 6.0 or later: read and ignored.
        if version >= 12 { _ = reader.string() }                                       // studyInstanceUID
        if version >= 13 && record.tool == ovalAngleTool { _ = reader.number(); _ = reader.number() }
        if version >= 14 { _ = reader.number() }                                       // rotation
        if version >= 15 { _ = reader.number() }                                       // z location

        // This fork writes placeholders for 12 to 15, then its own values.
        if version >= 16 {
            record.textNameOnly = reader.number()?.boolValue ?? false
            record.hidden = reader.number()?.boolValue ?? false
        }

        guard reader.valid else {
            refusal?.pointee = .invalidValue
            return nil
        }
        refusal?.pointee = .none
        return record
    }

    /// The brush texture: its sides must be in range, its corner on some image,
    /// and its data must hold width x height bytes. A down right corner past
    /// the texture is put back on its last pixel.
    private static func readTexture(into record: ROIArchiveRecord, from reader: inout Reader) {
        let width = reader.number()?.int64Value ?? 0
        _ = reader.number()?.int32Value     // kept for compatibility with the encoder
        let height = reader.number()?.int64Value ?? 0
        _ = reader.number()?.int32Value     // kept for compatibility with the encoder
        let upLeftX = reader.number()?.int64Value ?? 0
        let upLeftY = reader.number()?.int64Value ?? 0
        let downRightX = reader.number()?.int64Value ?? 0
        let downRightY = reader.number()?.int64Value ?? 0
        let texture = reader.object(of: NSData.self) as? NSData

        guard width >= 0, width <= maximumTextureSide, height >= 0, height <= maximumTextureSide,
              abs(upLeftX) <= maximumTextureCorner, abs(upLeftY) <= maximumTextureCorner,
              UInt64(texture?.length ?? 0) >= UInt64(width * height) else {
            reader.valid = false
            return
        }
        record.textureWidth = Int32(width)
        record.textureHeight = Int32(height)
        record.textureUpLeftCornerX = Int32(upLeftX)
        record.textureUpLeftCornerY = Int32(upLeftY)
        // Painting and hit testing index the texture by the down right corner: it may not lie past the texture.
        record.textureDownRightCornerX = downRightX >= upLeftX - 1 && downRightX <= upLeftX + width
            ? Int32(downRightX) : record.textureUpLeftCornerX + record.textureWidth - 1
        record.textureDownRightCornerY = downRightY >= upLeftY - 1 && downRightY <= upLeftY + height
            ? Int32(downRightY) : record.textureUpLeftCornerY + record.textureHeight - 1
        record.texture = texture
    }

    /// Writes `record` at the current version; the caller sets ROI's class version.
    @objc(writeRecord:toCoder:)
    public static func write(_ record: ROIArchiveRecord, to coder: NSCoder) {
        coder.encode(record.points)
        coder.encode(NSStringFromRect(record.rect) as NSString)
        coder.encode(NSNumber(value: record.type))
        coder.encode(NSNumber(value: record.needQuartz))
        coder.encode(NSNumber(value: record.thickness))
        coder.encode(NSNumber(value: record.fill))
        coder.encode(NSNumber(value: record.opacity))
        coder.encode(NSNumber(value: record.colorRed))
        coder.encode(NSNumber(value: record.colorGreen))
        coder.encode(NSNumber(value: record.colorBlue))
        coder.encode(record.name)
        coder.encode(record.comments)
        coder.encode(NSNumber(value: record.pixelSpacingX))
        coder.encode(NSStringFromPoint(record.imageOrigin) as NSString)
        coder.encode(NSNumber(value: record.pixelSpacingY))
        if record.tool == brushTool {
            coder.encode(NSNumber(value: record.textureWidth))
            coder.encode(NSNumber(value: Int32(0)))
            coder.encode(NSNumber(value: record.textureHeight))
            coder.encode(NSNumber(value: Int32(0)))
            coder.encode(NSNumber(value: record.textureUpLeftCornerX))
            coder.encode(NSNumber(value: record.textureUpLeftCornerY))
            coder.encode(NSNumber(value: record.textureDownRightCornerX))
            coder.encode(NSNumber(value: record.textureDownRightCornerY))
            coder.encode(record.texture)
        }
        coder.encode(record.zPositions)
        coder.encode(NSNumber(value: record.offsetTextBoxX))
        coder.encode(NSNumber(value: record.offsetTextBoxY))
        coder.encode(NSNumber(value: record.calciumThreshold))
        coder.encode(NSNumber(value: record.displayCalciumScoring))

        // Version 6
        coder.encode(NSNumber(value: record.groupID))
        if record.tool == layerTool {
            coder.encode(record.layerImage)
        }
        coder.encode(record.textualBoxLine1)
        coder.encode(record.textualBoxLine2)
        coder.encode(record.textualBoxLine3)
        coder.encode(record.textualBoxLine4)
        coder.encode(record.textualBoxLine5)

        // Version 7
        coder.encode(NSNumber(value: record.isLayerOpacityConstant))
        coder.encode(NSNumber(value: record.canColorizeLayer))
        coder.encode(record.layerColor)
        coder.encode(NSNumber(value: record.displayTextualData))

        // Version 8
        coder.encode(NSNumber(value: record.canResizeLayer))

        // Version 9
        coder.encode(NSNumber(value: record.selectable))
        coder.encode(NSNumber(value: record.locked))

        // Version 10
        coder.encode(NSNumber(value: record.isAliased))

        // Version 11
        coder.encode(NSNumber(value: record.isSpline))
        coder.encode(NSNumber(value: record.hasIsSpline))

        // Versions 12 to 15 are OsiriX 6's, which the reader reads and ignores:
        // placeholders, so that what follows is read at its place.
        coder.encode(record.emptyString)
        if record.tool == ovalAngleTool {
            coder.encode(NSNumber(value: 0.0))
            coder.encode(NSNumber(value: 0.0))
        }
        coder.encode(NSNumber(value: 0.0))
        coder.encode(NSNumber(value: 0.0))

        // Version 16
        coder.encode(NSNumber(value: record.textNameOnly))
        coder.encode(NSNumber(value: record.hidden))
    }

    /// The next values of an unkeyed archive, each checked for its class.
    private struct Reader {
        let coder: NSCoder
        /// Every value so far is of the class and size the writer puts there.
        var valid = true

        /// The next object, when it is nil or of `type`; otherwise nil, and the archive is invalid.
        mutating func object(of type: AnyClass) -> AnyObject? {
            guard let object = coder.decodeObject() as AnyObject? else { return nil }
            if !object.isKind(of: type) {
                valid = false
                return nil
            }
            return object
        }

        /// A number, which the writer puts as an NSNumber. nil reads as 0, as it always did.
        mutating func number() -> NSNumber? { object(of: NSNumber.self) as? NSNumber }

        mutating func string() -> NSString? { object(of: NSString.self) as? NSString }

        /// An array whose elements are all of `type`, mutable as the ROI keeps it.
        mutating func array(of type: AnyClass) -> NSMutableArray? {
            guard let array = object(of: NSArray.self) as? NSArray else { return nil }
            for element in array where !(element as AnyObject).isKind(of: type) {
                valid = false
                return nil
            }
            return NSMutableArray(array: array)
        }
    }
}
