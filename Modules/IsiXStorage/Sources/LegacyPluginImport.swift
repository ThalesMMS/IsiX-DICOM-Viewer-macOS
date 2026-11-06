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

public struct LegacyPluginImport {
    public enum Problem: Equatable {
        case alreadyInstalled(String)
        case copyFailed(String, String)
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

    /// Offers the user a single choice once there are plugins to copy. The
    /// saved selection also lets an interrupted copy resume without asking
    /// again or adding bundles that appeared after the offer.
    public func offerIfNeeded(isPlugin: (String) -> Bool, shouldCopy: ([String]) -> Bool) throws -> [Problem] {
        let saved = try readChoice()
        if saved?.isEmpty == true { return [] }
        let candidates = saved ?? findCandidates(isPlugin: isPlugin)
        guard !candidates.isEmpty else { return [] }

        let files = FileManager.default
        try files.createDirectory(at: support, withIntermediateDirectories: true)
        let fd = open(support.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return [] }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        let selection: [Candidate]
        if let saved = try readChoice() {
            selection = saved
        } else {
            selection = shouldCopy(candidates.map { $0.source.lastPathComponent }) ? candidates : []
            try saveChoice(selection)
        }
        guard !selection.isEmpty else { return [] }

        let problems = try copy(selection, isPlugin: isPlugin)
        try saveChoice([])
        return problems
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

    private func entries(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                      options: .skipsHiddenFiles)) ?? []
    }

    private func isDirectoryBundle(_ url: URL) -> Bool {
        guard let attributes = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return attributes.isDirectory == true && attributes.isSymbolicLink == false
    }

    private func findCandidates(isPlugin: (String) -> Bool) -> [Candidate] {
        [userDomain, systemDomain].flatMap { domain in
            [true, false].flatMap { active in
                StorageLocations.pluginImportFolders(inDomain: domain, active: active).flatMap { folder in
                    entries(in: folder).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
                        guard isPlugin(url.lastPathComponent), isDirectoryBundle(url) else { return nil }
                        return Candidate(source: url, active: active)
                    }
                }
            }
        }
    }

    private func nameKey(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func copy(_ selection: [Candidate], isPlugin: (String) -> Bool) throws -> [Problem] {
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
