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
@testable import IsiXPreferences

/// The first entry of each list of compression settings stays the default.
@Suite struct CompressionSettingsNormalizationTests {
    private let factory = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:]

    @Test func theFactoryListsAreLeftAlone() {
        let preferences = MemoryPreferences(registered: factory)
        CompressionSettingsNormalization.normalize(in: preferences, defaultModality: "default")
        #expect(preferences.writes.isEmpty)
    }

    @Test func theFirstEntryIsTheDefaultAgain() throws {
        let list: [[String: Any]] = [["modality": "CT", "compression": "0", "quality": "1"], ["modality": "MR", "compression": "0"]]
        let low: [[String: Any]] = [["modality": "default", "compression": 0, "quality": "0"]]
        let preferences = MemoryPreferences(["CompressionSettings": list, "CompressionSettingsLowRes": low], registered: factory)
        CompressionSettingsNormalization.normalize(in: preferences, defaultModality: "padrão")
        let written = try #require(preferences.object(forKey: "CompressionSettings") as? [[String: Any]])
        #expect(written[0]["modality"] as? String == "padrão")
        #expect(written[0]["compression"] as? String == "1")
        #expect(written[0]["quality"] as? String == "1")
        #expect(written[1]["modality"] as? String == "MR" && written.count == 2)
        let writtenLow = try #require(preferences.object(forKey: "CompressionSettingsLowRes") as? [[String: Any]])
        #expect(writtenLow[0]["modality"] as? String == "padrão" && writtenLow[0]["compression"] as? String == "1")

        // Only the name: the compression stays as it was.
        let named = MemoryPreferences(["CompressionSettings": [["modality": "CT", "compression": "4"]]], registered: factory)
        CompressionSettingsNormalization.normalize(in: named, defaultModality: "default")
        let entry = try #require((named.object(forKey: "CompressionSettings") as? [[String: Any]])?.first)
        #expect(entry["compression"] as? String == "4" && entry["modality"] as? String == "default")
        #expect(named.writes == ["CompressionSettings"])
    }

    @Test func anEmptyListIsNotWrittenAndAMissingOneIsRemoved() {
        let empty = MemoryPreferences(["CompressionSettings": [Any](), "CompressionSettingsLowRes": [Any]()])
        CompressionSettingsNormalization.normalize(in: empty, defaultModality: "default")
        #expect(empty.writes.isEmpty)
        let missing = MemoryPreferences()
        CompressionSettingsNormalization.normalize(in: missing, defaultModality: "default")
        #expect(missing.writes == ["CompressionSettings", "CompressionSettingsLowRes"])
    }
}
