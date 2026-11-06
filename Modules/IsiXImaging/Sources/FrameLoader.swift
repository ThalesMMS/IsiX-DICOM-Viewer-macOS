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

/// What an image declares about its frames' samples.
public struct FrameLayout: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// As the object declares it. The loading reads the photometry's, which
    /// PALETTE COLOR sets to 8.
    public var bitsAllocated: Int16
    public var bitsStored: Int16
    public var isSigned: Bool
    public var slope: Float
    public var offset: Float

    public init(width: Int, height: Int, bitsAllocated: Int16, bitsStored: Int16, isSigned: Bool, slope: Float, offset: Float) {
        self.width = width
        self.height = height
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.isSigned = isSigned
        self.slope = slope
        self.offset = offset
    }

    var pixelCount: Int { width &* height }
}

/// A frame that carried fewer bytes than its pixels need; the rest of the
/// image is black, and the image says why.
public struct ShortFrame: Equatable, Sendable {
    public let carried: Int
    public let needed: Int
}

/// The log lines of the frame loading, as they always read.
enum FrameLog {
    /// The file's name, as `[path lastPathComponent]` printed it.
    static func name(of file: String?) -> String {
        file.map { ($0 as NSString).lastPathComponent } ?? "(null)"
    }
}

/// Turns one decoded frame into the image's buffer: ARGB bytes for colour,
/// floating-point values after the modality LUT for grey, with the overlays
/// drawn in.
///
/// The image's buffer is the series' volume when the image is part of one
/// (`externalImage`), or one this allocates with `malloc` for the image to
/// own and free.
public struct FrameLoader {
    public var layout: FrameLayout
    public var photometry: FramePhotometry
    public var externalImage: UnsafeMutablePointer<Float>?
    /// Planes to draw into the pixels; empty when overlays are not shown.
    public var overlays: [OverlayBitmap] = []
    /// The words of a 32-bit frame are integers: Pixel Representation is
    /// present, or the preference says they always are.
    public var thirtyTwoBitWordsAreIntegers = false
    /// The VOI LUT step, given the 16-bit samples of a frame that carries all
    /// of them, before the modality LUT.
    public var voiLUT: ((UnsafeMutablePointer<UInt16>) -> Void)?

    public private(set) var shortFrame: ShortFrame?
    public private(set) var ranOutOfMemory = false

    public init(layout: FrameLayout, photometry: FramePhotometry, externalImage: UnsafeMutablePointer<Float>?) {
        self.layout = layout
        self.photometry = photometry
        self.externalImage = externalImage
    }

    /// Loads `frame` and returns the image's buffer: the external one, or a
    /// new one, or nil when there was no memory for it.
    public mutating func load(_ frame: UnsafeRawBufferPointer) -> UnsafeMutablePointer<Float>? {
        let bytes = FrameBytes(base: frame.baseAddress, count: frame.count)
        let scratch = FrameScratch()
        return photometry.isRGB ? loadColour(bytes) : loadGrey(bytes, scratch: scratch)
    }

    private mutating func report(_ carried: Int, of needed: Int) {
        if shortFrame == nil { shortFrame = ShortFrame(carried: carried, needed: needed) }
    }

    private func allocateImage() -> UnsafeMutablePointer<Float>? {
        if let externalImage { return externalImage }
        return malloc(layout.pixelCount &* MemoryLayout<Float>.size &+ 100)?.assumingMemoryBound(to: Float.self)
    }

    // MARK: - colour

    private mutating func loadColour(_ frame: FrameBytes) -> UnsafeMutablePointer<Float>? {
        let count = layout.pixelCount
        let image: UnsafeMutableRawPointer
        if let externalImage {
            image = UnsafeMutableRawPointer(externalImage)
        } else {
            guard let allocated = malloc(max(count &* 4, 1)) else {
                ranOutOfMemory = true
                return nil
            }
            image = allocated
        }
        var pixels = count
        // What a sample is stored in, which is not always what the object
        // declares: files exist that say Bits Allocated 16 and pack bytes,
        // and files that say 16 and mean it. Reading the wrong one gives
        // either a picture of noise or half a picture, and the length
        // settles it.
        if frame.count >= count &* 6 {
            if count > 0 { FrameSamples.argb(fromRGB16: frame.base!, into: image, count: count) }
        } else {
            if frame.count < count &* 3 {
                NSLog("************* [pixData length] < height*width*3")
                pixels = frame.count / 3
                report(frame.count, of: count &* 3)
            }
            if pixels > 0 { FrameSamples.argb(fromRGB: frame.base!, into: image, count: pixels) }
        }
        // A short frame - an empty one above all - leaves the rest black, not
        // whatever the memory held: that was drawn as a band of colour over
        // the sentence explaining that there is no frame.
        if pixels < count { memset(image + pixels &* 4, 0, (count &- pixels) &* 4) }

        if !overlays.isEmpty {
            OverlayBurnIn.burn(overlays, intoARGB: image, width: layout.width, height: layout.height)
        }
        return image.assumingMemoryBound(to: Float.self)
    }

