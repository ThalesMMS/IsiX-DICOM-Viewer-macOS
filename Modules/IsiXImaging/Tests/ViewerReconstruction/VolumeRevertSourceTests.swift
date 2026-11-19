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
@testable import IsiXImaging

// Where Revert Series in the VR window takes the volume back from. The window's
// part (whether its 2D viewer shows its slices, reading them from the files,
// the alert) is checked outside the package, in tests/.
@Suite struct VolumeRevertSourceTests {

    private func source(shows: Bool, postprocessed: Bool, fromFiles: Bool, copy: Bool) -> VolumeRevertSource {
        VolumeRevertSource(viewerShowsSlices: shows, viewerPostprocessed: postprocessed, slicesFromFiles: fromFiles,
                           hasFilterCopy: copy)
    }

    @Test func theViewerReadsTheSlicesItShowsAsReadFromTheirFiles() {
        for fromFiles in [false, true] {
            for copy in [false, true] {
                #expect(source(shows: true, postprocessed: false, fromFiles: fromFiles, copy: copy) == .viewerReadsFiles)
            }
        }
    }

    @Test func afterAChangeOfPlaneTheWindowReadsTheSlicesItKept() {
        // The 2D viewer shows resliced slices: it is post-processed, and the
        // window still has the slices of the files, filtered or not.
        for postprocessed in [false, true] {
            for copy in [false, true] {
                #expect(source(shows: false, postprocessed: postprocessed, fromFiles: true, copy: copy) == .windowReadsFiles)
            }
        }
    }

    @Test func slicesNotReadFromFilesComeBackFromTheCopyOrNothing() {
        // A window opened on a resliced series, after another change of plane.
        #expect(source(shows: false, postprocessed: true, fromFiles: false, copy: true) == .filterCopy)
        #expect(source(shows: false, postprocessed: true, fromFiles: false, copy: false) == .nothing)
        // A window opened on a resliced series the 2D viewer still shows: it
        // must not read the files, which hold other slices.
        #expect(source(shows: true, postprocessed: true, fromFiles: false, copy: true) == .filterCopy)
        #expect(source(shows: true, postprocessed: true, fromFiles: false, copy: false) == .nothing)
        // Slices of the files that the 2D viewer post-processed in place while
        // it showed them: the files would undo what the 2D viewer shows.
        #expect(source(shows: true, postprocessed: true, fromFiles: true, copy: true) == .filterCopy)
        #expect(source(shows: true, postprocessed: true, fromFiles: true, copy: false) == .nothing)
    }

    @Test func onlyAVolumeNotReadFromTheFilesKeepsChanges() {
        for source in [VolumeRevertSource.viewerReadsFiles, .windowReadsFiles] {
            #expect(source.readsFiles)
            for changed in [false, true] {
                for tilt in [false, true] {
                    #expect(!source.keepsChanges(changedWithoutCopy: changed, tiltCorrected: tilt))
                }
            }
        }
        for source in [VolumeRevertSource.filterCopy, .nothing] {
            #expect(!source.readsFiles)
            #expect(!source.keepsChanges(changedWithoutCopy: false, tiltCorrected: false))
            #expect(source.keepsChanges(changedWithoutCopy: true, tiltCorrected: false))
            #expect(source.keepsChanges(changedWithoutCopy: false, tiltCorrected: true))
        }
    }
}
