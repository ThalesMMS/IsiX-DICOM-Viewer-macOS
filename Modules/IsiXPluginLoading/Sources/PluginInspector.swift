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

/// The identity and entry of a version 1 plugin, as its Info.plist declares them.
public struct PluginManifest: Sendable, Equatable {
    public var identifier: String
    public var name: String
    public var version: String
    public var apiVersion: Int
    public var principalClass: String
    public var executableName: String
    public var capabilities: [String]
    public var minimumSystemVersion: String?
}

/// Why a bundle is not loaded. Every one is found by reading files only.
public enum PluginDiagnostic: Sendable, Equatable {
    case notVersion1Bundle(pathExtension: String)
    /// A `.horosplugin` or `.osirixplugin`: the former plugin API, which this
    /// application no longer loads.
    case formerPluginAPI(pathExtension: String)
    case missingInfoPlist
    case invalidInfoPlist
    case legacyMetadata(keys: [String])
    case missingAPIVersion
    case invalidAPIVersion(found: String)
    case unsupportedAPIVersion(Int)
    case futureAPIVersion(Int, newestSupported: Int)
    case missingIdentifier
    case missingPrincipalClass
    case invalidPrincipalClass(String)
    case missingExecutable(String)
    case invalidCapabilities
    case unknownCapabilities([String])
    case requiresNewerSystem(required: String, running: String)
    case embedsKitCopy
    case unreadableExecutable
    case architectureMismatch(found: [String], required: String)
    case notLoadableExecutable
    case legacyDependency(frameworks: [String])
    case kitNotLinked
    /// Code for Apple silicon runs only signed, ad hoc at least.
    case unsignedExecutable(architecture: String)

    /// A sentence for the plugin manager and the log: what is wrong, and what
    /// the user can do about it.
    public var message: String {
        switch self {
        case .notVersion1Bundle(let pathExtension):
            return "Only .\(PluginContract.bundleExtension) bundles use the plugin API version 1; this one is .\(pathExtension)."
        case .formerPluginAPI(let pathExtension):
            return "This plugin (.\(pathExtension)) was made for Horos or OsiriX. Since version 6.0 this application loads only plugins built with \(PluginContract.kitFrameworkName) (.\(PluginContract.bundleExtension)); it did not open, move or change this one. Obtain a version 1 plugin from its author."
        case .missingInfoPlist:
            return "The bundle has no Contents/Info.plist. Reinstall a complete copy from its author."
        case .invalidInfoPlist:
            return "The bundle's Info.plist cannot be read. Reinstall a complete copy from its author."
        case .legacyMetadata(let keys):
            return "The bundle declares keys of the former plugin API (\(keys.joined(separator: ", "))). A former plugin is not made compatible by renaming it; obtain a version 1 plugin from its author."
        case .missingAPIVersion:
            return "The bundle does not declare \(PluginContract.apiVersionKey). Obtain a plugin built with IsiXPluginKit version 1."
        case .invalidAPIVersion(let found):
            return "\(PluginContract.apiVersionKey) must be an integer; the bundle declares \(found)."
        case .unsupportedAPIVersion(let version):
            return "\(PluginContract.apiVersionKey) \(version) is not a valid plugin API version."
        case .futureAPIVersion(let version, let newest):
            return "The plugin needs plugin API version \(version); this application supports up to version \(newest). Update the application or obtain a compatible plugin."
        case .missingIdentifier:
            return "The bundle has no CFBundleIdentifier."
        case .missingPrincipalClass:
            return "The bundle does not name its entry class in \(PluginContract.principalClassKey)."
        case .invalidPrincipalClass(let name):
            return "\(PluginContract.principalClassKey) \"\(name)\" is not a class name. Use ModuleName.ClassName."
        case .missingExecutable(let name):
            return name.isEmpty ? "The bundle has no CFBundleExecutable." : "The bundle's executable \(name) is missing."
        case .invalidCapabilities:
            return "\(PluginContract.capabilitiesKey) must be a list of strings."
        case .unknownCapabilities(let names):
            return "The plugin needs capabilities this application does not provide: \(names.joined(separator: ", ")). Update the application or obtain a compatible plugin."
        case .requiresNewerSystem(let required, let running):
            return "The plugin needs macOS \(required); this Mac runs \(running)."
        case .embedsKitCopy:
            return "The bundle carries its own copy of \(PluginContract.kitFrameworkName).framework. A plugin links the copy the application provides; rebuild it without embedding the framework."
        case .unreadableExecutable:
            return "The bundle's executable is not a readable Mach-O file."
        case .architectureMismatch(let found, let required):
            return "The plugin is built for \(found.isEmpty ? "no known architecture" : found.joined(separator: ", ")); this application runs as \(required). Obtain a plugin built for \(required)."
        case .notLoadableExecutable:
            return "The bundle's executable is an application, not a loadable bundle or library."
        case .legacyDependency(let frameworks):
            return "The plugin links frameworks of the former plugin API (\(frameworks.joined(separator: ", "))). Obtain a version 1 plugin from its author."
        case .kitNotLinked:
            return "The plugin does not link \(PluginContract.kitFrameworkName). Obtain a plugin built with IsiXPluginKit version 1."
        case .unsignedExecutable(let architecture):
            return "The plugin's \(architecture) code is not signed, and macOS runs code for Apple silicon only when it is signed. Sign the bundle, ad hoc at least (codesign --sign - <bundle>), or obtain a signed plugin from its author."
        }
    }
}

