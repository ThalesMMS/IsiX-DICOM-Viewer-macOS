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
import Testing
@testable import IsiXPluginLoading

/// A Mach-O header with the load commands the inspector reads, built byte by
/// byte: the tests need no compiler and no real plugin.
struct SyntheticMachO {
    var cpuType: UInt32 = 0x0100_000C   // arm64
    var cpuSubtype: UInt32 = 0
    var fileType: UInt32 = 8            // MH_BUNDLE
    var libraries: [String] = ["@rpath/IsiXPluginKit.framework/Versions/A/IsiXPluginKit", "/usr/lib/libSystem.B.dylib"]
    var minimumSystem: UInt32? = 0x000F_0000 // 15.0
    var signed = true

    static func x86_64() -> SyntheticMachO {
        var image = SyntheticMachO()
        image.cpuType = 0x0100_0007
        image.cpuSubtype = 3
        return image
    }

    func data() -> Data {
        var commands = Data()
        var count: UInt32 = 0
        for library in libraries {
            var name = Array(library.utf8) + [0]
            while (24 + name.count) % 8 != 0 { name.append(0) }
            commands.append(le(0xC)); commands.append(le(UInt32(24 + name.count)))
            commands.append(le(24)); commands.append(le(2)); commands.append(le(0x10000)); commands.append(le(0x10000))
            commands.append(contentsOf: name)
            count += 1
        }
        if let minimumSystem {
            commands.append(le(0x32)); commands.append(le(24))
            commands.append(le(1)); commands.append(le(minimumSystem)); commands.append(le(minimumSystem)); commands.append(le(0))
            count += 1
        }
        if signed {
            // LC_CODE_SIGNATURE: only its presence is read.
            commands.append(le(0x1D)); commands.append(le(16)); commands.append(le(0x8000)); commands.append(le(0x100))
            count += 1
        }
        var header = Data()
        for value in [0xFEED_FACF, cpuType, cpuSubtype, fileType, count, UInt32(commands.count), 0, 0] {
            header.append(le(value))
        }
        return header + commands
    }

    /// A universal file holding the given thin images.
    static func fat(_ images: [SyntheticMachO]) -> Data {
        let thin = images.map { $0.data() }
        var data = Data()
        data.append(be(0xCAFE_BABE)); data.append(be(UInt32(images.count)))
        var offset = UInt32(4096)
        for (image, bytes) in zip(images, thin) {
            data.append(be(image.cpuType)); data.append(be(image.cpuSubtype))
            data.append(be(offset)); data.append(be(UInt32(bytes.count))); data.append(be(12))
            offset += 4096
        }
        for bytes in thin {
            data.append(Data(count: 4096 - data.count % 4096))
            data.append(bytes)
        }
        return data
    }
}

