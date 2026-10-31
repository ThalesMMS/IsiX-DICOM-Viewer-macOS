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
@testable import IsiXContracts

@Suite struct DICOMIngestingTests {
    @Test func everySourceHasAPresetAndNoNameRepeats() {
        #expect(Set(IngestPreset.all.map(\.source)) == Set(IngestSource.allCases))
        #expect(Set(IngestPreset.all.map(\.name)).count == IngestPreset.all.count)
    }

    // The transports leave their files for the scan: what they bring is
    // indexed with what the scan passes, whatever its name.
    @Test func whatTheTransportsPublishIsIndexedWithTheOptionsOfTheScan() {
        for preset in [IngestPreset.listener, .retrieve, .dicomweb, .wado] {
            #expect(preset.options == IngestPreset.incoming.options, "\(preset.name)")
        }
    }

    @Test func dicomOnlyResolvesAgainstThePreference() {
        #expect(IngestDicomOnly.always.resolved(preference: false))
        #expect(!IngestDicomOnly.never.resolved(preference: true))
        #expect(IngestDicomOnly.preference.resolved(preference: true))
        #expect(!IngestDicomOnly.preference.resolved(preference: false))
    }

    @Test func aDraftIsHiddenUntilItIsPublished() {
        let draft = IngestDraft(folder: IngestFolder(path: "/data/INCOMING.noindex"), name: "WADO-1.dcm")
        #expect(draft.path == "/data/INCOMING.noindex/.WADO-1.dcm")
        #expect(draft.folder.path(named: draft.name) == "/data/INCOMING.noindex/WADO-1.dcm")
    }

    @Test func aFolderOfNoDatabaseKeepsTheNameAlone() {
        #expect(IngestFolder(path: "").hiddenPath(named: "x") == ".x")
        #expect(IngestFolder(path: "").path(named: "x") == "x")
    }

    @Test func aPublicationSaysWhatTheRenameSaid() {
        let folder = IngestFolder(path: "/in")
        #expect(IngestPublication(errorNumber: 0, folder: folder).succeeded)
        #expect(!IngestPublication(errorNumber: ENOSPC, folder: folder).succeeded)
    }
}
