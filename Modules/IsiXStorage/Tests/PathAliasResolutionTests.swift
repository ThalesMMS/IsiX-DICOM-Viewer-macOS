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
import Testing
@testable import IsiXStorage

/// A folder of links and aliases with no link in its own path, so that what a
/// path resolves to can be compared as it is written.
final class LinkFolder {
    let root: URL

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        guard let real = realpath(made.path, nil) else { throw POSIXError(.ENOENT) }
        defer { free(real) }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    /// One spelling for the paths to an item: the resolution answers a path
    /// that leads to it, with or without the /private of the temporary folder.
    static func real(_ path: String?) -> String? {
        path.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    @discardableResult func folder(_ name: String) throws -> String {
        try FileManager.default.createDirectory(atPath: path(name), withIntermediateDirectories: true)
        return path(name)
    }

    @discardableResult func file(_ name: String) throws -> String {
        try FileManager.default.createDirectory(atPath: (path(name) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: URL(fileURLWithPath: path(name)))
        return path(name)
    }

    /// A symbolic link at `name` that names `target` as written.
    @discardableResult func link(_ name: String, to target: String) throws -> String {
        try FileManager.default.createDirectory(atPath: (path(name) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path(name), withDestinationPath: target)
        return path(name)
    }

    /// A Finder alias at `name` to the existing item at `target`.
    @discardableResult func alias(_ name: String, to target: String) throws -> String {
        try FileManager.default.createDirectory(atPath: (path(name) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let bookmark = try URL(fileURLWithPath: target).bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(bookmark, to: URL(fileURLWithPath: path(name)))
        return path(name)
    }

    /// A Finder alias at `name` whose original is gone.
    @discardableResult func deadAlias(_ name: String) throws -> String {
        let original = try folder(name + " original")
        try alias(name, to: original)
        try FileManager.default.removeItem(atPath: original)
        return path(name)
    }
}

@Suite struct PathAliasResolutionTests {
    /// Links that lead back to one another used to be followed for ever, and
    /// the launch that read a plugins folder holding them never finished.
    @Test(.timeLimit(.minutes(1))) func linksThatLeadBackToOneAnotherCannotBeFollowed() throws {
        let folder = try LinkFolder()
        let first = try folder.link("A.osirixplugin", to: folder.path("B.osirixplugin"))
        let second = try folder.link("B.osirixplugin", to: folder.path("A.osirixplugin"))
        let relative = try folder.link("C.osirixplugin", to: "D.osirixplugin")
        try folder.link("D.osirixplugin", to: "C.osirixplugin")
        let itself = try folder.link("Itself.osirixplugin", to: "Itself.osirixplugin")
        let itselfAbsolute = try folder.link("Same.osirixplugin", to: folder.path("Same.osirixplugin"))
        for path in [first, second, relative, itself, itselfAbsolute] {
            #expect((path as NSString).byIterativelyResolvingSymlinkOrAlias() == nil, "\(path)")
            #expect((path as NSString).resolvingSymlinksAndAliases() == nil, "\(path)")
            // Also as a folder on the way to something else.
            #expect(((path as NSString).appendingPathComponent("Contents/Info.plist") as NSString).resolvingSymlinksAndAliases() == nil, "\(path)")
        }
    }

    /// As many links in a row as the system itself follows still resolve.
    @Test(.timeLimit(.minutes(1))) func aLongChainOfLinksIsFollowedToItsEnd() throws {
        let folder = try LinkFolder()
        let end = try folder.folder("End.osirixplugin")
        var target = "End.osirixplugin"
        for index in 1...Int(MAXSYMLINKS) {
            try folder.link("Link \(index)", to: target)
            target = "Link \(index)"
        }
        #expect(LinkFolder.real((folder.path(target) as NSString).resolvingSymlinksAndAliases()) == LinkFolder.real(end))
        try folder.link("One too many", to: target)
        #expect((folder.path("One too many") as NSString).resolvingSymlinksAndAliases() == nil)
    }

    @Test func aLinkToNothingCannotBeFollowed() throws {
        let folder = try LinkFolder()
        let absolute = try folder.link("Gone.osirixplugin", to: folder.path("Removed.osirixplugin"))
        let relative = try folder.link("gone", to: "../nowhere/Removed.osirixplugin")
        for path in [absolute, relative] {
            #expect((path as NSString).byIterativelyResolvingSymlinkOrAlias() == nil)
            #expect((path as NSString).resolvingSymlinksAndAliases() == nil)
        }
    }

    /// An alias whose original is gone is answered as the alias file it is:
    /// the callers that need to know look at what the path they got is.
    @Test func anAliasWhoseOriginalIsGoneResolvesToItself() throws {
        let folder = try LinkFolder()
        let alias = try folder.deadAlias("Dead.osirixplugin")
        #expect((alias as NSString).byIterativelyResolvingSymlinkOrAlias() == alias)
        #expect((alias as NSString).resolvingSymlinksAndAliases() == alias)
        #expect((alias as NSString).resolvingAlias() == alias)
    }

    @Test func aRelativeLinkLeadsToWhatItNamesFromItsOwnFolder() throws {
        let folder = try LinkFolder()
        let bundle = try folder.folder("OsiriX/Plugins/QA.osirixplugin")
        let link = try folder.link("Horos/Plugins/QA.osirixplugin", to: "../../OsiriX/Plugins/QA.osirixplugin")
        #expect(LinkFolder.real((link as NSString).resolvingSymlinksAndAliases()) == LinkFolder.real(bundle))
        let beside = try folder.link("OsiriX/Plugins/Again.osirixplugin", to: "QA.osirixplugin")
        #expect(LinkFolder.real((beside as NSString).resolvingSymlinksAndAliases()) == LinkFolder.real(bundle))
        // And an alias to it, and a link to that alias.
        let alias = try folder.alias("Horos/Plugins/QA alias", to: bundle)
        #expect(LinkFolder.real((alias as NSString).resolvingSymlinksAndAliases()) == LinkFolder.real(bundle))
        let linkToAlias = try folder.link("Horos/Plugins/Through.osirixplugin", to: "QA alias")
        #expect(LinkFolder.real((linkToAlias as NSString).resolvingSymlinksAndAliases()) == LinkFolder.real(bundle))
    }
}
