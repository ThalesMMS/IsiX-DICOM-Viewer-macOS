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
@testable import IsiXStorage

@Suite struct PluginFolderScanTests {
    private static let formats = ["isixplugin", "horosplugin", "osirixplugin"]

    private func scan() -> PluginFolderScan {
        PluginFolderScan(isPlugin: { Self.formats.contains(($0 as NSString).pathExtension.lowercased()) })
    }

    /// An answer with the path of what the entry leads to in one spelling.
    private func real(_ entry: PluginFolderScan.Entry) -> PluginFolderScan.Entry {
        switch entry {
        case .load(let path): return .load(LinkFolder.real(path) ?? path)
        case .sameBundle(let resolved, let first): return .sameBundle(resolved: LinkFolder.real(resolved) ?? resolved, entry: first)
        case .notAPlugin(let destination): return .notAPlugin(destination: LinkFolder.real(destination))
        case .leadsNowhere: return entry
        }
    }

    /// One plugins folder with everything a user or an installer leaves in
    /// it: a bundle, links and aliases to it, and links and aliases to nothing.
    @Test(.timeLimit(.minutes(1))) func everyEntryOfAFolderIsAnsweredAndNoneStopsTheOthers() throws {
        let folder = try LinkFolder()
        let bundle = try folder.folder("Plugins/Real.osirixplugin")
        let gone = folder.path("Removed/Gone.osirixplugin")
        try folder.link("Plugins/Gone.osirixplugin", to: gone)
        try folder.link("Plugins/gone link", to: "../Removed/Gone.osirixplugin")
        try folder.link("Plugins/Other.horosplugin", to: bundle)
        try folder.alias("Plugins/Real.osirixplugin alias", to: bundle)
        try folder.link("Plugins/Real", to: "Real.osirixplugin")
        try folder.deadAlias("Plugins/Dead.osirixplugin")
        try folder.deadAlias("Plugins/dead alias")
        try folder.link("Plugins/LoopA.osirixplugin", to: "LoopB.osirixplugin")
        try folder.link("Plugins/LoopB.osirixplugin", to: "LoopA.osirixplugin")
        let documents = try folder.folder("Documents")
        try folder.link("Plugins/Documents.horosplugin", to: documents)
        try folder.file("Plugins/.DS_Store")
        try folder.file("Plugins/DoNotLoad.txt")
        try folder.folder("Plugins/.horos-plugin-previous")
        try folder.file("Plugins/Loose.horosplugin")

        var scan = scan()
        func judge(_ name: String) -> PluginFolderScan.Entry { scan.judge(entryAt: folder.path("Plugins/" + name)) }

        #expect(judge("Gone.osirixplugin") == .leadsNowhere(destination: gone))
        #expect(judge("gone link") == .leadsNowhere(destination: "../Removed/Gone.osirixplugin"))
        #expect(judge("Dead.osirixplugin") == .leadsNowhere(destination: nil))
        #expect(judge("dead alias") == .leadsNowhere(destination: nil))
        #expect(judge("LoopA.osirixplugin") == .leadsNowhere(destination: "LoopB.osirixplugin"))
        #expect(judge("LoopB.osirixplugin") == .leadsNowhere(destination: "LoopA.osirixplugin"))
        // The bundle, after all of those.
        #expect(real(judge("Real.osirixplugin")) == real(.load(bundle)))
        // A link under another plugin's name reaches the bundle already offered.
        #expect(real(judge("Other.horosplugin")) == real(.sameBundle(resolved: bundle, entry: folder.path("Plugins/Real.osirixplugin"))))
        // The name the Finder gives an alias, and a link with no extension:
        // neither is a plugin by its name, whatever it leads to.
        #expect(real(judge("Real.osirixplugin alias")) == real(.notAPlugin(destination: bundle)))
        #expect(real(judge("Real")) == real(.notAPlugin(destination: bundle)))
        // A plugin's name that leads to something that is not one.
        #expect(real(judge("Documents.horosplugin")) == real(.notAPlugin(destination: documents)))
        // The folder's own files are not followed anywhere.
        for name in [".DS_Store", "DoNotLoad.txt", ".horos-plugin-previous"] {
            #expect(real(judge(name)) == real(.notAPlugin(destination: nil)), "\(name)")
        }
        // A file with a plugin's name goes on to the loader, which says what it is.
        #expect(real(judge("Loose.horosplugin")) == real(.load(folder.path("Plugins/Loose.horosplugin"))))
        // Asked again, the bundle itself is one already offered.
        #expect(real(judge("Real.osirixplugin")) == real(.sameBundle(resolved: bundle, entry: folder.path("Plugins/Real.osirixplugin"))))
    }

