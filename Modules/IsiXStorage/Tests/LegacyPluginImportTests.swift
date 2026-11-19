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

@Suite struct LegacyPluginImportTests {
    private final class Folders {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var user: URL { root.appendingPathComponent("User/Library/Application Support") }
        var system: URL { root.appendingPathComponent("System/Library/Application Support") }
        var isix: URL { user.appendingPathComponent("IsiX") }
        var importer: LegacyPluginImport {
            LegacyPluginImport(userDomain: root.appendingPathComponent("User").path,
                               systemDomain: root.appendingPathComponent("System").path)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let formats = ["isixplugin", "horosplugin", "osirixplugin"]

    /// Whether a stand-in bundle is one this Mac can load: its executable
    /// does not say "foreign".
    @Sendable private static func loads(_ url: URL) -> Bool {
        let executable = url.appendingPathComponent("Contents/MacOS/\(url.deletingPathExtension().lastPathComponent)")
        return (try? String(contentsOf: executable, encoding: .utf8))?.hasPrefix("foreign") != true
    }

    /// Stand-ins for the rules of the plugin loader, which are another
    /// module's: the version is the "version=" line of the Info.plist these
    /// tests write, versions compare as numbers, a bundle whose executable
    /// says "foreign" is one this Mac cannot load and comes after one it can,
    /// and between equal versions the folder decides, then the format.
    private var rules: LegacyPluginImport.Rules { Self.rules(inspecting: Self.loads, canLoad: Self.loads) }

    /// The rules as the application makes them: `inspecting` is what the
    /// choice between two bundles of one name asks whether each one loads,
    /// of the bundle an entry leads to, and `canLoad` is the rule itself.
    private static func rules(inspecting: @escaping @Sendable (URL) -> Bool,
                              canLoad: @escaping @Sendable (URL) -> Bool) -> LegacyPluginImport.Rules {
        @Sendable func compare(_ first: String?, _ second: String?) -> ComparisonResult? {
            guard let a = first.flatMap(Double.init), let b = second.flatMap(Double.init) else { return nil }
            return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
        }
        return LegacyPluginImport.Rules(
            isPlugin: { Self.formats.contains(($0 as NSString).pathExtension.lowercased()) },
            version: { url in
                (try? String(contentsOf: url.appendingPathComponent("Contents/Info.plist"), encoding: .utf8))?
                    .split(separator: "\n").first { $0.hasPrefix("version=") }.map { String($0.dropFirst("version=".count)) }
            },
            compare: compare,
            isPreferred: { first, second in
                let firstLoads = inspecting(first.target ?? first.url), secondLoads = inspecting(second.target ?? second.url)
                if firstLoads != secondLoads { return firstLoads }
                if let order = compare(first.version, second.version), order != .orderedSame { return order == .orderedDescending }
                if first.rank != second.rank { return first.rank < second.rank }
                return (Self.formats.firstIndex(of: first.url.pathExtension.lowercased()) ?? 9)
                    < (Self.formats.firstIndex(of: second.url.pathExtension.lowercased()) ?? 9)
            },
            canLoad: canLoad)
    }

    /// A bundle whose Info.plist declares `version`, if any, and whose
    /// executable is `build`.
    private func makePlugin(_ url: URL, version: String?, build: String = "code") throws {
        try write((version.map { "version=\($0)\n" } ?? "") + "name=\(url.deletingPathExtension().lastPathComponent)",
                  to: url.appendingPathComponent("Contents/Info.plist"))
        try write(build, to: url.appendingPathComponent("Contents/MacOS/\(url.deletingPathExtension().lastPathComponent)"))
    }

    private func version(of url: URL) -> String? { rules.version(url) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    /// A Finder alias at `url` to the existing item at `target`.
    private func alias(_ url: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try URL.writeBookmarkData(try target.bookmarkData(options: .suitableForBookmarkFile), to: url)
    }

    private func link(_ url: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    private func isLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    @Test func asksOnlyWhenPluginsExistAndRemembersDecline() throws {
        let folders = Folders()
        try write("settings migration already finished", to: folders.isix.appendingPathComponent(".ImportFromHoros.json"))
        try write("loose file", to: folders.user.appendingPathComponent("Horos/Plugins/Loose.horosplugin"))
        _ = try folders.importer.offerIfNeeded(rules: rules) { _ in
            Issue.record("An empty plugin inventory prompted for a copy")
            return false
        }
        let plugin = folders.user.appendingPathComponent("OsiriX/Plugins/Choice.osirixplugin/Contents/Info.plist")
        try write("original", to: plugin)
        _ = try folders.importer.offerIfNeeded(rules: rules) { names in
            #expect(names == ["Choice.osirixplugin"])
            return false
        }
        _ = try folders.importer.offerIfNeeded(rules: rules) { _ in
            Issue.record("A previous decline prompted again")
            return true
        }
        #expect(!FileManager.default.fileExists(atPath: folders.isix.appendingPathComponent("Plugins").path))
        #expect(try String(contentsOf: plugin, encoding: .utf8) == "original")
    }

    @Test func copiesToMatchingActivationFoldersAndKeepsExistingNames() throws {
        let folders = Folders()
        let active = "Plugins/Active.horosplugin/Contents/Info.plist"
        let disabled = "Plugins Disabled/Disabled.osirixplugin/Contents/Info.plist"
        let original = folders.user.appendingPathComponent("Horos/" + active)
        try write("horos", to: original)
        try write("osirix", to: folders.system.appendingPathComponent("OsiriX/" + disabled))
        try write("newer", to: folders.isix.appendingPathComponent("Plugins Disabled/Same.isixplugin/Contents/Info.plist"))
        try write("older", to: folders.user.appendingPathComponent("OsiriX/Plugins/same.osirixplugin/Contents/Info.plist"))

        let problems = try folders.importer.offerIfNeeded(rules: rules) { names in
            #expect(names == ["Active.horosplugin", "same.osirixplugin", "Disabled.osirixplugin"])
            return true
        }
        #expect(problems == [.alreadyInstalled("same.osirixplugin")])
        #expect(try String(contentsOf: folders.isix.appendingPathComponent(active), encoding: .utf8) == "horos")
        #expect(try String(contentsOf: folders.isix.appendingPathComponent(disabled), encoding: .utf8) == "osirix")
        #expect(try String(contentsOf: original, encoding: .utf8) == "horos")
        #expect(!FileManager.default.fileExists(atPath: folders.isix.appendingPathComponent("Plugins/same.osirixplugin").path))
        _ = try folders.importer.offerIfNeeded(rules: rules) { _ in
            Issue.record("A completed copy prompted again")
            return false
        }
    }

    /// `Horos App/Plugins` in Application Support was read by earlier direct
    /// builds, so what is there is offered with the rest; a sandbox container
    /// is another build's and is never looked at.
    @Test func offersHorosAppPluginsButNotAContainer() throws {
        let folders = Folders()
        let original = folders.user.appendingPathComponent("Horos App/Plugins/Direct.horosplugin/Contents/Info.plist")
        try write("direct", to: original)
        try write("disabled", to: folders.user.appendingPathComponent("Horos App/Plugins Disabled/Off.horosplugin/Contents/Info.plist"))
        try write("sandbox", to: folders.root.appendingPathComponent(
            "User/Library/Containers/thalesmms.isis.Isis-DICOM-Viewer/Data/Library/Application Support/Horos App/Plugins/Sandboxed.horosplugin/Contents/Info.plist"))

        let problems = try folders.importer.offerIfNeeded(rules: rules) { names in
            #expect(names == ["Direct.horosplugin", "Off.horosplugin"])
            return true
        }
        #expect(problems.isEmpty)
        #expect(try String(contentsOf: folders.isix.appendingPathComponent("Plugins/Direct.horosplugin/Contents/Info.plist"), encoding: .utf8) == "direct")
        #expect(try String(contentsOf: folders.isix.appendingPathComponent("Plugins Disabled/Off.horosplugin/Contents/Info.plist"), encoding: .utf8) == "disabled")
        #expect(try String(contentsOf: original, encoding: .utf8) == "direct")
    }

    @Test func resumesOnlyTheSelectionAlreadyApproved() throws {
        struct SavedCandidate: Encodable {
            let source: URL
            let active: Bool
        }
        let folders = Folders()
        let relative = "Plugins/Pending.horosplugin"
        let source = folders.user.appendingPathComponent("Horos/" + relative)
        try write("complete", to: source.appendingPathComponent("Contents/Info.plist"))
        try write("appeared later", to: folders.user.appendingPathComponent("Horos/Plugins/Later.horosplugin/Contents/Info.plist"))
        let staging = folders.isix.appendingPathComponent(".ImportLegacyPlugins-staging")
        try write("partial", to: staging.appendingPathComponent("Pending.horosplugin/Contents/Info.plist"))
        let choice = folders.isix.appendingPathComponent(".ImportLegacyPlugins.json")
        try JSONEncoder().encode([SavedCandidate(source: source, active: true)]).write(to: choice)

        let problems = try folders.importer.offerIfNeeded(rules: rules) { _ in
            Issue.record("Resuming an approved selection prompted again")
            return false
        }
        #expect(problems.isEmpty)
        #expect(try String(contentsOf: folders.isix.appendingPathComponent(relative + "/Contents/Info.plist"), encoding: .utf8) == "complete")
        #expect(!FileManager.default.fileExists(atPath: folders.isix.appendingPathComponent("Plugins/Later.horosplugin").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    // MARK: one name, two versions

    /// Two installers of one author leave the older build as QA.horosplugin
    /// and the newer one as QA.osirixplugin: the single offer takes the newer.
    @Test func theSingleOfferTakesTheHigherVersionOfOneName() throws {
        let folders = Folders()
        try makePlugin(folders.user.appendingPathComponent("Horos/Plugins/QA.horosplugin"), version: "1.0", build: "old")
        try makePlugin(folders.user.appendingPathComponent("Horos/Plugins/QA.osirixplugin"), version: "2.0", build: "new")
        let problems = try folders.importer.offerIfNeeded(rules: rules) { names in
            #expect(names == ["QA.osirixplugin"])
            return true
        }
        #expect(problems.isEmpty)
        #expect(version(of: folders.isix.appendingPathComponent("Plugins/QA.osirixplugin")) == "2.0")
        #expect(!exists(folders.isix.appendingPathComponent("Plugins/QA.horosplugin")))
    }

    /// The same, with the newer build under the extension that sorts first.
    @Test func theExtensionDoesNotDecideWhichOneIsOffered() throws {
        let folders = Folders()
        try makePlugin(folders.user.appendingPathComponent("Horos/Plugins/QA.horosplugin"), version: "2.0")
        try makePlugin(folders.user.appendingPathComponent("OsiriX/Plugins/QA.osirixplugin"), version: "1.0")
        _ = try folders.importer.offerIfNeeded(rules: rules) { names in
            #expect(names == ["QA.horosplugin"])
            return false
        }
    }

    // MARK: asked for again

    private func describe(_ survey: LegacyPluginImport.Survey) -> [String] {
        survey.additions.map { addition in
            "add \(addition.source.name) \(addition.source.version ?? "-")"
                + (addition.replaces.map { " replacing \($0.name) \($0.version ?? "-")" } ?? "")
        } + survey.skipped.map { skipped in
            let reason: String
            switch skipped.reason {
            case .symbolicLink: reason = "link"
            case .alias: reason = "alias"
            case .leadsNowhere: reason = "leads nowhere"
            case .sameName(let preferred): reason = "same name as \(preferred.name) \(preferred.version ?? "-")"
            case .installedKept(let installed): reason = "IsiX keeps \(installed.name) \(installed.version ?? "-")"
            case .copyFailed(let why): reason = "failed: \(why)"
            }
            return "skip \(skipped.name) \(skipped.version ?? "-"): \(reason)"
        }
    }

    @Test func aSurveyFindsWhatIsNewOrNewerAndSaysWhatItLeavesOut() throws {
        let folders = Folders()
        let horos = folders.user.appendingPathComponent("Horos/Plugins")
        let isix = folders.isix.appendingPathComponent("Plugins")
        // Installed after the single offer.
        try makePlugin(horos.appendingPathComponent("New.horosplugin"), version: "1.0")
        // IsiX has the old build under the other extension.
        try makePlugin(isix.appendingPathComponent("QA.horosplugin"), version: "1.0", build: "old")
        try makePlugin(horos.appendingPathComponent("QA.osirixplugin"), version: "2.0", build: "new")
        // The installer put an older build back in the source folder.
        try makePlugin(isix.appendingPathComponent("Kept.osirixplugin"), version: "3.3")
        try makePlugin(horos.appendingPathComponent("Kept.osirixplugin"), version: "3.0")
        // Already there as it is: nothing to do and nothing to report.
        try makePlugin(isix.appendingPathComponent("Same.horosplugin"), version: "2.0")
        try makePlugin(horos.appendingPathComponent("Same.horosplugin"), version: "2.0")
        try makePlugin(folders.isix.appendingPathComponent("Plugins Disabled/Plain.horosplugin"), version: nil, build: "one build")
        try makePlugin(horos.appendingPathComponent("Plain.horosplugin"), version: nil, build: "one build")
        // No version on either side and not the same build: not replaced, and said.
        try makePlugin(isix.appendingPathComponent("Unknown.horosplugin"), version: nil, build: "one build")
        try makePlugin(horos.appendingPathComponent("Unknown.horosplugin"), version: nil, build: "another build")
        // Twice in the source folders, at two versions.
        try makePlugin(horos.appendingPathComponent("Twice.horosplugin"), version: "1.0", build: "old")
        try makePlugin(folders.system.appendingPathComponent("OsiriX/Plugins Disabled/Twice.osirixplugin"), version: "1.5", build: "new")
        // A link and an alias to a bundle of the source folders are that
        // bundle: nothing to add and nothing to report.
        try FileManager.default.createSymbolicLink(at: horos.appendingPathComponent("Linked.horosplugin"),
                                                   withDestinationURL: horos.appendingPathComponent("New.horosplugin"))
        try alias(horos.appendingPathComponent("Aliased.osirixplugin"), to: horos.appendingPathComponent("New.horosplugin"))
        // As an installer leaves it: the bundle in the folder of one
        // application, for every user, and a link to it in the other's.
        try makePlugin(folders.system.appendingPathComponent("OsiriX/Plugins/Shared.osirixplugin"), version: "5.0")
        try link(folders.system.appendingPathComponent("Horos/Plugins/Shared.osirixplugin"),
                 to: folders.system.appendingPathComponent("OsiriX/Plugins/Shared.osirixplugin"))
        // A bundle kept outside those folders, reached by a link under another
        // name and by an alias: copied from where it is, under its own name, once.
        let outside = folders.root.appendingPathComponent("Elsewhere/Outside.osirixplugin")
        try makePlugin(outside, version: "4.0")
        try FileManager.default.createSymbolicLink(at: horos.appendingPathComponent("LinkedOutside.horosplugin"), withDestinationURL: outside)
        try alias(folders.user.appendingPathComponent("OsiriX/Plugins/Outside.osirixplugin"), to: outside)
        // Links that lead nowhere: to a bundle that is gone, and to one another.
        try FileManager.default.createSymbolicLink(at: horos.appendingPathComponent("Gone.horosplugin"),
                                                   withDestinationURL: folders.root.appendingPathComponent("Elsewhere/Removed.horosplugin"))
        try FileManager.default.createSymbolicLink(atPath: horos.appendingPathComponent("LoopA.horosplugin").path, withDestinationPath: "LoopB.horosplugin")
        try FileManager.default.createSymbolicLink(atPath: horos.appendingPathComponent("LoopB.horosplugin").path, withDestinationPath: "LoopA.horosplugin")
        // Not bundles, and not leading to one.
        try write("a document", to: folders.root.appendingPathComponent("Elsewhere/Document.txt"))
        try FileManager.default.createSymbolicLink(at: horos.appendingPathComponent("ToDocument.horosplugin"),
                                                   withDestinationURL: folders.root.appendingPathComponent("Elsewhere/Document.txt"))
        try alias(horos.appendingPathComponent("AliasToDocument.osirixplugin"), to: folders.root.appendingPathComponent("Elsewhere/Document.txt"))
        try write("loose file", to: horos.appendingPathComponent("Loose.horosplugin"))

        let before = try FileManager.default.subpathsOfDirectory(atPath: folders.root.path).sorted()
        let survey = folders.importer.survey(rules: rules)

        #expect(describe(survey) == [
            "add New.horosplugin 1.0",
            "add Outside.osirixplugin 4.0",
            "add QA.osirixplugin 2.0 replacing QA.horosplugin 1.0",
            "add Shared.osirixplugin 5.0",
            "add Twice.osirixplugin 1.5",
            "skip AliasToDocument.osirixplugin -: alias",
            "skip Gone.horosplugin -: leads nowhere",
            "skip Kept.osirixplugin 3.0: IsiX keeps Kept.osirixplugin 3.3",
            "skip LoopA.horosplugin -: leads nowhere",
            "skip LoopB.horosplugin -: leads nowhere",
            "skip ToDocument.horosplugin -: link",
            "skip Twice.horosplugin 1.0: same name as Twice.osirixplugin 1.5",
            "skip Unknown.horosplugin -: IsiX keeps Unknown.horosplugin -",
        ])
        #expect(survey.upToDate == 2)
        #expect(survey.additions.first { $0.source.name == "Twice.osirixplugin" }?.source.active == false)
        // The bundle outside is the source, in the place of the first folder that links to it.
        let linked = survey.additions.first { $0.source.name == "Outside.osirixplugin" }?.source
        #expect(linked?.url.resolvingSymlinksInPath() == outside.resolvingSymlinksInPath())
        #expect(linked?.rank == 0)
        // Looking changes nothing, and asks nothing of the single offer.
        #expect(try FileManager.default.subpathsOfDirectory(atPath: folders.root.path).sorted() == before)
    }

    @Test func addingCopiesTheNewOnesAndHandsTheNewerOnesToTheReplacement() throws {
        let folders = Folders()
        let horos = folders.user.appendingPathComponent("Horos/Plugins")
        let isix = folders.isix.appendingPathComponent("Plugins")
        try makePlugin(horos.appendingPathComponent("New.horosplugin"), version: "1.0")
        try makePlugin(folders.user.appendingPathComponent("OsiriX/Plugins Disabled/Off.osirixplugin"), version: "1.0")
        try makePlugin(isix.appendingPathComponent("QA.horosplugin"), version: "1.0", build: "old")
        try makePlugin(horos.appendingPathComponent("QA.osirixplugin"), version: "2.0", build: "new")
        try makePlugin(isix.appendingPathComponent("Stuck.horosplugin"), version: "1.0")
        try makePlugin(horos.appendingPathComponent("Stuck.horosplugin"), version: "2.0")

        let survey = folders.importer.survey(rules: rules)
        var replaced: [String] = []
        let failures = try folders.importer.add(survey.additions, rules: rules) { source, installed in
            replaced.append("\(source.lastPathComponent) over \(installed.lastPathComponent)")
            if source.lastPathComponent.hasPrefix("Stuck") { throw CocoaError(.fileWriteNoPermission) }
        }

        #expect(version(of: isix.appendingPathComponent("New.horosplugin")) == "1.0")
        #expect(version(of: folders.isix.appendingPathComponent("Plugins Disabled/Off.osirixplugin")) == "1.0")
        #expect(replaced == ["QA.osirixplugin over QA.horosplugin", "Stuck.horosplugin over Stuck.horosplugin"])
        #expect(failures.map(\.name) == ["Stuck.horosplugin"])
        if case .copyFailed? = failures.first?.reason {} else { Issue.record("the failed replacement was not reported as one") }
        // The source folders are only read.
        #expect(version(of: horos.appendingPathComponent("New.horosplugin")) == "1.0")
        #expect(version(of: horos.appendingPathComponent("QA.osirixplugin")) == "2.0")
        #expect(!exists(folders.isix.appendingPathComponent(".ImportLegacyPlugins-staging")))
        // The user has chosen what to copy: the single offer does not come up after that.
        _ = try folders.importer.offerIfNeeded(rules: rules) { _ in
            Issue.record("The single offer came up after a manual import")
            return false
        }
        // What was brought in is not found again; what the stand-in did not replace still is.
        let again = folders.importer.survey(rules: rules)
        #expect(again.additions.map(\.source.name) == ["QA.osirixplugin", "Stuck.horosplugin"])
        #expect(again.upToDate == 2)
    }

    @Test func aLowerVersionInTheSourceNeverReplacesTheOneOfIsiX() throws {
        let folders = Folders()
        let installed = folders.isix.appendingPathComponent("Plugins/CalciumScore.osirixplugin")
        try makePlugin(installed, version: "3.3", build: "newer")
        try makePlugin(folders.user.appendingPathComponent("Horos/Plugins/CalciumScore.osirixplugin"), version: "3.0", build: "older")
        try makePlugin(folders.user.appendingPathComponent("Horos/Plugins Disabled/CalciumScore.horosplugin"), version: "2.0", build: "oldest")

        let survey = folders.importer.survey(rules: rules)
        #expect(survey.additions.isEmpty)
        #expect(describe(survey) == ["skip CalciumScore.horosplugin 2.0: same name as CalciumScore.osirixplugin 3.0",
                                     "skip CalciumScore.osirixplugin 3.0: IsiX keeps CalciumScore.osirixplugin 3.3"])
        let failures = try folders.importer.add(survey.additions, rules: rules) { _, _ in Issue.record("nothing was to be replaced") }
        #expect(failures.isEmpty)
        #expect(version(of: installed) == "3.3")
    }

