//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// Named architecture check for a product binary, helper, or plugin.
@objc(HorosArchitectureDecision)
public final class HorosArchitectureDecision: NSObject {
    @objc public let accepted: Bool
    @objc public let role: String
    @objc public let diagnosis: String
    @objc public let architectures: [String]

    @objc public init(accepted: Bool, role: String, diagnosis: String, architectures: [String]) {
        self.accepted = accepted
        self.role = role
        self.diagnosis = diagnosis
        self.architectures = architectures
    }
}

/// Publication policy of the two packages, one arm64 and one x86_64. Each
/// product binary carries only the slice of its package; a plugin or helper
/// must carry the slice of the running process. A foreign-only plugin is named
/// before NSBundle loads it; a foreign-only helper keeps its command but is not
/// launched (an Intel helper would need Rosetta in the arm64 package).
@objc(HorosArchitectureAudit)
public final class HorosArchitectureAudit: NSObject {
    /// The slice of the running process: the package it belongs to. Under
    /// Rosetta an x86_64 copy is x86_64 here, whatever the hardware.
    @objc public static let productArchitecture: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }()
    /// The slices published, each in its own package.
    @objc public static let supportedArchitectures = ["arm64", "x86_64"]
    private static let excludedSlices = ["i386", "ppc", "ppc64"]

    @objc(machOArchitecturesAtPath:)
    public static func machOArchitectures(at path: String) -> [String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count >= 8 else {
            return []
        }
        func u32(_ offset: Int, swap: Bool) -> UInt32 {
            guard offset + 4 <= data.count else { return 0 }
            var value: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: offset..<(offset + 4)) }
            return swap ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
        }
        let magic = u32(0, swap: false)
        let fat = magic == 0xCAFEBABE || magic == 0xBEBAFECA || magic == 0xCAFED00D || magic == 0x0DD0FECA
        if fat {
            let swapped = magic == 0xBEBAFECA || magic == 0x0DD0FECA
            let count = Int(u32(4, swap: swapped))
            var names: [String] = []
            var offset = 8
            let stride = magic == 0xCAFED00D || magic == 0x0DD0FECA ? 32 : 20
            for _ in 0..<count {
                if let name = cpuName(u32(offset, swap: swapped)), !names.contains(name) {
                    names.append(name)
                }
                offset += stride
            }
            return names
        }
        let swapped = magic == 0xCFFAEDFE || magic == 0xCEFAEDFE
        if let name = cpuName(u32(4, swap: swapped)) {
            return [name]
        }
        return []
    }

    @objc(machOArchitecturesInBundleAtPath:)
    public static func machOArchitectures(inBundleAt path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            let contents = url.appendingPathComponent("Contents")
            let info = (NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any]) ?? [:]
            let executable = (info["CFBundleExecutable"] as? String)
                ?? url.deletingPathExtension().lastPathComponent
            let binary = contents.appendingPathComponent("MacOS").appendingPathComponent(executable)
            let nested = machOArchitectures(at: binary.path)
            if !nested.isEmpty { return nested }
        }
        return machOArchitectures(at: path)
    }

    @objc(productDiagnosisAtPath:)
    public static func productDiagnosis(at path: String) -> HorosArchitectureDecision {
        productDiagnosis(at: path, process: productArchitecture)
    }

    static func productDiagnosis(at path: String, process: String) -> HorosArchitectureDecision {
        let architectures = machOArchitectures(inBundleAt: path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        if architectures.isEmpty {
            return HorosArchitectureDecision(accepted: false, role: "product",
                                            diagnosis: "\(name) is not a readable Mach-O",
                                            architectures: [])
        }
        let excluded = architectures.filter { excludedSlices.contains($0) }
        if !excluded.isEmpty {
            return HorosArchitectureDecision(
                accepted: false, role: "product",
                diagnosis: "\(name) contains unsupported slices (\(excluded.joined(separator: "/"))). IsiX DICOM Viewer is published as one arm64 package and one x86_64 package.",
                architectures: architectures)
        }
        if !architectures.contains(process) {
            return HorosArchitectureDecision(
                accepted: false, role: "product",
                diagnosis: "\(name) has no \(process) slice (\(architectures.joined(separator: "/"))).",
                architectures: architectures)
        }
        let others = architectures.filter { $0 != process }
        if !others.isEmpty {
            return HorosArchitectureDecision(
                accepted: false, role: "product",
                diagnosis: "\(name) also contains \(others.joined(separator: "/")) slices. Each IsiX DICOM Viewer package carries only its own slice (\(process)); do not ship a universal product.",
                architectures: architectures)
        }
        return HorosArchitectureDecision(accepted: true, role: "product",
                                        diagnosis: "\(process)-only",
                                        architectures: architectures)
    }

    @objc(pluginDiagnosisAtPath:)
    public static func pluginDiagnosis(at path: String) -> String? {
        pluginDiagnosis(at: path, process: productArchitecture)
    }

    static func pluginDiagnosis(at path: String, process: String) -> String? {
        let architectures = machOArchitectures(inBundleAt: path)
        if architectures.isEmpty { return nil }
        if architectures.contains(process) { return nil }
        return "This plugin is \(kind(of: architectures)) (\(architectures.joined(separator: "/"))) and cannot load in this \(process) IsiX DICOM Viewer process. Obtain an \(process) plugin from its author."
    }

    @objc(helperDiagnosisAtPath:)
    public static func helperDiagnosis(at path: String) -> String? {
        helperDiagnosis(at: path, process: productArchitecture)
    }

    static func helperDiagnosis(at path: String, process: String) -> String? {
        let architectures = machOArchitectures(at: path)
        if architectures.isEmpty { return nil }
        if architectures.contains(process) { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let abi = architectures.joined(separator: "/")
        let launch = process == "arm64" && architectures.contains(where: { intelSlices.contains($0) })
            ? "is not launched under Rosetta in" : "is not launched by"
        return "\(name) is \(kind(of: architectures)) (\(abi)) and \(launch) this \(process) IsiX DICOM Viewer process. Rebuild the helper for \(process); the command remains in the bundle."
    }

    private static let intelSlices = ["x86_64", "i386"]

    /// What the slices of a foreign-only binary are, in words a user knows.
    private static func kind(of architectures: [String]) -> String {
        if architectures.allSatisfy({ intelSlices.contains($0) }) { return "Intel-only" }
        if architectures.allSatisfy({ $0 == "arm64" || $0 == "arm" }) { return "Apple Silicon-only" }
        if architectures.allSatisfy({ $0 == "ppc" || $0 == "ppc64" }) { return "PowerPC-only" }
        return "built only for other architectures"
    }

    private static func cpuName(_ type: UInt32) -> String? {
        switch Int32(bitPattern: type) {
        case 7: return "i386"
        case 7 | Int32(bitPattern: 0x01000000): return "x86_64"
        case 12: return "arm"
        case 12 | Int32(bitPattern: 0x01000000): return "arm64"
        case 18: return "ppc"
        case 18 | Int32(bitPattern: 0x01000000): return "ppc64"
        default: return nil
        }
    }
}
