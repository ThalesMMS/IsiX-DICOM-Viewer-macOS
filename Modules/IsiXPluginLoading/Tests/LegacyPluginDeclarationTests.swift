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

@Suite struct LegacyPluginDeclarationTests {
    typealias Declaration = LegacyPluginDeclaration

    @Test func rolesArePartsOfPluginType() {
        #expect(Declaration.Roles(pluginType: "imageFilter") == [.imageFilter])
        #expect(Declaration.Roles(pluginType: "imageFilter, Report") == [.imageFilter, .report])
        #expect(Declaration.Roles(pluginType: "Pre-Process") == [.preProcess])
        #expect(Declaration.Roles(pluginType: "fusionFilter") == [.fusionFilter])
        #expect(Declaration.Roles(pluginType: "Database") == [.database])
        #expect(Declaration.Roles(pluginType: "roiTool") == [.roiTool])
        #expect(Declaration.Roles(pluginType: "other") == [])
        // No pluginType names no role, and so does one that is not a string.
        #expect(Declaration(info: [:]).roles == [])
        #expect(Declaration(info: ["pluginType": 3]).roles == [])
    }

    @Test func menusAndCommandsByRole() {
        func declared(_ type: String?) -> Declaration { Declaration(info: type.map { ["pluginType": $0] } ?? [:]) }
        #expect(declared("imageFilter").menu == .imageFilters)
        #expect(declared("imageFilter").command == .viewer)
        #expect(declared("roiTool").menu == .roiTools)
        #expect(declared("fusionFilter").menu == .fusion)
        #expect(declared("fusionFilter").command == .fusion)
        #expect(declared("Database").menu == .database)
        #expect(declared("Database").command == .database)
        #expect(declared("Report").menu == .others)
        #expect(declared("Report").command == .database)
        #expect(declared(nil).menu == .others)
        #expect(declared(nil).command == .viewer)
        // The first role in the former order decides the menu.
        #expect(declared("roiTool imageFilter").menu == .imageFilters)
        #expect(Declaration.Command.fusion.selectorName == "endBlendingType:")
        #expect(Declaration.Command.database.selectorName == "executeFilterDB:")
        #expect(Declaration.Command.viewer.selectorName == "executeFilter:")
    }

    @Test func registrations() {
        let filter = Declaration(info: ["pluginType": "imageFilter", "MenuTitles": ["A", "(-", "B"], "ToolbarNames": ["T"]])
        #expect(filter.hasSubmenu)
        #expect(filter.registration(answersFilterImage: true) == .filter(titles: ["A", "B", "T"]))
        #expect(filter.registration(answersFilterImage: false) == .none)
        let single = Declaration(info: ["MenuTitles": "Only"])
        #expect(!single.hasSubmenu && single.menuTitles == ["Only"])
        #expect(Declaration(info: ["pluginType": "Pre-Process", "FileFormats": ["xyz"]]).registration(answersFilterImage: true) == .preProcess)
        #expect(Declaration(info: ["FileFormats": ["xyz", "abc"]]).registration(answersFilterImage: true) == .fileFormats(["xyz", "abc"]))
        #expect(Declaration(info: ["FileFormats": ["b": "xyz", "a": "abc"]]).registration(answersFilterImage: false) == .fileFormats(["abc", "xyz"]))
        #expect(Declaration(info: ["pluginType": "imageFilter, Report"]).isReport)
        #expect(Declaration(info: ["MenuTitles": 7]).menuTitles == nil)
    }

    @Test func requirementsLoadFirst() {
        func pending(_ name: String, _ requirements: [String] = []) -> Declaration.Pending {
            Declaration.Pending(path: "/p/\(name).horosplugin", name: name, requirements: requirements)
        }
        let (order, unmet) = Declaration.loadOrder([pending("A", ["C"]), pending("B"), pending("C"), pending("D", ["Missing"])])
        #expect(order.map(\.name) == ["C", "A", "B", "D"])
        #expect(unmet.count == 1 && unmet[0].plugin == "D" && unmet[0].requirement == "Missing")
        // A requirement already before its plugin stays where it is.
        #expect(Declaration.loadOrder([pending("C"), pending("A", ["C"])]).order.map(\.name) == ["C", "A"])
        // A chain: each plugin after the one it requires.
        #expect(Declaration.loadOrder([pending("A", ["B"]), pending("B", ["C"]), pending("C")]).order.map(\.name) == ["C", "B", "A"])
    }

    @Test func readsTheBundlesInfoPlist() throws {
        let bundle = try SyntheticBundle(name: "Former.horosplugin",
                                         info: ["CFBundleExecutable": "Former", "CFBundleName": "Former Name",
                                                "NSPrincipalClass": "FormerFilter", "pluginType": "Database", "Requirements": ["X"]])
        let declaration = try #require(withExtendedLifetime(bundle) { Declaration(bundleAt: bundle.url) })
        #expect(declaration.principalClass == "FormerFilter" && declaration.executableName == "Former")
        #expect(declaration.bundleName == "Former Name" && declaration.requirements == ["X"] && declaration.menu == .database)
        let empty = try SyntheticBundle(name: "Empty.horosplugin", info: nil)
        #expect(withExtendedLifetime(empty) { Declaration(bundleAt: empty.url) } == nil)
    }
}