    /// A plugin of IsiX that this Mac cannot load, as the Intel-only build of
    /// a plugin, with a build number above the version of its universal
    /// successor, is replaced by a bundle of its name in the source folders
    /// that it can load, whatever versions they declare: the one IsiX keeps is
    /// refused at every launch. In the source folders the one that loads is
    /// the one offered. One this Mac cannot load either is left as it is.
    @Test func aPluginOfIsiXThisMacCannotLoadIsReplacedByOneItCan() throws {
        let folders = Folders()
        let horos = folders.user.appendingPathComponent("Horos/Plugins")
        let isix = folders.isix.appendingPathComponent("Plugins")
        try makePlugin(isix.appendingPathComponent("QA.horosplugin"), version: "300", build: "foreign")
        try makePlugin(horos.appendingPathComponent("QA.horosplugin"), version: "300", build: "foreign")
        try makePlugin(horos.appendingPathComponent("QA.osirixplugin"), version: "2.0", build: "universal")
        // One version, two builds.
        try makePlugin(isix.appendingPathComponent("Same.osirixplugin"), version: "3.3", build: "foreign")
        try makePlugin(horos.appendingPathComponent("Same.osirixplugin"), version: "3.3", build: "universal")
        try makePlugin(isix.appendingPathComponent("Neither.horosplugin"), version: "2.0", build: "foreign")
        try makePlugin(horos.appendingPathComponent("Neither.horosplugin"), version: "1.0", build: "foreign, older")

        let survey = folders.importer.survey(rules: rules)
        #expect(describe(survey) == [
            "add QA.osirixplugin 2.0 replacing QA.horosplugin 300",
            "add Same.osirixplugin 3.3 replacing Same.osirixplugin 3.3",
            "skip Neither.horosplugin 1.0: IsiX keeps Neither.horosplugin 2.0",
            "skip QA.horosplugin 300: same name as QA.osirixplugin 2.0",
        ])
        #expect(survey.upToDate == 0)