private func le(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
private func be(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

/// A bundle in a temporary folder, removed when the test ends.
final class SyntheticBundle {
    let folder: URL
    let url: URL

    init(name: String = "Example.isixplugin", info: [String: Any]? = SyntheticBundle.validInfo(),
         executable: Data? = SyntheticMachO().data()) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("IsiXPluginLoadingTests-" + UUID().uuidString)
        url = folder.appendingPathComponent(name)
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        if let info {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        if let executable, let name = info?["CFBundleExecutable"] as? String {
            try executable.write(to: contents.appendingPathComponent("MacOS").appendingPathComponent(name))
        }
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    static func validInfo() -> [String: Any] {
        [
            "CFBundleIdentifier": "org.example.isix.example",
            "CFBundleName": "Example",
            "CFBundleExecutable": "Example",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0",
            "IsiXPluginAPIVersion": 1,
            "NSPrincipalClass": "Example.ExamplePlugin",
            "IsiXPluginCapabilities": ["viewer.read", "roi"],
        ]
    }
}

@Suite struct PluginInspectorTests {
    let inspector = PluginInspector(hostArchitecture: "arm64",
                                    runningSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0))

    func inspect(_ info: [String: Any]? = SyntheticBundle.validInfo(), name: String = "Example.isixplugin",
                 executable: Data? = SyntheticMachO().data()) throws -> PluginInspection {
        let bundle = try SyntheticBundle(name: name, info: info, executable: executable)
        return withExtendedLifetime(bundle) { inspector.inspect(bundleAt: bundle.url) }
    }

    func info(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var info = SyntheticBundle.validInfo()
        change(&info)
        return info
    }

    @Test func validBundleHasItsManifest() throws {
        let inspection = try inspect()
        #expect(inspection.diagnostics == [])
        #expect(inspection.isLoadable)
        #expect(inspection.manifest == PluginManifest(identifier: "org.example.isix.example", name: "Example", version: "1.0",
                                                      apiVersion: 1, principalClass: "Example.ExamplePlugin",
                                                      executableName: "Example", capabilities: ["viewer.read", "roi"],
                                                      minimumSystemVersion: nil))
    }

    @Test func missingOrUnreadableInfoPlist() throws {
        #expect(try inspect(nil).diagnostics == [.missingInfoPlist])
        let bundle = try SyntheticBundle()
        try Data("not a plist".utf8).write(to: bundle.url.appendingPathComponent("Contents/Info.plist"))
        #expect(inspector.inspect(bundleAt: bundle.url).diagnostics == [.invalidInfoPlist])
    }

    @Test func apiVersions() throws {
        #expect(try inspect(info { $0["IsiXPluginAPIVersion"] = nil }).diagnostics == [.missingAPIVersion])
        #expect(try inspect(info { $0["IsiXPluginAPIVersion"] = 0 }).diagnostics == [.unsupportedAPIVersion(0)])
        #expect(try inspect(info { $0["IsiXPluginAPIVersion"] = -1 }).diagnostics == [.unsupportedAPIVersion(-1)])
        #expect(try inspect(info { $0["IsiXPluginAPIVersion"] = 2 }).diagnostics == [.futureAPIVersion(2, newestSupported: 1)])
        #expect(try inspect(info { $0["IsiXPluginAPIVersion"] = "1" }).diagnostics == [.invalidAPIVersion(found: "1")])
        #expect(try inspect(info { $0["IsiXPluginAPIVersion"] = 1.5 }).diagnostics == [.invalidAPIVersion(found: "1.5")])
        #expect(try inspect(info { $0["IsiXPluginAPIVersion"] = true }).isLoadable == false)
        let newer = PluginInspector(supportedAPIVersions: 1...2, hostArchitecture: "arm64",
                                    runningSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        let bundle = try SyntheticBundle(info: info { $0["IsiXPluginAPIVersion"] = 2 })
        #expect(newer.inspect(bundleAt: bundle.url).isLoadable)
    }

    @Test func identityAndEntry() throws {
        #expect(try inspect(info { $0["CFBundleIdentifier"] = nil }).diagnostics == [.missingIdentifier])
        #expect(try inspect(info { $0["NSPrincipalClass"] = nil }).diagnostics == [.missingPrincipalClass])
        #expect(try inspect(info { $0["NSPrincipalClass"] = "My Plugin" }).diagnostics == [.invalidPrincipalClass("My Plugin")])
        #expect(try inspect(info { $0["NSPrincipalClass"] = "A.B.C" }).diagnostics == [.invalidPrincipalClass("A.B.C")])
        #expect(try inspect(info { $0["NSPrincipalClass"] = "$(PRODUCT_MODULE_NAME).P" }).diagnostics
                == [.invalidPrincipalClass("$(PRODUCT_MODULE_NAME).P")])
        #expect(try inspect(info { $0["NSPrincipalClass"] = "MyObjCPlugin" }).isLoadable)
        #expect(try inspect(executable: nil).diagnostics == [.missingExecutable("Example")])
        #expect(try inspect(info { $0["CFBundleExecutable"] = nil }).diagnostics == [.missingExecutable("")])
    }

    @Test func capabilities() throws {
        #expect(try inspect(info { $0["IsiXPluginCapabilities"] = nil }).manifest?.capabilities == [])
        #expect(try inspect(info { $0["IsiXPluginCapabilities"] = "roi" }).diagnostics == [.invalidCapabilities])
        #expect(try inspect(info { $0["IsiXPluginCapabilities"] = ["roi", "network.dicom"] }).diagnostics
                == [.unknownCapabilities(["network.dicom"])])
        // The database: reading, importing and changing what the user edits.
        let database = try inspect(info { $0["IsiXPluginCapabilities"] = ["database.read", "database.import", "database.write"] })
        #expect(database.isLoadable)
        #expect(database.manifest?.capabilities == ["database.read", "database.import", "database.write"])
        // The network: sending to and querying the configured nodes, and XML-RPC methods.
        let network = try inspect(info { $0["IsiXPluginCapabilities"] = ["network.send", "network.query", "xmlrpc"] })
        #expect(network.isLoadable)
        #expect(network.manifest?.capabilities == ["network.send", "network.query", "xmlrpc"])
    }

    @Test func architecture() throws {
        #expect(try inspect(executable: SyntheticMachO.x86_64().data()).diagnostics
                == [.architectureMismatch(found: ["x86_64"], required: "arm64")])
        #expect(try inspect(executable: SyntheticMachO.fat([.x86_64(), SyntheticMachO()])).isLoadable)
        var arm64e = SyntheticMachO()
        arm64e.cpuSubtype = 2
        #expect(try inspect(executable: arm64e.data()).diagnostics == [.architectureMismatch(found: ["arm64e"], required: "arm64")])
        let intelHost = PluginInspector(hostArchitecture: "x86_64",
                                        runningSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        let bundle = try SyntheticBundle(executable: SyntheticMachO.fat([.x86_64(), SyntheticMachO()]))
        #expect(intelHost.inspect(bundleAt: bundle.url).isLoadable)
        #expect(try inspect(executable: Data("#!/bin/sh\n".utf8)).diagnostics == [.unreadableExecutable])
        var application = SyntheticMachO()
        application.fileType = 2
        #expect(try inspect(executable: application.data()).diagnostics == [.notLoadableExecutable])
    }

    @Test func unsignedAppleSiliconCode() throws {
        var unsigned = SyntheticMachO()
        unsigned.signed = false
        let inspection = try inspect(executable: unsigned.data())
        #expect(inspection.diagnostics == [.unsignedExecutable(architecture: "arm64")])
        #expect(inspection.summary.contains("not signed"))
        // x86_64 code may run unsigned: only the slice the host runs counts.
        var unsignedIntel = SyntheticMachO.x86_64()
        unsignedIntel.signed = false
        let intelHost = PluginInspector(hostArchitecture: "x86_64",
                                        runningSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        let bundle = try SyntheticBundle(executable: SyntheticMachO.fat([unsignedIntel, SyntheticMachO()]))
        #expect(intelHost.inspect(bundleAt: bundle.url).isLoadable)
        #expect(try MachOImage(data: unsigned.data()).slices[0].hasCodeSignature == false)
        #expect(try MachOImage(data: SyntheticMachO().data()).slices[0].hasCodeSignature)
    }

    @Test func minimumSystem() throws {
        var newer = SyntheticMachO()
        newer.minimumSystem = 0x001A_0000 // 26.0
        #expect(try inspect(executable: newer.data()).diagnostics == [.requiresNewerSystem(required: "26.0.0", running: "15.4.0")])
        #expect(try inspect(info { $0["LSMinimumSystemVersion"] = "15.5" }).diagnostics
                == [.requiresNewerSystem(required: "15.5.0", running: "15.4.0")])
        #expect(try inspect(info { $0["LSMinimumSystemVersion"] = "15.0" }).isLoadable)
    }

    @Test func legacyPluginRenamed() throws {
        // A former plugin with only its extension changed: former keys, no
        // API version, a former SDK linked and not the kit.
        var legacy = SyntheticMachO()
        legacy.libraries = ["@executable_path/../Frameworks/Horos.framework/Versions/A/Horos", "/usr/lib/libSystem.B.dylib"]
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.legacy", "CFBundleExecutable": "Example",
            "NSPrincipalClass": "LegacyFilter", "pluginType": "imageFilter", "MenuTitles": ["Run"],
        ]
        let inspection = try inspect(info, executable: legacy.data())
        #expect(inspection.isRenamedLegacyPlugin)
        #expect(!inspection.isLoadable)
        #expect(inspection.diagnostics == [.legacyMetadata(keys: ["pluginType", "MenuTitles"]), .missingAPIVersion,
                                           .legacyDependency(frameworks: ["Horos.framework"]), .kitNotLinked])
        // Declaring the version is not enough either.
        var declared = info
        declared["IsiXPluginAPIVersion"] = 1
        #expect(try inspect(declared, executable: legacy.data()).isRenamedLegacyPlugin)
        // Nor is linking the kit while still linking a former SDK.
        var both = SyntheticMachO()
        both.libraries.append("@rpath/OsiriXAPI.framework/Versions/A/OsiriXAPI")
        #expect(try inspect(executable: both.data()).diagnostics == [.legacyDependency(frameworks: ["OsiriXAPI.framework"])])
        // A former plugin that resolved the host's symbols at run time links nothing of either SDK.
        var dynamicLookup = SyntheticMachO()
        dynamicLookup.libraries = ["/usr/lib/libSystem.B.dylib"]
        #expect(try inspect(executable: dynamicLookup.data()).diagnostics == [.kitNotLinked])
    }

    @Test func extensionAndEmbeddedKit() throws {
        #expect(try inspect(name: "Example.plugin").diagnostics == [.notVersion1Bundle(pathExtension: "plugin")])
        // A former plugin is refused by its extension, whatever it holds.
        #expect(try inspect(name: "Example.osirixplugin").diagnostics == [.formerPluginAPI(pathExtension: "osirixplugin")])
        #expect(try inspect(name: "Example.HorosPlugin").diagnostics == [.formerPluginAPI(pathExtension: "HorosPlugin")])
        let bundle = try SyntheticBundle()
        try FileManager.default.createDirectory(at: bundle.url.appendingPathComponent("Contents/Frameworks/IsiXPluginKit.framework"),
                                                withIntermediateDirectories: true)
        #expect(inspector.inspect(bundleAt: bundle.url).diagnostics == [.embedsKitCopy])
    }

    @Test func everyDiagnosticSaysSomething() {
        let all: [PluginDiagnostic] = [
            .notVersion1Bundle(pathExtension: "plugin"), .formerPluginAPI(pathExtension: "horosplugin"), .missingInfoPlist, .invalidInfoPlist, .legacyMetadata(keys: ["pluginType"]),
            .missingAPIVersion, .invalidAPIVersion(found: "x"), .unsupportedAPIVersion(0), .futureAPIVersion(2, newestSupported: 1),
            .missingIdentifier, .missingPrincipalClass, .invalidPrincipalClass("a b"), .missingExecutable(""), .missingExecutable("E"),
            .invalidCapabilities, .unknownCapabilities(["x"]), .requiresNewerSystem(required: "26.0.0", running: "15.0.0"),
            .embedsKitCopy, .unreadableExecutable, .architectureMismatch(found: [], required: "arm64"), .notLoadableExecutable,
            .legacyDependency(frameworks: ["Horos.framework"]), .kitNotLinked, .unsignedExecutable(architecture: "arm64"),
        ]
        #expect(Set(all.map(\.message)).count == all.count)
        #expect(all.allSatisfy { $0.message.hasSuffix(".") })
    }
}