/// What reading a bundle found: its manifest when the Info.plist has one,
/// and every reason found not to load it.
public struct PluginInspection: Sendable, Equatable {
    public var bundleURL: URL
    public var manifest: PluginManifest?
    public var diagnostics: [PluginDiagnostic]

    public var isLoadable: Bool { diagnostics.isEmpty && manifest != nil }

    /// The diagnostics, one sentence each, for a single line of the plugin manager.
    public var summary: String { diagnostics.map(\.message).joined(separator: " ") }

    /// Whether the bundle is a plugin of the former API under the new extension.
    public var isRenamedLegacyPlugin: Bool {
        diagnostics.contains {
            switch $0 {
            case .legacyMetadata, .legacyDependency: return true
            default: return false
            }
        }
    }
}

/// Reads a `.isixplugin` bundle and decides whether the host may load it,
/// before any of its code runs: Info.plist metadata, the API version, the
/// entry class, the capabilities, the executable's architectures, the
/// libraries it links and the system it needs.
public struct PluginInspector: Sendable {
    public var supportedAPIVersions: ClosedRange<Int>
    public var hostArchitecture: String
    public var runningSystem: OperatingSystemVersion
    public var knownCapabilities: Set<String>

    public init(supportedAPIVersions: ClosedRange<Int> = PluginContract.supportedAPIVersions,
                hostArchitecture: String = MachOImage.hostArchitecture,
                runningSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                knownCapabilities: Set<String> = PluginContract.knownCapabilities) {
        self.supportedAPIVersions = supportedAPIVersions
        self.hostArchitecture = hostArchitecture
        self.runningSystem = runningSystem
        self.knownCapabilities = knownCapabilities
    }

