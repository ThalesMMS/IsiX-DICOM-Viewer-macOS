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

/// What the loader needs from a plugin's executable, read from its Mach-O
/// headers without loading it: the architectures it carries and, for each,
/// its file type, the libraries it links and the system it requires.
///
/// Reading the file is all this does. Nothing is mapped for execution, so a
/// bundle can be refused before any of its code runs.
public struct MachOImage: Sendable, Equatable {
    public enum FileType: Sendable, Equatable {
        case executable, dylib, bundle, other(UInt32)
    }

    public struct Slice: Sendable, Equatable {
        /// `arm64`, `arm64e`, `x86_64`, or `cpu <type>/<subtype>` for others.
        public var architecture: String
        public var fileType: FileType
        /// The install names of the libraries the slice links, in order.
        public var linkedLibraries: [String]
        /// The minimum macOS version of LC_BUILD_VERSION or
        /// LC_VERSION_MIN_MACOSX, if the slice names one.
        public var minimumSystem: OperatingSystemVersion?
        /// Whether the slice carries a code signature (LC_CODE_SIGNATURE), ad
        /// hoc or not. Whether it is valid is the signature check's business.
        public var hasCodeSignature = false

        public static func == (a: Slice, b: Slice) -> Bool {
            a.architecture == b.architecture && a.fileType == b.fileType && a.linkedLibraries == b.linkedLibraries &&
                a.minimumSystem.map(MachOImage.versionString) == b.minimumSystem.map(MachOImage.versionString) &&
                a.hasCodeSignature == b.hasCodeSignature
        }
    }

    public enum ReadError: Error, Sendable, Equatable {
        case unreadable
        case notMachO
        case truncated
    }

    public var slices: [Slice]

    public var architectures: [String] { slices.map(\.architecture) }

    public func slice(for architecture: String) -> Slice? {
        slices.first { $0.architecture == architecture }
    }

    /// The architecture the running process executes: an x86_64 host under
    /// Rosetta is x86_64.
    public static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public static func versionString(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public init(slices: [Slice]) {
        self.slices = slices
    }

    public init(contentsOf url: URL) throws(ReadError) {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw .unreadable
        }
        try self.init(data: data)
    }

    public init(data: Data) throws(ReadError) {
        let reader = Reader(data: data)
        guard let magic = reader.uint32(at: 0, bigEndian: true) else { throw .notMachO }
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let wide = magic == 0xCAFE_BABF
            guard let count = reader.uint32(at: 4, bigEndian: true), count > 0, count < 64 else { throw .notMachO }
            var slices: [Slice] = []
            let entrySize = wide ? 32 : 20
            for index in 0..<Int(count) {
                let entry = 8 + index * entrySize
                guard let offset = wide ? reader.uint64(at: entry + 8, bigEndian: true).map(Int.init)
                                        : reader.uint32(at: entry + 8, bigEndian: true).map(Int.init) else {
                    throw .truncated
                }
                slices.append(try Self.thinSlice(reader, at: offset))
            }
            self.slices = slices
        default:
            self.slices = [try Self.thinSlice(reader, at: 0)]
        }
    }

    private static let cpuArchABI64: UInt32 = 0x0100_0000

    static func architectureName(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        let subtype = cpuSubtype & 0x00FF_FFFF
        switch cpuType {
        case 7 | cpuArchABI64: return "x86_64"
        case 12 | cpuArchABI64: return subtype == 2 ? "arm64e" : "arm64"
        default: return "cpu \(cpuType)/\(subtype)"
        }
    }

    private static func thinSlice(_ reader: Reader, at base: Int) throws(ReadError) -> Slice {
        guard let magic = reader.uint32(at: base, bigEndian: false) else { throw .truncated }
        let headerSize: Int
        switch magic {
        case 0xFEED_FACF: headerSize = 32
        case 0xFEED_FACE: headerSize = 28
        default: throw .notMachO
        }
        guard let cpuType = reader.uint32(at: base + 4, bigEndian: false),
              let cpuSubtype = reader.uint32(at: base + 8, bigEndian: false),
              let fileType = reader.uint32(at: base + 12, bigEndian: false),
              let commandCount = reader.uint32(at: base + 16, bigEndian: false) else {
            throw .truncated
        }
        var slice = Slice(architecture: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype),
                          fileType: {
                              switch fileType {
                              case 2: return .executable
                              case 6: return .dylib
                              case 8: return .bundle
                              default: return .other(fileType)
                              }
                          }(),
                          linkedLibraries: [], minimumSystem: nil)
        var cursor = base + headerSize
        for _ in 0..<min(Int(commandCount), 4096) {
            guard let command = reader.uint32(at: cursor, bigEndian: false),
                  let size = reader.uint32(at: cursor + 4, bigEndian: false), size >= 8,
                  reader.contains(cursor, Int(size)) else {
                throw .truncated
            }
            switch command {
            case 0xC, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023:
                // LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
                // LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB.
                guard let nameOffset = reader.uint32(at: cursor + 8, bigEndian: false),
                      Int(nameOffset) < Int(size),
                      let name = reader.cString(at: cursor + Int(nameOffset), limit: Int(size) - Int(nameOffset)) else {
                    throw .truncated
                }
                slice.linkedLibraries.append(name)
            case 0x32:
                // LC_BUILD_VERSION: platform, minos. Platform 1 is macOS.
                if reader.uint32(at: cursor + 8, bigEndian: false) == 1,
                   let minos = reader.uint32(at: cursor + 12, bigEndian: false) {
                    slice.minimumSystem = decodeVersion(minos)
                }
            case 0x1D:
                // LC_CODE_SIGNATURE.
                slice.hasCodeSignature = true
            case 0x24:
                // LC_VERSION_MIN_MACOSX.
                if let version = reader.uint32(at: cursor + 8, bigEndian: false) {
                    slice.minimumSystem = decodeVersion(version)
                }
            default:
                break
            }
            cursor += Int(size)
        }
        return slice
    }

    /// xxxx.yy.zz in nibbles, as the load commands encode it.
    static func decodeVersion(_ value: UInt32) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: Int(value >> 16), minorVersion: Int((value >> 8) & 0xFF), patchVersion: Int(value & 0xFF))
    }

    private struct Reader {
        let data: Data

        func contains(_ offset: Int, _ length: Int) -> Bool {
            offset >= 0 && length >= 0 && offset + length <= data.count
        }

        func uint32(at offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            var value: UInt32 = 0
            for index in 0..<4 {
                let byte = UInt32(data[data.startIndex + offset + index])
                value |= bigEndian ? byte << (8 * (3 - index)) : byte << (8 * index)
            }
            return value
        }

        func uint64(at offset: Int, bigEndian: Bool) -> UInt64? {
            guard let first = uint32(at: offset, bigEndian: bigEndian),
                  let second = uint32(at: offset + 4, bigEndian: bigEndian) else { return nil }
            return bigEndian ? UInt64(first) << 32 | UInt64(second) : UInt64(second) << 32 | UInt64(first)
        }

        func cString(at offset: Int, limit: Int) -> String? {
            guard offset >= 0, limit > 0, offset < data.count else { return nil }
            let end = min(offset + limit, data.count)
            let bytes = data[(data.startIndex + offset)..<(data.startIndex + end)]
            let terminated = bytes.firstIndex(of: 0).map { bytes[..<$0] } ?? bytes
            return String(decoding: terminated, as: UTF8.self)
        }
    }
}
