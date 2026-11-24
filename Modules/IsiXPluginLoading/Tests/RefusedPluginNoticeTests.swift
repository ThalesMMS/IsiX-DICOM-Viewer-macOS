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

@Suite struct RefusedPluginNoticeTests {
    private let folder = "/Users/somebody/Library/Application Support/IsiX/Plugins/"
    private let reason = "The plugin is built for x86_64; this application runs as arm64. Obtain a plugin built for arm64."

    private func refusal(_ name: String, _ version: String?) -> RefusedPluginNotice.Refusal {
        .init(path: folder + name, version: version, reason: reason)
    }

    private func notice() throws -> (RefusedPluginNotice, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (RefusedPluginNotice(recordURL: directory.appendingPathComponent(RefusedPluginNotice.recordName)), directory)
    }

    @Test func aRefusedPluginIsSaidOnceForItsVersion() throws {
        let (notice, directory) = try notice()
        defer { try? FileManager.default.removeItem(at: directory) }
        let intelOnly = refusal("MRHeart.osirixplugin", "0.9.3")
        #expect(notice.take([intelOnly]) == [intelOnly])
        #expect(notice.take([intelOnly]).isEmpty)
        #expect(intelOnly.name == "MRHeart.osirixplugin")
        // A new version of the same bundle, still refused, is said again.
        let next = refusal("MRHeart.osirixplugin", "0.9.4")
        #expect(notice.take([next]) == [next])
        #expect(notice.take([next]).isEmpty)
    }

    @Test func onlyTheNewRefusalsAreSaidInTheirOrder() throws {
        let (notice, directory) = try notice()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = refusal("First.horosplugin", nil)
        let second = refusal("Second.osirixplugin", "2")
        let third = refusal("Third.isixplugin", "1.0")
        #expect(notice.take([first]) == [first])
        #expect(notice.take([third, first, second]) == [third, second])
    }

    @Test func aPluginThatLoadedInBetweenIsSaidAgain() throws {
        let (notice, directory) = try notice()
        defer { try? FileManager.default.removeItem(at: directory) }
        let plugin = refusal("Thing.osirixplugin", "1")
        #expect(notice.take([plugin]) == [plugin])
        // A launch where it loads (no refusal) clears the record.
        #expect(notice.take([]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: notice.recordURL.path))
        #expect(notice.take([plugin]) == [plugin])
    }

    @Test func anUnreadableRecordCountsAsEmpty() throws {
        let (notice, directory) = try notice()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: notice.recordURL)
        let plugin = refusal("Thing.osirixplugin", "1")
        #expect(notice.take([plugin]) == [plugin])
        #expect(notice.take([plugin]).isEmpty)
    }

    @Test func foreignArchitecturesAreThoseOfAnArchitectureRefusal() {
        let url = URL(fileURLWithPath: folder + "MRHeart.osirixplugin")
        let intelOnly = PluginInspection(bundleURL: url, manifest: nil,
                                         diagnostics: [.architectureMismatch(found: ["x86_64"], required: "arm64")])
        #expect(intelOnly.foreignArchitectures == ["x86_64"])
        let newerSystem = PluginInspection(bundleURL: url, manifest: nil,
                                           diagnostics: [.requiresNewerSystem(required: "27.0", running: "26.0")])
        #expect(newerSystem.foreignArchitectures == nil)
        #expect(PluginInspection(bundleURL: url, manifest: nil, diagnostics: []).foreignArchitectures == nil)
    }
}
