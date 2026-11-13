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
@testable import IsiXDICOMFile

@Suite struct ViewerFileDropTests {

    typealias Drop = ViewerFileDrop

    private let windows: [Drop.Window] = [.viewer2D, .reconstruction]

    @Test func picturesBecomeASeriesInEveryWindow() {
        for window in windows {
            #expect(Drop.decision(for: ["/a/photo.jpg"], optionPressed: false, in: window) == .newSeries)
            #expect(Drop.decision(for: ["/a/photo.jpg", "/a/shot.PNG", "/a/scan.tiff"], optionPressed: false, in: window) == .newSeries)
        }
    }

    @Test func pdfsBecomeASeriesToo() {
        for window in windows {
            #expect(Drop.decision(for: ["/a/letter.pdf"], optionPressed: false, in: window) == .newSeries)
            #expect(Drop.decision(for: ["/a/letter.pdf", "/a/photo.jpg"], optionPressed: false, in: window) == .newSeries)
        }
    }

    @Test func optionKeepsTheLayerROIOfThe2DViewerOnly() {
        #expect(Drop.decision(for: ["/a/photo.jpg", "/a/shot.png"], optionPressed: true, in: .viewer2D) == .layerROI)
        #expect(Drop.decision(for: ["/a/letter.pdf"], optionPressed: true, in: .viewer2D) == .layerROI)
        // No other window lays a picture on its image.
        #expect(Drop.decision(for: ["/a/photo.jpg"], optionPressed: true, in: .reconstruction) == .newSeries)
    }

    @Test func roiFilesAndCurvedPathsStayTheWindowsOwn() {
        for window in windows {
            for option in [false, true] {
                for path in ["/a/marks.roi", "/a/all.rois_series", "/a/all.json", "/a/vessel.curvedPath"] {
                    #expect(Drop.decision(for: [path], optionPressed: option, in: window) == .windowsOwn, "\(path)")
                }
                // Beside a picture too: the window answers the whole drop as it did.
                #expect(Drop.decision(for: ["/a/photo.jpg", "/a/marks.roi"], optionPressed: option, in: window) == .windowsOwn)
                #expect(Drop.decision(for: ["/a/vessel.curvedPath", "/a/photo.png"], optionPressed: option, in: window) == .windowsOwn)
            }
        }
    }

    @Test func dicomFilesFoldersAndMixesStayTheWindowsOwn() {
        for window in windows {
            for paths in [["/a/IM0001.dcm"], ["/a/IM0001"], ["/a/folder"], ["/a/photo.jpg", "/a/IM0001.dcm"], ["/a/letter.pdf", "/a/folder"],
                          ["/a/movie.mov"], [String]()] {
                #expect(Drop.decision(for: paths, optionPressed: false, in: window) == .windowsOwn, "\(paths)")
            }
        }
    }

    @Test func aStudyTakesFilesUnlessItsDatabaseOrItselfRefuses() {
        #expect(Drop.refusal(hasStudy: true, databaseIsLocal: true, databaseIsReadOnly: false, studyIsDistant: false, studyIsLocked: false) == nil)
        #expect(Drop.refusal(hasStudy: false, databaseIsLocal: true, databaseIsReadOnly: false, studyIsDistant: false, studyIsLocked: false) == .noStudy)
        #expect(Drop.refusal(hasStudy: true, databaseIsLocal: false, databaseIsReadOnly: false, studyIsDistant: false, studyIsLocked: false) == .databaseNotLocal)
        #expect(Drop.refusal(hasStudy: true, databaseIsLocal: true, databaseIsReadOnly: true, studyIsDistant: false, studyIsLocked: false) == .databaseReadOnly)
        #expect(Drop.refusal(hasStudy: true, databaseIsLocal: true, databaseIsReadOnly: false, studyIsDistant: true, studyIsLocked: false) == .distantStudy)
        #expect(Drop.refusal(hasStudy: true, databaseIsLocal: true, databaseIsReadOnly: false, studyIsDistant: false, studyIsLocked: true) == .lockedStudy)
    }

    @Test func theDragIsAnsweredBeforeItIsDropped() {
        let pictures = ["/a/photo.jpg", "/a/shot.png"]
        for window in windows {
            #expect(Drop.answer(for: pictures, optionPressed: false, in: window, sourceAllowsCopy: true, refusal: nil) == .copy)
            // A study that takes no files refuses while the files are still over the window.
            for refusal in [Drop.Refusal.noStudy, .databaseNotLocal, .databaseReadOnly, .distantStudy, .lockedStudy] {
                #expect(Drop.answer(for: pictures, optionPressed: false, in: window, sourceAllowsCopy: true, refusal: refusal) == .refuse)
            }
            #expect(Drop.answer(for: pictures, optionPressed: false, in: window, sourceAllowsCopy: false, refusal: nil) == .refuse)
            #expect(Drop.answer(for: ["/a/marks.roi"], optionPressed: false, in: window, sourceAllowsCopy: true, refusal: .databaseReadOnly) == .windowsOwn)
            #expect(Drop.answer(for: ["/a/IM0001.dcm", "/a/photo.jpg"], optionPressed: false, in: window, sourceAllowsCopy: true, refusal: nil) == .windowsOwn)
        }
    }

    @Test func aLayerROINeedsNoStudyThatTakesFiles() {
        // Nothing is written: a read-only database does not refuse it, and the study is not asked.
        var asked = false
        func refusal() -> Drop.Refusal? {
            asked = true
            return .databaseReadOnly
        }
        #expect(Drop.answer(for: ["/a/photo.jpg"], optionPressed: true, in: .viewer2D, sourceAllowsCopy: true, refusal: refusal()) == .copy)
        #expect(!asked)
        // A source that offers no copy is answered as the viewer always answered.
        #expect(Drop.answer(for: ["/a/photo.jpg"], optionPressed: true, in: .viewer2D, sourceAllowsCopy: false, refusal: nil) == .windowsOwn)
    }

    @Test func theWindowsOwnDropsDoNotAskTheStudy() {
        var asked = false
        func refusal() -> Drop.Refusal? {
            asked = true
            return nil
        }
        #expect(Drop.answer(for: ["/a/vessel.curvedPath"], optionPressed: false, in: .reconstruction, sourceAllowsCopy: true, refusal: refusal()) == .windowsOwn)
        #expect(!asked)
    }
}
