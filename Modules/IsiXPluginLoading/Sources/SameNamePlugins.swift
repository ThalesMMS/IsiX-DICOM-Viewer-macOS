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

/// The version a plugin bundle declares, compared as the update check compares
/// the versions of a catalog: numeric dotted releases, with the conventional
/// alpha, beta and rc suffixes, which come before the release they precede.
public struct PluginBundleVersion: Equatable, Sendable {
    /// The numbers of the release, without leading zeros.
    let release: [String]
    /// What follows the release ("rc.1", "b2"), or nothing.
    let suffix: String

    /// Nil for a text that is not a version of that form.
    public init?(_ text: String?) {
        guard let text, !text.isEmpty,
              let match = text.wholeMatch(of: #/([0-9]+(?:\.[0-9]+)*)(?:-([0-9A-Za-z][0-9A-Za-z.\-]*)|([A-Za-z][0-9A-Za-z.\-]*))?(?:\+[0-9A-Za-z.\-]+)?/#) else { return nil }
        release = match.1.split(separator: ".").map { part in
            let trimmed = part.drop { $0 == "0" }
            return trimmed.isEmpty ? "0" : String(trimmed)
        }
        suffix = String(match.2 ?? match.3 ?? "")
    }

    /// How two declared versions compare, or nil when either is missing or is
    /// not a version: such a pair is never said to be older or newer.
    public static func compare(_ left: String?, _ right: String?) -> ComparisonResult? {
        guard let a = PluginBundleVersion(left), let b = PluginBundleVersion(right) else { return nil }
        for index in 0..<max(a.release.count, b.release.count) {
            let x = index < a.release.count ? a.release[index] : "0"
            let y = index < b.release.count ? b.release[index] : "0"
            if x.count != y.count { return x.count < y.count ? .orderedAscending : .orderedDescending }
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        if a.suffix.isEmpty != b.suffix.isEmpty { return a.suffix.isEmpty ? .orderedDescending : .orderedAscending }
        return a.suffix.compare(b.suffix, options: [.numeric, .caseInsensitive])
    }

    /// The version the bundle at `url` declares in its Info.plist, read as a
    /// file: the bundle is not opened, and nothing of it is cached. The build
    /// version first, as the plugins list shows it.
    public static func declared(byBundleAt url: URL) -> String? {
        let candidates = [url.appendingPathComponent("Contents/Info.plist"), url.appendingPathComponent("Info.plist")]
        for file in candidates {
            guard let data = try? Data(contentsOf: file),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            for key in ["CFBundleVersion", "CFBundleShortVersionString"] {
                if let text = info[key] as? String, !text.isEmpty { return text }
            }
            return nil
        }
        return nil
    }
}

/// Which bundle stands for a plugin when several have its name.
///
/// A plugin is known by the name of its bundle without the extension: the
/// menus, the plugins list and the commands that activate or delete one all go
/// by it, so `Thing.horosplugin` and `Thing.osirixplugin` are one plugin, and
/// only one of them loads. Installers of plugins made for Horos or OsiriX leave
/// exactly that behind: a newer version under the other extension, beside the
/// old one or in another folder.
///
/// A bundle this Mac can load comes first: one the loader refuses before
/// opening it (no code for this process's architecture, as the Intel-only
/// build of a plugin left beside its universal successor, a newer system, a
/// missing executable, a signature that no longer validates) would be refused
/// after the one that loads had been set aside, and the plugin would load from
/// neither. Then the higher declared version stands for the plugin.
/// Between versions that are equal, or that cannot be compared, the choice is a
/// stated one, never the order a folder happens to list its entries in nor the
/// alphabet of the extensions: first the folder with the lower rank, which the
/// caller gives (the user's before the computer's, for one), then the format, a
/// plugin of the current API before one made for Horos and that before one for
/// OsiriX.
public enum SameNamePlugins {
    /// A bundle with the name of others.
    public struct Candidate: Equatable, Sendable {
        public var path: String
        /// The version it declares, if any.
        public var version: String?
        /// The rank of the folder it is in: lower is preferred between equal versions.
        public var folderRank: Int

        public init(path: String, version: String?, folderRank: Int) {
            self.path = path
            self.version = version
            self.folderRank = folderRank
        }
    }

    /// The name bundles of one plugin share: the file name without the
    /// extension, whatever its case and its Unicode normalization, as the
    /// Finder and APFS take it.
    public static func nameKey(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The order of the formats between bundles of equal version in one folder.
    public static func formatRank(_ path: String) -> Int {
        switch (path as NSString).pathExtension.lowercased() {
        case PluginContract.bundleExtension: return 0
        case "horosplugin": return 1
        case "osirixplugin": return 2
        default: return 3
        }
    }

    /// Whether this Mac can load the bundle at `path` by what its files say
    /// (PluginInspector), one of the checks the loader makes before opening a
    /// bundle: the bundle is not opened. The loader first refuses a bundle
    /// whose signature does not validate, which this does not check: the
    /// plugin manager passes the functions below a `canLoad` of its own that
    /// checks the signature too.
    public static func canLoad(bundleAt path: String) -> Bool {
        PluginInspector().inspect(bundleAt: URL(fileURLWithPath: path)).isLoadable
    }

    /// Whether `first` stands for the plugin rather than `second`. `canLoad`
    /// answers whether this Mac can load the bundle at a path.
    public static func isPreferred(_ first: Candidate, to second: Candidate,
                                   canLoad: (String) -> Bool = SameNamePlugins.canLoad(bundleAt:)) -> Bool {
        let firstLoads = canLoad(first.path), secondLoads = canLoad(second.path)
        if firstLoads != secondLoads { return firstLoads }
        if let order = PluginBundleVersion.compare(first.version, second.version), order != .orderedSame {
            return order == .orderedDescending
        }
        // One that declares a version before one that declares none or nonsense.
        let firstValid = PluginBundleVersion(first.version) != nil, secondValid = PluginBundleVersion(second.version) != nil
        if firstValid != secondValid { return firstValid }
        if first.folderRank != second.folderRank { return first.folderRank < second.folderRank }
        let firstFormat = formatRank(first.path), secondFormat = formatRank(second.path)
        if firstFormat != secondFormat { return firstFormat < secondFormat }
        return first.path < second.path
    }

    /// The candidate that stands for the plugin, whatever the order they are
    /// given in. Each bundle is inspected once.
    public static func preferred(among candidates: [Candidate],
                                 canLoad: (String) -> Bool = SameNamePlugins.canLoad(bundleAt:)) -> Candidate? {
        guard candidates.count > 1 else { return candidates.first }
        var loads: [String: Bool] = [:]
        for candidate in candidates where loads[candidate.path] == nil {
            loads[candidate.path] = canLoad(candidate.path)
        }
        return candidates.reduce(nil) { best, next in
            guard let best else { return next }
            return isPreferred(next, to: best, canLoad: { loads[$0] ?? false }) ? next : best
        }
    }

    /// One bundle set aside in favour of another of its name.
    public struct SetAside: Equatable, Sendable {
        public var bundle: Candidate
        public var preferred: Candidate
    }

    /// Among bundles of any names, those set aside because another of their
    /// name stands for the plugin. The rest are the ones to load or copy. Only
    /// bundles that share a name are inspected.
    public static func setAside(among candidates: [Candidate],
                                canLoad: (String) -> Bool = SameNamePlugins.canLoad(bundleAt:)) -> [SetAside] {
        let groups = Dictionary(grouping: candidates) { nameKey($0.path) }.filter { $0.value.count > 1 }
        let best = groups.compactMapValues { preferred(among: $0, canLoad: canLoad) }
        return candidates.compactMap { candidate in
            guard let chosen = best[nameKey(candidate.path)], chosen != candidate else { return nil }
            return SetAside(bundle: candidate, preferred: chosen)
        }
    }
}