        var replaced: [String] = []
        let failures = try folders.importer.add(survey.additions, rules: rules) { source, installed in
            replaced.append("\(source.lastPathComponent) over \(installed.lastPathComponent)")
            try FileManager.default.removeItem(at: installed)
            try FileManager.default.copyItem(at: source, to: installed)
        }
        #expect(failures.isEmpty)
        #expect(replaced == ["QA.osirixplugin over QA.horosplugin", "Same.osirixplugin over Same.osirixplugin"])
        #expect(version(of: isix.appendingPathComponent("QA.horosplugin")) == "2.0")
        // What was brought in is not found again.
        let again = folders.importer.survey(rules: rules)
        #expect(again.additions.isEmpty)
        #expect(again.upToDate == 2)
    }

    // MARK: links and aliases

    /// The copy of a bundle a link reaches comes from the bundle, under the
    /// bundle's name, and the single offer of the first launch takes it too.
    @Test func aLinkedBundleIsCopiedFromWhereItIsUnderItsOwnName() throws {
        let folders = Folders()
        let outside = folders.root.appendingPathComponent("Elsewhere/Outside.osirixplugin")
        try makePlugin(outside, version: "4.0", build: "kept elsewhere")
        try link(folders.user.appendingPathComponent("Horos/Plugins Disabled/Linked.horosplugin"), to: outside)
        try link(folders.system.appendingPathComponent("Horos/Plugins/Outside.osirixplugin"), to: outside)
        try link(folders.user.appendingPathComponent("Horos/Plugins/Gone.horosplugin"), to: folders.root.appendingPathComponent("Elsewhere/Removed.horosplugin"))

        let problems = try folders.importer.offerIfNeeded(rules: rules) { names in
            #expect(names == ["Outside.osirixplugin"])
            return true
        }
        #expect(problems.isEmpty)
        // In the place of the first folder that links to it: the user's disabled plugins.
        let copy = folders.isix.appendingPathComponent("Plugins Disabled/Outside.osirixplugin")
        #expect(version(of: copy) == "4.0")
        #expect(!isLink(copy))
        #expect(version(of: outside) == "4.0")
        #expect(isLink(folders.user.appendingPathComponent("Horos/Plugins Disabled/Linked.horosplugin")))
        let again = folders.importer.survey(rules: rules)
        #expect(describe(again) == ["skip Gone.horosplugin -: leads nowhere"])
        #expect(again.upToDate == 1)
    }

    /// A link or an alias in a folder of IsiX is judged by the bundle it leads
    /// to, which is the one that loads: the same build is up to date, an older
    /// one is replaced as the entry it is, and one that leads nowhere is
    /// replaced by the plugin of its name, without being asked whether it loads.
    @Test func anEntryOfIsiXThatIsALinkOrAnAliasIsJudgedByWhatItLeadsTo() throws {
        let folders = Folders()
        let horos = folders.user.appendingPathComponent("Horos/Plugins")
        let isix = folders.isix.appendingPathComponent("Plugins")
        let elsewhere = folders.root.appendingPathComponent("Elsewhere")
        // An alias and a link to the build the source folder has, with and without a version.
        try makePlugin(elsewhere.appendingPathComponent("Aliased.osirixplugin"), version: "2.0")
        try alias(isix.appendingPathComponent("Aliased.osirixplugin"), to: elsewhere.appendingPathComponent("Aliased.osirixplugin"))
        try makePlugin(horos.appendingPathComponent("Aliased.osirixplugin"), version: "2.0")
        try makePlugin(elsewhere.appendingPathComponent("Plain.horosplugin"), version: nil, build: "one build")
        try link(isix.appendingPathComponent("Plain.horosplugin"), to: elsewhere.appendingPathComponent("Plain.horosplugin"))
        try makePlugin(horos.appendingPathComponent("Plain.horosplugin"), version: nil, build: "one build")
        // A link to the source bundle itself.
        try makePlugin(horos.appendingPathComponent("Direct.horosplugin"), version: nil, build: "its own")
        try link(isix.appendingPathComponent("Direct.horosplugin"), to: horos.appendingPathComponent("Direct.horosplugin"))
        // A link to an older build.
        try makePlugin(elsewhere.appendingPathComponent("Older.osirixplugin"), version: "1.0", build: "old")
        try link(isix.appendingPathComponent("Older.osirixplugin"), to: elsewhere.appendingPathComponent("Older.osirixplugin"))
        try makePlugin(horos.appendingPathComponent("Older.osirixplugin"), version: "2.0", build: "new")
        // A link whose bundle is gone, and an alias whose original is gone.
        try link(isix.appendingPathComponent("Gone.horosplugin"), to: elsewhere.appendingPathComponent("Removed.horosplugin"))
        try makePlugin(horos.appendingPathComponent("Gone.horosplugin"), version: "1.0")
        try makePlugin(elsewhere.appendingPathComponent("Dead.osirixplugin"), version: "1.0")
        try alias(isix.appendingPathComponent("Dead.osirixplugin"), to: elsewhere.appendingPathComponent("Dead.osirixplugin"))
        try FileManager.default.removeItem(at: elsewhere.appendingPathComponent("Dead.osirixplugin"))
        try makePlugin(horos.appendingPathComponent("Dead.osirixplugin"), version: nil)

        // What is asked whether it loads is the bundle an entry leads to, never
        // the entry: of one that leads nowhere nothing is asked.
        let asked = Counter()
        let counting = Self.rules(inspecting: Self.loads, canLoad: { url in
            asked.paths.append(url.path)
            return Self.loads(url)
        })
        let survey = folders.importer.survey(rules: counting)
        #expect(describe(survey) == [
            "add Dead.osirixplugin - replacing Dead.osirixplugin -",
            "add Gone.horosplugin 1.0 replacing Gone.horosplugin -",
            "add Older.osirixplugin 2.0 replacing Older.osirixplugin 1.0",
        ])
        #expect(survey.upToDate == 3)
        func folder(_ path: String) -> String { URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path }
        #expect(!asked.paths.isEmpty)
        #expect(asked.paths.filter { folder($0) == isix.resolvingSymlinksInPath().path } == [])
        #expect(asked.paths.contains { folder($0) == elsewhere.resolvingSymlinksInPath().path && $0.hasSuffix("/Aliased.osirixplugin") })
        // The entry is what a replacement takes the place of, and what it leads to is what was judged.
        let older = survey.additions.first { $0.source.name == "Older.osirixplugin" }?.replaces
        #expect(older?.url.lastPathComponent == "Older.osirixplugin")
        #expect(older.map { folder($0.url.path) } == isix.resolvingSymlinksInPath().path)
        #expect(older?.target?.resolvingSymlinksInPath() == elsewhere.appendingPathComponent("Older.osirixplugin").resolvingSymlinksInPath())
        #expect(survey.additions.first { $0.source.name == "Gone.horosplugin" }?.replaces?.target == nil)

        var replaced: [String] = []
        let failures = try folders.importer.add(survey.additions, rules: rules) { source, installed in
            replaced.append("\(source.lastPathComponent) over \(installed.lastPathComponent)")
            #expect(folder(installed.path) == isix.resolvingSymlinksInPath().path)
            // As the installer does: the entry goes, never what it led to.
            try FileManager.default.removeItem(at: installed)
            try FileManager.default.copyItem(at: source, to: installed)
        }
        #expect(failures.isEmpty)
        #expect(replaced == ["Dead.osirixplugin over Dead.osirixplugin", "Gone.horosplugin over Gone.horosplugin",
                             "Older.osirixplugin over Older.osirixplugin"])
        #expect(version(of: elsewhere.appendingPathComponent("Older.osirixplugin")) == "1.0")
        #expect(version(of: isix.appendingPathComponent("Older.osirixplugin")) == "2.0")
        #expect(!isLink(isix.appendingPathComponent("Gone.horosplugin")))
        let again = folders.importer.survey(rules: rules)
        #expect(describe(again).isEmpty)
        #expect(again.upToDate == 6)
    }

    /// The single offer never replaces: a link that leads nowhere keeps its
    /// name taken, and the command repairs it.
    @Test func theSingleOfferLeavesALinkThatLeadsNowhereToTheCommand() throws {
        let folders = Folders()
        let entry = folders.isix.appendingPathComponent("Plugins/QA.osirixplugin")
        try link(entry, to: folders.root.appendingPathComponent("Elsewhere/Removed.osirixplugin"))
        try makePlugin(folders.user.appendingPathComponent("OsiriX/Plugins/QA.osirixplugin"), version: "1.0")
        let problems = try folders.importer.offerIfNeeded(rules: rules) { _ in true }
        #expect(problems == [.alreadyInstalled("QA.osirixplugin")])
        #expect(isLink(entry))
        #expect(describe(folders.importer.survey(rules: rules)) == ["add QA.osirixplugin 1.0 replacing QA.osirixplugin -"])
    }

    // MARK: at a later launch

    private final class Counter: @unchecked Sendable {
        var paths: [String] = []
    }

    /// What a launch offered, as lines, and what it answered.
    private func offer(_ folders: Folders, rules: LegacyPluginImport.Rules? = nil, importing: Bool = true) throws -> [String]? {
        var offered: [String]?
        let failures = try folders.importer.offerNewerIfNeeded(rules: rules ?? self.rules, shouldImport: { additions in
            #expect(offered == nil, "asked twice in one launch")
            offered = describe(LegacyPluginImport.Survey(additions: additions))
            return importing
        }, replace: { source, installed in
            try FileManager.default.removeItem(at: installed)
            try FileManager.default.copyItem(at: source, to: installed)
        })
        #expect(failures.isEmpty)
        return offered
    }

    private func record(_ folders: Folders) throws -> [String: String]? {
        let file = folders.isix.appendingPathComponent(".ImportLegacyPlugins-offered.json")
        guard exists(file) else { return nil }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    }

    private func answerTheSingleOffer(_ folders: Folders) throws {
        try write("[]", to: folders.isix.appendingPathComponent(".ImportLegacyPlugins.json"))
    }

    /// The single offer records what it showed, copied or not, so that the
    /// launches that follow do not offer it again.
    @Test func theSingleOfferRecordsEveryPluginItShowed() throws {
        for copying in [true, false] {
            let folders = Folders()
            try makePlugin(folders.user.appendingPathComponent("Horos/Plugins/QA.horosplugin"), version: "1.0", build: "old")
            try makePlugin(folders.user.appendingPathComponent("OsiriX/Plugins/QA.osirixplugin"), version: "2.0", build: "new")
            try makePlugin(folders.system.appendingPathComponent("OsiriX/Plugins Disabled/Plain.osirixplugin"), version: nil)
            try makePlugin(folders.isix.appendingPathComponent("Plugins/Taken.horosplugin"), version: "1.0")
            try makePlugin(folders.user.appendingPathComponent("Horos/Plugins/Taken.horosplugin"), version: "3.0")
            #expect(try offer(folders) == nil, "a launch offered before the single offer was answered")
            #expect(try record(folders) == nil)
            _ = try folders.importer.offerIfNeeded(rules: rules) { _ in copying }
            #expect(try record(folders) == ["qa": "2.0", "plain": "", "taken": "3.0"])
            #expect(try offer(folders) == nil, "copying \(copying): the launch offered what the single offer had shown")
            #expect(exists(folders.isix.appendingPathComponent("Plugins/QA.osirixplugin")) == copying)
            // A version above the one shown is news.
            try makePlugin(folders.user.appendingPathComponent("OsiriX/Plugins/QA.osirixplugin"), version: "2.5", build: "newer")
            let expected = copying ? "add QA.osirixplugin 2.5 replacing QA.osirixplugin 2.0" : "add QA.osirixplugin 2.5"
            #expect(try offer(folders) == [expected])
        }
    }

    /// An installation whose single offer was answered before there was a
    /// record: it begins with what IsiX has, so that the update an installer
    /// left in the source folders since is offered, and takes the plugins IsiX
    /// does not have as declined then.
    @Test func aRecordBeginsWithWhatIsiXHasAndOffersTheHigherVersionOnce() throws {
        let folders = Folders()
        let osirix = folders.system.appendingPathComponent("OsiriX/Plugins")
        let isix = folders.isix.appendingPathComponent("Plugins")
        try answerTheSingleOffer(folders)
        try makePlugin(isix.appendingPathComponent("IBNeuro.osirixplugin"), version: "21.12", build: "old")
        try makePlugin(osirix.appendingPathComponent("IBNeuro.osirixplugin"), version: "26.10", build: "new")
        try link(folders.system.appendingPathComponent("Horos/Plugins/IBNeuro.osirixplugin"), to: osirix.appendingPathComponent("IBNeuro.osirixplugin"))
        try makePlugin(isix.appendingPathComponent("Same.horosplugin"), version: "2.0")
        try makePlugin(osirix.appendingPathComponent("Same.horosplugin"), version: "2.0")
        try makePlugin(isix.appendingPathComponent("Newer.horosplugin"), version: "3.0")
        try makePlugin(osirix.appendingPathComponent("Newer.horosplugin"), version: "2.0")
        try makePlugin(osirix.appendingPathComponent("Declined.osirixplugin"), version: "1.0")
        try makePlugin(isix.appendingPathComponent("OnlyHere.isixplugin"), version: "1.0")

        #expect(try offer(folders) == ["add IBNeuro.osirixplugin 26.10 replacing IBNeuro.osirixplugin 21.12"])
        #expect(try record(folders) == ["ibneuro": "26.10", "same": "2.0", "newer": "3.0", "declined": "1.0"])
        #expect(version(of: isix.appendingPathComponent("IBNeuro.osirixplugin")) == "26.10")
        #expect(!exists(isix.appendingPathComponent("Declined.osirixplugin")))
        // Once: neither the version brought in nor anything else comes up again.
        #expect(try offer(folders) == nil)
        // The source folders are only read.
        #expect(version(of: osirix.appendingPathComponent("IBNeuro.osirixplugin")) == "26.10")
        #expect(isLink(folders.system.appendingPathComponent("Horos/Plugins/IBNeuro.osirixplugin")))
    }

    /// Not Now is an answer too: the version does not come back at the next
    /// launch, the command still finds it, and a higher one is news again.
    @Test func aVersionDeclinedAtLaunchIsNotOfferedAgain() throws {
        let folders = Folders()
        let source = folders.user.appendingPathComponent("OsiriX/Plugins/QA.osirixplugin")
        let installed = folders.isix.appendingPathComponent("Plugins/QA.horosplugin")
        try answerTheSingleOffer(folders)
        try makePlugin(installed, version: "1.0", build: "old")
        try makePlugin(source, version: "2.0", build: "new")

        #expect(try offer(folders, importing: false) == ["add QA.osirixplugin 2.0 replacing QA.horosplugin 1.0"])
        #expect(version(of: installed) == "1.0")
        #expect(try record(folders) == ["qa": "2.0"])
        #expect(try offer(folders) == nil)
        #expect(describe(folders.importer.survey(rules: rules)) == ["add QA.osirixplugin 2.0 replacing QA.horosplugin 1.0"])
        try makePlugin(source, version: "2.1", build: "newer")
        #expect(try offer(folders) == ["add QA.osirixplugin 2.1 replacing QA.horosplugin 1.0"])
        #expect(version(of: installed) == "2.1")
        #expect(try offer(folders) == nil)
    }

    /// A plugin installed for Horos or OsiriX after the record began is
    /// offered as a new one, copied on Import, and offered once either way. A
    /// plugin deleted in IsiX does not come back by itself: only a higher
    /// version of it is news.
    @Test func aNameIsiXDoesNotHaveIsOfferedOnce() throws {
        let folders = Folders()
        let horos = folders.user.appendingPathComponent("Horos/Plugins")
        let isix = folders.isix.appendingPathComponent("Plugins")
        try answerTheSingleOffer(folders)
        try makePlugin(isix.appendingPathComponent("Deleted.horosplugin"), version: "1.0")
        try makePlugin(horos.appendingPathComponent("Deleted.horosplugin"), version: "1.0")
        #expect(try offer(folders) == nil)
        #expect(try record(folders) == ["deleted": "1.0"])

        try makePlugin(horos.appendingPathComponent("Arrived.horosplugin"), version: "1.0")
        try makePlugin(folders.user.appendingPathComponent("Horos/Plugins Disabled/Off.osirixplugin"), version: nil)
        try FileManager.default.removeItem(at: isix.appendingPathComponent("Deleted.horosplugin"))
        #expect(try offer(folders, importing: false) == ["add Arrived.horosplugin 1.0", "add Off.osirixplugin -"])
        #expect(!exists(isix.appendingPathComponent("Arrived.horosplugin")))
        #expect(try offer(folders) == nil)

        try makePlugin(horos.appendingPathComponent("Later.osirixplugin"), version: "0.9")
        try makePlugin(horos.appendingPathComponent("Deleted.horosplugin"), version: "1.1")
        #expect(try offer(folders) == ["add Deleted.horosplugin 1.1", "add Later.osirixplugin 0.9"])
        #expect(version(of: isix.appendingPathComponent("Later.osirixplugin")) == "0.9")
        #expect(version(of: isix.appendingPathComponent("Deleted.horosplugin")) == "1.1")
        #expect(try offer(folders) == nil)
    }

    /// Versions that cannot be compared are the command's to show: a launch
    /// decides by declared versions alone.
    @Test func aVersionThatCannotBeComparedIsNotOfferedAtLaunch() throws {
        let folders = Folders()
        let horos = folders.user.appendingPathComponent("Horos/Plugins")
        let isix = folders.isix.appendingPathComponent("Plugins")
        try answerTheSingleOffer(folders)
        try write("{}", to: folders.isix.appendingPathComponent(".ImportLegacyPlugins-offered.json"))
        try makePlugin(isix.appendingPathComponent("Words.horosplugin"), version: "1.0")
        try makePlugin(horos.appendingPathComponent("Words.horosplugin"), version: "three")
        try makePlugin(isix.appendingPathComponent("Unversioned.horosplugin"), version: "1.0")
        try makePlugin(horos.appendingPathComponent("Unversioned.horosplugin"), version: nil, build: "another build")
        try makePlugin(isix.appendingPathComponent("NoneHere.horosplugin"), version: nil, build: "one build")
        try makePlugin(horos.appendingPathComponent("NoneHere.horosplugin"), version: "2.0", build: "another build")
        try link(isix.appendingPathComponent("Gone.horosplugin"), to: folders.root.appendingPathComponent("Elsewhere/Removed.horosplugin"))
        try makePlugin(horos.appendingPathComponent("Gone.horosplugin"), version: "2.0")
        #expect(try offer(folders) == nil)
        #expect(try record(folders) == [:])
        // The command still shows them.
        #expect(describe(folders.importer.survey(rules: rules)).contains("add Gone.horosplugin 2.0 replacing Gone.horosplugin -"))
    }

    /// Before the single offer is answered the launch offers nothing and
    /// records nothing: with no choice saved, and with a copy still to resume.
    @Test func nothingIsOfferedAtLaunchBeforeTheSingleOfferIsAnswered() throws {
        struct SavedCandidate: Encodable {
            let source: URL
            let active: Bool
        }
        let folders = Folders()
        let source = folders.user.appendingPathComponent("Horos/Plugins/QA.osirixplugin")
        try makePlugin(folders.isix.appendingPathComponent("Plugins/QA.horosplugin"), version: "1.0")
        try makePlugin(source, version: "2.0")
        try makePlugin(folders.user.appendingPathComponent("Horos/Plugins/New.horosplugin"), version: "1.0")
        #expect(try offer(folders) == nil)
        try JSONEncoder().encode([SavedCandidate(source: source, active: true)])
            .write(to: folders.isix.appendingPathComponent(".ImportLegacyPlugins.json"))
        #expect(try offer(folders) == nil)
        #expect(try record(folders) == nil)
        #expect(version(of: folders.isix.appendingPathComponent("Plugins/QA.horosplugin")) == "1.0")
    }

    /// A launch validates no signature and inspects no bundle: neither the
    /// rule that says whether a bundle loads nor the one the choice between
    /// two bundles of one name is given is called, where the command calls both.
    @Test func aLaunchNeverAsksWhetherABundleLoads() throws {
        let folders = Folders()
        let horos = folders.user.appendingPathComponent("Horos/Plugins")
        let isix = folders.isix.appendingPathComponent("Plugins")
        try answerTheSingleOffer(folders)
        // Two of one name in the source folders and in IsiX, a plugin IsiX
        // has at the same version, at a higher one and at none.
        try makePlugin(horos.appendingPathComponent("QA.horosplugin"), version: "1.0", build: "old")
        try makePlugin(folders.user.appendingPathComponent("OsiriX/Plugins/QA.osirixplugin"), version: "2.0", build: "new")
        try makePlugin(isix.appendingPathComponent("QA.horosplugin"), version: "1.0", build: "old")
        try makePlugin(folders.isix.appendingPathComponent("Plugins Disabled/QA.osirixplugin"), version: "0.5", build: "older")
        try makePlugin(isix.appendingPathComponent("Same.horosplugin"), version: "2.0")
        try makePlugin(horos.appendingPathComponent("Same.horosplugin"), version: "2.0")
        try makePlugin(isix.appendingPathComponent("Kept.horosplugin"), version: "3.0")
        try makePlugin(horos.appendingPathComponent("Kept.horosplugin"), version: "2.0")
        try makePlugin(isix.appendingPathComponent("Plain.horosplugin"), version: nil, build: "one build")
        try makePlugin(horos.appendingPathComponent("Plain.horosplugin"), version: nil, build: "another build")

        let inspected = Counter(), asked = Counter()
        @Sendable func count(_ counter: Counter) -> @Sendable (URL) -> Bool {
            { url in counter.paths.append(url.lastPathComponent); return Self.loads(url) }
        }
        // The command, for comparison, calls both.
        _ = folders.importer.survey(rules: Self.rules(inspecting: count(inspected), canLoad: count(asked)))
        #expect(!inspected.paths.isEmpty && !asked.paths.isEmpty)
        inspected.paths = []
        asked.paths = []
        // The launch's rules: the choice between two bundles is told that each
        // loads, so it is made by version, folder and format alone.
        let launch = Self.rules(inspecting: { _ in true }, canLoad: count(asked))
        #expect(try offer(folders, rules: launch) == ["add QA.osirixplugin 2.0 replacing QA.horosplugin 1.0"])
        #expect(try offer(folders, rules: launch) == nil)
        #expect(asked.paths.isEmpty)
    }
}
