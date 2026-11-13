//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Darwin
import Foundation

/// Copies the plugins found in the plugins folders of Horos, OsiriX and
/// earlier versions into the user's IsiX plugins folders.
///
/// Installers of plugins made for Horos or OsiriX only know those folders, so
/// for their users this copy is the installation. It is offered once, the
/// first time there is something to copy (`offerIfNeeded`), and can be asked
/// for again at any time (`survey`, then `add`): that finds what was installed
/// or updated in those folders since, and says what it leaves out and why.
///
/// A plugin is known by the name of its bundle without the extension. Between
/// bundles of one name the higher version stands for the plugin, wherever it
/// is and whatever its extension; the rules of that choice are the plugin
/// loader's, given here as `Rules`. A plugin of IsiX is only ever replaced by
/// a higher version of itself. The source folders are only read.
public struct LegacyPluginImport: Sendable {
    public enum Problem: Equatable {
        case alreadyInstalled(String)
        case copyFailed(String, String)
    }

    /// A plugin bundle, in a source folder or in a folder of IsiX.
    public struct Found: Equatable, Sendable {
        public let url: URL
        /// The version it declares, if any.
        public let version: String?
        /// Whether it is in a folder of active plugins.
        public let active: Bool
        /// The place of its folder among the folders looked into: the user's
        /// before the computer's, the active before the disabled.
        public let rank: Int

        public var name: String { url.lastPathComponent }

        public init(url: URL, version: String?, active: Bool, rank: Int) {
            self.url = url
            self.version = version
            self.active = active
            self.rank = rank
        }
    }

    /// What the import asks of the rules of plugin bundles.
    public struct Rules: Sendable {
        /// Whether a file name is a plugin bundle's.
        public var isPlugin: @Sendable (String) -> Bool
        /// The version the bundle at a URL declares.
        public var version: @Sendable (URL) -> String?
        /// How two declared versions compare; nil when they cannot be compared.
        public var compare: @Sendable (String?, String?) -> ComparisonResult?
        /// Whether the first of two bundles of one name stands for the plugin.
        public var isPreferred: @Sendable (Found, Found) -> Bool

        public init(isPlugin: @escaping @Sendable (String) -> Bool, version: @escaping @Sendable (URL) -> String?,
                    compare: @escaping @Sendable (String?, String?) -> ComparisonResult?,
                    isPreferred: @escaping @Sendable (Found, Found) -> Bool) {
            self.isPlugin = isPlugin
            self.version = version
            self.compare = compare
            self.isPreferred = isPreferred
        }
    }

    /// Why something in a source folder is not copied.
    public enum Reason: Equatable, Sendable {
        /// A symbolic link: what it points to is not in the folder.
        case symbolicLink
        /// A Finder alias.
        case alias
        /// Another bundle of its name in the source folders stands for the plugin.
        case sameName(preferred: Found)
        /// IsiX has a plugin of its name that is newer, or that cannot be
        /// compared with it: that one stays.
        case installedKept(installed: Found)
        /// The copy failed, for the reason given.
        case copyFailed(String)
    }

    public struct Skipped: Equatable, Sendable {
        public let name: String
        public let version: String?
        public let reason: Reason

        public init(name: String, version: String?, reason: Reason) {
            self.name = name
            self.version = version
            self.reason = reason
        }
    }

    /// A plugin to bring in: new to IsiX, or a higher version of one it has.
    public struct Addition: Equatable, Sendable {
        public let source: Found
        /// The plugin of IsiX it takes the place of, or nil for a new one.
        public let replaces: Found?

        public init(source: Found, replaces: Found?) {
            self.source = source
            self.replaces = replaces
        }
    }

    public struct Survey: Equatable, Sendable {
        public var additions: [Addition]
        public var skipped: [Skipped]
        /// How many plugins of the source folders IsiX already has as they are.
        public var upToDate: Int

        public init(additions: [Addition] = [], skipped: [Skipped] = [], upToDate: Int = 0) {
            self.additions = additions
            self.skipped = skipped
            self.upToDate = upToDate
        }
    }

    private struct Candidate: Codable {
        let source: URL
        let active: Bool
    }

    private let userDomain: String
    private let systemDomain: String
    private let support: URL
    private var choiceFile: URL { support.appendingPathComponent(".ImportLegacyPlugins.json") }
    private var staging: URL { support.appendingPathComponent(".ImportLegacyPlugins-staging", isDirectory: true) }

    public init(userDomain: String, systemDomain: String) {
        self.userDomain = userDomain
        self.systemDomain = systemDomain
        support = URL(fileURLWithPath: StorageLocations.supportFolder(for: .direct, inDomain: userDomain), isDirectory: true)
    }

    // MARK: the single offer

