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
@testable import IsiXDICOMNetwork

/// What a DICOMweb node said about a request, for the user and for the log.
/// Every name, identifier and date here is made up.
struct DICOMwebNodeAnswerTests {
    @Test func theUserIsShownTheNodesWordsOnOneLine() {
        #expect(DICOMwebNodeAnswer.reason(code: "QIDO-400", warning: "299 node \"The fuzzymatching parameter is not supported.\"",
                                          body: "Unknown  patient\r\n\tDOE^JOHN\u{0}")
                == "error code QIDO-400; Warning: 299 node \"The fuzzymatching parameter is not supported.\"; Unknown patient DOE^JOHN")
        #expect(DICOMwebNodeAnswer.reason(code: nil, warning: nil, body: "no such study") == "no such study")
        #expect(DICOMwebNodeAnswer.reason(code: " \r\n", warning: "", body: nil) == nil)
        #expect(DICOMwebNodeAnswer.reason(code: nil, warning: nil, body: nil) == nil)
    }

    @Test func theLogIsToldAnErrorCodeOnlyWhenItHasTheFormOfOne() {
        #expect(DICOMwebNodeAnswer.logReason(code: "QIDO-400.bad_request", warning: nil, body: nil) == "error code QIDO-400.bad_request")
        // Words in place of a code, which may be the node quoting what it was sent.
        #expect(DICOMwebNodeAnswer.logReason(code: "DOE JOHN", warning: nil, body: nil) == "error code of 8 characters")
        #expect(DICOMwebNodeAnswer.logReason(code: "DOE^JOHN", warning: nil, body: nil) == "error code of 8 characters")
        #expect(DICOMwebNodeAnswer.logReason(code: "Jos\u{E9}", warning: nil, body: nil) == "error code of 4 characters")
        #expect(DICOMwebNodeAnswer.logReason(code: String(repeating: "A", count: 64), warning: nil, body: nil)
                == "error code " + String(repeating: "A", count: 64))
        #expect(DICOMwebNodeAnswer.logReason(code: String(repeating: "A", count: 65), warning: nil, body: nil)
                == "error code of 65 characters")
    }

    @Test func theLogIsToldAWarningByItsWarnCodeAndWhichOfTheSearchWarningsItIs() {
        #expect(DICOMwebNodeAnswer.logReason(code: nil, warning: "299 node \"The fuzzymatching parameter is not supported.\"", body: nil)
                == "Warning 299 (fuzzy matching not supported), 56 characters")
        #expect(DICOMwebNodeAnswer.logReason(code: nil, warning: "299 - \"There are additional results.\"", body: "x")
                == "Warning 299 (more results than the node returned), 37 characters; a body of 1 character")
        #expect(DICOMwebNodeAnswer.logReason(code: nil, warning: "299 - \"The results were truncated\"", body: nil)
                == "Warning 299 (more results than the node returned), 34 characters")
        #expect(DICOMwebNodeAnswer.logReason(code: nil, warning: "199", body: nil) == "Warning 199, 3 characters")
        // No warn-code: three digits that go on, or words.
        #expect(DICOMwebNodeAnswer.logReason(code: nil, warning: "2990 many", body: nil) == "Warning, 9 characters")
        #expect(DICOMwebNodeAnswer.logReason(code: nil, warning: "Unknown patient DOE^JOHN", body: nil) == "Warning, 24 characters")
    }

    @Test func theLogIsNeverToldTheNodesWords() throws {
        let said = "Unknown patient DOE^JOHN, born 19700101, identifier 12345"
        let logged = try #require(DICOMwebNodeAnswer.logReason(code: said, warning: said, body: said))
        #expect(logged == "error code of 57 characters; Warning, 57 characters; a body of 57 characters")
        for word in ["DOE", "JOHN", "19700101", "12345", "Unknown", "born"] {
            #expect(!logged.contains(word))
        }
    }

    @Test func aNodeThatSaidNothingIsNotLogged() {
        #expect(DICOMwebNodeAnswer.logReason(code: nil, warning: nil, body: nil) == nil)
        #expect(DICOMwebNodeAnswer.logReason(code: " ", warning: "\r\n", body: "\t") == nil)
        #expect(DICOMwebNodeAnswer.logReason(code: "DOE JOHN", warning: "Unknown patient DOE^JOHN", body: " \r\n")
                == "error code of 8 characters; Warning, 24 characters")
    }
}
