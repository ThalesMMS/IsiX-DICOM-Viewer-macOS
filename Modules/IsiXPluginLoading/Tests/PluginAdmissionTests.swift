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

@Suite struct PluginAdmissionTests {
    @Test func kindsByExtension() {
        #expect(PluginAdmission.kind(of: "/a/Example.isixplugin") == .version1)
        #expect(PluginAdmission.kind(of: "Example.IsiXPlugin") == .version1)
        #expect(PluginAdmission.kind(of: "/a/Old.horosplugin") == .formerAPI)
        #expect(PluginAdmission.kind(of: "/a/Old.OsiriXPlugin") == .formerAPI)
        #expect(PluginAdmission.kind(of: "/a/Old.plugin") == .other)
        #expect(PluginAdmission.kind(of: "/a/study.dcm") == .other)
        #expect(PluginAdmission.kind(of: "/a/isixplugin") == .other)
    }

    @Test func eachFormatHasItsLoader() {
        #expect(PluginAdmission.loader(for: "Example.isixplugin") == .version1)
        #expect(PluginAdmission.loader(for: "/a/Old.horosplugin") == .formerAPI)
        #expect(PluginAdmission.loader(for: "/a/Old.OsiriXPlugin") == .formerAPI)
        #expect(PluginAdmission.loader(for: "/a/Old.plugin") == nil)
        for name in ["Example.isixplugin", "Example.horosplugin", "Example.osirixplugin"] {
            #expect(PluginAdmission.isManaged(name))
            #expect(PluginAdmission.isPluginBundle(name))
        }
        #expect(!PluginAdmission.isManaged("Example"))
        #expect(!PluginAdmission.isPluginBundle("Example.zip"))
    }

    @Test func admissions() throws {
        let inspector = PluginInspector(hostArchitecture: "arm64",
                                        runningSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        let valid = try SyntheticBundle()
        #expect(withExtendedLifetime(valid) { PluginAdmission.refusal(forBundleAt: valid.url, inspector: inspector) } == nil)

        // A former plugin as it was built: its former keys, no API version, a
        // former SDK linked and not the kit. It goes to its own loader.
        var image = SyntheticMachO()
        image.libraries = ["@executable_path/../Frameworks/OsiriXAPI.framework/Versions/A/OsiriXAPI", "/usr/lib/libSystem.B.dylib"]
        let formerInfo: [String: Any] = ["CFBundleExecutable": "Example", "CFBundleIdentifier": "com.example.former",
                                         "NSPrincipalClass": "FormerFilter", "pluginType": "imageFilter", "MenuTitles": ["Run"]]
        for name in ["Old.horosplugin", "Old.osirixplugin"] {
            let former = try SyntheticBundle(name: name, info: formerInfo, executable: image.data())
            withExtendedLifetime(former) {
                #expect(PluginAdmission.refusal(forBundleAt: former.url, inspector: inspector) == nil)
                #expect(inspector.inspect(bundleAt: former.url).loader == .formerAPI)
                #expect(PluginAdmission.mayManage(bundleAt: former.url))
            }
        }

        // The same bundle renamed to .isixplugin goes to the version 1 loader,
        // which refuses it; it is not tried as a former plugin.
        let renamed = try SyntheticBundle(name: "Renamed.isixplugin", info: formerInfo, executable: image.data())
        withExtendedLifetime(renamed) {
            let refusal = PluginAdmission.refusal(forBundleAt: renamed.url, inspector: inspector)
            #expect(refusal?.loader == .version1)
            #expect(refusal?.isRenamedLegacyPlugin == true)
            #expect(refusal?.summary.contains(".horosplugin or .osirixplugin") == true)
            // It stays the user's to deactivate or delete.
            #expect(PluginAdmission.mayManage(bundleAt: renamed.url))
        }

        // Another architecture is refused in either format, with that reason.
        var intelFormer = SyntheticMachO.x86_64()
        intelFormer.libraries = ["/usr/lib/libSystem.B.dylib"]
        let intel = try SyntheticBundle(name: "Intel.horosplugin", info: formerInfo, executable: intelFormer.data())
        let intel1 = try SyntheticBundle(name: "Intel.isixplugin", executable: SyntheticMachO.x86_64().data())
        withExtendedLifetime([intel, intel1]) {
            #expect(PluginAdmission.refusal(forBundleAt: intel.url, inspector: inspector)?.diagnostics
                    == [.architectureMismatch(found: ["x86_64"], required: "arm64")])
            #expect(PluginAdmission.refusal(forBundleAt: intel1.url, inspector: inspector) != nil)
            #expect(PluginAdmission.mayManage(bundleAt: intel.url))
            #expect(PluginAdmission.mayManage(bundleAt: intel1.url))
        }
    }
}