    /// Whichever entry the folder lists first offers the bundle.
    @Test func theFirstEntryThatReachesABundleOffersIt() throws {
        let folder = try LinkFolder()
        let bundle = try folder.folder("Plugins/Real.osirixplugin")
        let link = try folder.link("Plugins/Again.osirixplugin", to: "Real.osirixplugin")
        var scan = scan()
        #expect(real(scan.judge(entryAt: link)) == real(.load(bundle)))
        #expect(real(scan.judge(entryAt: bundle)) == real(.sameBundle(resolved: bundle, entry: link)))
    }

    /// A link in the user's folder to the bundle in the computer's: the
    /// bundles offered are kept from one folder to the next.
    @Test func aBundleReachedFromTwoFoldersIsOfferedOnce() throws {
        let folder = try LinkFolder()
        let system = try folder.folder("System/Plugins/QA.osirixplugin")
        let other = try folder.folder("System/Plugins/Other.horosplugin")
        let user = try folder.link("User/Plugins/QA.osirixplugin", to: system)
        let alias = try folder.alias("User/Plugins/Other.horosplugin", to: other)
        var scan = scan()
        #expect(real(scan.judge(entryAt: user)) == real(.load(system)))
        #expect(real(scan.judge(entryAt: alias)) == real(.load(other)))
        #expect(real(scan.judge(entryAt: system)) == real(.sameBundle(resolved: system, entry: user)))
        #expect(real(scan.judge(entryAt: other)) == real(.sameBundle(resolved: other, entry: alias)))
        // Another scan, another discovery: nothing is remembered.
        var later = self.scan()
        #expect(real(later.judge(entryAt: system)) == real(.load(system)))
    }

    /// Two copies of one plugin are two bundles: only the same bundle is one.
    @Test func twoCopiesOfOnePluginAreTwoBundles() throws {
        let folder = try LinkFolder()
        let user = try folder.folder("User/Plugins/QA.osirixplugin")
        let copy = try folder.folder("Elsewhere/QA.osirixplugin")
        let system = try folder.link("System/Plugins/QA.osirixplugin", to: copy)
        var scan = scan()
        #expect(real(scan.judge(entryAt: user)) == real(.load(user)))
        #expect(real(scan.judge(entryAt: system)) == real(.load(copy)))
    }

    /// A link written in another case reaches the same bundle on a volume
    /// that ignores case, though its path is spelled differently.
    @Test func aLinkSpelledInAnotherCaseReachesTheSameBundle() throws {
        let folder = try LinkFolder()
        let bundle = try folder.folder("Plugins/Real.osirixplugin")
        let spelled = folder.path("Plugins/REAL.osirixplugin")
        guard FileManager.default.fileExists(atPath: spelled) else { return }
        let link = try folder.link("Plugins/Again.osirixplugin", to: spelled)
        var scan = scan()
        #expect(real(scan.judge(entryAt: bundle)) == real(.load(bundle)))
        #expect(real(scan.judge(entryAt: link)) == real(.sameBundle(resolved: spelled, entry: bundle)))
    }

    @Test func whereAnEntryLeads() throws {
        let folder = try LinkFolder()
        let bundle = try folder.folder("Plugins/Real.osirixplugin")
        #expect(LinkFolder.real(PluginFolderScan.destination(ofEntryAt: bundle)) == LinkFolder.real(bundle))
        #expect(!PluginFolderScan.isLinkOrAlias(bundle))
        let link = try folder.link("Plugins/Link.osirixplugin", to: "Real.osirixplugin")
        #expect(LinkFolder.real(PluginFolderScan.destination(ofEntryAt: link)) == LinkFolder.real(bundle))
        #expect(PluginFolderScan.isLinkOrAlias(link))
        #expect(PluginFolderScan.linkDestination(link) == "Real.osirixplugin")
        let alias = try folder.alias("Plugins/Alias.osirixplugin", to: bundle)
        #expect(LinkFolder.real(PluginFolderScan.destination(ofEntryAt: alias)) == LinkFolder.real(bundle))
        #expect(PluginFolderScan.isLinkOrAlias(alias))
        #expect(PluginFolderScan.linkDestination(alias) == nil)
        let dead = try folder.deadAlias("Plugins/Dead.osirixplugin")
        #expect(PluginFolderScan.destination(ofEntryAt: dead) == nil)
        // A link to an alias whose original is gone leads nowhere either.
        let throughDead = try folder.link("Plugins/Through.osirixplugin", to: "Dead.osirixplugin")
        #expect(PluginFolderScan.destination(ofEntryAt: throughDead) == nil)
        // A path to nothing at all is answered as it is: the loader says it is missing.
        #expect(PluginFolderScan.destination(ofEntryAt: folder.path("Plugins/Missing.osirixplugin")) == folder.path("Plugins/Missing.osirixplugin"))
        // One form for the paths the plugins list and the discovery write.
        #expect(PluginFolderScan.canonical(link) == PluginFolderScan.canonical(bundle))
    }
}
