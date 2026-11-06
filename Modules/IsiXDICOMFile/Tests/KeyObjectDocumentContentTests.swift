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
@testable import IsiXDICOMFile

@Suite struct KeyObjectDocumentContentTests {

    typealias Content = KeyObjectDocumentContent

    static let study = "1.2.826.0.1.3680043.8.498.10"
    static let ct = "1.2.840.10008.5.1.4.1.1.2"
    static let enhancedMR = "1.2.840.10008.5.1.4.1.1.4.1"

    func image(_ instance: String?, series: String? = "1.2.3.1", seriesNumber: Int = 1, instanceNumber: Int = 1,
               sopClass: String? = ct, study: String? = KeyObjectDocumentContentTests.study, frame: Int = 0,
               frames: Int = 1, key: Bool = true, picture: Bool = true) -> Content.Image {
        Content.Image(studyInstanceUID: study, seriesInstanceUID: series, sopClassUID: sopClass, sopInstanceUID: instance,
                      frameIndex: frame, numberOfFrames: frames, seriesNumber: seriesNumber, instanceNumber: instanceNumber,
                      isKeyImage: key, isPicture: picture)
    }

    @Test func theDocumentIsAKeyObjectSelectionOfInterest() {
        #expect(Content.sopClassUID == "1.2.840.10008.5.1.4.1.1.88.59")
        #expect(Content.sopClassUID == DICOMSOPClass.keyObjectSelectionDocumentStorage())
        #expect(Content.documentTitle == Content.Code(value: "113000", scheme: "DCM", meaning: "Of Interest"))
        let tree = Content.tree(of: [])
        #expect(tree.title == Content.documentTitle)
        #expect(tree.templateIdentifier == "2010" && tree.mappingResource == "DCMR")
    }

    @Test func keyImagesComeFromEverySeriesOfTheStudy() {
        let images = [
            image("1.2.3.2.1", series: "1.2.3.2", seriesNumber: 2, instanceNumber: 1),
            image("1.2.3.1.2", series: "1.2.3.1", seriesNumber: 1, instanceNumber: 2),
            image("1.2.3.1.1", series: "1.2.3.1", seriesNumber: 1, instanceNumber: 1, key: false),
            image("1.2.3.1.3", series: "1.2.3.1", seriesNumber: 1, instanceNumber: 3),
        ]
        let references = Content.keyImages(images, inStudy: Self.study)
        #expect(references.map(\.sopInstanceUID) == ["1.2.3.1.2", "1.2.3.1.3", "1.2.3.2.1"])
        #expect(references.map(\.seriesInstanceUID) == ["1.2.3.1", "1.2.3.1", "1.2.3.2"])
        #expect(references.allSatisfy { $0.studyInstanceUID == Self.study && $0.sopClassUID == Self.ct && $0.frames.isEmpty })
    }

    @Test func documentsOtherStudiesAndImagesWithoutUIDsAreLeftOut() {
        let images = [
            image("1.2.3.9.1", sopClass: "1.2.840.10008.5.1.4.1.1.88.22", picture: false),
            image("1.2.3.8.1", study: "1.2.3.999"),
            image(nil),
            image(""),
            image("1.2.3.7.1", series: nil),
            image("1.2.3.7.2", sopClass: ""),
            image("1.2.3.1.1"),
        ]
        #expect(Content.keyImages(images, inStudy: Self.study).map(\.sopInstanceUID) == ["1.2.3.1.1"])
        #expect(Content.keyImages([image("1.2.3.1.1", key: false)], inStudy: Self.study).isEmpty)
    }

    @Test func theKeyFramesOfAMultiFrameObjectAreOneReference() {
        let some = [0, 4, 2, 4].map { image("1.2.3.5.1", sopClass: Self.enhancedMR, frame: $0, frames: 6) }
        let partial = Content.keyImages(some, inStudy: Self.study)
        #expect(partial.count == 1)
        #expect(partial.first?.frames == [1, 3, 5])
        #expect(partial.first?.framesText == "1,3,5")

        let every = (0..<3).map { image("1.2.3.5.1", sopClass: Self.enhancedMR, frame: $0, frames: 3) }
        let whole = Content.keyImages(every, inStudy: Self.study)
        #expect(whole.first?.frames == [])
        #expect(whole.first?.framesText == nil)
    }

    @Test func theEvidenceGroupsTheInstancesBySeries() {
        let references = [
            Content.Reference(studyInstanceUID: Self.study, seriesInstanceUID: "1.2.3.1", sopClassUID: Self.ct, sopInstanceUID: "1.2.3.1.1"),
            Content.Reference(studyInstanceUID: Self.study, seriesInstanceUID: "1.2.3.2", sopClassUID: Self.enhancedMR,
                              sopInstanceUID: "1.2.3.2.1", frames: [2]),
            Content.Reference(studyInstanceUID: Self.study, seriesInstanceUID: "1.2.3.1", sopClassUID: Self.ct, sopInstanceUID: "1.2.3.1.2"),
            Content.Reference(studyInstanceUID: Self.study, seriesInstanceUID: "1.2.3.1", sopClassUID: Self.ct, sopInstanceUID: "1.2.3.1.1"),
        ]
        let evidence = Content.evidence(of: references)
        #expect(evidence.count == 1)
        #expect(evidence.first?.studyInstanceUID == Self.study)
        #expect(evidence.first?.series.map(\.seriesInstanceUID) == ["1.2.3.1", "1.2.3.2"])
        #expect(evidence.first?.series.first?.instances == [
            Content.Instance(sopClassUID: Self.ct, sopInstanceUID: "1.2.3.1.1"),
            Content.Instance(sopClassUID: Self.ct, sopInstanceUID: "1.2.3.1.2"),
        ])
        #expect(evidence.first?.series.last?.instances == [Content.Instance(sopClassUID: Self.enhancedMR, sopInstanceUID: "1.2.3.2.1")])
        #expect(Content.evidence(of: []).isEmpty)
    }

    @Test func theTreeListsTheReferencesInOrder() {
        let images = [image("1.2.3.1.2", instanceNumber: 2), image("1.2.3.1.1", instanceNumber: 1)]
        let references = Content.keyImages(images, inStudy: Self.study)
        #expect(Content.tree(of: references).images == references)
    }

    @Test func theNewSeriesIsNumberedAfterTheStudysOwn() {
        #expect(Content.seriesNumber(after: []) == 1)
        #expect(Content.seriesNumber(after: [1, 3, 2]) == 4)
        #expect(Content.seriesNumber(after: [2, 5002, 5003, 5004, 5006]) == 3)
        #expect(Content.seriesNumber(after: [5004]) == 1)
        #expect(Content.seriesNumber(after: [7000]) == 7001)
    }

    @Test func aDocumentReadsBackWithItsTitleAndItsImagesInOrder() {
        let references = Content.keyImages([image("1.2.3.1.1", instanceNumber: 1), image("1.2.3.1.2", instanceNumber: 2)],
                                           inStudy: Self.study)
        #expect(Content.readsBack(title: "Of Interest", instances: ["1.2.3.1.1", "1.2.3.1.2"], as: references))
        #expect(!Content.readsBack(title: "Of Interest", instances: ["1.2.3.1.2", "1.2.3.1.1"], as: references))
        #expect(!Content.readsBack(title: "Of Interest", instances: ["1.2.3.1.1"], as: references))
        #expect(!Content.readsBack(title: "For Teaching", instances: ["1.2.3.1.1", "1.2.3.1.2"], as: references))
        #expect(!Content.readsBack(title: nil, instances: [], as: []))
    }
}
