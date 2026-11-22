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
    /// The minimum system as the linkers before LC_BUILD_VERSION wrote it,
    /// in LC_VERSION_MIN_MACOSX.
    var versionMinimum: UInt32?
    var signed = true
    /// A 32-bit slice has the shorter header (MH_MAGIC, no reserved word).
    var is32Bit = false
    /// A PowerPC slice is written big-endian, header and load commands alike.
    var isBigEndian = false

    static func x86_64() -> SyntheticMachO {
        var image = SyntheticMachO()
        image.cpuType = 0x0100_0007
        image.cpuSubtype = 3
        return image
    }

    /// The 32-bit Intel slice a former OsiriX plugin carried beside x86_64.
    static func i386() -> SyntheticMachO {
        var image = SyntheticMachO()
        image.cpuType = 7
        image.cpuSubtype = 3
        image.is32Bit = true
        image.libraries = ["@executable_path/../Frameworks/OsiriXAPI.framework/Versions/A/OsiriXAPI", "/usr/lib/libSystem.B.dylib"]
        image.minimumSystem = nil
        image.versionMinimum = 0x000A_0500 // 10.5
        image.signed = false
        return image
    }

    /// The PowerPC slice of an older OsiriX plugin.
    static func ppc() -> SyntheticMachO {
        var image = i386()
        image.cpuType = 18
        image.cpuSubtype = 0
        image.isBigEndian = true
        return image
    }

    func data() -> Data {
        let word = isBigEndian ? be : le
        var commands = Data()
        var count: UInt32 = 0
        for library in libraries {
            var name = Array(library.utf8) + [0]
            while (24 + name.count) % 8 != 0 { name.append(0) }
            commands.append(word(0xC)); commands.append(word(UInt32(24 + name.count)))
            commands.append(word(24)); commands.append(word(2)); commands.append(word(0x10000)); commands.append(word(0x10000))
            commands.append(contentsOf: name)
            count += 1
        }
        if let minimumSystem {
            commands.append(word(0x32)); commands.append(word(24))
            commands.append(word(1)); commands.append(word(minimumSystem)); commands.append(word(minimumSystem)); commands.append(word(0))
            count += 1
        }
        if let versionMinimum {
            // LC_VERSION_MIN_MACOSX: version, sdk.
            commands.append(word(0x24)); commands.append(word(16)); commands.append(word(versionMinimum)); commands.append(word(versionMinimum))
            count += 1
        }
        if signed {
            // LC_CODE_SIGNATURE: only its presence is read.
            commands.append(word(0x1D)); commands.append(word(16)); commands.append(word(0x8000)); commands.append(word(0x100))
            count += 1
        }
        var header = Data()
        let fields: [UInt32] = [is32Bit ? 0xFEED_FACE : 0xFEED_FACF, cpuType, cpuSubtype, fileType, count, UInt32(commands.count), 0]
        for value in fields + (is32Bit ? [] : [0]) {
            header.append(word(value))
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
        // Commands in the Report menu: a capability so that an application
        // without that menu refuses the plugin before loading it.
        let report = try inspect(info { $0["IsiXPluginCapabilities"] = ["viewer.read", "report"] })
        #expect(report.isLoadable)
        #expect(report.manifest?.capabilities == ["viewer.read", "report"])
        // Several series in one viewer: a capability so that an application
        // without that call refuses the plugin before loading it.
        let fourD = try inspect(info { $0["IsiXPluginCapabilities"] = ["database.read", "viewer.read", "viewer.4d"] })
        #expect(fourD.isLoadable)
        #expect(fourD.manifest?.capabilities == ["database.read", "viewer.read", "viewer.4d"])
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

    @Test func formerPluginWithoutAppleSiliconCodeNamesItsArchitectures() throws {
        // A former OsiriX plugin: i386 and x86_64, or PowerPC and i386 for the
        // oldest, refused by the arm64 package with the names its author knows.
        let info: [String: Any] = ["CFBundleExecutable": "Former", "NSPrincipalClass": "FormerFilter"]
        let intel = try inspect(info, name: "Former.osirixplugin", executable: SyntheticMachO.fat([.i386(), .x86_64()]))
        #expect(intel.diagnostics == [.architectureMismatch(found: ["i386", "x86_64"], required: "arm64")])
        #expect(intel.summary == "The plugin is built for i386, x86_64; this application runs as arm64. Obtain a plugin built for arm64.")
        let powerPC = try inspect(info, name: "Former.osirixplugin", executable: SyntheticMachO.fat([.ppc(), .i386()]))
        #expect(powerPC.diagnostics == [.architectureMismatch(found: ["ppc", "i386"], required: "arm64")])
        #expect(powerPC.summary.contains("built for ppc, i386;"))
        #expect(!intel.summary.contains("cpu ") && !powerPC.summary.contains("cpu "))
    }

    @Test func threeWayFormerPluginLoadsItsIntelSlice() throws {
        // The universal build of an older OsiriX plugin, PowerPC, i386 and
        // x86_64: the PowerPC slice is read, not taken for an unreadable
        // file, so the x86_64 package loads the x86_64 slice as dyld does,
        // and the arm64 package names the three.
        var intel64 = SyntheticMachO.x86_64()
        intel64.libraries = SyntheticMachO.i386().libraries
        intel64.minimumSystem = nil
        intel64.versionMinimum = 0x000A_0600 // 10.6
        intel64.signed = false
        let info: [String: Any] = ["CFBundleExecutable": "Former", "NSPrincipalClass": "FormerFilter"]
        let bundle = try SyntheticBundle(name: "Former.osirixplugin", info: info,
                                         executable: SyntheticMachO.fat([.ppc(), .i386(), intel64]))
        let intelHost = PluginInspector(hostArchitecture: "x86_64",
                                        runningSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        let onIntel = intelHost.inspect(bundleAt: bundle.url)
        #expect(!onIntel.diagnostics.contains(.unreadableExecutable))
        #expect(onIntel.diagnostics == [])
        #expect(onIntel.isLoadable)
        #expect(inspector.inspect(bundleAt: bundle.url).diagnostics
                == [.architectureMismatch(found: ["ppc", "i386", "x86_64"], required: "arm64")])
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
        let bundle = try SyntheticBundle()
        try FileManager.default.createDirectory(at: bundle.url.appendingPathComponent("Contents/Frameworks/IsiXPluginKit.framework"),
                                                withIntermediateDirectories: true)
        #expect(inspector.inspect(bundleAt: bundle.url).diagnostics == [.embedsKitCopy])
    }

    @Test func formerPlugin() throws {
        // What the former loader needs: an Info.plist and an executable this
        // process loads. Former keys and frameworks, no API version, no kit
        // and no identifier are what such a plugin is.
        var image = SyntheticMachO()
        image.libraries = ["@executable_path/../Frameworks/Horos.framework/Versions/A/Horos", "/usr/lib/libSystem.B.dylib"]
        image.minimumSystem = nil
        let info: [String: Any] = ["CFBundleExecutable": "Former", "CFBundleVersion": "2.1",
                                   "pluginType": "roiTool", "MenuTitles": ["One", "Two"], "Requirements": ["Other"]]
        let inspection = try inspect(info, name: "Former.HorosPlugin", executable: image.data())
        #expect(inspection.diagnostics == [])
        #expect(inspection.isLoadable && inspection.loader == .formerAPI)
        #expect(inspection.manifest == PluginManifest(identifier: "", name: "Former", version: "2.1", apiVersion: 0,
                                                      principalClass: "", executableName: "Former", capabilities: [],
                                                      minimumSystemVersion: nil))
        // Without CFBundleExecutable, NSBundle looks for the bundle's name.
        let unnamed = try SyntheticBundle(name: "Unnamed.osirixplugin", info: ["NSPrincipalClass": "U"], executable: nil)
        try image.data().write(to: unnamed.url.appendingPathComponent("Contents/MacOS/Unnamed"))
        #expect(inspector.inspect(bundleAt: unnamed.url).isLoadable)

        // What stops its loader, before any of its code runs.
        #expect(try inspect(nil, name: "Former.horosplugin").diagnostics == [.missingInfoPlist])
        #expect(try inspect(info, name: "Former.horosplugin", executable: nil).diagnostics == [.missingExecutable("Former")])
        #expect(try inspect(info, name: "Former.horosplugin", executable: Data("text".utf8)).diagnostics == [.unreadableExecutable])
        var intel = SyntheticMachO.x86_64()
        intel.minimumSystem = nil
        #expect(try inspect(info, name: "Former.osirixplugin", executable: intel.data()).diagnostics
                == [.architectureMismatch(found: ["x86_64"], required: "arm64")])
        #expect(try inspect(info, name: "Former.osirixplugin", executable: SyntheticMachO.fat([intel, image])).isLoadable)
        var unsigned = image
        unsigned.signed = false
        #expect(try inspect(info, name: "Former.osirixplugin", executable: unsigned.data()).diagnostics
                == [.unsignedExecutable(architecture: "arm64")])
        var application = image
        application.fileType = 2
        #expect(try inspect(info, name: "Former.osirixplugin", executable: application.data()).diagnostics == [.notLoadableExecutable])
        var newer = info
        newer["LSMinimumSystemVersion"] = "27.0"
        #expect(try inspect(newer, name: "Former.osirixplugin", executable: image.data()).diagnostics
                == [.requiresNewerSystem(required: "27.0.0", running: "15.4.0")])
    }

    @Test func everyDiagnosticSaysSomething() {
        let all: [PluginDiagnostic] = [
            .notVersion1Bundle(pathExtension: "plugin"), .missingInfoPlist, .invalidInfoPlist, .legacyMetadata(keys: ["pluginType"]),
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

    @Test func architectureNames() {
        let abi64: UInt32 = 0x0100_0000
        let named: [(type: UInt32, subtype: UInt32, name: String)] = [
            (7, 3, "i386"), (7, 4, "i386"),
            (7 | abi64, 3, "x86_64"),
            (12 | abi64, 0, "arm64"), (12 | abi64, 2, "arm64e"),
            // The capability bits of the subtype (arm64e's pointer
            // authentication ABI) do not change the name.
            (12 | abi64, 0x8000_0002, "arm64e"),
            // A family keeps its name whatever processor model the subtype
            // names: i486, ARMv6/v7, ppc7400, ppc970.
            (12, 0, "arm"), (12, 5, "arm"), (12, 6, "arm"), (12, 9, "arm"), (12, 11, "arm"), (12, 12, "arm"),
            (18, 0, "ppc"), (18, 10, "ppc"), (18, 100, "ppc"), (18 | abi64, 0, "ppc64"),
        ]
        for (type, subtype, name) in named {
            #expect(MachOImage.architectureName(cpuType: type, cpuSubtype: subtype) == name, "cpu \(type)/\(subtype)")
        }
        // Only a processor without a name is told by its numbers.
        #expect(MachOImage.architectureName(cpuType: 99, cpuSubtype: 0x8000_0003) == "cpu 99/3")
        #expect(MachOImage.architectureName(cpuType: 13, cpuSubtype: 0) == "cpu 13/0")
    }

    @Test func formerArchitecturesAreRead() throws {
        // 32-bit headers, and a PowerPC slice in its own byte order.
        let intel = try MachOImage(data: SyntheticMachO.fat([.i386(), .x86_64()]))
        #expect(intel.architectures == ["i386", "x86_64"])
        #expect(intel.slices[0].linkedLibraries == SyntheticMachO.i386().libraries)
        #expect(intel.slices[0].fileType == .bundle)
        #expect(intel.slices[0].minimumSystem.map(MachOImage.versionString) == "10.5.0")
        let powerPC = try MachOImage(data: SyntheticMachO.ppc().data())
        #expect(powerPC.architectures == ["ppc"])
        #expect(powerPC.slices[0].fileType == .bundle)
        #expect(powerPC.slices[0].linkedLibraries == SyntheticMachO.ppc().libraries)
        // LC_VERSION_MIN_MACOSX, big-endian like the rest of the slice.
        #expect(powerPC.slices[0].minimumSystem.map(MachOImage.versionString) == "10.5.0")
        #expect(try MachOImage(data: SyntheticMachO.fat([.ppc(), .i386()])).architectures == ["ppc", "i386"])
        var ppc64 = SyntheticMachO.ppc()
        ppc64.cpuType = 18 | 0x0100_0000
        ppc64.is32Bit = false
        #expect(try MachOImage(data: ppc64.data()).architectures == ["ppc64"])
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
