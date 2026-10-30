/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXImaging

/// What the import reads of an Analyze 7.5 header (348 bytes, beside its
/// `.img`): the sizes, the dataset name and the experiment date, in the
/// header's byte order (the other one when `dim[0]` is not 0...15).
public struct AnalyzeImportHeader {
    /// The image's base header, as the viewer reads it.
    public let header: AnalyzeHeader
    /// `dim[1]`, `dim[2]` and `dim[3]`, as the import keeps them: the import
    /// takes `dim[1]` for the height and `dim[2]` for the width.
    public let height: Int
    public let width: Int
    public let frames: Int
    /// The bytes of `db_name` and `exp_date`, read as C strings: up to the
    /// first NUL, which may lie past the field.
    public let databaseName: [UInt8]
    public let experimentDate: [UInt8]
    /// The bytes of image data the header asks of its `.img`: `dim[3]` frames
    /// (at least one) of `dim[1]` x `dim[2]` voxels at the width of the
    /// datatype; -1 when there are no columns or no rows, 0 for a datatype the
    /// viewer does not read. The header was all the import looked at, so an
    /// `.img` cut short - an interrupted copy - became a series whose frames
    /// were read past the end of the file.
    public let imageBytes: Int64

    public init?(_ data: Data) {
        guard let header = AnalyzeHeader(data) else { return nil }
        self.header = header
        let file = NonDICOMFileBytes(data)
        let short = { (offset: Int) in Int16(bitPattern: file.uint16(at: offset)) }
        let swaps = header.swapsBytes
        // A long of a short, or of the unsigned short Endian16_Swap answers.
        let dimension = { (offset: Int) in swaps ? Int(UInt16(bitPattern: short(offset)).byteSwapped) : Int(short(offset)) }
        height = dimension(42)
        width = dimension(44)
        frames = dimension(46)

        // The size check kept each field in a short, swapped or not.
        let signed = { (offset: Int) in swaps ? Int16(bitPattern: UInt16(bitPattern: short(offset)).byteSwapped) : short(offset) }
        let columns = signed(42), rows = signed(44), depth = signed(46), datatype = signed(70)
        if columns <= 0 || rows <= 0 {
            imageBytes = -1
        } else {
            let bytesPerVoxel: Int64
            switch datatype {
            case 2: bytesPerVoxel = 1
            case 4: bytesPerVoxel = 2
            case 8, 16: bytesPerVoxel = 4
            case 64: bytesPerVoxel = 8
            default: bytesPerVoxel = 0
            }
            imageBytes = Int64(columns) * Int64(rows) * Int64(depth > 0 ? depth : 1) * bytesPerVoxel
        }

        func cString(at offset: Int) -> [UInt8] {
            data.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                var end = offset
                while end < bytes.count && bytes[end] != 0 { end += 1 }
                return Array(bytes[offset..<end])
            }
        }
        databaseName = cString(at: 14)
        experimentDate = cString(at: 293)
    }
}

/// What the import reads of a Bio-Rad PIC header (76 bytes, little-endian).
public struct BioradImportHeader {
    public let width: Int
    public let height: Int
    /// `npic`, unsigned as NSSwapLittleShortToHost answers it.
    public let frames: Int

    /// `header` is what the file holds of its first 76 bytes; what is missing reads 0.
    public init(_ header: Data) {
        let file = NonDICOMFileBytes(header.prefix(BioradImage.headerLength))
        let image = BioradImage(header: file)
        width = image.width
        height = image.height
        frames = Int(file.uint16(at: 4))
    }
}

/// What the import reads of a Zeiss LSM file: the size of the first image and,
/// from its CZ_LSMINFO block, the frames and channels.
public struct LSMImportHeader {
    public var width: Int?
    public var height: Int?
    /// Frames and series (channels), when the file has a CZ_LSMINFO block.
    public var frames: Int?
    public var series: Int?

    /// Reads `data` as the Objective-C read it with fread: a value past the end
    /// of the file is left as it was (zero here, where the C left it unset).
    public init(_ data: Data) {
        let file = NonDICOMFileBytes(data)
        var count: UInt16 = 0
        var lsmInfo: Int32 = 0
        // The tags of the first directory, at offset 8, in their order: the last
        // of a tag wins. The Objective-C read this directory twice; the second
        // reading took the same values.
        count = file.uint16(at: 8, fallback: count)
        var entry = [UInt8](repeating: 0, count: 12)
        for k in 0..<Int(count) {
            entry.withUnsafeMutableBytes { _ = file.read($0.baseAddress!, at: 10 + 12 * k, count: 12) }
            let tag = (Int32(entry[1]) << 8) | Int32(entry[0])
            let value = (Int32(entry[11]) << 24) | (Int32(entry[10]) << 16) | (Int32(entry[9]) << 8) | Int32(entry[8])
            switch tag {
            case 256: width = Int(value)
            case 257: height = Int(value)
            case 34412: lsmInfo = value
            default: break
            }
        }
        guard lsmInfo != 0 else { return }
        let info = Int(lsmInfo)
        let read = { (offset: Int) in Int32(bitPattern: file.uint32(at: offset)) }
        let dimensionZ = read(info + 16)
        let channels = read(info + 20)
        let timeStack = read(info + 24)
        let scanType = read(info + 64)
        switch scanType {
        case 3, 4: frames = Int(timeStack)
        default: frames = Int(dimensionZ &* timeStack)
        }
        series = Int(channels)
    }
}

