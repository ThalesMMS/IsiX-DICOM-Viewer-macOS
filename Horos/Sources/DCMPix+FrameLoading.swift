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

import Cocoa
import IsiXDICOMDataset
import IsiXImaging

/// A frame of the Pixel Data into the image's buffer. Turning the frame a
/// decoder produced into the buffer - photometric interpretation, sign
/// extension, 8 to 16 bits, RGB to ARGB, the modality LUT, 32-bit integers,
/// overlays, short and empty frames - is FrameLoad, in the IsiXImaging module.
/// What stays here is what only the app has: the decoders, the VOI LUT, the
/// sentences explaining missing pixels, and the object's state.
extension DCMPix {

    final func frameLoad() -> FrameLoad {
        let load = FrameLoad()
        load.file = srcFile
        load.setSamples(width: horos_width, height: horos_height, bitsAllocated: horos_bitsAllocated, bitsStored: horos_bitsStored,
                        signed: horos_fIsSigned)
        load.setModalityLUT(slope: horos_slope, offset: horos_offset)
        load.planarConfiguration = horos_fPlanarConf
        load.inverts = horos_inverseVal
        load.externalImage = horos_fExternalOwnedImage
        load.keepsNuclearMedicinePolarity = UserDefaults.standard.bool(forKey: "OpacityTableNM")
        load.thirtyTwoBitPixelsAreIntegers = UserDefaults.standard.bool(forKey: "32bitDICOMAreAlwaysIntegers")
        if DCMPixSettings.displayDICOMOverlays {
            let arrays = horos_arrays
            for i in 0..<DCMPixArrays.overlays where arrays.overlayOn[i] {
                load.addOverlay(arrays.overlayData[i], rows: arrays.overlayRows[i], columns: arrays.overlayColumns[i],
                                originX: arrays.overlayOrigin[2 * i], originY: arrays.overlayOrigin[2 * i + 1])
            }
        }
        return load
    }

    /// The frame's bytes, from the decoder its transfer syntax needs.
    ///
    /// A frame without bytes is shown empty, and named. What was here once
    /// filled it with a ramp of 0..width-1 repeated on every row: a picture of
    /// bands, which is what the reports of "lines instead of the examination"
    /// describe, with nothing saying the pixels were missing.
    final func decodedFrame(_ imageNb: Int, of pixelAttr: DCMPixelDataAttribute?) -> NSData? {
        var pixData: NSData?
        var videoFailure: String?
        let syntax = pixelAttr?.transferSyntax?.transferSyntax
        let carriesAVideoStream = H264StreamDecoder.isVideo(transferSyntax: syntax)
        if carriesAVideoStream {
            pixData = videoFrame(imageNb, ofStreamIn: pixelAttr, reason: &videoFailure) as NSData?
        } else {
            pixData = pixelAttr?.decodeFrame(at: Int32(clamping: imageNb))
        }

        if (pixData?.length ?? 0) == 0 {
            missingPixelsReason = videoFailure ?? MissingPixelsReason.reasonForEmptyFrame(imageNb)
            NSLog("---- %@ frame %d carries no pixels; it is shown empty%@%@", ((srcFile ?? "") as NSString).lastPathComponent as NSString,
                  Int32(clamping: imageNb), (videoFailure != nil ? ": " : "") as NSString, (videoFailure ?? "") as NSString)
        }
        return pixData
    }

