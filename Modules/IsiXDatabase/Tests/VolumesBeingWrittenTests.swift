//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
@testable import IsiXDatabase

@Suite struct VolumesBeingWrittenTests {
    @Test func noVolumeIsBeingWrittenAtFirst() {
        let volumes = VolumesBeingWritten()
        #expect(!volumes.contains("/Volumes/KEY"))
        #expect(!volumes.contains(nil))
    }

    /// The copy ends with the volume renamed after the medium, and then again
    /// when the file system refused the name.
    @Test func aVolumeBeingWrittenIsFollowedThroughItsRenames() {
        var volumes = VolumesBeingWritten()
        volumes.begin("/Volumes/KEY")
        #expect(volumes.contains("/Volumes/KEY"))
        volumes.renamed(from: "/Volumes/KEY", to: "/Volumes/CHEST STUDY")
        #expect(!volumes.contains("/Volumes/KEY"))
        #expect(volumes.contains("/Volumes/CHEST STUDY"))
        volumes.renamed(from: "/Volumes/CHEST STUDY", to: "/Volumes/DICOM")
        #expect(volumes.contains("/Volumes/DICOM"))
    }

    @Test func theRenameOfAnotherVolumeChangesNothing() {
        var volumes = VolumesBeingWritten()
        volumes.begin("/Volumes/KEY")
        volumes.renamed(from: "/Volumes/DISC", to: "/Volumes/ARCHIVE")
        volumes.renamed(from: nil, to: "/Volumes/ARCHIVE")
        #expect(volumes.contains("/Volumes/KEY"))
        #expect(!volumes.contains("/Volumes/ARCHIVE"))
    }

    /// The key written, ejected and put back in is a disc that arrived.
    @Test func anUnmountedVolumeIsNotBeingWrittenAnyMore() {
        var volumes = VolumesBeingWritten()
        volumes.begin("/Volumes/KEY")
        volumes.renamed(from: "/Volumes/KEY", to: "/Volumes/DICOM")
        volumes.unmounted("/Volumes/OTHER")
        #expect(volumes.contains("/Volumes/DICOM"))
        volumes.unmounted("/Volumes/DICOM")
        #expect(!volumes.contains("/Volumes/DICOM"))
        #expect(volumes == VolumesBeingWritten())
    }

    /// A writing that failed leaves the volume mounted: it is let go all the same.
    @Test func theEndOfTheWritingLetsEveryVolumeGo() {
        var volumes = VolumesBeingWritten()
        volumes.begin("/Volumes/KEY")
        volumes.renamed(from: "/Volumes/KEY", to: "/Volumes/DICOM")
        volumes.end()
        #expect(!volumes.contains("/Volumes/DICOM"))
        #expect(!volumes.contains("/Volumes/KEY"))
    }
}
