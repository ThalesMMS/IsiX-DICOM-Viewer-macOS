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
import IsiXDatabase

@Suite struct KeyObjectSelectionMarkingTests {

    private typealias Marking = KeyObjectSelectionMarking

    private static let ofInterest = Marking.Title(value: "113000", scheme: "DCM", meaning: "Of Interest")
    private static let forTeaching = Marking.Title(value: "113004", scheme: "DCM", meaning: "For Teaching")
    private static let study: Set<String> = ["1.1", "1.2", "1.3", "1.4"]

    private func document(_ title: Marking.Title?, _ references: [String], new: Bool) -> Marking.Document {
        Marking.Document(title: title, referencedInstances: references, isNew: new)
    }

    @Test func aNewDocumentMarksTheImagesTheStudyAlreadyHas() {
        let documents = [document(Self.ofInterest, ["1.1", "1.3", "9.9"], new: true)]
        #expect(Marking.instancesToMark(documents: documents, newInstances: [], studyInstances: Self.study) == ["1.1", "1.3"])
    }

    @Test func imagesThatArriveAfterTheDocumentAreMarkedWhenTheyArrive() {
        let documents = [document(Self.ofInterest, ["1.1", "1.3", "9.9"], new: false)]
        #expect(Marking.instancesToMark(documents: documents, newInstances: ["1.3", "1.4"], studyInstances: Self.study) == ["1.3"])
    }

    @Test func bothOrdersMarkTheSameImages() {
        let references = ["1.2", "1.4"]
        let documentFirst = Marking.instancesToMark(documents: [document(Self.ofInterest, references, new: false)],
                                                    newInstances: Self.study, studyInstances: Self.study)
        let imagesFirst = Marking.instancesToMark(documents: [document(Self.ofInterest, references, new: true)],
                                                  newInstances: [], studyInstances: Self.study)
        let together = Marking.instancesToMark(documents: [document(Self.ofInterest, references, new: true)],
                                               newInstances: Self.study, studyInstances: Self.study)
        #expect(documentFirst == ["1.2", "1.4"])
        #expect(imagesFirst == documentFirst)
        #expect(together == documentFirst)
    }

    @Test func anOldDocumentIsNotAppliedAgainToTheImagesItMetBefore() {
        // 1.1 was marked when the document came, and the user took it out since.
        let documents = [document(Self.ofInterest, ["1.1", "1.2"], new: false)]
        #expect(Marking.instancesToMark(documents: documents, newInstances: ["1.4"], studyInstances: Self.study).isEmpty)
    }

    @Test func otherTitlesAndUnreadDocumentsMarkNothing() {
        let documents = [document(Self.forTeaching, ["1.1"], new: true), document(nil, ["1.2"], new: true),
                         document(Marking.Title(value: "113000", scheme: "99LOCAL", meaning: "Of Interest"), ["1.3"], new: true),
                         document(Self.forTeaching, ["1.4"], new: false)]
        #expect(Marking.instancesToMark(documents: documents, newInstances: Self.study, studyInstances: Self.study).isEmpty)
    }

    @Test func theTitleIsToldByItsCodeNotItsMeaning() {
        #expect(Marking.isOfInterest(Marking.Title(value: "113000", scheme: "DCM", meaning: "Of interest")))
        #expect(Marking.isOfInterest(Marking.Title(value: "113000 ", scheme: "DCM", meaning: "")))
        #expect(!Marking.isOfInterest(Marking.Title(value: "113004", scheme: "DCM", meaning: "Of Interest")))
        #expect(!Marking.isOfInterest(nil))
    }

    @Test func theReaderCodeMakesATitle() {
        #expect(Marking.Title(code: ["113000", "DCM", "Of Interest"]) == Self.ofInterest)
        #expect(Marking.Title(code: ["113000", "DCM"]) == nil)
        #expect(Marking.Title(code: []) == nil)
    }

    @Test func severalDocumentsAddUp() {
        let documents = [document(Self.ofInterest, ["1.1"], new: true), document(Self.ofInterest, ["1.4", "1.2"], new: false)]
        #expect(Marking.instancesToMark(documents: documents, newInstances: ["1.2"], studyInstances: Self.study) == ["1.1", "1.2"])
    }
}
