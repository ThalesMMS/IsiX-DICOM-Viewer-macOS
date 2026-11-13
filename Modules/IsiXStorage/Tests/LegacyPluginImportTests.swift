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

    /// Stand-ins for the rules of the plugin loader, which are another
    /// module's: the version is the "version=" line of the Info.plist these
    /// tests write, versions compare as numbers, and between equal versions
    /// the folder decides, then the format.
    private var rules: LegacyPluginImport.Rules {
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
                if let order = compare(first.version, second.version), order != .orderedSame { return order == .orderedDescending }
                if first.rank != second.rank { return first.rank < second.rank }
                return (Self.formats.firstIndex(of: first.url.pathExtension.lowercased()) ?? 9)
                    < (Self.formats.firstIndex(of: second.url.pathExtension.lowercased()) ?? 9)
            })
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
        // Not bundles.
        try FileManager.default.createSymbolicLink(at: horos.appendingPathComponent("Linked.horosplugin"),
                                                   withDestinationURL: horos.appendingPathComponent("New.horosplugin"))
        let alias = horos.appendingPathComponent("Aliased.osirixplugin")
        try URL.writeBookmarkData(try horos.appendingPathComponent("New.horosplugin").bookmarkData(options: .suitableForBookmarkFile), to: alias)
        try write("loose file", to: horos.appendingPathComponent("Loose.horosplugin"))

        let before = try FileManager.default.subpathsOfDirectory(atPath: folders.root.path).sorted()
        let survey = folders.importer.survey(rules: rules)

        #expect(describe(survey) == [
            "add New.horosplugin 1.0",
            "add QA.osirixplugin 2.0 replacing QA.horosplugin 1.0",
            "add Twice.osirixplugin 1.5",
            "skip Aliased.osirixplugin -: alias",
            "skip Kept.osirixplugin 3.0: IsiX keeps Kept.osirixplugin 3.3",
            "skip Linked.horosplugin -: link",
            "skip Twice.horosplugin 1.0: same name as Twice.osirixplugin 1.5",
            "skip Unknown.horosplugin -: IsiX keeps Unknown.horosplugin -",
        ])
        #expect(survey.upToDate == 2)
        #expect(survey.additions.first { $0.source.name == "Twice.osirixplugin" }?.source.active == false)
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
}