    public func inspect(bundleAt bundleURL: URL) -> PluginInspection {
        var inspection = PluginInspection(bundleURL: bundleURL, manifest: nil, diagnostics: [])
        let pathExtension = bundleURL.pathExtension
        // A former plugin is told apart by its extension alone: nothing in it is read.
        if PluginAdmission.kind(of: bundleURL.path) == .formerAPI {
            inspection.diagnostics.append(.formerPluginAPI(pathExtension: pathExtension))
            return inspection
        }
        if pathExtension != PluginContract.bundleExtension {
            inspection.diagnostics.append(.notVersion1Bundle(pathExtension: pathExtension))
        }

        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let infoURL = contents.appendingPathComponent("Info.plist")
        guard let infoData = try? Data(contentsOf: infoURL) else {
            inspection.diagnostics.append(.missingInfoPlist)
            return inspection
        }
        guard let info = (try? PropertyListSerialization.propertyList(from: infoData, format: nil)) as? [String: Any] else {
            inspection.diagnostics.append(.invalidInfoPlist)
            return inspection
        }

        let legacyKeys = PluginContract.legacyInfoKeys.filter { info[$0] != nil }
        if !legacyKeys.isEmpty {
            inspection.diagnostics.append(.legacyMetadata(keys: legacyKeys))
        }

        let apiVersion = readAPIVersion(info[PluginContract.apiVersionKey], into: &inspection.diagnostics)

        let identifier = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        if identifier.isEmpty {
            inspection.diagnostics.append(.missingIdentifier)
        }

        let principalClass = (info[PluginContract.principalClassKey] as? String) ?? ""
        if principalClass.isEmpty {
            inspection.diagnostics.append(.missingPrincipalClass)
        } else if !Self.isClassName(principalClass) {
            inspection.diagnostics.append(.invalidPrincipalClass(principalClass))
        }

        var capabilities: [String] = []
        if let declared = info[PluginContract.capabilitiesKey] {
            if let list = declared as? [String] {
                capabilities = list
                let unknown = list.filter { !knownCapabilities.contains($0) }
                if !unknown.isEmpty {
                    inspection.diagnostics.append(.unknownCapabilities(unknown))
                }
            } else {
                inspection.diagnostics.append(.invalidCapabilities)
            }
        }

        let minimumSystemVersion = info["LSMinimumSystemVersion"] as? String
        if let required = minimumSystemVersion.flatMap(Self.parseVersion), Self.isNewer(required, than: runningSystem) {
            inspection.diagnostics.append(.requiresNewerSystem(required: MachOImage.versionString(required),
                                                               running: MachOImage.versionString(runningSystem)))
        }

        let kitCopy = contents.appendingPathComponent("Frameworks/\(PluginContract.kitFrameworkName).framework")
        if FileManager.default.fileExists(atPath: kitCopy.path) {
            inspection.diagnostics.append(.embedsKitCopy)
        }

        let executableName = (info["CFBundleExecutable"] as? String) ?? ""
        let executableURL = contents.appendingPathComponent("MacOS", isDirectory: true).appendingPathComponent(executableName)
        if executableName.isEmpty || !FileManager.default.fileExists(atPath: executableURL.path) {
            inspection.diagnostics.append(.missingExecutable(executableName))
        } else {
            inspectExecutable(at: executableURL, minimumSystemDeclared: minimumSystemVersion != nil, into: &inspection.diagnostics)
        }

        let name = (info["CFBundleName"] as? String) ?? bundleURL.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String) ?? ""
        inspection.manifest = PluginManifest(identifier: identifier, name: name, version: version,
                                             apiVersion: apiVersion ?? 0, principalClass: principalClass,
                                             executableName: executableName, capabilities: capabilities,
                                             minimumSystemVersion: minimumSystemVersion)
        return inspection
    }

    private func readAPIVersion(_ value: Any?, into diagnostics: inout [PluginDiagnostic]) -> Int? {
        guard let value else {
            diagnostics.append(.missingAPIVersion)
            return nil
        }
        // An integer, not a string, a boolean or a fraction.
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else {
            diagnostics.append(.invalidAPIVersion(found: "\(value)"))
            return nil
        }
        let version = number.intValue
        if version <= 0 || version < supportedAPIVersions.lowerBound {
            diagnostics.append(.unsupportedAPIVersion(version))
        } else if version > supportedAPIVersions.upperBound {
            diagnostics.append(.futureAPIVersion(version, newestSupported: supportedAPIVersions.upperBound))
        }
        return version
    }

    private func inspectExecutable(at url: URL, minimumSystemDeclared: Bool, into diagnostics: inout [PluginDiagnostic]) {
        guard let image = try? MachOImage(contentsOf: url) else {
            diagnostics.append(.unreadableExecutable)
            return
        }
        guard let slice = image.slice(for: hostArchitecture) else {
            diagnostics.append(.architectureMismatch(found: image.architectures, required: hostArchitecture))
            return
        }
        switch slice.fileType {
        case .bundle, .dylib: break
        default: diagnostics.append(.notLoadableExecutable)
        }
        let legacy = PluginContract.legacyFrameworkNames.filter { name in
            slice.linkedLibraries.contains { $0.contains("/\(name).framework/") }
        }
        if !legacy.isEmpty {
            diagnostics.append(.legacyDependency(frameworks: legacy.map { $0 + ".framework" }))
        }
        let kit = "/\(PluginContract.kitFrameworkName).framework/"
        if !slice.linkedLibraries.contains(where: { $0.contains(kit) }) {
            diagnostics.append(.kitNotLinked)
        }
        // dyld refuses unsigned arm64 code with only "could not be loaded":
        // say why before trying. x86_64 code, on Intel or under Rosetta, may
        // run unsigned.
        if slice.architecture.hasPrefix("arm64"), !slice.hasCodeSignature {
            diagnostics.append(.unsignedExecutable(architecture: slice.architecture))
        }
        if !minimumSystemDeclared, let required = slice.minimumSystem, Self.isNewer(required, than: runningSystem) {
            diagnostics.append(.requiresNewerSystem(required: MachOImage.versionString(required),
                                                    running: MachOImage.versionString(runningSystem)))
        }
    }

    /// `Module.Class` or an Objective-C class name: identifiers joined by dots.
    static func isClassName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2 else { return false }
        return parts.allSatisfy { part in
            guard let first = part.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
            return part.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
        }
    }

    static func parseVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let numbers = parts.map { $0! } + Array(repeating: 0, count: 3 - parts.count)
        return OperatingSystemVersion(majorVersion: numbers[0], minorVersion: numbers[1], patchVersion: numbers[2])
    }

    static func isNewer(_ a: OperatingSystemVersion, than b: OperatingSystemVersion) -> Bool {
        (a.majorVersion, a.minorVersion, a.patchVersion) > (b.majorVersion, b.minorVersion, b.patchVersion)
    }
}
