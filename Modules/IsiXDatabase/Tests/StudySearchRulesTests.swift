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
@testable import IsiXDatabase

// The predicate of the study list for each item of the search field's menu,
// as the browser wrote its format before the rules left it.
@Suite struct StudySearchRulesTests {
    /// The patient's name, as the browser's name predicate stands in here.
    let name: (String) -> NSPredicate? = { NSPredicate(format: "name LIKE %@", $0) }

    func format(_ type: Int, _ string: String?) -> String? {
        StudySearchRules.filterPredicate(searchString: string, searchType: type, namePredicate: name)?.predicateFormat
    }

    @Test func oneAttributeFields() {
        let expected: [Int: String] = [
            1: "patientID CONTAINS[cd] \"ab\"",
            2: "id CONTAINS[cd] \"ab\"",
            3: "comment CONTAINS[cd] \"ab\"",
            4: "studyName CONTAINS[cd] \"ab\"",
            5: "modality CONTAINS[cd] \"ab\"",
            6: "accessionNumber CONTAINS[cd] \"ab\"",
            8: "comment2 CONTAINS[cd] \"ab\"",
            9: "comment3 CONTAINS[cd] \"ab\"",
            10: "comment4 CONTAINS[cd] \"ab\"",
            11: "ANY series.name CONTAINS[cd] \"ab\"",
        ]
        for (type, predicate) in expected {
            #expect(format(type, "ab") == predicate)
            let former = NSPredicate(format: predicate.replacingOccurrences(of: "\"ab\"", with: "%@"), "ab" as NSString)
            #expect(format(type, "ab") == former.predicateFormat)
        }
    }

    @Test func nameAllFieldsAndNone() {
        #expect(format(0, "Doe") == "name LIKE \"Doe\"")
        // Fewer than three characters search the name only.
        #expect(format(7, "Do") == "name LIKE \"Do\"")
        let all = NSPredicate(format: "(name CONTAINS[cd] %@) OR (patientID CONTAINS[cd] %@) OR (id CONTAINS[cd] %@) OR (comment CONTAINS[cd] %@) OR (comment2 CONTAINS[cd] %@) OR (comment3 CONTAINS[cd] %@) OR (comment4 CONTAINS[cd] %@) OR (studyName CONTAINS[cd] %@) OR (modality CONTAINS[cd] %@) OR (accessionNumber CONTAINS[cd] %@) OR (performingPhysician CONTAINS[cd] %@) OR (referringPhysician CONTAINS[cd] %@) OR (institutionName CONTAINS[cd] %@) OR (note CONTAINS[cd] %@)",
                              argumentArray: Array(repeating: "Doe" as NSString, count: 14))
        #expect(format(7, "Doe") == all.predicateFormat)
        #expect(format(100, "Doe") == nil)
        #expect(format(42, "Doe") == nil)
        #expect(format(1, "") == nil)
        #expect(format(1, nil) == nil)
        #expect(StudySearchRules.field(searchType: 11, searchString: "x") == .seriesDescription)
        #expect(StudySearchRules.field(searchType: 11, searchString: "") == nil)
    }

    @Test func matchingIgnoresCaseAndDiacritics() {
        let predicate = StudySearchRules.filterPredicate(searchString: "localiz", searchType: 4, namePredicate: name)
        #expect(predicate?.evaluate(with: ["studyName": "LOCALÍZADOR"]) == true)
        #expect(predicate?.evaluate(with: ["studyName": "Axial"]) == false)
    }

    @Test func hiddenSearchText() {
        #expect(StudySearchRules.hidesSearchText(searchType: 0, hidePatientName: true))
        #expect(StudySearchRules.hidesSearchText(searchType: 0, hidePatientName: false) == false)
        #expect(StudySearchRules.hidesSearchText(searchType: 7, hidePatientName: true) == false)
    }
}