    // MARK: - grey

    private mutating func loadGrey(_ frame: FrameBytes, scratch: FrameScratch) -> UnsafeMutablePointer<Float>? {
        let count = layout.pixelCount
        let bitsAllocated = photometry.bitsAllocated
        // The 16-bit samples the conversion reads, when they are not the frame's own bytes.
        var samples: UnsafeMutableRawPointer?

        if layout.isSigned && bitsAllocated != layout.bitsStored && bitsAllocated == 16
            && layout.bitsStored > 0 && layout.bitsStored < bitsAllocated {
            // A shift of 16 or more, or a negative one, is not a sign
            // extension of anything; the attribute reading clamps Bits
            // Stored so this cannot happen.
            guard let source = frame.prefix(count &* 2, alignment: 1, scratch: scratch),
                  let extended = scratch.uninitialized(count &* 2) else { return outOfMemory() }
            FrameSamples.signExtend(source, into: extended, count: count, bitsStored: Int(layout.bitsStored))
            samples = extended
        }

        if bitsAllocated == 8 {
            guard let widened = scratch.zeroed(count &* 2) else { return outOfMemory() }
            var carried = count
            if frame.count < count {
                NSLog("************* [pixData length] < height * width")
                report(frame.count, of: count)
                carried = frame.count
            }
            if carried > 0 { FrameSamples.widen(frame.base!, into: widened, count: carried) }
            samples = widened
        }

        if bitsAllocated == 32 { return loadThirtyTwoBits(frame) }

        if let voiLUT, frame.count >= count &* 2 {
            if samples == nil {
                guard let copy = scratch.uninitialized(count &* 2) else { return outOfMemory() }
                frame.copy(count &* 2, into: copy)
                samples = copy
            }
            voiLUT(samples!.assumingMemoryBound(to: UInt16.self))
        }

        guard let image = allocateImage() else { return outOfMemory() }

        if bitsAllocated == 16 && frame.count < count &* 2 {
            NSLog("************* [pixData length] < height * width")
            report(frame.count, of: count &* 2)
            if frame.count == count {
                NSLog("************* [[pixData length] == height*width : 8 bits? but declared as 16 bits...")
                FrameConversion.floats(fromBytes: samples.map { UnsafeRawPointer($0) } ?? frame.base!, count: count, into: image)
            } else {
                memset(image, 0, count &* MemoryLayout<Float>.size)
            }
        } else if count > 0 {
            let source: UnsafeRawPointer
            if let samples {
                source = UnsafeRawPointer(samples)
            } else {
                guard let aligned = frame.prefix(count &* 2, alignment: 2, scratch: scratch) else { return outOfMemory() }
                source = aligned
            }
            FrameConversion.floats(from16: source, signed: layout.isSigned, width: layout.width, height: layout.height,
                                   slope: layout.slope, offset: layout.offset, into: image)
        }

        burnGreyOverlays(into: image)
        return image
    }

    private mutating func loadThirtyTwoBits(_ frame: FrameBytes) -> UnsafeMutablePointer<Float>? {
        let count = layout.pixelCount
        guard let image = allocateImage() else { return outOfMemory() }
        frame.copy(count &* 4, into: image)
        if thirtyTwoBitWordsAreIntegers || layout.slope != 1 || layout.offset != 0 {
            FrameConversion.integersToFloats(image, count: count, signed: layout.isSigned, slope: layout.slope, offset: layout.offset)
        }
        burnGreyOverlays(into: image)
        return image
    }

    private func burnGreyOverlays(into image: UnsafeMutablePointer<Float>) {
        guard !overlays.isEmpty else { return }
        let value = OverlayBurnIn.greyValue(bitsStored: layout.bitsStored, slope: layout.slope, offset: layout.offset,
                                            inverts: photometry.inverts)
        OverlayBurnIn.burn(overlays, into: image, width: layout.width, height: layout.height, value: value)
    }

    private mutating func outOfMemory() -> UnsafeMutablePointer<Float>? {
        ranOutOfMemory = true
        return nil
    }
}
