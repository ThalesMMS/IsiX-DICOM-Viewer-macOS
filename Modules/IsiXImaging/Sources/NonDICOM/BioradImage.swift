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

/// A Bio-Rad PIC file (little-endian): a 76-byte header, the images, then notes
/// of 96 bytes whose text gives the spacing and a Z correction factor.
public struct BioradImage {
    public static let headerLength = 76
    public static let noteLength = 96

    public let width: Int
    public let height: Int
    public let imageCount: Int
    /// One byte a pixel (`byte_format` 1), else two.
    public let bytesPerPixel: Int

    public init(header file: NonDICOMFileBytes) {
        height = Int(Int16(bitPattern: file.uint16(at: 2)))
        width = Int(Int16(bitPattern: file.uint16(at: 0)))
        imageCount = Int(Int16(bitPattern: file.uint16(at: 4)))
        bytesPerPixel = Int16(bitPattern: file.uint16(at: 14)) != 1 ? 2 : 1
    }

    /// Frame `frame` of `width` x `height` pixels as 16-bit samples, unsigned
    /// as the format stores them.
    public func samples(_ file: NonDICOMFileBytes, frame: Int, width: Int, height: Int) -> [UInt16] {
        let count = Swift.max(width * height, 0)
        var shorts = [UInt16](repeating: 0, count: count)
        if bytesPerPixel == 2 {
            shorts.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: Self.headerLength + frame * (height * width * 2), count: count * 2) }
            for i in 0..<count { shorts[i] = UInt16(littleEndian: shorts[i]) }
        } else {
            var bytes = [UInt8](repeating: 0, count: count)
            bytes.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: Self.headerLength + frame * (height * width), count: count) }
            for i in 0..<count { shorts[i] = UInt16(bytes[i]) }
        }
        return shorts
    }

    /// What the notes set, each from the last note that gives it.
    public struct Notes {
        public var pixelSpacingX: Double?
        public var pixelSpacingY: Double?
        public var sliceThickness: Float?
        public var zCorrection: Double = 1
        public var messages: [String] = []
        /// The note too short to name its axis the reading stopped at, if any.
        public var stopped: String?
    }

    /// The notes after the images (`imageCount` of `width` x `height`), read as
    /// fread read them up to the end of the file: a note shorter than 96 bytes
    /// keeps the rest of the one before. Each note is read once.
    public func notes(_ file: NonDICOMFileBytes, width: Int, height: Int) -> Notes {
        var result = Notes()
        var offset = Self.headerLength + height * width * imageCount * bytesPerPixel
        var note = [UInt8](repeating: 0, count: Self.noteLength)
        let printable = CharacterSet(charactersIn: Unicode.Scalar(32)...Unicode.Scalar(127))
        var atEnd = false
        while !atEnd {
            let read = note.withUnsafeMutableBytes { file.read($0.baseAddress!, at: offset, count: Self.noteLength) }
            if read == 0 { break }  // past the last note: nothing new to read
            offset += read
            if read < Self.noteLength { atEnd = true }
            // The text: bytes 16 on, cut at 79.
            var text = Array(note[16..<Self.noteLength])
            text[79] = 0
            let end = text.firstIndex(of: 0) ?? text.count
            let noteText = NSString(bytes: text, length: end, encoding: String.Encoding.isoLatin1.rawValue) as String? ?? ""
            let scanner = Scanner(string: noteText)
            guard let line = scanner.scanCharacters(from: printable) else { continue }
            if line.range(of: "AXIS_") != nil {
                // The axis is the sixth character: the reading stops at a shorter line.
                guard (line as NSString).length >= 6 else {
                    result.stopped = line
                    return result
                }
                let axis = (line as NSString).substring(with: NSRange(location: 5, length: 1))
                let items = line.components(separatedBy: " ")
                let spacing = items.count >= 5 ? items[3] : ""
                switch (axis as NSString).intValue {
                case 2: result.pixelSpacingX = (spacing as NSString).doubleValue
                case 3: result.pixelSpacingY = (spacing as NSString).doubleValue
                case 4: result.sliceThickness = (spacing as NSString).floatValue
                default: break
                }
            } else if line.range(of: "Z_CORRECT_FACTOR") != nil {
                let items = line.components(separatedBy: " ")
                if items.count >= 3 {
                    result.zCorrection = Double((items[2] as NSString).floatValue)
                    result.messages.append(String(format: "Set zCorrection factor = %f", result.zCorrection))
                } else {
                    result.messages.append("LoadBioradPic: Error setting zCorrection factor - insufficient fields")
                }
            }
        }
        return result
    }
}
