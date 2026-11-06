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

/// A Zeiss LSM file: a little-endian TIFF whose directories alternate images
/// and thumbnails, read directly as DCMPix did (not through libtiff, which it
/// uses only for a compressed 8-bit image).
public enum LSMImage {
    /// One 12-byte entry of a directory: its tag and the 32-bit count and value.
    struct Entry {
        let tag: Int32
        let count: Int32
        let value: Int32
        let firstByte: Int32

        init(_ bytes: [UInt8]) {
            tag = (Int32(bytes[1]) << 8) | Int32(bytes[0])
            count = (Int32(bytes[7]) << 24) | (Int32(bytes[6]) << 16) | (Int32(bytes[5]) << 8) | Int32(bytes[4])
            value = (Int32(bytes[11]) << 24) | (Int32(bytes[10]) << 16) | (Int32(bytes[9]) << 8) | Int32(bytes[8])
            firstByte = Int32(bytes[8])
        }
    }

    /// Where the image of a frame and channel is, and what the first directory says.
    public struct Layout {
        /// Directories before the frame's (its index, for libtiff).
        public var directory = 0
        /// The file offset of the frame's pixels for the channel.
        public var imageOffset = 0
        /// The first directory's: width and height (in tag order), compression and CZ_LSMINFO offset.
        public var width: Int32?
        public var height: Int32?
        public var compression: Int32 = 0
        /// Whether the first directory has a compression tag (its value was logged).
        public var compressionTagged = false
        public var lsmInfo: Int32 = 0
        /// Why the file is not read further, if it is not.
        public var refusal: String?
    }

    /// The layout of frame `frame`, channel `channel`.
    public static func layout(_ file: NonDICOMFileBytes, frame: Int, channel: Int) -> Layout {
        var layout = Layout()
        var entry = [UInt8](repeating: 0, count: 12)
        func readEntry(at offset: Int) -> Entry {
            entry.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: offset, count: 12) }
            return Entry(entry)
        }

        // The directories, until the frame's: thumbnails (subfile type not 0) are not counted.
        var position: Int32 = 8
        var count16: UInt16 = 0
        var nextOffset: UInt32 = 0
        var channels: Int32 = 0, stripOffsets: Int32 = 0
        var goodFrames = 0
        var visited = 0
        repeat {
            count16 = file.uint16(at: Int(position), fallback: count16)
            let entries = Int(count16)
            var subfileType: Int32 = -1
            for k in 0..<entries {
                let e = readEntry(at: Int(position) + 2 + 12 * k)
                switch e.tag {
                case 254: subfileType = e.value
                case 273:
                    channels = e.count
                    stripOffsets = e.value
                default: break
                }
            }
            if subfileType == 0 {
                if goodFrames == frame {
                    if channels == 1 {
                        layout.imageOffset = Int(stripOffsets)
                    } else {
                        if channels > 1 && channel >= Int(channels) {
                            layout.refusal = String(format: "LoadLSM: zero indexed serieNo (%d) is greater than number of channels (%d)",
                                                    Int32(truncatingIfNeeded: channel), channels)
                            return layout
                        }
                        var offset: UInt32 = 0
                        for i in 0...Swift.max(channel, 0) {
                            offset = file.uint32(at: Int(stripOffsets) + 4 * i, fallback: offset)
                        }
                        layout.imageOffset = Int(Int32(bitPattern: offset))
                    }
                    layout.directory = visited
                    break
                }
                goodFrames += 1
            }
            nextOffset = file.uint32(at: Int(position) + 2 + 12 * entries, fallback: nextOffset)
            position = Int32(bitPattern: nextOffset)
            visited += 1
        } while position != 0
        layout.directory = visited

        // The first directory in detail.
        let firstEntries = Int(file.uint16(at: 8, fallback: count16))
        for k in 0..<firstEntries {
            let e = readEntry(at: 10 + 12 * k)
            switch e.tag {
            case 254:
                if e.value != 0 {
                    layout.refusal = "LoadLSM unable to handle files in which the first image directory entry is a thumbnail"
                    return layout
                }
            case 256: layout.width = e.value
            case 257: layout.height = e.value
            case 259:
                layout.compression = e.firstByte
                layout.compressionTagged = true
            case 34412: layout.lsmInfo = e.value
            default: break
            }
        }
        return layout
    }

    /// What CZ_LSMINFO gives: the datatype (1: 8 bits, 2: 16 bits, 5: float) and the voxel size in metres.
    public struct Info {
        public var datatype: Int32
        public var voxelX: Double
        public var voxelY: Double
        public var voxelZ: Double
    }

    public static func info(_ file: NonDICOMFileBytes, at offset: Int) -> Info {
        Info(datatype: Int32(bitPattern: file.uint32(at: offset + 28)),
             voxelX: file.double(at: offset + 40), voxelY: file.double(at: offset + 48), voxelZ: file.double(at: offset + 56))
    }

    /// `count` pixels from `offset`: bytes or little-endian shorts as 16-bit samples, or little-endian floats.
    public enum Pixels {
        case samples([Int16])
        case floats([Float])
    }

    public static func pixels(_ file: NonDICOMFileBytes, datatype: Int32, at offset: Int, count: Int) -> Pixels {
        let count = Swift.max(count, 0)
        switch datatype {
        case 2:
            var shorts = [Int16](repeating: 0, count: count)
            shorts.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: offset, count: count * 2) }
            return .samples(shorts.map { Int16(littleEndian: $0) })
        case 5:
            var floats = [UInt32](repeating: 0, count: count)
            floats.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: offset, count: count * 4) }
            return .floats(floats.map { Float(bitPattern: UInt32(littleEndian: $0)) })
        default:
            var bytes = [UInt8](repeating: 0, count: count)
            bytes.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: offset, count: count) }
            return .samples(bytes.map { Int16($0) })
        }
    }
}
