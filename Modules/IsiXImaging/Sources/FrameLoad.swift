/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// One frame's loading, for the Objective-C image object that keeps its
/// pixels and attributes in instance variables.
///
/// The object hands over what it declares and the frame its decoder produced,
/// and takes back the buffer and the attributes the frame decided, in flat
/// properties Objective-C can reach. The work is `FramePhotometry` and
/// `FrameLoader`, on value types. The decoders, the VOI LUT and the sentences
/// that explain missing pixels stay with the object, which owns them.
@objc(IsiXFrameLoad)
public final class FrameLoad: NSObject {
    private var layout = FrameLayout(width: 0, height: 0, bitsAllocated: 16, bitsStored: 16, isSigned: false, slope: 1, offset: 0)
    private var photometry = FramePhotometry(bitsAllocated: 16, planarConfiguration: 0)
    private var overlays: [OverlayBitmap] = []
    private var raised: AttributeReadException?

    // MARK: - what the image declares

    @objc(setWidth:height:bitsAllocated:bitsStored:signed:)
    public func setSamples(width: Int, height: Int, bitsAllocated: Int16, bitsStored: Int16, signed: Bool) {
        layout.width = width
        layout.height = height
        layout.bitsAllocated = bitsAllocated
        layout.bitsStored = bitsStored
        layout.isSigned = signed
        photometry.bitsAllocated = bitsAllocated
    }

    @objc(setSlope:offset:)
    public func setModalityLUT(slope: Float, offset: Float) {
        layout.slope = slope
        layout.offset = offset
    }

    @objc public var planarConfiguration: Int {
        get { photometry.planarConfiguration }
        set { photometry.planarConfiguration = newValue }
    }
    @objc public var file: String?
    /// The series' volume, when the image's pixels live in it.
    @objc public var externalImage: UnsafeMutablePointer<Float>?
    /// The NM opacity table is in use: a MONOCHROME1 NM image keeps its polarity.
    @objc public var keepsNuclearMedicinePolarity = false
    /// The preference that 32-bit Pixel Data always holds integers.
    @objc public var thirtyTwoBitPixelsAreIntegers = false

    /// An overlay plane to draw into the pixels. Only the planes to be shown
    /// are added; the bitmap must outlive the loading.
    @objc(addOverlay:rows:columns:originX:originY:)
    public func addOverlay(_ pixels: UnsafePointer<UInt8>?, rows: Int32, columns: Int32, originX: Int32, originY: Int32) {
        guard let pixels else { return }
        overlays.append(OverlayBitmap(pixels: pixels, rows: rows, columns: columns, originX: originX, originY: originY))
    }

    // MARK: - loading

    /// The frame's position along the normal: an RT Dose object's frames are
    /// planes of one grid, each at its Grid Frame Offset Vector value from
    /// the object's origin (PS 3.3 C.8.8.3.2). Returns NO when the reading
    /// raised.
    @objc(readFrameOffset:from:)
    public func readFrameOffset(_ frame: Int, from dataset: DICOMAttributeSource) -> Bool {
        attempt { frameOffset = try FramePosition.gridFrameOffset(of: frame, in: dataset) }
    }

    /// Whether the frame is offset from the image's origin, and by how much.
    @objc public var hasFrameOffset: Bool { frameOffset != nil }
    @objc public var frameOffsetValue: Double { frameOffset ?? 0 }
    private var frameOffset: Double?

    /// Loads a decoded frame - nil or empty when the frame carried nothing -
    /// into `image`, reading its bytes where they are. Returns NO when
    /// reading the attributes raised; the photometry then holds what was
    /// decided up to there.
    @objc(loadFrame:of:applyingVOILUT:)
    public func load(_ frame: NSData?, of dataset: DICOMAttributeSource,
                     applyingVOILUT voiLUT: ((UnsafeMutablePointer<UInt16>) -> Void)?) -> Bool {
        let length = frame?.length ?? 0
        return attempt {
            try photometry.read(from: dataset, frameLength: length, width: layout.width, height: layout.height,
                                keepsNuclearMedicinePolarity: keepsNuclearMedicinePolarity, file: file)
            var loader = FrameLoader(layout: layout, photometry: photometry, externalImage: externalImage)
            loader.overlays = overlays
            loader.voiLUT = voiLUT
            if photometry.bitsAllocated == 32 && !photometry.isRGB {
                loader.thirtyTwoBitWordsAreIntegers = dataset.attributeValue(withName: "PixelRepresentation") != nil
                    || thirtyTwoBitPixelsAreIntegers
            }
            image = loader.load(UnsafeRawBufferPointer(start: length > 0 ? frame?.bytes : nil, count: length))
            shortFrame = loader.shortFrame
            ranOutOfMemory = loader.ranOutOfMemory
            withExtendedLifetime(frame) {}
        }
    }

    // MARK: - what the frame decided

    /// The image's buffer: `externalImage`, or one allocated with `malloc` that
    /// the image owns. Nil when there was no memory for it.
    @objc public private(set) var image: UnsafeMutablePointer<Float>?
    @objc public var isRGB: Bool { photometry.isRGB }
    /// MONOCHROME1, shown inverted. Set it to the image's current polarity,
    /// which a frame whose reading raises before deciding it leaves as it was.
    @objc public var inverts: Bool {
        get { photometry.inverts }
        set { photometry.inverts = newValue }
    }
    @objc public var bitsAllocated: Int16 { photometry.bitsAllocated }
    @objc public private(set) var ranOutOfMemory = false
    private var shortFrame: ShortFrame?
    /// The bytes a short frame carried and needed; both zero when it was whole.
    @objc public var shortFrameCarried: Int { shortFrame?.carried ?? 0 }
    @objc public var shortFrameNeeded: Int { shortFrame?.needed ?? 0 }
    @objc public var raisedException: NSException? { raised?.exception }

    /// The empty picture of an object without Pixel Data, of the size it
    /// declares: the series' volume cleared - it holds whatever was written
    /// into it last, which was drawn as this object's picture - or a new
    /// buffer the image owns. Nil for a size that is none, or too large to be
    /// an image.
    @objc(emptyImageWidth:height:external:)
    public static func emptyImage(width: Int, height: Int, external: UnsafeMutablePointer<Float>?) -> UnsafeMutablePointer<Float>? {
        guard width > 0 && height > 0 && width &* height < 1024 * 1024 * 64 else { return nil }
        if let external {
            memset(external, 0, width &* height &* MemoryLayout<Float>.size)
            return external
        }
        return calloc(width &* height, MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self)
    }

    private func attempt(_ body: () throws -> Void) -> Bool {
        do {
            try body()
            raised = nil
        } catch let exception as AttributeReadException {
            raised = exception
        } catch {
            raised = AttributeReadException(name: NSExceptionName.genericException.rawValue, reason: String(describing: error))
        }
        return raised == nil
    }
}

/// Where a frame lies along the normal of its image plane.
enum FramePosition {
    /// The Grid Frame Offset Vector value of `frame`, for an RT Dose object;
    /// nil for any other. A vector without the frame's value raises, as it
    /// always did; an object without the vector offsets it by zero.
    static func gridFrameOffset(of frame: Int, in dataset: DICOMAttributeSource) throws -> Double? {
        guard try ParsedValue.isEqual(dataset.attributeValue(withName: "Modality"), toString: "RTDOSE") else { return nil }
        let offsets = dataset.attributeArray(withName: "GridFrameOffsetVector")
        return try ParsedValue.double(try ParsedValue.element(frame, of: offsets.map { $0 as NSArray }))
    }
}