    /// One frame of an object that has Pixel Data. Where reading an attribute
    /// raised, what was decided up to there is kept, and the exception is answered.
    /// The frame number is the object's own: a 16-bit copy of it, as there
    /// once was, asked the decoder for frame -32 768 instead of 32 768.
    final func loadFrame(_ imageNb: Int, of dcmObject: DCMObject) -> NSException? {
        let load = frameLoad()
        let source = dcmObject.attributeSource

        if !load.readFrameOffset(imageNb, from: source) { return load.raisedException }
        if load.hasFrameOffset {
            horos_originZ += load.frameOffsetValue
            computeSliceLocation()
        }

        let pixData = decodedFrame(imageNb, of: dcmObject.attribute(withName: "PixelData") as? DCMPixelDataAttribute)

        var voiLUT: ((UnsafeMutablePointer<UInt16>) -> Void)?
        if DCMPixSettings.useVOILUT {
            voiLUT = { samples in self.applyVOILUT(from: dcmObject, to: samples) }
        }

        let loaded = load.load(pixData, of: source, applyingVOILUT: voiLUT)

        horos_isRGB = load.isRGB
        horos_inverseVal = load.inverts
        horos_bitsAllocated = load.bitsAllocated
        horos_fPlanarConf = load.planarConfiguration
        if !loaded { return load.raisedException }

        horos_fImage = load.image
        if load.ranOutOfMemory { N2LogStackTraceMessage("*** Not enough memory - malloc failed") }
        if load.shortFrameNeeded > 0 { reportShortFrame(load.shortFrameCarried, of: load.shortFrameNeeded) }

        horos_wl = 0
        horos_ww = 0    // Computed later, only if needed.
        if horos_savedWW != 0 {
            horos_wl = horos_savedWL
            horos_ww = horos_savedWW
        }
        return nil
    }

    /// An object with no Pixel Data element at all: a Hardcopy record or a
    /// structured document. It gets an empty frame of the size it declares,
    /// and a sentence saying why; nothing filled it once, which left whatever
    /// the view had drawn last on screen, under this object's annotations.
    final func loadAbsentPixelData() {
        missingPixelsReason = MissingPixelsReason.reasonForAbsentPixelData()
        NSLog("---- %@ carries no Pixel Data element; it is shown empty", ((srcFile ?? "") as NSString).lastPathComponent as NSString)
        if horos_fImage == nil {
            horos_fImage = FrameLoad.emptyImage(width: horos_width, height: horos_height, external: horos_fExternalOwnedImage)
        }
    }

    /// A frame shorter than the picture it has to fill leaves the rest black.
    /// Saying so on the image is the difference between an examination that is
    /// dark and a frame that arrived incomplete; only the log said it before.
    final func reportShortFrame(_ carried: Int, of needed: Int) {
        if carried < needed && missingPixelsReason == nil {
            missingPixelsReason = MissingPixelsReason.reasonForShortFrame(carried, of: needed)
        }
    }

    // MARK: - The VOI LUT

    /// The table the object carries instead of a window.
    ///
    /// PS 3.3 C.11.2: a VOI LUT Sequence is how the object says its values are
    /// meant to be shown, and Window Center and Width are the alternative. The
    /// table's input is the output of the modality LUT, so it is only applied
    /// where that is the identity; with a rescale in the way the index would be
    /// the wrong value, and a wrong picture is worse than an unwindowed one.
    final func applyVOILUT(from dcmObject: DCMObject, to samples: UnsafeMutablePointer<UInt16>?) {
        guard let samples, !horos_VOILUTApplied, horos_width > 0, horos_height > 0 else { return }
        guard horos_slope == 1.0 && horos_offset == 0.0 else { return }
        guard let sequence = dcmObject.attribute(withName: "VOILUTSequence") as? DCMSequenceAttribute,
              let item = sequence.sequence?.first as? DCMObject else { return }

        guard let lut = VOILookupTable(descriptor: item.attributeArray(withName: "LUTDescriptor") as? [NSNumber],
                                       data: item.attributeValue(withName: "LUTData"), signed: horos_fIsSigned) else {
            NSLog("---- %@ carries a VOI LUT this cannot read; its window is used instead",
                  ((srcFile ?? "") as NSString).lastPathComponent as NSString)
            return
        }

        if let old = horos_VOILUT_table { free(old) }
        horos_VOILUT_table = malloc(lut.entries * MemoryLayout<UInt32>.size)?.assumingMemoryBound(to: UInt32.self)
        guard let table = horos_VOILUT_table else { return }
        lut.table.copyBytes(to: UnsafeMutableRawBufferPointer(start: table, count: lut.entries * MemoryLayout<UInt32>.size))
        horos_VOILUT_first = Int32(truncatingIfNeeded: lut.firstMapped)
        horos_VOILUT_number = UInt32(truncatingIfNeeded: lut.entries)
        horos_VOILUT_depth = UInt32(truncatingIfNeeded: lut.depth)

        if VOILUTMapping.apply(first: Int(horos_VOILUT_first), number: Int(horos_VOILUT_number), table: table, to: samples,
                               count: horos_width * horos_height, signed: horos_fIsSigned) {
            horos_VOILUTApplied = true
            // The values are the table's output now, and the object's Window
            // Center and Width describe its input, so they no longer say
            // anything about what is on screen.
            horos_savedWL = Float(lut.windowCenter)
            horos_savedWW = Float(lut.windowWidth)
            horos_fIsSigned = false
        } else {
            DCMPixSettings.useVOILUT = false
            UserDefaults.standard.set(false, forKey: "UseVOILUT")
            NSLog("***** VOI LUT seems corrupted ! -> It will be turned OFF")
        }
    }

