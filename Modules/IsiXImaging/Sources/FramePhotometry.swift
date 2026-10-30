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

/// How the samples of a frame are to be read and shown, from its Photometric
/// Interpretation (PS 3.3 C.7.6.3.1.2), the samples it carries and its modality.
public struct FramePhotometry: Equatable, Sendable {
    /// Three samples a pixel, read into ARGB.
    public var isRGB = false
    /// MONOCHROME1: the lowest value is white. This is presentation polarity
    /// only; the values themselves are not negated, which changed every ROI
    /// and plugin measurement when they were.
    public var inverts = false
    /// PALETTE COLOR arrives already looked up into three bytes a pixel.
    public var bitsAllocated: Int16
    /// The parser converts YBR to interleaved RGB, whatever the object declared.
    public var planarConfiguration: Int

    public init(bitsAllocated: Int16, planarConfiguration: Int) {
        self.bitsAllocated = bitsAllocated
        self.planarConfiguration = planarConfiguration
    }

    /// Reads the frame's photometry, in the order the Objective-C reading
    /// asked: what was decided before a value raised stays decided.
    ///
    /// - Parameters:
    ///   - frameLength: the bytes the decoded frame carries.
    ///   - keepsNuclearMedicinePolarity: the NM opacity table is in use, so a
    ///     MONOCHROME1 NM image keeps its polarity, as PET always does.
    public mutating func read(from dataset: DICOMAttributeSource, frameLength: Int, width: Int, height: Int,
                              keepsNuclearMedicinePolarity opacityTableNM: Bool, file: String?) throws {
        isRGB = false
        let colorspace = dataset.attributeValue(withName: "PhotometricInterpretation")
        let keepsPolarity = try ParsedValue.isEqual(dataset.attributeValue(withName: "Modality"), toString: "PT")
            || (opacityTableNM && (try ParsedValue.isEqual(dataset.attributeValue(withName: "Modality"), toString: "NM")))
        inverts = try ParsedValue.isEqual(colorspace, toString: "MONOCHROME1") && !keepsPolarity

        // Past isEqualToString: the value is a string or nil. A message to nil
        // answers NO, and a zero range, whose location is not NSNotFound: an
        // object without Photometric Interpretation was always taken for RGB
        // here, and only the sample check below brings it back to grey.
        let text = ParsedValue.object(colorspace) as? NSString
        func contains(_ part: String) -> Bool { text.map { $0.range(of: part).location != NSNotFound } ?? true }
        if text?.hasPrefix("YBR") == true { isRGB = true }
        if text?.hasPrefix("PALETTE") == true {
            bitsAllocated = 8
            isRGB = true
            NSLog("Palette depth conveted to 8 bit")
        }
        if contains("RGB") { isRGB = true }
        // The parser has already converted YBR to interleaved RGB.
        if contains("YBR") {
            planarConfiguration = 0
            isRGB = true
        }

        // A colour photometric interpretation on an object that carries one
        // sample per pixel is usually a header contradicting itself, and
        // reading three bytes where there is one turns a grey ultrasound into
        // the green and purple picture the reports describe.
        //
        // PALETTE COLOR is the exception, and the standard requires it: its
        // samples are indices, one per pixel, and the frame has already been
        // looked up into three bytes per pixel before it gets here. What
        // settles it is the frame: three samples per pixel are there, or they
        // are not.
        let samplesPerPixel = try ParsedValue.int(dataset.attributeValue(withName: "SamplesperPixel"))
        let frameCarriesThreeSamples = frameLength >= height &* width &* 3
        if isRGB && samplesPerPixel == 1 && !frameCarriesThreeSamples {
            NSLog("---- %@ says %@ and carries one sample per pixel; it is read as grey",
                  FrameLog.name(of: file), text ?? "(null)")
            isRGB = false
        }
    }
}