    /// Offers the user a single choice once there are plugins to copy. The
    /// saved selection also lets an interrupted copy resume without asking
    /// again or adding bundles that appeared after the offer. This copy never
    /// replaces a plugin IsiX already has.
    public func offerIfNeeded(rules: Rules, shouldCopy: ([String]) -> Bool) throws -> [Problem] {
        let saved = try readChoice()
        if saved?.isEmpty == true { return [] }
        let candidates = saved ?? findCandidates(rules: rules)
        guard !candidates.isEmpty else { return [] }

        return try locked {
            let selection: [Candidate]
            if let saved = try readChoice() {
                selection = saved
            } else {
                selection = shouldCopy(candidates.map { $0.source.lastPathComponent }) ? candidates : []
                try saveChoice(selection)
            }
            guard !selection.isEmpty else { return [] }

            let problems = try copy(selection, isPlugin: rules.isPlugin)
            try saveChoice([])
            return problems
        } ?? []
    }

    /// Runs `body` holding the lock of the support folder, so that two copies
    /// of the application do not copy at once; nil when another one holds it.
    private func locked<Result>(_ body: () throws -> Result) throws -> Result? {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let fd = open(support.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try body()
    }

    private func readChoice() throws -> [Candidate]? {
        do {
            return try JSONDecoder().decode([Candidate].self, from: Data(contentsOf: choiceFile))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func saveChoice(_ selection: [Candidate]) throws {
        try JSONEncoder().encode(selection).write(to: choiceFile, options: .atomic)
    }

    // MARK: what the folders hold

    private func entries(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey],
                                                       options: .skipsHiddenFiles)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isDirectoryBundle(_ url: URL) -> Bool {
        guard let attributes = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return attributes.isDirectory == true && attributes.isSymbolicLink == false
    }

    /// The name bundles of one plugin share, whatever their extension.
    private func nameKey(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The plugin bundles of the source folders, in the order of the folders,
    /// and what is there under a plugin's name without being a bundle.
    private func sources(rules: Rules) -> (bundles: [Found], notBundles: [Skipped]) {
        var bundles: [Found] = []
        var notBundles: [Skipped] = []
        var rank = 0
        for domain in [userDomain, systemDomain] {
            for active in [true, false] {
                for folder in StorageLocations.pluginImportFolders(inDomain: domain, active: active) {
                    for url in entries(in: folder) where rules.isPlugin(url.lastPathComponent) {
                        let attributes = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey])
                        if attributes?.isSymbolicLink == true {
                            notBundles.append(Skipped(name: url.lastPathComponent, version: nil, reason: .symbolicLink))
                        } else if attributes?.isDirectory == true {
                            bundles.append(Found(url: url, version: rules.version(url), active: active, rank: rank))
                        } else if attributes?.isAliasFile == true {
                            notBundles.append(Skipped(name: url.lastPathComponent, version: nil, reason: .alias))
                        }
                    }
                    rank += 1
                }
            }
        }
        return (bundles, notBundles)
    }

    /// The plugins in the folders of IsiX, the user's and the computer's.
    private func installed(rules: Rules) -> [Found] {
        var found: [Found] = []
        var rank = 0
        for domain in [userDomain, systemDomain] {
            for active in [true, false] {
                let folder = URL(fileURLWithPath: StorageLocations.pluginsFolder(inDomain: domain, active: active))
                for url in entries(in: folder) where rules.isPlugin(url.lastPathComponent) {
                    found.append(Found(url: url, version: rules.version(url), active: active, rank: rank))
                }
                rank += 1
            }
        }
        return found
    }

    /// The bundle that stands for each name, and the others of that name.
    private func choose(among bundles: [Found], rules: Rules) -> (preferred: [Found], setAside: [(bundle: Found, preferred: Found)]) {
        var best: [String: Found] = [:]
        for bundle in bundles {
            let key = nameKey(bundle.url)
            if let current = best[key], !rules.isPreferred(bundle, current) { continue }
            best[key] = bundle
        }
        var preferred: [Found] = []
        var setAside: [(bundle: Found, preferred: Found)] = []
        for bundle in bundles {
            guard let chosen = best[nameKey(bundle.url)] else { continue }
            if chosen == bundle { preferred.append(bundle) } else { setAside.append((bundle, chosen)) }
        }
        return (preferred, setAside)
    }

    private func findCandidates(rules: Rules) -> [Candidate] {
        choose(among: sources(rules: rules).bundles, rules: rules).preferred.map { Candidate(source: $0.url, active: $0.active) }
    }

    // MARK: asked for again

    /// What the source folders hold that IsiX does not have, or has at a lower
    /// version, and what they hold that is left out, each with its reason.
    /// Nothing is copied or changed.
    public func survey(rules: Rules) -> Survey {
        var survey = Survey()
        let (bundles, notBundles) = sources(rules: rules)
        survey.skipped = notBundles
        let (preferred, setAside) = choose(among: bundles, rules: rules)
        // Two copies of one build, also with no version to compare, are not worth a line.
        for (bundle, chosen) in setAside where !PluginBundleFiles.sameBuild(bundle.url, chosen.url) {
            survey.skipped.append(Skipped(name: bundle.name, version: bundle.version, reason: .sameName(preferred: chosen)))
        }
        let (inIsiX, _) = choose(among: installed(rules: rules), rules: rules)
        let installedByName = Dictionary(inIsiX.map { (nameKey($0.url), $0) }, uniquingKeysWith: { first, _ in first })
        for source in preferred {
            guard let existing = installedByName[nameKey(source.url)] else {
                survey.additions.append(Addition(source: source, replaces: nil))
                continue
            }
            switch rules.compare(source.version, existing.version) {
            case .orderedDescending?:
                survey.additions.append(Addition(source: source, replaces: existing))
            case .orderedSame?:
                survey.upToDate += 1
            case .orderedAscending?:
                survey.skipped.append(Skipped(name: source.name, version: source.version, reason: .installedKept(installed: existing)))
            case nil:
                if PluginBundleFiles.sameBuild(source.url, existing.url) {
                    survey.upToDate += 1
                } else {
                    survey.skipped.append(Skipped(name: source.name, version: source.version, reason: .installedKept(installed: existing)))
                }
            }
        }
        func byName(_ first: String, _ second: String) -> Bool {
            first.localizedStandardCompare(second) == .orderedAscending
        }
        survey.additions.sort { byName($0.source.name, $1.source.name) }
        survey.skipped.sort { byName($0.name, $1.name) }
        return survey
    }

    /// Brings the additions of a survey in, and answers the ones that failed.
    /// A new plugin is copied to the user's folder, active or disabled as it
    /// was at the source. A higher version of a plugin IsiX has goes through
    /// `replace`, which puts the bundle at the first URL in the place of the
    /// one at the second and throws if it cannot.
    ///
    /// The user has now chosen what to copy, so the single offer of the next
    /// launch is settled too.
    public func add(_ additions: [Addition], rules: Rules, replace: (URL, URL) throws -> Void) throws -> [Skipped] {
        try locked {
            var failures: [Skipped] = []
            let fresh = additions.filter { $0.replaces == nil }
            for problem in try copy(fresh.map { Candidate(source: $0.source.url, active: $0.source.active) }, isPlugin: rules.isPlugin) {
                switch problem {
                case .alreadyInstalled(let name):
                    failures.append(Skipped(name: name, version: fresh.first { $0.source.name == name }?.source.version,
                                            reason: .copyFailed(CocoaError(.fileWriteFileExists).localizedDescription)))
                case .copyFailed(let name, let reason):
                    failures.append(Skipped(name: name, version: fresh.first { $0.source.name == name }?.source.version, reason: .copyFailed(reason)))
                }
            }
            for addition in additions {
                guard let existing = addition.replaces else { continue }
                do {
                    try replace(addition.source.url, existing.url)
                } catch {
                    failures.append(Skipped(name: addition.source.name, version: addition.source.version, reason: .copyFailed(error.localizedDescription)))
                }
            }
            if try readChoice() == nil { try saveChoice([]) }
            return failures
        } ?? additions.map { Skipped(name: $0.source.name, version: $0.source.version,
                                     reason: .copyFailed(POSIXError(.EBUSY).localizedDescription)) }
    }

    // MARK: copying

    private func copy(_ selection: [Candidate], isPlugin: (String) -> Bool) throws -> [Problem] {
        guard !selection.isEmpty else { return [] }
        let files = FileManager.default
        if files.fileExists(atPath: staging.path) { try files.removeItem(at: staging) }
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        let installed = [userDomain, systemDomain].flatMap { domain in
            [true, false].flatMap { active in
                entries(in: URL(fileURLWithPath: StorageLocations.pluginsFolder(inDomain: domain, active: active)))
            }
        }
        var occupied = Set(installed.filter { isPlugin($0.lastPathComponent) }.map(nameKey))
        var problems: [Problem] = []
        for candidate in selection {
            let name = candidate.source.lastPathComponent
            let key = nameKey(candidate.source)
            guard !occupied.contains(key) else {
                problems.append(.alreadyInstalled(name))
                continue
            }
            let folder = URL(fileURLWithPath: StorageLocations.pluginsFolder(inDomain: userDomain, active: candidate.active))
            let destination = folder.appendingPathComponent(name)
            let staged = staging.appendingPathComponent(name)
            do {
                defer { try? files.removeItem(at: staged) }
                try files.copyItem(at: candidate.source, to: staged)
                guard isDirectoryBundle(staged) else { throw CocoaError(.fileReadCorruptFile) }
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                if renamex_np(staged.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                    occupied.insert(key)
                } else if errno == EEXIST {
                    occupied.insert(key)
                    problems.append(.alreadyInstalled(name))
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } catch {
                problems.append(.copyFailed(name, error.localizedDescription))
            }
        }
        return problems
    }
}
