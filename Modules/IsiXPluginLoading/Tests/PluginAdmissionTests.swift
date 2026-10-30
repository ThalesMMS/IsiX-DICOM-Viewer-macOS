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

    @Test func onlyVersion1BundlesAreManaged() {
        #expect(PluginAdmission.isManaged("Example.isixplugin"))
        #expect(!PluginAdmission.isManaged("Example.horosplugin"))
        #expect(!PluginAdmission.isManaged("Example.osirixplugin"))
        #expect(!PluginAdmission.isManaged("Example"))
        #expect(PluginAdmission.isPluginBundle("Example.osirixplugin"))
        #expect(PluginAdmission.isPluginBundle("Example.isixplugin"))
        #expect(!PluginAdmission.isPluginBundle("Example.zip"))
    }

    @Test func refusals() throws {
        let inspector = PluginInspector(hostArchitecture: "arm64",
                                        runningSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        let valid = try SyntheticBundle()
        #expect(withExtendedLifetime(valid) { PluginAdmission.refusal(forBundleAt: valid.url, inspector: inspector) } == nil)

        // A former plugin, even one whose Info.plist and executable look like a
        // version 1 plugin's, is refused by its extension.
        let former = try SyntheticBundle(name: "Old.horosplugin")
        let refusal = withExtendedLifetime(former) { PluginAdmission.refusal(forBundleAt: former.url, inspector: inspector) }
        #expect(refusal?.diagnostics == [.formerPluginAPI(pathExtension: "horosplugin")])
        #expect(refusal?.summary.contains("Horos or OsiriX") == true)
        #expect(refusal?.manifest == nil)

        // A former plugin renamed to .isixplugin is refused by what it declares.
        var info = SyntheticBundle.validInfo()
        info["pluginType"] = "imageFilter"
        info.removeValue(forKey: "IsiXPluginAPIVersion")
        let renamed = try SyntheticBundle(name: "Renamed.isixplugin", info: info)
        let renamedRefusal = withExtendedLifetime(renamed) { PluginAdmission.refusal(forBundleAt: renamed.url, inspector: inspector) }
        #expect(renamedRefusal?.isRenamedLegacyPlugin == true)

        // Which bundles the plugin manager may move or delete.
        withExtendedLifetime([valid, former, renamed]) {
            #expect(PluginAdmission.mayManage(bundleAt: valid.url, inspector: inspector))
            #expect(!PluginAdmission.mayManage(bundleAt: former.url, inspector: inspector))
            #expect(!PluginAdmission.mayManage(bundleAt: renamed.url, inspector: inspector))
            #expect(PluginAdmission.isFormerPlugin(bundleAt: former.url, inspector: inspector))
            #expect(PluginAdmission.isFormerPlugin(bundleAt: renamed.url, inspector: inspector))
            #expect(!PluginAdmission.isFormerPlugin(bundleAt: valid.url, inspector: inspector))
        }
        // A version 1 bundle for another architecture is not a former plugin: the user may still remove it.
        let intel = try SyntheticBundle(name: "Intel.isixplugin", executable: SyntheticMachO.x86_64().data())
        withExtendedLifetime(intel) {
            #expect(PluginAdmission.refusal(forBundleAt: intel.url, inspector: inspector) != nil)
            #expect(PluginAdmission.mayManage(bundleAt: intel.url, inspector: inspector))
        }
    }
}