    // MARK: - Images carried whole

    /// Draws the image file a private transfer syntax wraps in the Pixel Data
    /// fragments, when the fragments are one image file of the object's size.
    final func loadImageFileWrapped(inPixelDataOf dcmObject: DCMObject) -> Bool {
        guard let pixelAttr = dcmObject.attribute(withName: "PixelData") as? DCMPixelDataAttribute,
              WrappedImageFragments.isPrivateTransferSyntax(pixelAttr.transferSyntax?.transferSyntax) else { return false }
        let fragments = (pixelAttr.values as? [Any] ?? []).compactMap { $0 as? Data }
        guard let image = WrappedImageFragments.image(
            fromFragments: fragments,
            width: Int(intValue(DICOMAttributeValues.numberValue(of: dcmObject.attributeSource, name: "Columns", file: srcFile))),
            height: Int(intValue(DICOMAttributeValues.numberValue(of: dcmObject.attributeSource, name: "Rows", file: srcFile))))
        else { return false }
        getData(from: image)
        return true
    }

    /// -intValue of a value the attribute guards answered: a number or a string.
    private func intValue(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }

    /// A frame of the video an instance carries whole.
    ///
    /// Transfer syntaxes 1.2.840.10008.1.2.4.100 and up put the entire stream in
    /// the Pixel Data element - one fragment for the lot, not one fragment per
    /// frame - so asking the framework for a frame of it hands back the
    /// compressed stream for every index. Nil, with a sentence for the viewer to
    /// draw over the empty frame, when the stream is of a codec this does not
    /// decode, cannot be decoded, or decodes to another size than the object states.
    final func videoFrame(_ index: Int, ofStreamIn pixelAttr: DCMPixelDataAttribute?, reason: inout String?) -> Data? {
        let syntax = pixelAttr?.transferSyntax?.transferSyntax
        guard H264StreamDecoder.handles(transferSyntax: syntax) else {
            reason = MissingPixelsReason.reasonForUndecodableVideoStream(syntax)
            return nil
        }
        // One decoder per file: the frames of a multi-frame object are loaded by
        // one DCMPix each, and a decoder built for a single frame would have no
        // reference pictures to decode a predicted one from.
        guard let decoder = H264StreamDecoder.cachedDecoder(forKey: srcFile ?? "", streamProvider: { pixelAttr?.encapsulatedStream() })
        else {
            reason = MissingPixelsReason.reasonForUndecodableVideoStream(syntax)
            return nil
        }
        if decoder.width != horos_width || decoder.height != horos_height {
            reason = MissingPixelsReason.reasonForVideoSizeMismatch(decoder.width, by: decoder.height,
                                                                     expectedWidth: horos_width, by: horos_height)
            return nil
        }
        let frame = decoder.rgbFrame(at: index)
        if frame == nil { reason = MissingPixelsReason.reasonForUndecodableVideoStream(syntax) }
        return frame
    }
}