/// The NIfTI-1 checks of the import.
public enum NIfTIImportRules {
    /// The bytes a NIfTI-1 header says its voxels need, counted as nifti1_io
    /// counts them before reading: every dimension up to `dim[0]`, one that is
    /// not positive past `dim[1]` taken as 1. 0 when the header describes no
    /// readable data, which nifti_image_read refuses too (`dim[0]` outside
    /// 1...7, `dim[1]` not positive, a datatype without a size).
    public static func voxelBytes(dimensions dim: [Int16], bytesPerVoxel: Int32) -> UInt64 {
        guard dim.count >= 8, bytesPerVoxel > 0, dim[0] >= 1, dim[0] <= 7, dim[1] > 0 else { return 0 }
        var voxels: UInt64 = 1
        for axis in 1...Int(dim[0]) {
            voxels = voxels &* UInt64(dim[axis] > 0 ? Int(dim[axis]) : 1)
        }
        return voxels &* UInt64(bytesPerVoxel)
    }

    /// Where nifti1_io reads the voxels from: `vox_offset`, but not before the
    /// 348 header bytes in a single `.nii` file, and not before the start of
    /// the `.img` of a pair.
    public static func voxelOffset(_ voxOffset: Float, singleFile: Bool) -> Int64 {
        // The C conversion of a float to a long long, as arm64 makes it: NaN
        // is 0 and a value out of range is the nearest end.
        let offset: Int64
        if voxOffset.isNaN {
            offset = 0
        } else if voxOffset >= 9.223372e18 {
            offset = .max
        } else if voxOffset <= -9.223372e18 {
            offset = .min
        } else {
            offset = Int64(voxOffset)
        }
        return singleFile ? max(offset, 348) : max(offset, 0)
    }
}

/// The series of an Olympus FluoView TIFF: one per position along its
/// dimensions other than X, Y and Z.
public enum FluoViewSeries {

    /// One dimension of the MM header: its name (the C string) and size.
    public struct Dimension {
        public let name: String
        public let size: Int
        public init(name: String, size: Int) {
            self.name = name
            self.size = size
        }
        var letter: UInt8 { name.utf8.first ?? 0 }
        var isPlanar: Bool { letter == UInt8(ascii: "X") || letter == UInt8(ascii: "Y") }
        var isSpatial: Bool { isPlanar || letter == UInt8(ascii: "Z") }
        /// The positions along the dimension. The header always lists ten
        /// dimensions, and FluoView writes those the acquisition did not use
        /// with a size of 0: such a dimension has the one position a size of 1
        /// has, instead of multiplying the series of the file down to none.
        public var steps: Int { max(size, 1) }
    }

    /// The frames (the steps of the Z dimension, 1 without one) and the series
    /// (the product of the steps of the dimensions other than X, Y and Z).
    public static func counts(_ dimensions: [Dimension]) -> (frames: Int, series: Int) {
        var frames = 1, series = 1
        for dimension in dimensions {
            if dimension.letter == UInt8(ascii: "Z") {
                frames = dimension.steps
            } else if !dimension.isPlanar {
                series = series &* dimension.steps
            }
        }
        return (frames, series)
    }

    /// The description of series `index`: "FV " and, from the last dimension
    /// to the first, the name and position of each of more than one step,
    /// separated by commas.
    public static func description(ofSeries index: Int, _ dimensions: [Dimension]) -> String {
        var position = Int32(truncatingIfNeeded: index)
        var description = "FV "
        var largest: Int32 = 1
        for dimension in dimensions where !dimension.isSpatial {
            largest = largest &* Int32(truncatingIfNeeded: dimension.steps)
        }
        for dimension in dimensions.reversed() where dimension.size > 1 && !dimension.isSpatial {
            if description != "FV " { description += ", " }
            largest /= Int32(truncatingIfNeeded: dimension.size)
            // A product that overflowed to 0 divides as arm64 divides: to 0.
            description += "\(dimension.name) \(largest == 0 ? 0 : position / largest)"
            if largest != 0 { position %= largest }
        }
        return description
    }
}
