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

/// The comments of the study and of the series in the large description.
struct DescriptionInLargeCommentsTests {
    private func text(studyComment: String?, seriesComment: String?, limit: Int = DescriptionInLarge.commentLineLimit,
                      fits: (String) -> Bool = { _ in true }) -> String {
        DescriptionInLarge.text(patientName: "DOE^JANE", studyName: "CT HEAD", seriesName: "AXIAL 5mm", date: "03/11/2026 10:21",
                                openPatientNames: ["DOE^JANE", "ROE^JOHN"], openStudyNames: ["CT HEAD", "CT HEAD"],
                                studyComment: studyComment, seriesComment: seriesComment, commentLineLimit: limit, commentFits: fits)
    }

    private let identification = "DOE^JANE\r03/11/2026 10:21\rAXIAL 5mm"

    @Test func withoutACommentTheTextIsTheIdentificationAlone() {
        let plain = DescriptionInLarge.text(patientName: "DOE^JANE", studyName: "CT HEAD", seriesName: "AXIAL 5mm", date: "03/11/2026 10:21",
                                            openPatientNames: ["DOE^JANE", "ROE^JOHN"], openStudyNames: ["CT HEAD", "CT HEAD"])
        #expect(plain == identification)
        #expect(text(studyComment: nil, seriesComment: nil) == identification)
        #expect(DescriptionInLarge.commentLines(study: nil, series: nil).isEmpty)
    }

    @Test func aCommentThatIsOnlyWhiteSpaceIsNoComment() {
        for blank in ["", " ", "\t", "\n", " \r\n \u{A0}"] {
            #expect(text(studyComment: blank, seriesComment: blank) == identification, "\(blank.debugDescription)")
            #expect(text(studyComment: blank, seriesComment: nil) == identification)
            #expect(text(studyComment: nil, seriesComment: blank) == identification)
        }
        #expect(text(studyComment: "  urgent \n", seriesComment: " ") == identification + "\rurgent")
    }

    @Test func theCommentOfTheStudyAloneFollowsTheIdentification() {
        #expect(text(studyComment: "Compare with 2024", seriesComment: nil) == identification + "\rCompare with 2024")
    }

    @Test func theCommentOfTheSeriesAloneFollowsTheIdentification() {
        #expect(text(studyComment: nil, seriesComment: "Motion artefacts") == identification + "\rMotion artefacts")
    }

    @Test func theSameCommentInBothIsShownOnce() {
        #expect(text(studyComment: "Urgent", seriesComment: "Urgent") == identification + "\rUrgent")
        #expect(text(studyComment: "Urgent ", seriesComment: "\tUrgent\n") == identification + "\rUrgent")
    }

    @Test func differentCommentsAreBothShownTheStudyFirst() {
        #expect(text(studyComment: "Urgent", seriesComment: "Motion artefacts") == identification + "\rUrgent\rMotion artefacts")
        #expect(DescriptionInLarge.commentLines(study: "Urgent", series: "urgent") == ["Urgent", "urgent"])
    }

    @Test func aCommentAloneIsTheWholeTextWhenNothingIdentifiesTheSeries() {
        #expect(DescriptionInLarge.text(patientName: nil, studyName: nil, seriesName: nil, date: nil, openPatientNames: [], openStudyNames: [],
                                        studyComment: "Urgent") == "Urgent")
    }

    @Test func aLongCommentIsBrokenBetweenWordsWhereItStopsFitting() {
        let fits: (String) -> Bool = { $0.count <= 12 }
        #expect(DescriptionInLarge.commentLines(study: "Compare with the study of 2024", series: nil, fits: fits)
                == ["Compare with", "the study of", "2024"])
        #expect(DescriptionInLarge.commentLines(study: "one   two\tthree", series: nil, fits: fits) == ["one two", "three"])
    }

    @Test func theLineBreaksOfACommentAreKeptAndItsBlankLinesAreNot() {
        #expect(DescriptionInLarge.commentLines(study: "first\nsecond\r\nthird\r\r \rfourth", series: nil)
                == ["first", "second", "third", "fourth"])
        #expect(text(studyComment: "first\nsecond", seriesComment: nil) == identification + "\rfirst\rsecond")
    }

    @Test func aWordThatDoesNotFitAloneIsBrokenInside() {
        let fits: (String) -> Bool = { $0.count <= 5 }
        #expect(DescriptionInLarge.commentLines(study: "ab abcdefghijkl", series: nil, fits: fits) == ["ab", "abcde", "fghij", "kl"])
        // Nothing fits: one character a line, and the search still ends.
        #expect(DescriptionInLarge.commentLines(study: "abc", series: nil, fits: { _ in false }) == ["a", "b", "c"])
    }

    @Test func aCommentBeyondTheLimitOfLinesEndsInAnEllipsis() {
        let fits: (String) -> Bool = { $0.count <= 5 }
        #expect(DescriptionInLarge.commentLineLimit == 4)
        #expect(DescriptionInLarge.commentLines(study: "1\n2\n3\n4", series: nil) == ["1", "2", "3", "4"])
        #expect(DescriptionInLarge.commentLines(study: "1\n2\n3\n4\n5", series: nil) == ["1", "2", "3", "4…"])
        // The ellipsis takes its place inside the width.
        #expect(DescriptionInLarge.commentLines(study: "aaaaa bbbbb ccccc ddddd eeeee", series: nil, fits: fits)
                == ["aaaaa", "bbbbb", "ccccc", "dddd…"])
        #expect(DescriptionInLarge.commentLines(study: "aa bb cc dd ee ff", series: nil, limit: 2, fits: fits) == ["aa bb", "cc d…"])
        #expect(DescriptionInLarge.commentLines(study: String(repeating: "x", count: 100_000), series: nil, fits: fits)
                == ["xxxxx", "xxxxx", "xxxxx", "xxxx…"])
        #expect(DescriptionInLarge.commentLines(study: "1\n2", series: nil, limit: 0).isEmpty)
    }

    @Test func theLimitIsOfEachComment() {
        let lines = DescriptionInLarge.commentLines(study: "1\n2\n3\n4\n5", series: "a\nb\nc\nd\ne\nf")
        #expect(lines == ["1", "2", "3", "4…", "a", "b", "c", "d…"])
        #expect(text(studyComment: "1\n2", seriesComment: "a", limit: 1) == identification + "\r1…\ra")
    }
}
