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

@Suite struct StudyMetadataCSVTests {

    @Test func fieldsAreQuotedAsRFC4180Says() {
        #expect(StudyMetadataCSV.escaped("Thorax") == "Thorax")
        #expect(StudyMetadataCSV.escaped("Thorax, with contrast") == "\"Thorax, with contrast\"")
        #expect(StudyMetadataCSV.escaped("he said \"twice\"") == "\"he said \"\"twice\"\"\"")
        #expect(StudyMetadataCSV.escaped("one\rtwo") == "\"one\rtwo\"")
        #expect(StudyMetadataCSV.escaped("one\ntwo") == "\"one\ntwo\"")
        #expect(StudyMetadataCSV.escaped(nil) == "")
        // A tab does not have to be quoted in a CSV.
        #expect(StudyMetadataCSV.escaped("Hospital\tof Tabs") == "Hospital\tof Tabs")
    }

    @Test func rowsAreCRLFSeparatedAndTheFileEndsWithOne() {
        #expect(StudyMetadataCSV.csv(fromRows: [["a", "b"], ["c,d", "e"]]) == "a,b\r\n\"c,d\",e\r\n")
        #expect(StudyMetadataCSV.csv(fromRows: []) == "")
    }

    @Test func theDataIsUTF8WithAByteOrderMark() {
        let data = StudyMetadataCSV.data(forCSV: "Grüße,グリュース\r\n")
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(String(data: data.dropFirst(3), encoding: .utf8) == "Grüße,グリュース\r\n")
    }

    @Test func anAbsentFieldIsAnEmptyCellAndAMention() {
        let columns = ["PatientName", "AccessionNumber", "InstitutionName"]
        let row = StudyMetadataCSV.row(columns: columns, values: ["PatientName": "Grüße^Jörg", "AccessionNumber": ""])
        #expect(row == ["Grüße^Jörg", "", "", "InstitutionName"])
        #expect(StudyMetadataCSV.headerRow(columns: columns) == columns + [StudyMetadataCSV.missingHeader])
        #expect(StudyMetadataCSV.row(columns: ["PatientID"], values: ["PatientID": "A"]).last == "")
    }

    @Test func dicomPaddingAndMultipleValuesAreCleaned() {
        #expect(StudyMetadataCSV.cleaned("SMITH^JOHN ") == "SMITH^JOHN")
        #expect(StudyMetadataCSV.cleaned("CT\\PT") == "CT; PT")
    }

    @Test func columnsAreReadOnePerLineEachOnce() {
        let specified = StudyMetadataCSV.columns(fromText: """
        PatientName
          (0010,0020)   # the identifier

        PatientName
        # a whole line of comment
        StudyDescription
        """)
        #expect(specified == ["PatientName", "(0010,0020)", "StudyDescription"])
        #expect(StudyMetadataCSV.columns(fromText: "").isEmpty)
        #expect(StudyMetadataCSV.suggestedColumns.contains("PatientID"))
    }

    @Test func theEditorStartsFromTheStoredColumnsOrTheSuggestedOnes() {
        #expect(StudyMetadataCSV.editableColumns(stored: nil) == StudyMetadataCSV.suggestedColumns.joined(separator: "\n"))
        #expect(StudyMetadataCSV.editableColumns(stored: "") == StudyMetadataCSV.suggestedColumns.joined(separator: "\n"))
        #expect(StudyMetadataCSV.editableColumns(stored: "PatientID") == "PatientID")
    }

    @Test func aStudySelectedWithItsSeriesIsOneRow() {
        #expect(StudyMetadataCSV.firstOccurrences(["s1", "s2", "s1", "s3", "s2"]) == ["s1", "s2", "s3"])
        let table = StudyMetadataCSV.table(columns: ["PatientID"], studies: [["PatientID": "A"], [:]])
        #expect(table == [["PatientID", "Missing"], ["A", ""], ["", "PatientID"]])
    }

    @Test func theDatabaseListIsTabSeparatedWithAHeaderOnlyWhenAStudyIsListed() {
        #expect(StudyMetadataCSV.databaseList(header: ["Name", "Age"], rows: []) == "")
        #expect(StudyMetadataCSV.databaseList(header: ["Name", "Age"], rows: [["A", "36 y"]]) == "Name\tAge\rA\t36 y")
        // A cell that could not be read keeps its tab.
        #expect(StudyMetadataCSV.databaseList(header: ["Name", "Age"], rows: [["A", ""], ["", "6 d"]])
                == "Name\tAge\rA\t\r\t6 d")
        #expect(StudyMetadataCSV.databaseList(header: ["Age"], rows: [["36 y"]]) == "Age\r36 y")
    }
}