@Suite struct MachOImageTests {
    @Test func thinAndUniversal() throws {
        let thin = try MachOImage(data: SyntheticMachO().data())
        #expect(thin.architectures == ["arm64"])
        #expect(thin.slices[0].fileType == .bundle)
        #expect(thin.slices[0].linkedLibraries == ["@rpath/IsiXPluginKit.framework/Versions/A/IsiXPluginKit", "/usr/lib/libSystem.B.dylib"])
        #expect(thin.slices[0].minimumSystem.map(MachOImage.versionString) == "15.0.0")
        let universal = try MachOImage(data: SyntheticMachO.fat([.x86_64(), SyntheticMachO()]))
        #expect(universal.architectures == ["x86_64", "arm64"])
    }

    @Test func refusesWhatIsNotMachO() {
        #expect(throws: MachOImage.ReadError.notMachO) { try MachOImage(data: Data("hello world!".utf8)) }
        #expect(throws: MachOImage.ReadError.notMachO) { try MachOImage(data: Data()) }
        var truncated = SyntheticMachO().data()
        truncated.removeLast(20)
        #expect(throws: MachOImage.ReadError.truncated) { try MachOImage(data: truncated) }
    }

    @Test func readsTheRunningExecutable() throws {
        let image = try MachOImage(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]))
        #expect(image.architectures.contains(MachOImage.hostArchitecture))
    }
}
